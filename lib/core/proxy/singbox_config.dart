import 'dart:convert';

import '../models/models.dart';

/// sing-box 配置生成器（智能/全局两套路由规则）
class SingBoxConfigBuilder {
  SingBoxConfigBuilder._();

  /// 节点 → sing-box outbounds
  static List<Map<String, dynamic>> buildOutbounds(List<ProxyNode> nodes) {
    final outbounds = <Map<String, dynamic>>[];
    for (final n in nodes) {
      outbounds.add(_toOutbound(n));
    }
    outbounds.add({'type': 'direct', 'tag': 'direct'});
    outbounds.add({'type': 'block', 'tag': 'block'});
    return outbounds;
  }

  static Map<String, dynamic> _toOutbound(ProxyNode n) {
    // 类型归一化（Clash 名 → sing-box 名）
    final type = switch (n.type) {
      'ss' => 'shadowsocks',
      'ssr' => 'shadowsocksr',
      'vless' => 'vless',
      'vmess' => 'vmess',
      'trojan' => 'trojan',
      'hysteria2' => 'hysteria2',
      'tuic' => 'tuic',
      'anytls' => 'anytls',
      'wireguard' => 'wireguard',
      _ => n.type,
    };
    final base = <String, dynamic>{
      'type': type,
      'tag': n.tag,
      'server': n.server,
      'server_port': n.port,
    };
    final raw = n.raw;
    final insecure = raw['skip-cert-verify'] == true;
    final sni = n.sni ?? raw['servername']?.toString();

    Map<String, dynamic> tls({bool withReality = false}) {
      final t = <String, dynamic>{
        'enabled': n.tls != false,
        'server_name': sni ?? n.server,
        'insecure': insecure,
      };
      final fingerprint = raw['client-fingerprint']?.toString();
      if (fingerprint != null && fingerprint.isNotEmpty) {
        t['utls'] = {'enabled': true, 'fingerprint': fingerprint};
      }
      if (withReality) {
        final ro = raw['reality-opts'];
        if (ro is Map) {
          t['reality'] = {
            'enabled': true,
            'public_key': ro['public-key']?.toString() ?? '',
            'short_id': ro['short-id']?.toString() ?? '',
          };
        }
      }
      return t;
    }

    switch (n.type) {
      case 'vless':
        base['uuid'] = n.uuid ?? '';
        final flow = n.flow ?? raw['flow']?.toString();
        if (flow != null && flow.isNotEmpty) base['flow'] = flow;
        base['tls'] = tls(withReality: raw['reality-opts'] is Map);
        _applyTransport(base, n);
      case 'vmess':
        base['uuid'] = n.uuid ?? '';
        base['security'] = (n.cipher?.isNotEmpty ?? false) && n.cipher != 'auto' ? n.cipher! : 'auto';
        final alterId = raw['alterId'];
        if (alterId is num && alterId > 0) base['alter_id'] = alterId.toInt();
        base['tls'] = tls();
        _applyTransport(base, n);
      case 'trojan':
        base['password'] = n.password ?? '';
        base['tls'] = tls();
        _applyTransport(base, n);
      case 'shadowsocks':
      case 'ss':
        base['method'] = n.cipher ?? 'aes-128-gcm';
        base['password'] = n.password ?? '';
        final obfs = raw['obfs']?.toString();
        final obfsPwd = raw['obfs-password']?.toString();
        if (obfs != null && obfs.isNotEmpty) {
          base['plugin'] = obfs == 'http' ? 'obfs-local' : obfs;
          base['plugin_opts'] = 'obfs=$obfs${obfsPwd != null ? ';obfs-host=$obfsPwd' : ''}';
        }
      case 'hysteria2':
        base['password'] = n.password ?? '';
        base['tls'] = tls();
      case 'tuic':
        base['uuid'] = n.uuid ?? '';
        base['password'] = n.password ?? '';
        base['congestion_control'] = raw['congestion-controller']?.toString() ?? 'cubic';
        final relay = raw['udp-relay-mode']?.toString() ?? raw['udp_relay_mode']?.toString();
        if (relay != null && relay.isNotEmpty) base['udp_relay_mode'] = relay;
        final alpn = raw['alpn'];
        base['tls'] = tls();
        if (alpn is List && alpn.isNotEmpty) {
          (base['tls'] as Map<String, dynamic>)['alpn'] = alpn.map((e) => e.toString()).toList();
        }
      case 'anytls':
        base['password'] = n.password ?? '';
        base['tls'] = tls();
      case 'wireguard':
        base['private_key'] = raw['private-key'] ?? '';
      case 'shadowsocksr':
        base['method'] = n.cipher ?? 'aes-128-cfb';
        base['password'] = n.password ?? '';
        base['obfs'] = raw['obfs']?.toString() ?? 'plain';
        base['obfs_param'] = raw['obfs-param']?.toString() ?? '';
        base['protocol'] = raw['protocol']?.toString() ?? 'origin';
        base['protocol_param'] = raw['protocol-param']?.toString() ?? '';
    }
    return base;
  }

  static void _applyTransport(Map<String, dynamic> base, ProxyNode n) {
    final network = n.network ?? 'tcp';
    if (network == 'ws') {
      final headers = <String, dynamic>{};
      if (n.host != null && n.host!.isNotEmpty) headers['Host'] = n.host;
      base['transport'] = {
        'type': 'ws',
        'path': n.wsPath ?? '/',
        if (headers.isNotEmpty) 'headers': headers,
      };
    } else if (network == 'grpc') {
      base['transport'] = {'type': 'grpc', 'service_name': n.wsPath ?? ''};
    }
  }

  /// 生成完整配置
  /// [tunMode] 'auto' = TUN + 系统代理双通道 / 'force' = 仅 TUN / 'off' = 仅系统代理
  /// [bypassLan] true = 局域网流量直连（默认）
  /// [ruleSetDir] 本地规则集目录（内置 geoip/geosite .srs 的落盘路径）；
  ///              为空时回退远程地址（开发/降级用）
  static Map<String, dynamic> build({
    required List<ProxyNode> nodes,
    required String selectedTag,
    required bool smartMode,
    String dns = '223.5.5.5',
    String tunMode = 'auto',
    bool bypassLan = true,
    String tunStack = 'system', // 桌面端 system；Android 需 gvisor
    String? ruleSetDir,
  }) {
    final initialMode = smartMode ? 'Rule' : 'Global';
    final outbounds = buildOutbounds(nodes);
    // selector：包含全部节点 → 支持 clash-api 热切换到任意节点
    outbounds.insert(0, {
      'type': 'selector',
      'tag': 'select',
      'outbounds': [for (final n in nodes) n.tag, 'direct'],
      'default': nodes.any((n) => n.tag == selectedTag) ? selectedTag : (nodes.isNotEmpty ? nodes.first.tag : 'direct'),
    });
    // 智能模式规则集：优先用内置本地文件（随安装包分发，不受网络墙影响）；
    // ruleSetDir 为空时回退远程（开发环境未内置规则的情况）
    Map<String, dynamic> ruleSet(String tag, String file, String remoteUrl) {
      if (ruleSetDir != null) {
        return {
          'tag': tag,
          'type': 'local',
          'format': 'binary',
          'path': '$ruleSetDir/$file',
        };
      }
      return {
        'tag': tag,
        'type': 'remote',
        'format': 'binary',
        'url': remoteUrl,
        'download_detour': 'direct',
      };
    }

    final ruleSets = <Map<String, dynamic>>[
      ruleSet('geoip-cn', 'geoip-cn.srs',
          'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs'),
      ruleSet('geosite-cn', 'geosite-cn.srs',
          'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs'),
    ];
    // 回环地址始终直连（内核 API/本机服务必须可达）；
    // 局域网段按 bypassLan 决定是否直连
    final lanCidrs = <String>['127.0.0.0/8'];
    if (bypassLan) {
      lanCidrs.addAll(['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']);
    }
    // 智能/全局两套规则内置同一份配置，用 clash_mode 条件区分：
    // PATCH /configs {"mode":"Global"|"Rule"} 即可无缝切换（sing-box clash-api 唯一支持热更新的字段）
    final rules = <Map<String, dynamic>>[
      // 全局模式：除本地外全部走代理
      {'clash_mode': 'Global', 'ip_cidr': lanCidrs, 'outbound': 'direct'},
      {'clash_mode': 'Global', 'action': 'route', 'outbound': 'select'},
      // 智能模式（Rule）：国内直连 + UDP 走代理
      {'clash_mode': 'Rule', 'rule_set': ['geoip-cn'], 'outbound': 'direct'},
      {'clash_mode': 'Rule', 'rule_set': ['geosite-cn'], 'outbound': 'direct'},
      {'clash_mode': 'Rule', 'ip_cidr': lanCidrs, 'outbound': 'direct'},
      {'clash_mode': 'Rule', 'network': ['udp'], 'outbound': 'select'},
    ];
    return {
      // 元数据：告知 ProxyCoreCli 是否需要管理系统代理
      '_tunMode': tunMode,
      // 生产日志 warn：减少磁盘与 CPU 开销（调试时改 info）
      'log': {'level': 'warn', 'timestamp': true},
      // sing-box 1.14：DNS 服务器用 type+server 结构（address 字段已移除）
      'dns': {
        'servers': [
          {'type': 'udp', 'server': dns, 'tag': 'dns-main'},
          {'type': 'local', 'tag': 'dns-fallback'},
        ],
        'final': 'dns-main',
      },
      'inbounds': [
        // 设置 → TUN 虚拟网卡：off=仅系统代理 / force=仅 TUN / auto=双通道
        // 系统代理由 app 全权管理（SystemProxyManager：连接时设置、断开时恢复）。
        // 不启用 sing-box 的 set_system_proxy，避免双重管理互相覆盖
        // （sing-box 先设、app 再把 sing-box 的代理误记为原始状态）。
        if (tunMode != 'force')
          {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': 2080},
        if (tunMode != 'off')
          {
            'type': 'tun', 'tag': 'tun-in',
            // sing-box 1.12+：旧 inet4_address(字符串)已移除，改用 address(数组)。
            // 旧字段会导致内核拒绝启动：「legacy tun address fields ... removed
            // in sing-box 1.12.0」(Android 走 TUN 必现，桌面 tunMode=off 不触发)。
            'address': ['172.19.0.1/30'],
            'auto_route': true, 'strict_route': false, 'stack': tunStack,
          },
      ],
      'outbounds': outbounds,
      'route': {
        'rule_set': ruleSets,
        'rules': rules,
        'final': 'select',
        // sing-box 1.12+：出站域名解析走 DNS 服务器（否则启动报错）
        'default_domain_resolver': {'server': 'dns-main'},
      },
      'experimental': {
        'clash_api': {
          'external_controller': '127.0.0.1:9090',
          'external_ui': '',
          'secret': '',
          'default_mode': initialMode,
        },
      },
    };
  }

  /// 序列化（写入配置文件用）
  static String encode(Map<String, dynamic> cfg) => jsonEncode(cfg);
}
