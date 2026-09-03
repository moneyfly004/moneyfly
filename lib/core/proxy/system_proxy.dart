import 'dart:async';
import 'dart:ffi';
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

  /// 原始代理配置是否已捕获。仅在「本次连接的第一次 apply」时捕获一次；
  /// 之后的保活 reassert 不再覆盖 —— 否则会把我们自己写入（或被系统关到一半）
  /// 的状态误存为「原始值」，restore 时就还原不回用户真正的原始配置。
  static bool _captured = false;

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
      if (!_applied || _port != port) {
        // 首次应用，或端口变了：按（新）端口应用
        await _applyNow(port);
        return;
      }
      final ok = await _osProxyPointsTo(port);
      if (!ok) {
        // 被系统/外部关掉或改走 → 强制重新打开（reassert）。
        // 注意必须 force：此时 _applied 仍为 true、端口未变，
        // 普通 _applyNow 的幂等判断会直接 return，导致「检测到掉了却修不回」。
        await _applyNow(port, reassert: true);
      }
    });
  }

  /// 实际执行「指向本地端口」（调用方需已持有互斥锁）。
  /// [reassert]=true 表示保活巡检发现代理被外部关掉后的强制重写，
  /// 跳过幂等判断、且不重新捕获原始配置。
  static Future<void> _applyNow(int port, {bool reassert = false}) async {
    if (!reassert && _applied && _port == port) return;
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
      _captured = false; // 下次连接重新捕获原始配置
      _original.clear();
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

  /// Windows 残留检测：ProxyEnable=1 且 ProxyServer 指向我们自己的端口
  /// （上次未正常 restore 的残留）。用 reg query 的原始输出文本判断。
  static bool _winStateIsSelfResidual(
      String? enableOut, String? serverOut, int port) {
    if (enableOut == null || serverOut == null) return false;
    if (!enableOut.contains('0x1')) return false;
    final line = serverOut
        .split('\n')
        .firstWhere((l) => l.contains('ProxyServer'), orElse: () => '');
    return line.contains('127.0.0.1:$port');
  }

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

  /// 只读探测：apply 时设置过的活跃服务（_original.keys）三种代理是否都仍
  /// 指向本地端口。只查我们真正设过的少数服务，全并行（~0.1s）。
  static Future<bool> _macProxyPointsTo(int port) async {
    final services = _original.keys.toList();
    if (services.isEmpty) return true;
    try {
      final results = await Future.wait([
        for (final svc in services)
          for (final kind in ['web', 'secureweb', 'socksfirewall'])
            Process.run('networksetup', ['-get${kind}proxy', svc]).then(
                (r) => _macEntryEnabledToPort((r.stdout as String).trim(), port)),
      ]);
      return results.every((ok) => ok);
    } catch (_) {
      return false;
    }
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

  /// 仅返回「有 IP 地址的活跃网络服务」（通常 1~2 个）。
  /// 关键优化：用户机器常残留大量其他 VPN 的僵尸虚拟网卡（无流量），
  /// 而 macOS `networksetup -set` 走系统配置数据库全局写锁、并发无法真正并行 ——
  /// 对全部 20+ 服务串行 set 会让连接/断开卡 2~3s。只设活跃服务把 set 次数
  /// 从 60+ 降到 ~6，连接/断开各降到 <0.5s。getinfo 是只读、并行无锁竞争。
  static Future<List<String>> _macActiveServices() async {
    final all = await _macServices();
    final active = <String>[];
    await Future.wait([
      for (final svc in all)
        Process.run('networksetup', ['-getinfo', svc]).then((r) {
          final ip = _extractMacValue(r.stdout as String, 'IP address:');
          if (ip != null &&
              ip.isNotEmpty &&
              ip != 'none' &&
              !ip.startsWith('0.0.0.0')) {
            active.add(svc);
          }
        }).catchError((_) {}),
    ]);
    // 一个活跃服务都没找到（异常网络态）→ 回退全部，保证代理仍然生效
    return active.isEmpty ? all : active;
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

  /// macOS apply：跨「网络服务 × 代理类型」全部并行执行。
  /// 用户机器上常有大量残留虚拟网卡（其他 VPN 软件遗留），串行 networksetup
  /// 会让连接卡 2~3s；并行后降到 ~0.3s。每个 networksetup 调用相互独立，
  /// 并行无副作用。
  static Future<void> _applyMacOS(int port) async {
    // 1) 首次：筛活跃服务 + 捕获原状态（仅一次）。之后的服务集合固定为
    //    _original.keys —— reassert/restore/探测三者共用，保证一致。
    if (!_captured) {
      final active = await _macActiveServices();
      await Future.wait([
        for (final svc in active)
          for (final kind in ['web', 'secureweb', 'socksfirewall'])
            Process.run('networksetup', ['-get${kind}proxy', svc]).then((r) {
              var state = (r.stdout as String).trim();
              if (_isSelfResidual(state, port)) state = 'Enabled: No';
              (_original[svc] ??= <String, String>{})[kind] = state;
            }),
      ]);
      _captured = true;
    }
    // 2) 设置代理 on + 127.0.0.1:port。
    //    注意：networksetup -set 走系统配置数据库全局写锁，并发 set 会互相
    //    竞争、偶发丢写，故写操作串行执行。因只对活跃服务（通常 1~2 个、
    //    共 3~6 次），串行也仅 ~0.4s，可靠优先。
    final services = _original.keys.toList();
    for (final svc in services) {
      for (final kind in ['web', 'secureweb', 'socksfirewall']) {
        await Process.run(
            'networksetup', ['-set${kind}proxy', svc, '127.0.0.1', '$port']);
      }
    }
  }

  /// macOS restore：只恢复「apply 时真正设置过的活跃服务」（_original.keys）。
  /// 写操作串行（避免 networksetup 系统配置数据库写锁竞争丢写）；
  /// 因只涉及少数活跃服务，断开仍 <0.5s。
  static Future<void> _restoreMacOS() async {
    final services = _original.keys.toList();
    for (final svc in services) {
      for (final kind in ['web', 'secureweb', 'socksfirewall']) {
        await _restoreMacOneEntry(svc, kind);
      }
    }
    _original.clear();
  }

  /// 恢复单条 macOS 代理（service × kind）到原始状态
  static Future<void> _restoreMacOneEntry(String svc, String kind) async {
    final orig = _original[svc] as Map<String, String>?;
    final prev = orig?[kind] ?? '';
    final enabled = prev.contains('Enabled: Yes');
    final host = _extractMacValue(prev, 'Server:');
    final port = _extractMacValue(prev, 'Port:');
    if (enabled && host != null && port != null) {
      await Process.run('networksetup', ['-set${kind}proxy', svc, host, port]);
    } else {
      await Process.run('networksetup', ['-set${kind}proxystate', svc, 'off']);
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
    // 保存原值（仅首次捕获；保活 reassert 时不再覆盖，避免把「我们自己写入的
    // 值」或「被系统关到一半的值」误存为原始配置）。两次 query 并行。
    if (!_captured) {
      final results = await Future.wait([
        Process.run('reg', ['query', _winReg, '/v', 'ProxyEnable'],
            runInShell: true),
        Process.run('reg', ['query', _winReg, '/v', 'ProxyServer'],
            runInShell: true),
      ]);
      final enableOut =
          results[0].exitCode == 0 ? (results[0].stdout as String) : null;
      final serverOut =
          results[1].exitCode == 0 ? (results[1].stdout as String) : null;
      // 残留检测：上次崩溃/被强杀，代理仍指向我们自己的端口 →
      // 视为「原本关闭」，restore 时关掉而非还原到死端口（否则系统流量永久中断）。
      if (_winStateIsSelfResidual(enableOut, serverOut, port)) {
        _original['ProxyEnable'] = null;
        _original['ProxyServer'] = null;
      } else {
        _original['ProxyEnable'] = enableOut;
        _original['ProxyServer'] = serverOut;
      }
      _captured = true;
    }

    // 写不同注册表值互不冲突，可并行（注册表有细粒度锁，无 macOS 那种全局写锁）
    await Future.wait([
      Process.run('reg',
          ['add', _winReg, '/v', 'ProxyEnable', '/t', 'REG_DWORD', '/d', '1',
              '/f'],
          runInShell: true),
      Process.run('reg',
          ['add', _winReg, '/v', 'ProxyServer', '/t', 'REG_SZ', '/d',
              '127.0.0.1:$port', '/f'],
          runInShell: true),
      Process.run('reg',
          ['add', _winReg, '/v', 'ProxyOverride', '/t', 'REG_SZ', '/d',
              '<local>', '/f'],
          runInShell: true),
    ]);
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

  /// 让浏览器/系统立即感知代理注册表变化（仅 Windows；reg.exe 写注册表
  /// 不会自动通知 WinINET）。
  ///
  /// 旧实现每次都启动 PowerShell（冷启动 0.5~1s），连接/断开各吃一次，是
  /// Windows 端「连接慢、断开慢」的主因之一。改为 dart:ffi 直接调 wininet
  /// 的 InternetSetOption（INTERNET_OPTION_SETTINGS_CHANGED + REFRESH）——
  /// 无进程启动，微秒级返回，且是 WinINET 官方刷新方式。
  static Future<void> _notifyWinInetChanged() async {
    if (!_isWindows) return;
    // 优先 FFI（快）；任何失败都回退到 PowerShell（慢但已验证可靠）。
    // 代理注册表值此时已写入，通知只是让浏览器「立即」感知，回退不影响正确性。
    if (_notifyWinInetViaFfi()) return;
    await _notifyWinInetViaPowerShell();
  }

  /// FFI 直调 wininet InternetSetOption。成功返回 true；抛异常或调用失败返回
  /// false（交由调用方回退）。
  static bool _notifyWinInetViaFfi() {
    try {
      final wininet = DynamicLibrary.open('wininet.dll');
      final internetSetOption = wininet.lookupFunction<
          Int32 Function(IntPtr, Uint32, Pointer<Void>, Uint32),
          int Function(int, int, Pointer<Void>, int)>('InternetSetOptionW');
      const internetOptionSettingsChanged = 39;
      const internetOptionRefresh = 37;
      // hInternet=0（全局）、无缓冲区：通知「设置已变」+「立即刷新」。
      // 返回非 0 为成功；任一步失败即视为整体失败，回退 PowerShell。
      final r1 = internetSetOption(0, internetOptionSettingsChanged, nullptr, 0);
      final r2 = internetSetOption(0, internetOptionRefresh, nullptr, 0);
      return r1 != 0 && r2 != 0;
    } catch (e) {
      debugPrint('SystemProxyManager FFI 通知失败，回退 PowerShell: $e');
      return false;
    }
  }

  /// 回退方案：PowerShell 广播 WM_SETTINGCHANGE（旧实现，慢但可靠）
  static Future<void> _notifyWinInetViaPowerShell() async {
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
    } catch (e) {
      debugPrint('SystemProxyManager PowerShell 通知失败: $e');
    }
  }
}
