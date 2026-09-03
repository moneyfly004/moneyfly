// 回归：系统代理保活。核心验证「代理被外部关掉后，ensureApplied 能强制重开」
// —— 修复前的 bug：_applied 仍为 true 时 _applyNow 幂等 return，导致检测到掉了却修不回，
// 表现为「软件显示已连接，但 Windows/macOS 系统代理已被关闭且不再恢复」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/proxy/system_proxy.dart';

Future<String> _scutil() async =>
    (await Process.run('scutil', ['--proxy'])).stdout as String;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('保活：代理被外部关闭后 ensureApplied 强制重新开启', () async {
    if (!Platform.isMacOS) {
      markTestSkipped('仅 macOS 可真实验证系统代理保活');
      return;
    }
    try {
      // 1) 连接：设置系统代理
      await SystemProxyManager.apply(port: 2080);
      expect(SystemProxyManager.isApplied, isTrue);
      var s = await _scutil();
      expect(s.contains('HTTPEnable : 1'), isTrue, reason: 'apply 后应开启\n$s');
      expect(s.contains('HTTPPort : 2080'), isTrue);

      // 2) 模拟「系统/外部把代理关掉」——绕过 manager 直接关闭所有服务代理，
      //    但 manager 内部状态仍是 isApplied=true（正是触发 bug 的前置条件）。
      final services = (await Process.run(
              'networksetup', ['-listallnetworkservices']))
          .stdout as String;
      for (final svc in services
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && !e.startsWith('*') && !e.contains('denotes'))) {
        for (final kind in ['web', 'secureweb', 'socksfirewall']) {
          await Process.run('networksetup', ['-set${kind}proxystate', svc, 'off']);
        }
      }
      s = await _scutil();
      expect(s.contains('HTTPEnable : 0'), isTrue,
          reason: '前置：代理已被外部关闭\n$s');
      expect(SystemProxyManager.isApplied, isTrue,
          reason: 'manager 仍以为处于已应用态（bug 触发前提）');

      // 3) 保活巡检：必须检测到掉线并强制重开（修复点）
      await SystemProxyManager.ensureApplied(port: 2080);
      s = await _scutil();
      expect(s.contains('HTTPEnable : 1'), isTrue,
          reason: 'ensureApplied 应把被关掉的代理重新开启（保活核心）\n$s');
      expect(s.contains('HTTPPort : 2080'), isTrue);
    } finally {
      await SystemProxyManager.restore();
    }
    // 4) 断开：恢复到原始（关闭）状态
    final after = await _scutil();
    expect(after.contains('HTTPEnable : 0'), isTrue,
        reason: 'restore 后应回到关闭\n$after');
    expect(SystemProxyManager.isApplied, isFalse);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('保活 reassert 不破坏原始配置捕获：restore 仍回到原始关闭态', () async {
    if (!Platform.isMacOS) {
      markTestSkipped('仅 macOS');
      return;
    }
    try {
      await SystemProxyManager.apply(port: 2080);
      // 连续多次 reassert（模拟多轮保活），不应把「自己写入的值」误存为原始配置
      await SystemProxyManager.ensureApplied(port: 2080);
      await SystemProxyManager.ensureApplied(port: 2080);
    } finally {
      await SystemProxyManager.restore();
    }
    final after = await _scutil();
    expect(after.contains('HTTPEnable : 0'), isTrue,
        reason: '多轮保活后 restore 仍应回到原始关闭态\n$after');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
