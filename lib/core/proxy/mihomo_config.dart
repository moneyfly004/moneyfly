import 'dart:math';

import '../models/models.dart';

/// mihomo (Clash.Meta) 配置生成器。
///
/// mihomo 原生读 Clash YAML，订阅解析出的节点 raw（Clash map）直接可用，
/// SSR/VMess/VLESS/Trojan/Hysteria2/TUIC/AnyTLS/WireGuard 等协议全部由内核原生支持。
///
/// 路由设计：
/// - 智能模式（rule）：本地/局域网直连 + 国内(GEOSITE/GEOIP cn)直连 + 其余走代理
/// - 全局模式（global）：mihomo 内核 mode=global 时全部流量走内置 GLOBAL 组，
///   由 Clash API PATCH /configs 热切换，不断网。
/// - 模式/节点热切换全部走 Clash API（external-controller），
///   切节点时 select 组管智能模式、GLOBAL 组管全局模式。
class MihomoConfigBuilder {
  MihomoConfigBuilder._();

  static String generateSecret() {
    final rng = Random.secure();
    return List.generate(
        16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  /// 生成完整 mihomo 配置（Map 形式，由调用方序列化为 YAML 写入文件）。
  ///
  /// [nodes] 订阅解析出的节点（raw 为 Clash YAML 原始 map）
  /// [selectedTag] 当前选中节点的 name（select 组默认项）
  /// [smartMode] true=Rule 智能分流 / false=Global 全局代理
  /// [tunMode] 'auto'=TUN+系统代理 / 'force'=仅 TUN / 'off'=仅系统代理
  /// [geoReady] 离线 geo 数据(country.mmdb/geosite.dat)是否已就位；
  ///            缺失时智能模式降级为「全部走代理」，避免内核起不来
  static Map<String, dynamic> build({
    required List<ProxyNode> nodes,
    required String selectedTag,
    required bool smartMode,
    String dns = '223.5.5.5',
    String tunMode = 'off',
    String logLevel = 'warning',
    /// DNS 模式：auto / fake-ip / redir-host
    String dnsMode = 'auto',
    bool bypassLan = true,
    int localPort = 2080,
    int clashApiPort = 9090,
    bool geoReady = true,
    String? clashApiSecret,
    /// TUN 栈（Android 机型兼容性切换；桌面 TUN 场景也可用）
    String tunStack = 'gvisor',
    /// 用户自定义直连名单（域名后缀；命中 DIRECT，优先级最高）
    List<String> bypassDomains = const [],
  }) {
    final secret = clashApiSecret ?? generateSecret();
    final mode = smartMode ? 'rule' : 'global';
    final isTun = tunMode != 'off';
    // fake-ip 生效条件：显式选择，或 auto 且走 TUN（桌面 auto 保持传统解析）
    final useFakeIp =
        dnsMode == 'fake-ip' || (dnsMode != 'redir-host' && isTun);

    // 过滤掉面板伪节点（📢官网/⏰到期 等信息节点，server=baidu.com 等）
    final validNodes =
        nodes.where((n) => n.server.isNotEmpty && n.port > 0).toList();
    // 去重（同名节点 mihomo 会静默覆盖，App 侧依赖 tag 唯一做测速/切换）
    final seen = <String>{};
    final proxies = <Map<String, dynamic>>[];
    for (final n in validNodes) {
      if (!seen.add(n.tag)) continue;
      // raw 以订阅解析为准；关键字段缺失（如测试构造/解析遗漏）时用
      // ProxyNode 字段兜底，保证内核能加载
      // （mihomo 对缺必填字段的节点直接报错：missing type / unset fields）
      final m = Map<String, dynamic>.from(n.raw);
      m.putIfAbsent('name', () => n.tag);
      m.putIfAbsent('type', () => n.type);
      m.putIfAbsent('server', () => n.server);
      m.putIfAbsent('port', () => n.port);
      m.putIfAbsent('uuid', () => n.uuid ?? '');
      m.putIfAbsent('password', () => n.password ?? '');
      m.putIfAbsent('cipher', () => n.cipher ?? '');
      final sni = n.sni;
      if (sni != null && sni.isNotEmpty) {
        m.putIfAbsent('servername', () => sni);
      }
      // 节点显式声明了 TLS（如 vless+tls），raw 缺失时补上，避免裸连 443
      if (n.tls == true && m['tls'] == null) {
        m['tls'] = true;
      }
      proxies.add(m);
    }
    final names = [for (final n in validNodes) n.tag];

    // select 组默认选中项放列表首位 —— mihomo 的 select 组启动时选中
    // proxies 列表第一项（无 YAML 指定选中的字段），保证重启后线路不丢
    final defaultNode =
        names.contains(selectedTag) ? selectedTag : (names.isNotEmpty ? names.first : null);
    final selectMembers = <String>[
      ?defaultNode,
      for (final n in names)
        if (n != defaultNode) n,
      'DIRECT',
    ];
    if (selectMembers.isEmpty) {
      // 无任何可用节点：仍给一个可解析的组，内核可启动（连接层会拦空节点）
      selectMembers.add('DIRECT');
    }

    // 规则列表（mihomo 首条匹配即停）
    final rules = <String>[
      // 用户自定义「直连名单」：优先级最高，名单内域名不走代理
      for (final d in bypassDomains) 'DOMAIN-SUFFIX,$d,DIRECT',
      // 回环地址永远直连（内核 API / 本机服务必须可达）
      'IP-CIDR,127.0.0.0/8,DIRECT',
      // 局域网按设置直连
      if (bypassLan) ...[
        'IP-CIDR,10.0.0.0/8,DIRECT',
        'IP-CIDR,172.16.0.0/12,DIRECT',
        'IP-CIDR,192.168.0.0/16,DIRECT',
      ],
      // 智能模式：国内直连（离线 country.mmdb / geosite.dat；缺失则降级全代理）
      if (geoReady) ...[
        'GEOSITE,cn,DIRECT',
        'GEOIP,CN,DIRECT',
      ],
      // 其余走代理（select 组，App 通过 Clash API 热切换选中）
      'MATCH,select',
    ];

    final cfg = <String, dynamic>{
      // ===== 元数据（ProxyCore 读取后剥离，不写入配置文件）=====
      '_tunMode': tunMode,
      '_localPort': localPort,
      '_clashApiPort': clashApiPort,
      '_clashApiSecret': secret,

      // ===== mihomo 基础 =====
      // 本机 mixed 入站（HTTP + SOCKS5 同一端口，系统代理指向它）
      'mixed-port': localPort,
      // Clash API 管理通道（切模式/切节点/测速/流量统计全部走这里）
      'external-controller': '127.0.0.1:$clashApiPort',
      'secret': secret,
      // 智能 = rule；全局 = global（PATCH /configs 热切换）
      'mode': mode,
      'log-level': logLevel,
      'ipv6': false,
      'allow-lan': false,
      // 入站连接不查进程（省资源；find-process-mode 需管理员权限）
      'find-process-mode': 'off',
      // 统一延迟计算口径（测速 UI 与内核一致）
      'unified-delay': true,
      'tcp-concurrent': false,

      // ===== DNS =====
      // 桌面（系统代理/无 TUN）：内核内部解析用于 GEOSITE/GEOIP 规则匹配；
      // 不 listen（避免与本地 53/1053 冲突），不启用 fake-ip。
      // Android(TUN)：enhanced-mode fake-ip，域名路由防泄漏。
      //
      // 注意：不配置 fallback 到 8.8.8.8/1.1.1.1 —— 国内网络直连被墙，
      // 依赖 fallback 的解析会超时（实测会让 ssr 等「本地解析型」链路
      // 的 delay/建连全部失败）；nameserver 单源即可，规则走域名直传。
      //
      // DNS 模式（dnsMode）：
      //   auto      默认 —— TUN 用 fake-ip；桌面不写 enhanced-mode
      //             （mihomo 默认 redir-host 传统解析，行为与旧版一致）
      //   fake-ip   全端 fake-ip（域名映射 198.18.x.x，TUN/防泄漏场景推荐）
      //   redir-host 全端传统模式（域名真实解析后直连）
      'dns': {
        'enable': true,
        if (useFakeIp) ...{
          'enhanced-mode': 'fake-ip',
          'fake-ip-range': '198.18.0.1/16',
          'fake-ip-filter': [
            // 本地/内网域名不做 fake-ip
            '*.local',
            'localhost.ptlogin2.qq.com',
          ],
        } else if (dnsMode == 'redir-host')
          'enhanced-mode': 'redir-host',
        'nameserver': [dns],
      },

      // ===== 节点 =====
      'proxies': proxies,

      // ===== 代理组 =====
      // select：智能模式路由终点（规则 MATCH,select）。含 DIRECT 备用。
      'proxy-groups': [
        {
          'name': 'select',
          'type': 'select',
          'proxies': selectMembers,
        },
        // GLOBAL 组由内核内置（全部节点 + DIRECT），无需在 YAML 声明；
        // 全局模式(mode=global)时流量自动走 GLOBAL，切节点用 PUT /proxies/GLOBAL
      ],

      // ===== 规则 =====
      'rules': rules,
    };

    // ===== TUN（仅 Android / 显式开启时）=====
    // file-descriptor 由原生层在启动时注入（VpnService fd），不写死。
    // auto-route=false：路由与地址由原生 VpnService 全量下发，非 root 无需改表。
    if (isTun) {
      cfg['tun'] = {
        'enable': true,
        'stack': tunStack,
        'auto-route': false,
        'auto-detect-interface': true,
        'dns-hijack': ['any:53'],
      };
    }

    return cfg;
  }

  /// 序列化为 YAML 字符串（mihomo 兼容子集）。
  ///
  /// 实现要点：
  /// - Map 顶层键为 `key: value`，嵌套 map/list 逐层缩进；
  /// - proxies/proxy-groups 等对象列表用 flow 风格 `- {k: v}` 紧凑输出；
  /// - 标量按 YAML 规则加引号（含特殊字符 / 数字外观 / 布尔外观等），
  ///   避免节点名里的 `: # , { }` 等破坏结构。
  static String encode(Map<String, dynamic> cfg) {
    final buf = StringBuffer();
    // 过滤 `_` 前缀的 app 元数据键（_localPort/_clashApiPort/_clashApiSecret/
    // _tunMode），防御性兜底：任何调用方直接 encode 都不会把它们写进 YAML
    // （ProxyCore 启动前仍会 remove 并读取这些值）
    final filtered = Map<String, dynamic>.fromEntries(
        cfg.entries.where((e) => !e.key.startsWith('_')));
    _writeYaml(buf, filtered, 0);
    return buf.toString();
  }

  static void _writeYaml(StringBuffer buf, dynamic value, int indent) {
    final prefix = '  ' * indent;
    if (value is Map) {
      for (final e in value.entries) {
        final k = e.key.toString();
        final v = e.value;
        if (v is Map || v is List) {
          buf.writeln('$prefix$k:');
          _writeYaml(buf, v, indent + 1);
        } else {
          buf.writeln('$prefix$k: ${_scalarToYaml(v)}');
        }
      }
    } else if (value is List) {
      for (final item in value) {
        if (item is Map) {
          // 紧凑 flow 风格（proxies 大量节点时体积小、易读）
          buf.writeln('$prefix- ${_flowMap(item)}');
        } else if (item is List) {
          buf.writeln('$prefix-');
          _writeYaml(buf, item, indent + 1);
        } else {
          buf.writeln('$prefix- ${_scalarToYaml(item)}');
        }
      }
    }
  }

  /// 标量值 → YAML（字符串按需加引号，数字/布尔原样）
  static String _scalarToYaml(dynamic v) {
    if (v == null) return 'null';
    if (v is bool) return v ? 'true' : 'false';
    if (v is num) return '$v';
    final s = v.toString();
    if (s.isEmpty) return '""';
    // YAML 特殊起始字符 / 结构字符 / 注释符 / 数字或布尔外观 → 必须引号
    const specialStart = '*&!%@`|>-#?{}[],';
    final looksLikeNumber = num.tryParse(s) != null;
    final looksLikeBool = s == 'true' || s == 'false' || s == 'yes' ||
        s == 'no' || s == 'null' || s == 'on' || s == 'off';
    if (specialStart.contains(s[0]) ||
        s.contains(':') ||
        s.contains('#') ||
        s.contains('"') ||
        s.contains("'") ||
        s.contains('\n') ||
        s.contains('{') ||
        s.contains('}') ||
        s.contains('[') ||
        s.contains(']') ||
        s.contains(',') ||
        s.startsWith(' ') ||
        s.endsWith(' ') ||
        s.endsWith(':') ||
        looksLikeNumber ||
        looksLikeBool) {
      return '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';
    }
    return s;
  }

  /// Map → flow 风格 {key: val, key: val}（用于 proxies 列表里的节点定义）
  static String _flowMap(Map m) {
    final parts = <String>[];
    for (final e in m.entries) {
      final k = e.key.toString();
      final v = e.value;
      if (v is Map) {
        parts.add('$k: ${_flowMap(v)}');
      } else if (v is List) {
        parts.add('$k: [${v.map(_scalarToYaml).join(', ')}]');
      } else {
        parts.add('$k: ${_scalarToYaml(v)}');
      }
    }
    return '{${parts.join(', ')}}';
  }
}
