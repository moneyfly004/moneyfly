import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/singbox_config.dart';

/// 临时：用真实节点生成 sing-box 配置（运维验证用）
void main() {
  test('生成真实配置', () async {
    if (!File('/tmp/mf_proxies.json').existsSync()) {
      markTestSkipped('真实节点文件不存在，跳过（常规 CI）');
      return;
    }
    final proxies =
        jsonDecode(File('/tmp/mf_proxies.json').readAsStringSync()) as List;
    final nodes = proxies
        .map((e) => ProxyNode.fromClashMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    expect(nodes.length, greaterThan(100));
    final sel = nodes.firstWhere((n) => n.type == 'vless', orElse: () => nodes.first);
    final cfg = SingBoxConfigBuilder.build(nodes: nodes, selectedTag: sel.tag, smartMode: true);
    final out = <String, dynamic>{
      ...cfg,
      // 无 root 环境下移除 TUN，仅保留本地 mixed 代理做连通性测试
      'inbounds': [cfg['inbounds']!.first],
    };
    File('/tmp/singbox_config.json').writeAsStringSync(jsonEncode(out));
    debugPrint('已生成 ${nodes.length} 节点配置，选中 ${sel.tag}');
  });

  // 回归：TUN inbound 必须用 sing-box 1.12+ 的 address(数组)，
  // 不能用已移除的 inet4_address(字符串) —— 否则 1.14 内核拒绝启动，
  // Android 走 TUN 必现「内核启动失败」（真机 vivo S9 实测发现）。
  test('TUN inbound 使用新版 address 数组（非 legacy inet4_address）', () {
    final node = ProxyNode(
      tag: 't', type: 'vless', server: '1.1.1.1', port: 443,
      uuid: '00000000-0000-0000-0000-000000000000',
      countryCode: 'HK', raw: const {},
    );
    // Android 场景：tunMode=auto → 必含 TUN inbound
    final cfg = SingBoxConfigBuilder.build(
      nodes: [node], selectedTag: 't', smartMode: true, tunMode: 'auto',
      tunStack: 'gvisor',
    );
    final inbounds = (cfg['inbounds'] as List).cast<Map>();
    final tun = inbounds.firstWhere((i) => i['type'] == 'tun');
    expect(tun.containsKey('inet4_address'), isFalse,
        reason: '不得使用已移除的 legacy 字段 inet4_address');
    expect(tun.containsKey('inet6_address'), isFalse);
    expect(tun['address'], isA<List>(),
        reason: 'TUN 地址须为 address 数组（sing-box 1.12+）');
    expect((tun['address'] as List), contains('172.19.0.1/30'));
  });

  // 回归：本地 mixed 入站端口与 Clash API 端口都可配置（设置页），
  // 默认 2080 / 9090；两者以元数据 _localPort / _clashApiPort 下发给内核适配器
  // （CLI/Android 启动前读取并剥离，不传给内核）。
  test('mixed/Clash API 端口可配置（默认 2080/9090，自定义生效）', () {
    final node = ProxyNode(
      tag: 't', type: 'vless', server: '1.1.1.1', port: 443,
      uuid: '00000000-0000-0000-0000-000000000000',
      countryCode: 'HK', raw: const {},
    );
    Map<String, dynamic> cfgOf({int localPort = 2080, int clashApiPort = 9090}) =>
        SingBoxConfigBuilder.build(
          nodes: [node],
          selectedTag: 't',
          smartMode: true,
          tunMode: 'auto',
          tunStack: 'gvisor',
          localPort: localPort,
          clashApiPort: clashApiPort,
        );
    Map mixedOf(Map<String, dynamic> cfg) =>
        (cfg['inbounds'] as List).cast<Map>().firstWhere((i) => i['type'] == 'mixed');
    Map clashApiOf(Map<String, dynamic> cfg) =>
        (cfg['experimental']!['clash_api'] as Map).cast<String, dynamic>();

    // 默认值保持兼容
    expect(mixedOf(cfgOf())['listen_port'], 2080);
    expect(clashApiOf(cfgOf())['external_controller'], '127.0.0.1:9090');
    // 自定义端口生效 + 元数据同步下发
    final cfg = cfgOf(localPort: 10809, clashApiPort: 19090);
    expect(mixedOf(cfg)['listen_port'], 10809);
    expect(clashApiOf(cfg)['external_controller'], '127.0.0.1:19090');
    expect(cfg['_localPort'], 10809);
    expect(cfg['_clashApiPort'], 19090);
  });

  // --- 协议覆盖测试 ---

  ProxyNode mkNode(String type, {Map<String, dynamic> raw = const {}}) =>
      ProxyNode(tag: '$type-1', type: type, server: '1.2.3.4', port: 443,
        uuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        password: 'pass123', cipher: 'aes-128-gcm',
        tls: true, sni: 'sni.example.com', countryCode: 'HK',
        network: null, wsPath: null, host: null, flow: null, raw: raw);

  Map<String, dynamic> buildSingle(ProxyNode n) =>
      SingBoxConfigBuilder.build(nodes: [n], selectedTag: n.tag, smartMode: true);

  Map<String, dynamic> getOutbound(Map<String, dynamic> cfg, String tag) =>
      (cfg['outbounds'] as List).cast<Map<String, dynamic>>().firstWhere((o) => o['tag'] == tag);

  test('hysteria2 协议配置正确', () {
    final n = mkNode('hysteria2');
    final cfg = buildSingle(n);
    final ob = getOutbound(cfg, 'hysteria2-1');
    expect(ob['type'], 'hysteria2');
    expect(ob['password'], 'pass123');
    expect(ob['tls'], isA<Map>());
    expect(ob['tls']['enabled'], true);
    expect(ob['tls']['server_name'], 'sni.example.com');
  });

  test('tuic 协议配置正确', () {
    final n = mkNode('tuic', raw: {'congestion-controller': 'bbr', 'udp-relay-mode': 'quic'});
    final cfg = buildSingle(n);
    final ob = getOutbound(cfg, 'tuic-1');
    expect(ob['type'], 'tuic');
    expect(ob['uuid'], isNotEmpty);
    expect(ob['password'], 'pass123');
    expect(ob['congestion_control'], 'bbr');
    expect(ob['udp_relay_mode'], 'quic');
  });

  test('trojan + ws 传输', () {
    final n = ProxyNode(tag: 'trojan-ws', type: 'trojan', server: '1.2.3.4', port: 443,
      password: 'tpass', tls: true, sni: 'sni.com', network: 'ws', wsPath: '/path',
      host: 'ws.example.com', raw: const {});
    final cfg = buildSingle(n);
    final ob = getOutbound(cfg, 'trojan-ws');
    expect(ob['transport']['type'], 'ws');
    expect(ob['transport']['path'], '/path');
  });

  test('vless + reality', () {
    final n = mkNode('vless', raw: {
      'reality-opts': {'public-key': 'pk123', 'short-id': 'sid1'},
      'client-fingerprint': 'chrome',
    });
    final cfg = buildSingle(n);
    final ob = getOutbound(cfg, 'vless-1');
    expect(ob['tls']['reality']['enabled'], true);
    expect(ob['tls']['reality']['public_key'], 'pk123');
    expect(ob['tls']['utls']['fingerprint'], 'chrome');
  });

  test('shadowsocksr 协议配置正确', () {
    final n = mkNode('ssr', raw: {
      'obfs': 'http_simple', 'obfs-param': 'www.bing.com',
      'protocol': 'auth_aes128_md5', 'protocol-param': 'test',
    });
    final cfg = buildSingle(n);
    final ob = getOutbound(cfg, 'ssr-1');
    expect(ob['type'], 'shadowsocksr');
    expect(ob['obfs'], 'http_simple');
    expect(ob['protocol'], 'auth_aes128_md5');
  });

  test('vmess + http 传输层', () {
    final n = ProxyNode(tag: 'vmess-h2', type: 'vmess', server: '1.2.3.4', port: 443,
      uuid: 'uuid-1234', tls: true, sni: 'h2.com', network: 'http',
      wsPath: '/h2path', host: 'h2host.com', raw: const {});
    final cfg = buildSingle(n);
    final ob = getOutbound(cfg, 'vmess-h2');
    expect(ob['transport']['type'], 'http');
    expect(ob['transport']['path'], '/h2path');
    expect(ob['transport']['host'], contains('h2host.com'));
  });

  test('anytls 协议配置正确', () {
    final n = mkNode('anytls');
    final cfg = buildSingle(n);
    final ob = getOutbound(cfg, 'anytls-1');
    expect(ob['type'], 'anytls');
    expect(ob['password'], 'pass123');
    expect(ob['tls']['enabled'], true);
  });

  test('智能/全局模式路由规则正确', () {
    final n = mkNode('vless');
    final smart = SingBoxConfigBuilder.build(nodes: [n], selectedTag: n.tag, smartMode: true);
    final global = SingBoxConfigBuilder.build(nodes: [n], selectedTag: n.tag, smartMode: false);
    final smartApi = (smart['experimental']!['clash_api'] as Map);
    final globalApi = (global['experimental']!['clash_api'] as Map);
    expect(smartApi['default_mode'], 'Rule');
    expect(globalApi['default_mode'], 'Global');
    final rules = (smart['route']!['rules'] as List).cast<Map>();
    expect(rules.any((r) => r['clash_mode'] == 'Rule' && r['outbound'] == 'direct'), true);
    expect(rules.any((r) => r['clash_mode'] == 'Global' && r['outbound'] == 'select'), true);
  });

  test('Clash API secret 非空', () {
    final n = mkNode('vless');
    final cfg = buildSingle(n);
    final secret = (cfg['experimental']!['clash_api'] as Map)['secret'];
    expect(secret, isNotEmpty);
    expect(cfg['_clashApiSecret'], secret);
  });
}
