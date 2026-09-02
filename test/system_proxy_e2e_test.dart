// 端到端：真实内核 + 系统代理管理（macOS 上验证「连接改变系统代理、断开恢复」）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core_cli.dart';
import 'package:moneyfly/core/proxy/singbox_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final env = Platform.environment['MONEYFLY_SINGBOX'];
  final hasBinary = env != null && File(env).existsSync();
  final skip = hasBinary ? null : '未找到 sing-box 内核';

  test('端到端：连接设置系统代理 → 断开恢复', skip: skip, () async {
    if (!Platform.isMacOS) {
      markTestSkipped('仅 macOS 验证系统代理');
      return;
    }
    ProxyCoreCli.manageSystemProxy = true; // 本次测试真实管理系统代理
    final core = ProxyCoreCli();
    try {
      final node = ProxyNode(
        tag: '测试节点',
        type: 'vless',
        server: '127.0.0.1',
        port: 9,
        uuid: '00000000-0000-0000-0000-000000000000',
        countryCode: 'HK',
        raw: const {},
      );
      final cfg = SingBoxConfigBuilder.build(
        nodes: [node],
        selectedTag: '测试节点',
        smartMode: true,
        tunMode: 'off',
        ruleSetDir: ProxyCoreCli.workDir,
      );

      // 连接 → 系统代理应被设置
      await core.start(cfg);
      expect(core.isRunning, isTrue);
      await Future.delayed(const Duration(milliseconds: 800));
      final proxy = (await Process.run('scutil', ['--proxy'])).stdout as String;
      expect(proxy.contains('HTTPEnable : 1'), isTrue,
          reason: '连接后系统 HTTP 代理应启用\n$proxy');
      expect(proxy.contains('HTTPPort : 2080'), isTrue,
          reason: '代理端口应为 2080\n$proxy');

      // 断开 → 系统代理应恢复（关闭）
      await core.stop();
      await Future.delayed(const Duration(milliseconds: 800));
      final after = (await Process.run('scutil', ['--proxy'])).stdout as String;
      expect(after.contains('HTTPEnable : 0'), isTrue,
          reason: '断开后系统代理应恢复关闭\n$after');
      expect(after.contains('HTTPSEnable : 0'), isTrue);
      expect(after.contains('SOCKSEnable : 0'), isTrue);
    } finally {
      // 无论断言成败都确保内核停止 + 代理恢复，避免残留污染环境
      if (core.isRunning) {
        await core.stop();
      }
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
