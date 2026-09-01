import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'proxy_core.dart';

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
  /// Clash API 地址（与 SingBoxConfigBuilder 中 external_controller 一致）
  static const clashApi = 'http://127.0.0.1:9090';

  /// 内核工作目录（配置文件 + 内置规则集落盘处）
  static final String workDir = '${Directory.systemTemp.path}/moneyfly_core';
  static const _readyTimeout = Duration(seconds: 10);
  static const _statsInterval = Duration(seconds: 1);

  final Dio _api = Dio(BaseOptions(
    baseUrl: clashApi,
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
  ));

  Process? _proc;
  bool _intentionalStop = false;
  String? _lastError;
  String? _configPath;

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

  Timer? _statsTimer;
  int _lastUp = 0;
  int _lastDown = 0;
  DateTime? _lastStatsTime;

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

  @override
  Future<void> start(Map<String, dynamic> config) async {
    if (_proc != null) throw StateError('内核已在运行');
    _intentionalStop = false;
    _lastError = null;
    _logTail.clear();

    final binary = resolveBinary();
    final dir = Directory(workDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _configPath = '${dir.path}/config.json';

    // 把内置规则集落盘（智能模式 geoip/geosite 本地化，不依赖远程下载）
    await _materializeRuleAssets(dir);
    File(_configPath!).writeAsStringSync(jsonEncode(config));

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
          _startStatsTimer();
          return;
        }
      } catch (_) {
        // 未就绪，继续等
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    await stop();
    throw UnsupportedError('内核启动超时（10s）。日志：${_tail()}');
  }

  @override
  Future<void> stop() async {
    _intentionalStop = true;
    _statsTimer?.cancel();
    _statsTimer = null;
    final p = _proc;
    _proc = null;
    if (p == null) return;
    try {
      p.kill(ProcessSignal.sigterm);
      await p.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      p.kill(ProcessSignal.sigkill);
    }
  }

  @override
  Future<void> switchMode(bool smart) async {
    await _clash('PATCH', '/configs', {'mode': smart ? 'Rule' : 'Global'});
  }

  @override
  Future<void> switchNode(String tag) async {
    await _clash('PUT', '/proxies/select', {'name': tag});
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

  /// 从 App 资产中取出内置规则集写到内核工作目录（幂等）
  Future<void> _materializeRuleAssets(Directory dir) async {
    for (final file in const ['geoip-cn.srs', 'geosite-cn.srs']) {
      final target = File('${dir.path}/$file');
      if (target.existsSync()) continue;
      try {
        final data = await rootBundle.load('assets/rules/$file');
        await target.writeAsBytes(data.buffer.asUint8List(
          data.offsetInBytes, data.lengthInBytes), flush: true);
      } catch (_) {
        // 资产缺失（开发环境未内置）→ 配置生成器已回退远程地址，不阻塞启动
      }
    }
  }

  /// 进程退出监视：主动 stop 之外的退出 → 通知控制器重连
  Future<void> _watchProcess() async {
    final p = _proc;
    if (p == null) return;
    final code = await p.exitCode;
    if (_proc == p && !_intentionalStop) {
      _proc = null;
      _statsTimer?.cancel();
      _statsTimer = null;
      _lastError = '内核进程退出（code $code）：${_tail()}';
      _onUnexpectedExit?.call();
    }
  }

  /// 流量统计：1s 拉一次 /traffic（累计字节 → 增量换算 MB/s）
  void _startStatsTimer() {
    _statsTimer?.cancel();
    _lastUp = 0;
    _lastDown = 0;
    _lastStatsTime = null;
    _statsTimer = Timer.periodic(_statsInterval, (_) => _pollTraffic());
  }

  Future<void> _pollTraffic() async {
    if (_proc == null) return;
    try {
      final r = await _api.get('/traffic');
      final data = r.data;
      if (data is! Map) return;
      final up = (data['up'] as num?)?.toInt() ?? 0;
      final down = (data['down'] as num?)?.toInt() ?? 0;
      final now = DateTime.now();
      if (_lastStatsTime != null) {
        final dt = now.difference(_lastStatsTime!).inMilliseconds / 1000;
        if (dt > 0) {
          final upMbps = (up - _lastUp) / dt / 1024 / 1024;
          final downMbps = (down - _lastDown) / dt / 1024 / 1024;
          _onTraffic?.call(
            upMbps < 0 ? 0 : upMbps,
            downMbps < 0 ? 0 : downMbps,
          );
        }
      }
      _lastUp = up;
      _lastDown = down;
      _lastStatsTime = now;
    } catch (_) {
      // 瞬时失败忽略，下个周期重试
    }
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    _api.close(force: true);
    unawaited(stop());
  }
}
