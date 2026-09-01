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
    final base = <String, dynamic>{
      'type': n.type,
      'tag': n.tag,
      'server': n.server,
      'server_port': n.port,
    };
    switch (n.type) {
      case 'vless':
        base['uuid'] = n.uuid ?? '';
        if (n.flow != null && n.flow!.isNotEmpty) base['flow'] = n.flow;
        if (n.tls == true) {
          base['tls'] = {'enabled': true, 'server_name': n.sni ?? n.server, 'insecure': false};
        }
        _applyTransport(base, n);
      case 'vmess':
        base['uuid'] = n.uuid ?? '';
        base['security'] = 'auto';
        if (n.tls == true) {
          base['tls'] = {'enabled': true, 'server_name': n.sni ?? n.server, 'insecure': false};
        }
        _applyTransport(base, n);
      case 'trojan':
        base['password'] = n.password ?? '';
        if (n.tls != false) {
          base['tls'] = {'enabled': true, 'server_name': n.sni ?? n.server, 'insecure': false};
        }
        _applyTransport(base, n);
      case 'shadowsocks':
      case 'ss':
        base['method'] = n.cipher ?? 'aes-128-gcm';
        base['password'] = n.password ?? '';
      case 'hysteria2':
      case 'tuic':
        base['password'] = n.password ?? '';
        if (n.sni != null) base['tls'] = {'enabled': true, 'server_name': n.sni};
      case 'wireguard':
        base['private_key'] = n.raw['private-key'] ?? '';
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
  static Map<String, dynamic> build({
    required List<ProxyNode> nodes,
    required String selectedTag,
    required bool smartMode,
    String dns = '223.5.5.5',
  }) {
    final outbounds = buildOutbounds(nodes);
    // selector：用户当前选中节点
    outbounds.insert(0, {
      'type': 'selector',
      'tag': 'select',
      'outbounds': [if (nodes.any((n) => n.tag == selectedTag)) selectedTag, if (nodes.isNotEmpty) nodes.first.tag, 'direct'],
    });
    final rules = <Map<String, dynamic>>[];
    if (smartMode) {
      rules.addAll([
        {'geoip': ['cn'], 'outbound': 'direct'},
        {'geosite': ['cn'], 'outbound': 'direct'},
        {'ip_cidr': ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'], 'outbound': 'direct'},
        {'network': 'udp', 'outbound': 'select'},
      ]);
    } else {
      rules.add({'ip_cidr': ['127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16'], 'outbound': 'direct'});
    }
    return {
      'log': {'level': 'info', 'timestamp': true},
      'dns': {'servers': [{'address': dns}]},
      'inbounds': [
        {'type': 'mixed', 'tag': 'mixed-in', 'listen': '127.0.0.1', 'listen_port': 2080, 'set_system_proxy': true},
        {'type': 'tun', 'tag': 'tun-in', 'auto_route': true, 'strict_route': false, 'stack': 'system'},
      ],
      'outbounds': outbounds,
      'route': {'rules': rules, 'final': 'select'},
      'experimental': {'clash_api': {'external_controller': '127.0.0.1:9090', 'external_ui': '', 'secret': ''}},
    };
  }

  /// 序列化（写入配置文件用）
  static String encode(Map<String, dynamic> cfg) => jsonEncode(cfg);
}
