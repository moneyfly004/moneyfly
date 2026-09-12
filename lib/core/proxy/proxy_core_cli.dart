import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'proxy_core.dart';
import 'geo_assets.dart';
import 'mihomo_config.dart';
import 'system_proxy.dart';
import '../services/app_log.dart';
import '../services/local_paths.dart';

/// mihomo CLI 子进程 + 本地 Clash API（macOS / Windows / Linux）
///
/// 连接 = 写 config.yaml → 启动 `mihomo -d <workDir>` → 轮询 Clash API 就绪；
/// 切模式/切节点走 Clash API 热更新，不重启内核不断网；
/// 流量统计 1s 拉一次 /traffic（仅连接时，断开即停）。
///
/// 内核二进制位置（CI 打包进安装包；本地开发用 tool/fetch_mihomo.sh 获取）：
///   macOS    `App.app/Contents/MacOS/mihomo`
///   Windows  `exe 同目录/mihomo.exe`
///   可用环境变量 MONEYFLY_MIHOMO 覆盖（开发调试用）。
class ProxyCoreCli extends ProxyCore {

  /// 是否由 app 管理系统代理（连接时设置、断开时恢复）。
  /// 集成测试置 false，避免改动真实系统代理。
  static bool manageSystemProxy = true;

  /// 内核工作目录（config.yaml + 离线 geo 数据 country.mmdb/geosite.dat 落盘处；
  /// mihomo -d 以此为 homeDir，默认文件名直接加载 geo）
  static final String workDir = '${Directory.systemTemp.path}/moneyfly_core';
  static const _readyTimeout = Duration(seconds: 10);

  /// 内核日志实时流（广播）：_onLog 收到的每行都推送，
  /// 「内核日志」实时页订阅展示
  static final StreamController<String> kernelLogStream =
      StreamController<String>.broadcast();

  /// 最近内核日志快照（实时页初始历史用，环形保留末尾 ~200 行）
  static List<String> logTailSnapshot() =>
      List.unmodifiable(_lastCoreLogs);

  /// 当前智能(rule)/全局(global)状态 —— 决定热切节点时打 select 组还是 GLOBAL 组。
  /// 启动时从配置 mode 字段同步；switchMode 时更新。
  bool _smartMode = true;

  /// 最近一次成功切换/选中的节点 tag（切全局模式时把 GLOBAL 组指过来，
  /// 避免全局模式仍走内核默认第一节点导致线路跳变）
  String? _lastNodeTag;

  final Dio _api = Dio(BaseOptions(
    baseUrl: 'http://127.0.0.1:9090',
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
  ));

  Process? _proc;
  bool _intentionalStop = false;
  String? _lastError;
  String? _configPath;

  /// 本机 mixed 入站端口（设置页可改；随配置传入，默认 2080）。
  /// 系统代理的 apply/保活/探测全部指向该端口。
  int _localPort = SystemProxyManager.defaultPort;

  /// Clash API 管理端口（设置页可改；随配置传入，默认 9090）
  int _clashApiPort = 9090;

  /// 系统代理保活定时器：连接期间周期检查，被系统/外部关掉就重新开启。
  /// 目标：只要内核在跑，系统代理就保持指向本地端口，直到断开/退出。
  /// 20s 一次：探测是子进程(reg query / networksetup)，过密会累积进程创建
  /// 开销(macOS 每轮服务数×3 并行)；20s 内恢复被外部关闭的代理已足够快。
  Timer? _proxyKeepAlive;
  static const _proxyKeepAliveInterval = Duration(seconds: 20);

  /// 进程异常退出（非主动断开）→ 控制器触发自动重连
  VoidCallback? _onUnexpectedExit;

  /// 实时速率回调（MB/s），1s 一次，仅连接期间
  void Function(double upMbps, double downMbps)? _onTraffic;

  @override
  VoidCallback? get onUnexpectedExit => _onUnexpectedExit;

  @override
  set onUnexpectedExit(VoidCallback? cb) => _onUnexpectedExit = cb;

  @override
  void Function(double upMbps, double downMbps)? get onTraffic => _onTraffic;

  @override
  set onTraffic(void Function(double upMbps, double downMbps)? cb) =>
      _onTraffic = cb;

  CancelToken? _trafficCancel;
  final List<int> _trafficBuf = [];

  /// 最近内核日志（错误排查用，环形保留末尾 ~40 行）
  final List<String> _logTail = [];
  static const _logKeep = 40;
  /// 进程级内核日志环形缓冲（日志实时页跨实例读取；上限 200 行）
  static final List<String> _lastCoreLogs = [];
  static const _coreLogKeep = 200;

  @override
  bool get isRunning => _proc != null;

  @override
  String? get lastError => _lastError;

  /// 定位 mihomo 可执行文件（优先级：测试注入 → 用户切换/更新的副本
  /// [KernelManager.userActivePath] → 安装内置）。
  /// 用户副本放在应用支持目录，任意安装目录(含只读的 Program Files)都可用。
  Future<String> resolveBinary() async {
    final override = Platform.environment['MONEYFLY_MIHOMO'];
    if (override != null && override.isNotEmpty && File(override).existsSync()) {
      return override;
    }
    // 用户内核副本优先（内核管理页切换/更新写入的位置）
    try {
      final support = await LocalPaths.supportDir();
      if (support != null) {
        final userBin =
            '${support.path}/kernel/mihomo${Platform.isWindows ? '.exe' : ''}';
        if (File(userBin).existsSync()) return userBin;
      }
    } catch (_) {}
    final exe = Platform.resolvedExecutable;
    final candidates = <String>[
      if (Platform.isMacOS) '${Directory(exe).parent.path}/mihomo',
      '${Directory(exe).parent.path}/mihomo${Platform.isWindows ? '.exe' : ''}',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    throw FileSystemException(
      '未找到 mihomo 内核二进制。\n'
      '开发环境请运行: bash tool/fetch_mihomo.sh\n'
      '发布包由 CI 自动内置内核，无需额外操作。',
    );
  }

  bool _tunForceMode = false;

  /// 清理指向本项目工作目录的「僵尸 mihomo 进程」。
  ///
  /// 场景：App 被强杀/崩溃/异常退出时，内核子进程(mihomo -d workDir)可能
  /// 残留，继续占用 9090/2080 与 cache.db 锁 —— 再次启动时新内核
  /// bind 失败("address already in use")+ "[CacheFile] can't open cache
  /// file: timeout"，表现为「退出后重开连不上」。
  /// 只匹配命令行含 moneyfly_core 的 mihomo，不会误杀其它 Clash 类软件。
  static Future<void> killStaleKernels() async {
    try {
      if (Platform.isWindows) {
        await Process.run('powershell', [
          '-NoProfile', '-Command',
          "Get-CimInstance Win32_Process | Where-Object { \$_.Name -match 'mihomo' -and \$_.CommandLine -match 'moneyfly_core' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }",
        ]);
        return;
      }
      final r = await Process.run('ps', ['-axo', 'pid,ppid,command'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      if (r.exitCode != 0) return;
      final self = pid; // 当前 App 进程
      for (final line in (r.stdout as String).split('\n')) {
        if (!line.contains('mihomo') || !line.contains('moneyfly_core')) {
          continue;
        }
        final m = RegExp(r'^\s*(\d+)\s+(\d+)').firstMatch(line);
        if (m == null) continue;
        final pidToKill = int.tryParse(m.group(1)!);
        final ppid = int.tryParse(m.group(2)!);
        if (pidToKill == null || pidToKill <= 1) continue;
        // 跳过本 App 直接启动的内核子进程（非僵尸），避免误杀当前连接
        if (ppid == self) continue;
        AppLog.kernel('kill stale mihomo pid=$pidToKill: ${line.trim()}');
        await Process.run('kill', ['-9', '$pidToKill']);
      }
    } catch (_) {}
  }

  @override
  Future<void> start(Map<String, dynamic> config) async {
    if (_proc != null) throw StateError('内核已在运行');
    _intentionalStop = false;
    _lastError = null;
    _logTail.clear();
    // 桌面端兜底：清理上次异常退出残留的僵尸内核（避免端口/cache 锁冲突）
    await killStaleKernels();

    // 从配置同步当前模式（rule=智能 / global=全局），热切节点时选对组
    _smartMode = config['mode']?.toString() != 'global';
    // tunMode='force' 时无 mixed 端口，不管理系统代理
    _tunForceMode = config.remove('_tunMode') == 'force';
    // 本机监听端口（设置页自定义，默认 2080）
    _localPort =
        (config.remove('_localPort') as num?)?.toInt() ?? SystemProxyManager.defaultPort;
    // Clash API 管理端口（设置页自定义，默认 9090）
    _clashApiPort = (config.remove('_clashApiPort') as num?)?.toInt() ?? 9090;
    final clashSecret = config.remove('_clashApiSecret')?.toString() ?? '';
    _api.options.baseUrl = 'http://127.0.0.1:$_clashApiPort';
    if (clashSecret.isNotEmpty) {
      _api.options.headers['Authorization'] = 'Bearer $clashSecret';
    }

    final binary = await resolveBinary();
    final dir = Directory(workDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _configPath = '${dir.path}/config.yaml';

    // 确保离线 geo 数据就位（connect 路径会提前落盘；集成测试/外部直接调
    // start 时自保。幂等：文件已存在且非空则跳过）。
    // 失败时移除配置中的 GEOSITE/GEOIP 规则：mihomo 一旦引用 geo 规则而文件
    // 缺失，会在启动时联网下载（默认 GitHub 源，国内常被墙 → 卡 90s/失败），
    // 内置 assets 理应就位，缺失属异常 → 宁可降级全代理也绝不联网下载。
    final geoOk = await GeoAssets.materialize(preferDir: workDir);
    if (!geoOk) {
      final rules = config['rules'];
      if (rules is List) {
        config['rules'] = rules.where((r) {
          final s = r.toString();
          return !(s.startsWith('GEOSITE,') || s.startsWith('GEOIP,'));
        }).toList();
      }
    }

    // mihomo 原生读 Clash YAML，配置用 MihomoConfigBuilder.encode 序列化
    await File(_configPath!).writeAsString(MihomoConfigBuilder.encode(config), flush: true);

    _proc = await Process.start(
      binary,
      ['-d', dir.path],
      environment: {'PATH': Platform.environment['PATH'] ?? ''},
    );

    _proc!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLog);
    _proc!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLog);
    unawaited(_watchProcess());

    // 等内核就绪（Clash API 可访问）
    final sw = Stopwatch()..start();
    while (sw.elapsed < _readyTimeout) {
      if (_proc == null) {
        // 进程启动后立即退出（_watchProcess 已记录退出码与尾部日志）：
        // 给出可诊断信息，而不是含糊的「（无输出）」
        final why = (_lastError?.isNotEmpty ?? false)
            ? _lastError!
            : '内核进程启动后立即退出';
        throw UnsupportedError('内核启动失败：$why$_winKernelHint');
      }
      try {
        final r = await _api.get('/version', options: Options(validateStatus: (s) => true));
        if (r.statusCode == 200) {
          // 内核就绪后管理系统代理（仅有 mixed 端口时，TUN force 模式不需要）
          if (manageSystemProxy && !_tunForceMode) {
            await SystemProxyManager.apply(port: _localPort);
            _startProxyKeepAlive();
          }
          _startStatsTimer();
          return;
        }
      } catch (_) {
        // 未就绪，继续等
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await stop();
    throw UnsupportedError('内核启动超时（${_readyTimeout.inSeconds}s）。日志：${_tail()}$_winKernelHint');
  }

  /// Windows 附加引导：内核进程启动即退出时给出排障方向。
  /// - 退出码 0xC0000005(访问违例)/0xC000001D(非法指令)：通常是 CPU 过老
  ///   跑不了新版内核(官方 amd64 按新指令集编译) —— 已默认改用官方
  ///   compatible 版,仍出现可到「设置 → 内核管理」手动更新为兼容内核;
  /// - 无任何日志输出且反复被终止：多为杀毒软件/Windows 安全中心拦截
  ///   mihomo.exe,请把 MoneyFly 安装目录加入白名单
  String get _winKernelHint => Platform.isWindows
      ? '。提示：若退出码为 0xC0000005/0xC000001D 多为 CPU 过老与新版内核不兼容'
          '(可到设置→内核管理更新兼容内核)；若反复「无日志即退出」多为杀毒软件/'
          'Windows 安全中心拦截 mihomo.exe，请将 MoneyFly 安装目录加入白名单'
      : '';

  @override
  Future<void> stop() async {
    _intentionalStop = true;
    _stopProxyKeepAlive();
    _trafficCancel?.cancel();
    final p = _proc;
    _proc = null;

    final killFut = () async {
      if (p == null) return;
      // 优先通过 Clash API 请求内核优雅退出（mihomo 清理 TUN/虚拟网卡），
      // SIGTERM 在 Windows 上无效，直接 kill 会残留虚拟网卡。
      try {
        await _api.request('/shutdown',
            options: Options(method: 'POST', validateStatus: (_) => true,
                receiveTimeout: const Duration(milliseconds: 800)));
        await p.exitCode.timeout(const Duration(milliseconds: 1500));
        return;
      } catch (_) {}
      // API 退出失败：回退信号/强杀
      try {
        p.kill(ProcessSignal.sigterm);
        await p.exitCode.timeout(const Duration(milliseconds: 1500));
      } catch (_) {
        p.kill(ProcessSignal.sigkill);
      }
    }();
    final restoreFut =
        manageSystemProxy ? SystemProxyManager.restore() : Future.value();

    await Future.wait([killFut, restoreFut]);
  }

  /// 启动系统代理保活：每 20s 检查一次，被关/被改走则立即重新指向本地端口
  bool _keepAliveInFlight = false;

  void _startProxyKeepAlive() {
    _stopProxyKeepAlive();
    _keepAliveInFlight = false;
    _proxyKeepAlive = Timer.periodic(_proxyKeepAliveInterval, (_) async {
      if (_keepAliveInFlight) return;
      if (_proc == null || _tunForceMode || !manageSystemProxy) return;
      _keepAliveInFlight = true;
      try {
        await SystemProxyManager.ensureApplied(port: _localPort);
      } catch (_) {
      } finally {
        _keepAliveInFlight = false;
      }
    });
  }

  void _stopProxyKeepAlive() {
    _proxyKeepAlive?.cancel();
    _proxyKeepAlive = null;
  }

  @override
  Future<void> switchMode(bool smart) async {
    _smartMode = smart;
    // mihomo: rule=智能(规则分流) / global=全局(全部走 GLOBAL 组)。
    // 热切换 PATCH /configs 即可，内核不重启不断网。
    await _clash('PATCH', '/configs', {'mode': smart ? 'rule' : 'global'});
    if (!smart) {
      // 全局模式下流量走内置 GLOBAL 组：把 GLOBAL 指向当前节点，
      // 否则会回落到内核默认第一节点，线路跳变
      final tag = _lastNodeTag;
      if (tag != null) {
        try {
          await _clash('PUT', '/proxies/GLOBAL', {'name': tag});
        } catch (_) {
          // GLOBAL 组缺失/不可用时忽略（内核内置组通常总是存在）
        }
      }
    }
  }

  @override
  Future<void> switchNode(String tag) async {
    _lastNodeTag = tag;
    // 智能模式切 select 组；全局模式切内置 GLOBAL 组
    final group = _smartMode ? 'select' : 'GLOBAL';
    await _clash('PUT', '/proxies/$group', {'name': tag});
  }

  @override
  Future<void> setKernelLogLevel(String level) async {
    // mihomo PATCH /configs 支持 log-level 热更（debug/info/warning/error/silent）
    await _clash('PATCH', '/configs', {'log-level': level});
  }

  @override
  Future<int> testNodeDelay(String tag,
      {Duration timeout = const Duration(seconds: 5), String? url}) async {
    if (_proc == null) return -1;
    try {
      final r = await _api.get(
        '/proxies/${Uri.encodeComponent(tag)}/delay',
        queryParameters: {
          'timeout': timeout.inMilliseconds,
          'url': url ?? 'http://www.gstatic.com/generate_204',
        },
        options: Options(
            validateStatus: (s) => true,
            receiveTimeout: timeout + const Duration(seconds: 2)),
      );
      if (r.statusCode == 200 && r.data is Map && r.data['delay'] is num) {
        return (r.data['delay'] as num).toInt();
      }
      return -1; // 超时/不可达 → 内核返回非 200
    } catch (_) {
      return -1;
    }
  }

  Future<void> _clash(String method, String path, Object body) async {
    if (_proc == null) throw StateError('内核未运行');
    await _api.request(path,
        data: body,
        options: Options(
            method: method, validateStatus: (s) => s != null && s >= 200 && s < 300));
  }

  void _onLog(String line) {
    _logTail.add(line);
    if (_logTail.length > _logKeep) _logTail.removeAt(0);
    _lastCoreLogs.add(line);
    if (_lastCoreLogs.length > _coreLogKeep) _lastCoreLogs.removeAt(0);
    if (!kernelLogStream.isClosed) {
      kernelLogStream.add(line);
    }
  }

  String _tail() => _logTail.isEmpty ? '（无输出）' : _logTail.join(' | ');

  /// 进程退出监视：主动 stop 之外的退出 → 通知控制器重连
  Future<void> _watchProcess() async {
    final p = _proc;
    if (p == null) return;
    final code = await p.exitCode;
    if (_proc == p && !_intentionalStop) {
      _proc = null;
      _trafficCancel?.cancel();
      _lastError = '内核进程退出（code $code）：${_tail()}';
      AppLog.kernel('process exited unexpectedly, code=$code, log=${_tail()}');
      _onUnexpectedExit?.call();
    }
  }

  /// 流量统计：mihomo 的 /traffic 是持续流（每秒推送一行
  /// {"up":Δ,"down":Δ}，单位字节/秒），流式解析直接换算 MB/s 回调。
  /// 断开/出错后重连流，直到内核停止。
  void _startStatsTimer() {
    _trafficCancel?.cancel();
    _trafficCancel = CancelToken();
    _trafficBuf.clear();
    // 流任务自管理生命周期（内核停止/取消令牌时退出），无需持有引用
    unawaited(_streamTraffic(_trafficCancel!));
  }

  Future<void> _streamTraffic(CancelToken cancel) async {
    while (_proc != null && !cancel.isCancelled) {
      try {
        final resp = await _api.get(
          '/traffic',
          cancelToken: cancel,
          options: Options(responseType: ResponseType.stream),
        );
        final stream = resp.data.stream as Stream<List<int>>;
        await for (final chunk in stream) {
          if (cancel.isCancelled || _proc == null) break;
          _trafficBuf.addAll(chunk);
          if (_trafficBuf.length > 64 * 1024) _trafficBuf.removeRange(0, _trafficBuf.length - 4096);
          // 按行解析 JSON（流式，跨 chunk 的行由缓冲区拼接）
          while (true) {
            final nl = _trafficBuf.indexOf(0x0A); // '\n'
            if (nl < 0) break;
            final line = utf8.decode(_trafficBuf.sublist(0, nl)).trim();
            _trafficBuf.removeRange(0, nl + 1);
            if (line.isEmpty) continue;
            try {
              final obj = jsonDecode(line);
              if (obj is Map && obj['up'] is num && obj['down'] is num) {
                // 值即每秒增量字节 → 直接换算 MB/s
                _onTraffic?.call(
                  (obj['up'] as num) / 1024 / 1024,
                  (obj['down'] as num) / 1024 / 1024,
                );
              }
            } catch (_) {
              // 忽略无法解析的行
            }
          }
        }
      } catch (_) {
        // 流中断：稍后重连（内核仍在运行则继续尝试）
      }
      if (_proc == null || cancel.isCancelled) break;
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  @override
  void dispose() {
    _trafficCancel?.cancel();
    _api.close(force: true);
    unawaited(stop());
  }
}
