import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 系统代理管理器（macOS / Windows / Android）
///
/// 职责：连接 VPN 时把系统代理指向本地 sing-box mixed 端口，
/// 断开/退出时恢复原代理配置。参考 Hiddify：app 自己管理系统代理，
/// 不依赖 sing-box 的 set_system_proxy（实测 sing-box CLI 被终止后
/// 不会恢复系统代理，导致残留）。
///
/// - macOS：`networksetup` 设置所有网络服务的 web/secure/socks 代理
/// - Windows：注册表 `HKCU\...\Internet Settings` 的 ProxyEnable/ProxyServer
/// - Android：不需要 —— VpnService + TUN 已接管全部流量（无系统代理概念）
///
/// 并发安全：apply / restore / ensureApplied 全部经过同一把互斥锁串行执行，
/// 避免「重连失败时的延迟 restore 与重连成功后的 apply 交错，
/// 导致内核已连接但系统代理被误关」的竞态（Windows 实测偶发）。
class SystemProxyManager {
  SystemProxyManager._();

  static const int defaultPort = 2080;

  // ---- 状态 ----
  static bool _applied = false;
  static int _port = defaultPort;

  /// 原始代理配置（用于恢复）。macOS：service 名 → 原状态；Windows：原 Enable/Server
  static final Map<String, dynamic> _original = {};

  /// 互斥锁：所有系统代理写操作串行执行（消除 apply/restore 竞态）
  static Future<void> _mutex = Future.value();

  static bool get isApplied => _applied;

  static bool get _isMacOS =>
      !kIsWeb && (Platform.isMacOS);
  static bool get _isWindows =>
      !kIsWeb && (Platform.isWindows);

  static Future<void> _withLock(Future<void> Function() action) async {
    final prev = _mutex;
    final done = Completer<void>();
    _mutex = done.future;
    await prev;
    try {
      await action();
    } finally {
      done.complete();
    }
  }

  /// 设置系统代理指向本地端口（幂等；与 restore/ensureApplied 互斥串行）
  static Future<void> apply({int port = defaultPort}) async {
    await _withLock(() => _applyNow(port));
  }

  /// 恢复系统代理到原始状态（仅断开/退出时调用；互斥串行）
  static Future<void> restore() async {
    await _withLock(_restoreNow);
  }

  /// 巡检保活：连接期间周期调用。若系统代理已被外部/系统关闭或改走，
  /// 立即重新指向本地端口 —— 保持「只要 VPN 连着，系统代理就一直开着」，
  /// 直到真正断开连接或退出软件。
  static Future<void> ensureApplied({int port = defaultPort}) async {
    await _withLock(() async {
      if (_applied && _port != port) {
        // 端口变了：按新端口重新应用
        _applied = false;
      }
      if (!_applied) {
        await _applyNow(port);
        return;
      }
      final ok = await _osProxyPointsTo(port);
      if (!ok) {
        // 被系统/外部关掉或改走 → 重新打开
        await _applyNow(port);
      }
    });
  }

  /// 实际执行「指向本地端口」（调用方需已持有互斥锁）
  static Future<void> _applyNow(int port) async {
    if (_applied && _port == port) return;
    _port = port;
    try {
      if (_isMacOS) {
        await _applyMacOS(port);
      } else if (_isWindows) {
        await _applyWindows(port);
        await _notifyWinInetChanged();
      }
      // Android：TUN 接管流量，无需系统代理
      _applied = true;
    } catch (e) {
      debugPrint('SystemProxyManager.apply 失败: $e');
    }
  }

  /// 实际执行「恢复原始状态」（调用方需已持有互斥锁）
  static Future<void> _restoreNow() async {
    if (!_applied) return;
    try {
      if (_isMacOS) {
        await _restoreMacOS();
      } else if (_isWindows) {
        await _restoreWindows();
        await _notifyWinInetChanged();
      }
      _applied = false;
    } catch (e) {
      debugPrint('SystemProxyManager.restore 失败: $e');
    }
  }

  /// 只读探测：当前系统代理是否仍指向本地端口（无副作用）
  static Future<bool> _osProxyPointsTo(int port) async {
    if (_isWindows) return _winProxyPointsTo(port);
    if (_isMacOS) return _macProxyPointsTo(port);
    return true; // Android 等无系统代理概念
  }

  // ---------------- 保活探测 ----------------

  static Future<bool> _winProxyPointsTo(int port) async {
    try {
      final enable = await Process.run(
          'reg', ['query', _winReg, '/v', 'ProxyEnable'], runInShell: true);
      if (enable.exitCode != 0 || !(enable.stdout as String).contains('0x1')) {
        return false;
      }
      final server = await Process.run(
          'reg', ['query', _winReg, '/v', 'ProxyServer'], runInShell: true);
      if (server.exitCode != 0) return false;
      final line = (server.stdout as String)
          .split('\n')
          .firstWhere((l) => l.contains('ProxyServer'), orElse: () => '');
      return line.contains('127.0.0.1:$port');
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _macProxyPointsTo(int port) async {
    final services = await _macServices();
    if (services.isEmpty) return true;
    for (final svc in services) {
      for (final kind in ['web', 'secureweb', 'socksfirewall']) {
        try {
          final r = await Process.run(
              'networksetup', ['-get${kind}proxy', svc]);
          final state = (r.stdout as String).trim();
          if (!_macEntryEnabledToPort(state, port)) return false;
        } catch (_) {
          return false;
        }
      }
    }
    return true;
  }

  /// macOS 单条代理状态：Enabled: Yes 且 127.0.0.1:port
  static bool _macEntryEnabledToPort(String state, int port) {
    if (!state.contains('Enabled: Yes')) return false;
    final server = _extractMacValue(state, 'Server:');
    final p = _extractMacValue(state, 'Port:');
    return server == '127.0.0.1' && p == '$port';
  }

  // ---------------- macOS ----------------
  static Future<List<String>> _macServices() async {
    final r = await Process.run('networksetup', ['-listallnetworkservices']);
    if (r.exitCode != 0) return const [];
    return (r.stdout as String)
        .split('\n')
        .map((s) => s.trim())
        .where((s) =>
            s.isNotEmpty &&
            !s.startsWith('*') && // 禁用服务
            !s.contains('denotes')) // 说明行
        .toList();
  }

  /// 判断某网络服务的代理是否指向「我们自己设置的端口」（残留检测）。
  /// 若残留（上次崩溃/强杀未恢复），记录原状态时视为「关闭」，
  /// restore 时恢复为关闭而非还原残留，避免代理永远清不掉。
  static bool _isSelfResidual(String state, int port) {
    final server = _extractMacValue(state, 'Server:');
    final p = _extractMacValue(state, 'Port:');
    return state.contains('Enabled: Yes') &&
        server == '127.0.0.1' &&
        p == '$port';
  }

  static Future<void> _applyMacOS(int port) async {
    final services = await _macServices();
    for (final svc in services) {
      // 保存原状态
      final orig = <String, String>{};
      for (final kind in ['web', 'secureweb', 'socksfirewall']) {
        final r = await Process.run('networksetup', ['-get${kind}proxy', svc]);
        var state = (r.stdout as String).trim();
        // 残留检测：指向我们自己的端口 → 视为原为关闭
        if (_isSelfResidual(state, port)) {
          state = 'Enabled: No';
        }
        orig[kind] = state;
      }
      _original[svc] = orig;

      // 设置代理：on + 127.0.0.1:port
      for (final kind in ['web', 'secureweb', 'socksfirewall']) {
        await Process.run(
            'networksetup', ['-set${kind}proxy', svc, '127.0.0.1', '$port']);
      }
    }
  }

  static Future<void> _restoreMacOS() async {
    final services = await _macServices();
    for (final svc in services) {
      final orig = _original[svc] as Map<String, String>?;
      for (final kind in ['web', 'secureweb', 'socksfirewall']) {
        final prev = orig?[kind] ?? '';
        final enabled = prev.contains('Enabled: Yes');
        final host = _extractMacValue(prev, 'Server:');
        final port = _extractMacValue(prev, 'Port:');
        if (enabled && host != null && port != null) {
          // 还原原代理
          await Process.run(
              'networksetup', ['-set${kind}proxy', svc, host, port]);
        } else {
          // 原为关闭 → 关掉
          await Process.run(
              'networksetup', ['-set${kind}proxystate', svc, 'off']);
        }
      }
      _original.remove(svc);
    }
  }

  static String? _extractMacValue(String text, String key) {
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.startsWith(key)) {
        return t.substring(key.length).trim();
      }
    }
    return null;
  }

  // ---------------- Windows ----------------
  static const _winReg =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  static Future<void> _applyWindows(int port) async {
    // 保存原值
    final enable = await Process.run(
        'reg', ['query', _winReg, '/v', 'ProxyEnable'], runInShell: true);
    _original['ProxyEnable'] =
        enable.exitCode == 0 ? (enable.stdout as String) : null;
    final server = await Process.run(
        'reg', ['query', _winReg, '/v', 'ProxyServer'], runInShell: true);
    _original['ProxyServer'] =
        server.exitCode == 0 ? (server.stdout as String) : null;

    await Process.run('reg',
        ['add', _winReg, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1', '/f'],
        runInShell: true);
    await Process.run('reg',
        ['add', _winReg, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d',
            '127.0.0.1:$port', '/f'],
        runInShell: true);
    await Process.run('reg',
        ['add', _winReg, '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d',
            '<local>', '/f'],
        runInShell: true);
  }

  static Future<void> _restoreWindows() async {
    final enable = _original['ProxyEnable'] as String?;
    if (enable != null && enable.contains('ProxyEnable')) {
      // 还原原值（含 ProxyEnable=0 或 1）
      await Process.run('reg', ['add', _winReg, '/v', 'ProxyEnable', '/t',
          'REG_DWORD', '/d', enable.contains('0x1') ? '1' : '0', '/f'],
          runInShell: true);
    } else {
      await Process.run('reg',
          ['add', _winReg, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '0',
              '/f'],
          runInShell: true);
    }
    final server = _original['ProxyServer'] as String?;
    if (server != null && server.contains('ProxyServer')) {
      final line = server
          .split('\n')
          .firstWhere((l) => l.contains('ProxyServer'), orElse: () => '');
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 3) {
        await Process.run('reg', ['add', _winReg, '/v', 'ProxyServer',
            '/t', 'REG_SZ', '/d', parts.last, '/f'], runInShell: true);
      }
    }
  }

  /// 广播 WM_SETTINGCHANGE，让浏览器/系统立即感知代理注册表变化
  /// （仅 Windows；reg.exe 直接写注册表不会自动通知 WinINET）
  static Future<void> _notifyWinInetChanged() async {
    try {
      final script = r'''
Add-Type -MemberDefinition '[DllImport("user32.dll", SetLastError = true)] public static extern bool SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);' -Name P -Namespace W32
$r = [UIntPtr]::Zero
[void][W32.P]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, "InternetSettings", 2, 1000, [ref]$r)
''';
      final ps1 = File('${Directory.systemTemp.path}/moneyfly_proxy_notify.ps1');
      await ps1.writeAsString(script, flush: true);
      await Process.run('powershell', [
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ps1.path,
      ], runInShell: true);
    } catch (_) {}
  }
}
