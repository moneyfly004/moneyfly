import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'proxy_core.dart';
import 'rule_assets.dart';
import 'system_proxy.dart';

/// 方案 A：sing-box CLI 子进程 + 本地 Clash API（macOS / Windows / Linux）
///
/// 连接 = 写配置 → 启动 `sing-box run -c` → 轮询 Clash API 就绪；
/// 切模式/切节点走 Clash API 热更新，不重启内核不断网；
/// 流量统计 1s 拉一次 /traffic（仅连接时，断开即停）。
///
/// 内核二进制位置（CI 打包进安装包；本地开发用 tool/fetch_singbox.sh 获取）：
///   macOS    `App.app/Contents/MacOS/sing-box`
///   Windows  `exe 同目录/sing-box.exe`
///   可用环境变量 MONEYFLY_SINGBOX 覆盖（开发调试用）。
class ProxyCoreCli extends ProxyCore {

  /// 是否由 app 管理系统代理（连接时设置、断开时恢复）。
  /// 集成测试置 false，避免改动真实系统代理。
  static bool manageSystemProxy = true;

  /// 内核工作目录（配置文件 + 内置规则集落盘处）
  static final String workDir = '${Directory.systemTemp.path}/moneyfly_core';
  static const _readyTimeout = Duration(seconds: 10);

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
  /// 5s 一次：探测是只读的 reg query / networksetup -get，开销极小；
  /// 兼顾「代理被 Windows 关掉后最多 5s 内自动恢复」，避免长时间断流。
  Timer? _proxyKeepAlive;
  static const _proxyKeepAliveInterval = Duration(seconds: 5);

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

  @override
  bool get isRunning => _proc != null;

  @override
  String? get lastError => _lastError;

  /// 定位 sing-box 可执行文件；找不到时给出可读的修复指引
  String resolveBinary() {
    final override = Platform.environment['MONEYFLY_SINGBOX'];
    if (override != null && override.isNotEmpty && File(override).existsSync()) {
      return override;
    }
    final exe = Platform.resolvedExecutable;
    final candidates = <String>[
      // macOS: 与主程序同目录（Contents/MacOS/sing-box）
      if (Platform.isMacOS) '${Directory(exe).parent.path}/sing-box',
      // Windows / Linux: 与 exe 同目录
      '${Directory(exe).parent.path}/sing-box${Platform.isWindows ? '.exe' : ''}',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    throw FileSystemException(
      '未找到 sing-box 内核二进制。\n'
      '开发环境请运行: bash tool/fetch_singbox.sh\n'
      '发布包由 CI 自动内置内核，无需额外操作。',
    );
  }

  bool _tunForceMode = false;

  @override
  Future<void> start(Map<String, dynamic> config) async {
    if (_proc != null) throw StateError('内核已在运行');
    _intentionalStop = false;
    _lastError = null;
    _logTail.clear();

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

    final binary = resolveBinary();
    final dir = Directory(workDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _configPath = '${dir.path}/config.json';

    // 确保内置规则集落盘（connect 路径会提前调 RuleAssets.materialize，
    // 但集成测试/外部直接调 start 时不经 connect，需自保）
    await RuleAssets.materialize(preferDir: workDir);
    await File(_configPath!).writeAsString(jsonEncode(config), flush: true);

    _proc = await Process.start(
      binary,
      ['run', '-c', _configPath!, '--disable-color'],
      environment: {'PATH': Platform.environment['PATH'] ?? ''},
    );

    _proc!.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLog);
    _proc!.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(_onLog);
    unawaited(_watchProcess());

    // 等内核就绪（Clash API 可访问）
    final sw = Stopwatch()..start();
    while (sw.elapsed < _readyTimeout) {
      if (_proc == null) {
        throw UnsupportedError('内核启动失败：${_tail()}');
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
    throw UnsupportedError('内核启动超时（10s）。日志：${_tail()}');
  }

  @override
  Future<void> stop() async {
    _intentionalStop = true;
    _stopProxyKeepAlive();
    _trafficCancel?.cancel();
    final p = _proc;
    _proc = null;

    // 杀进程与恢复系统代理并行：两者互不依赖，串行会白白叠加耗时。
    // 内核收到 SIGTERM 实测 ~20ms 退出，1.5s 超时兜底即可（原 3s 过长）。
    final killFut = () async {
      if (p == null) return;
      try {
        p.kill(ProcessSignal.sigterm);
        await p.exitCode.timeout(const Duration(milliseconds: 1500));
      } catch (_) {
        p.kill(ProcessSignal.sigkill);
      }
    }();
    // 恢复系统代理（sing-box set_system_proxy 被终止后不会自动恢复）
    final restoreFut =
        manageSystemProxy ? SystemProxyManager.restore() : Future.value();

    await Future.wait([killFut, restoreFut]);
  }

  /// 启动系统代理保活：每 30s 检查一次，被关/被改走则立即重新指向本地端口
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
    await _clash('PATCH', '/configs', {'mode': smart ? 'Rule' : 'Global'});
  }

  @override
  Future<void> switchNode(String tag) async {
    await _clash('PUT', '/proxies/select', {'name': tag});
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
      _onUnexpectedExit?.call();
    }
  }

  /// 流量统计：sing-box 1.14 的 /traffic 是持续流（每秒推送一行
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
