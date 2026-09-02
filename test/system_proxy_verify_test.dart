// 临时验证：SystemProxyManager 在 macOS 上真实设置/恢复系统代理
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/proxy/system_proxy.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('macOS 系统代理：apply 设置 → restore 恢复', () async {
    if (!Platform.isMacOS) {
      markTestSkipped('仅 macOS 验证');
      return;
    }
    // 记录当前状态（scutil --proxy 检查）

    // 1) 设置系统代理
    await SystemProxyManager.apply(port: 2080);
    final applied =
        (await Process.run('scutil', ['--proxy'])).stdout as String;
    expect(applied.contains('HTTPEnable : 1'), isTrue,
        reason: 'HTTP 代理应已启用');
    expect(applied.contains('HTTPProxy : 127.0.0.1'), isTrue);
    expect(applied.contains('HTTPPort : 2080'), isTrue,
        reason: '代理端口应为 2080');

    // 2) 幂等：再次 apply 不报错
    await SystemProxyManager.apply(port: 2080);

    // 3) 恢复系统代理
    await SystemProxyManager.restore();
    final restored =
        (await Process.run('scutil', ['--proxy'])).stdout as String;
    expect(restored.contains('HTTPEnable : 0'), isTrue,
        reason: '代理应已关闭（恢复原状）');
    expect(restored.contains('HTTPSEnable : 0'), isTrue);
    expect(restored.contains('SOCKSEnable : 0'), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
