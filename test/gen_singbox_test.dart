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
}
