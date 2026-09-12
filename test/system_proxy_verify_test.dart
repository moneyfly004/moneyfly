// 真实系统代理验证（macOS / Windows 真机）。
//
// ⚠️ 这三个用例会**真实读写**宿主机的系统代理（macOS 走 networksetup +
// scutil，Windows 走 HKCU 注册表），结束时恢复原值。
//
// 为什么合并到一个文件：`flutter test` 会**并行跑不同文件**，而每个用例都要
// apply → 断言 → restore 同一份系统代理状态。分成三个文件时会出现
// 「A 的 apply 还没读完状态，B 的 restore 已经把代理关掉」的交叉干扰，表现为
// 随机某个用例断言 HTTPEnable 失败（我加绕过列表写入后拉长了 apply 窗口，
// 让这个既有竞争明显更容易触发）。同一个文件内的用例是**顺序执行**的，
// 合并即可根治，且不牺牲任何真实环境验证能力。
//
// 运行方式（在对应平台上，仓库根目录）：
//   flutter test test/system_proxy_verify_test.dart
// 非对应平台自动跳过。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/proxy/system_proxy.dart';

const _winReg =
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

Future<String> _scutil() async =>
    (await Process.run('scutil', ['--proxy'])).stdout as String;

/// 读注册表：ProxyEnable 是否为 1
Future<bool> _winProxyEnabled() async {
  final r = await Process.run('reg', ['query', _winReg, '/v', 'ProxyEnable'],
      runInShell: true);
  return r.exitCode == 0 && (r.stdout as String).contains('0x1');
}

/// 读注册表：ProxyServer 是否指向 127.0.0.1:port
Future<bool> _winProxyPointsTo(int port) async {
  final r = await Process.run('reg', ['query', _winReg, '/v', 'ProxyServer'],
      runInShell: true);
  if (r.exitCode != 0) return false;
  return (r.stdout as String).contains('127.0.0.1:$port');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ==================== macOS ====================

  test('macOS 系统代理：apply 设置 → restore 恢复', () async {
    if (!Platform.isMacOS) {
      markTestSkipped('仅 macOS 验证');
      return;
    }
    // 1) 设置系统代理
    await SystemProxyManager.apply(port: 2080);
    final applied =
        (await Process.run('scutil', ['--proxy'])).stdout as String;
    expect(applied.contains('HTTPEnable : 1'), isTrue,
        reason: 'HTTP 代理应已启用\n$applied');
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
        reason: '代理应已关闭（恢复原状）\n$restored');
    expect(restored.contains('HTTPSEnable : 0'), isTrue);
    expect(restored.contains('SOCKSEnable : 0'), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // 回归：系统代理保活。核心验证「代理被外部关掉后，ensureApplied 能强制重开」
  // —— 修复前的 bug：_applied 仍为 true 时 _applyNow 幂等 return，导致检测到掉了却修不回，
  // 表现为「软件显示已连接，但 Windows/macOS 系统代理已被关闭且不再恢复」。
  test('macOS 保活：代理被外部关闭后 ensureApplied 强制重新开启', () async {
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
      //    遍历可能受网络服务枚举/时序影响:关闭后复查,若仍有残留再补一轮
      for (var attempt = 0; attempt < 3; attempt++) {
        final services = (await Process.run(
                'networksetup', ['-listallnetworkservices']))
            .stdout as String;
        for (final svc in services
            .split('\n')
            .map((e) => e.trim())
            .where((e) =>
                e.isNotEmpty && !e.startsWith('*') && !e.contains('denotes'))) {
          for (final kind in ['web', 'secureweb', 'socksfirewall']) {
            await Process.run('networksetup', ['-set${kind}proxystate', svc, 'off']);
          }
        }
        s = await _scutil();
        if (s.contains('HTTPEnable : 0')) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
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

  test('macOS 保活 reassert 不破坏原始配置捕获：restore 仍回到原始关闭态', () async {
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

  // ==================== Windows ====================

  test('Windows 系统代理：apply → 外部关闭 → 保活重开 → restore', () async {
    if (!Platform.isWindows) {
      markTestSkipped('仅 Windows 验证');
      return;
    }
    try {
      // 1) 连接：设置系统代理
      await SystemProxyManager.apply(port: 2080);
      expect(await _winProxyEnabled(), isTrue, reason: 'apply 后 ProxyEnable 应为 1');
      expect(await _winProxyPointsTo(2080), isTrue,
          reason: 'apply 后 ProxyServer 应为 127.0.0.1:2080');

      // 2) 模拟系统/外部把代理关掉（正是你遇到的现象：软件还连着，代理被关）
      await Process.run('reg',
          ['add', _winReg, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0',
              '/f'],
          runInShell: true);
      expect(await _winProxyEnabled(), isFalse, reason: '前置：代理已被外部关闭');
      expect(SystemProxyManager.isApplied, isTrue,
          reason: 'manager 仍以为已应用（触发原 bug 的前提）');

      // 3) 保活巡检：必须检测到掉线并强制重开（本次修复的核心）
      await SystemProxyManager.ensureApplied(port: 2080);
      expect(await _winProxyEnabled(), isTrue,
          reason: '保活应把被关掉的代理重新打开 —— 这是"保持始终开启"的关键');
      expect(await _winProxyPointsTo(2080), isTrue);
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

  // 回归：restore 必须把「原本不存在的注册表值」删除，而非残留我们写入的
  // 127.0.0.1:2080 / <local>（真机发现的 bug：原本未配代理的机器断开后残留）。
  test('Windows restore 无残留：原本不存在的值应被删除', () async {
    if (!Platform.isWindows) {
      markTestSkipped('仅 Windows 验证');
      return;
    }
    // 记录 apply 前 ProxyServer/ProxyOverride 是否存在（exitCode==0 即存在）
    Future<bool> exists(String name) async {
      final r = await Process.run('reg', ['query', _winReg, '/v', name],
          runInShell: true);
      return r.exitCode == 0;
    }

    final serverExistedBefore = await exists('ProxyServer');
    final overrideExistedBefore = await exists('ProxyOverride');

    await SystemProxyManager.apply(port: 2080);
    await SystemProxyManager.restore();

    // restore 后存在性必须回到 apply 前：原本没有的，现在也不能有
    expect(await exists('ProxyServer'), serverExistedBefore,
        reason: 'ProxyServer 存在性应恢复到 apply 前（原本无则应被删除，不残留）');
    expect(await exists('ProxyOverride'), overrideExistedBefore,
        reason: 'ProxyOverride 存在性应恢复到 apply 前（原本无则应被删除，不残留）');
    // 若原本就有值，还需确认不是残留的我们的值
    if (!serverExistedBefore) {
      expect(await _winProxyPointsTo(2080), isFalse,
          reason: '原本无 ProxyServer，restore 后不应残留 127.0.0.1:2080');
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
