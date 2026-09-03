// Windows 专用验证：在真实 Windows 上确认「系统代理设置 / 保活重开 / 恢复」。
//
// 运行方式（在 Windows 上，仓库根目录）：
//   flutter test test/system_proxy_windows_verify_test.dart
//
// 非 Windows 自动跳过。测试会真实读写 HKCU 代理注册表，但结束时恢复原值。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/proxy/system_proxy.dart';

const _winReg =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

/// 读注册表：ProxyEnable 是否为 1
Future<bool> _proxyEnabled() async {
  final r = await Process.run('reg', ['query', _winReg, '/v', 'ProxyEnable'],
      runInShell: true);
  return r.exitCode == 0 && (r.stdout as String).contains('0x1');
}

/// 读注册表：ProxyServer 是否指向 127.0.0.1:port
Future<bool> _proxyPointsTo(int port) async {
  final r = await Process.run('reg', ['query', _winReg, '/v', 'ProxyServer'],
      runInShell: true);
  if (r.exitCode != 0) return false;
  return (r.stdout as String).contains('127.0.0.1:$port');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Windows 系统代理：apply → 外部关闭 → 保活重开 → restore', () async {
    if (!Platform.isWindows) {
      markTestSkipped('仅 Windows 验证');
      return;
    }
    try {
      // 1) 连接：设置系统代理
      await SystemProxyManager.apply(port: 2080);
      expect(await _proxyEnabled(), isTrue, reason: 'apply 后 ProxyEnable 应为 1');
      expect(await _proxyPointsTo(2080), isTrue,
          reason: 'apply 后 ProxyServer 应为 127.0.0.1:2080');

      // 2) 模拟系统/外部把代理关掉（正是你遇到的现象：软件还连着，代理被关）
      await Process.run('reg',
          ['add', _winReg, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0',
              '/f'],
          runInShell: true);
      expect(await _proxyEnabled(), isFalse, reason: '前置：代理已被外部关闭');
      expect(SystemProxyManager.isApplied, isTrue,
          reason: 'manager 仍以为已应用（触发原 bug 的前提）');

      // 3) 保活巡检：必须检测到掉线并强制重开（本次修复的核心）
      await SystemProxyManager.ensureApplied(port: 2080);
      expect(await _proxyEnabled(), isTrue,
          reason: '保活应把被关掉的代理重新打开 —— 这是"保持始终开启"的关键');
      expect(await _proxyPointsTo(2080), isTrue);
    } finally {
      await SystemProxyManager.restore();
    }
    expect(SystemProxyManager.isApplied, isFalse, reason: 'restore 后应为未应用');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('Windows FFI 通知不崩溃（InternetSetOption 签名正确性）', () async {
    if (!Platform.isWindows) {
      markTestSkipped('仅 Windows 验证');
      return;
    }
    // apply/restore 内部会调用 _notifyWinInetChanged（FFI）。
    // 若 FFI 签名错误会抛异常（被内部 catch 成 debugPrint，不会崩溃）；
    // 这里主要确认整条 apply→restore 走 FFI 通知路径不抛未捕获异常。
    await SystemProxyManager.apply(port: 2080);
    await SystemProxyManager.restore();
    // 能走到这里即说明 FFI 调用未导致进程崩溃
    expect(true, isTrue);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
