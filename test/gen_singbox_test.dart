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

  // 回归：本地 mixed 入站端口可配置（设置页「本地代理端口」，默认 2080）。
  // 端口必须同时落在：mixed inbound listen_port + 顶层 _localPort 元数据
  // （ProxyCoreCli 据此管理系统代理指向；Android 启动前剥离）。
  test('mixed inbound 端口可配置（默认 2080，自定义生效）', () {
    final node = ProxyNode(
      tag: 't', type: 'vless', server: '1.1.1.1', port: 443,
      uuid: '00000000-0000-0000-0000-000000000000',
      countryCode: 'HK', raw: const {},
    );
    Map<String, dynamic> cfgOf(int port) => SingBoxConfigBuilder.build(
          nodes: [node],
          selectedTag: 't',
          smartMode: true,
          tunMode: 'auto',
          tunStack: 'gvisor',
          localPort: port,
        );
    Map mixedOf(Map<String, dynamic> cfg) =>
        (cfg['inbounds'] as List).cast<Map>().firstWhere((i) => i['type'] == 'mixed');

    expect(mixedOf(cfgOf(2080))['listen_port'], 2080); // 默认不变
    expect(mixedOf(cfgOf(10809))['listen_port'], 10809); // 自定义生效
    expect(cfgOf(10809)['_localPort'], 10809);
  });
}
