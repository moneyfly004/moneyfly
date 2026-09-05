import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import '../services/app_log.dart';
import '../services/permission_service.dart';
import 'mihomo_config.dart';
import 'proxy_core.dart';

/// 看门狗单次巡检后的决策（纯逻辑，便于单元测试）
enum WatchdogAction {
  /// 隧道正常，继续
  healthy,
  /// 本次失败但未达阈值 / 原生确认存活 → 保持连接，绝不断连
  keepAlive,
  /// 连续失败达阈值且原生确认已停 → 判定内核死亡
  declareDead,
}

/// 看门狗判死纯函数（无副作用，可单测）：
/// - 本次巡检 OK → healthy
/// - 失败但连续次数未达阈值 → keepAlive（等下次）
/// - 达阈值但原生 VpnService 仍在跑 → keepAlive（App 后台/限流导致的假失败）
/// - 达阈值且原生已停 → declareDead
///
/// [consecutiveFailures] 含本次在内的连续失败次数（本次失败时由调用方 +1 后传入）。
WatchdogAction decideWatchdog({
  required bool pollOk,
  required int consecutiveFailures,
  required int deadThreshold,
  required bool nativeAlive,
}) {
  if (pollOk) return WatchdogAction.healthy;
  if (consecutiveFailures < deadThreshold) return WatchdogAction.keepAlive;
  if (nativeAlive) return WatchdogAction.keepAlive;
  return WatchdogAction.declareDead;
}

/// Android 内核：VpnService(原生 Kotlin) + libmihomo(gomobile 库，mihomo 官方源码 CI 编译)。
///
/// Flutter 侧把 mihomo YAML 配置与 TUN 开关经 MethodChannel 交给原生；
/// 原生负责：VpnService 授权 → 建立 TUN(拿到 fd) → libmihomo.Start(homeDir, yaml, fd)。
/// 切模式/切节点/测速/流量统计走 Clash API(127.0.0.1:9090)，与桌面端一致。
class ProxyCoreAndroid extends ProxyCore {
  static const _channel = MethodChannel('top.moneyfly/vpn_core');

  final Dio _api = Dio(BaseOptions(
    baseUrl: 'http://127.0.0.1:9090',
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
  ));

  /// 当前智能(rule)/全局(global)状态 —— 决定热切节点时打 select 组还是 GLOBAL 组
  bool _smartMode = true;

  /// 最近一次切换的节点 tag（切全局模式时把 GLOBAL 组指过来）
  String? _lastNodeTag;

  bool _running = false;
  String? _lastError;
  VoidCallback? _onUnexpectedExit;
  void Function(double upMbps, double downMbps)? _onTraffic;
  Timer? _watchdog;
  CancelToken? _trafficCancel;
  final List<int> _trafficBuf = [];

  /// 看门狗连续失败计数。单次 /version 失败不判定内核死亡 —— App 切后台、
  /// 弹系统框、Doze 限流都可能让某一次轮询瞬时失败，但隧道其实还活着。
  /// 连续多次失败、且原生 VpnService 也确认已停，才判定真死亡。
  int _watchdogFailures = 0;
  static const _watchdogDeadThreshold = 3; // 连续 3 次(约15s)才判死

  @override
  bool get isRunning => _running;
  @override
  String? get lastError => _lastError;
  @override
  VoidCallback? get onUnexpectedExit => _onUnexpectedExit;
  @override
  set onUnexpectedExit(VoidCallback? cb) => _onUnexpectedExit = cb;
  @override
  void Function(double upMbps, double downMbps)? get onTraffic => _onTraffic;
  @override
  set onTraffic(void Function(double upMbps, double downMbps)? cb) => _onTraffic = cb;

  @override
  Future<void> start(Map<String, dynamic> config) async {
    if (_running) throw StateError('already running');
    _lastError = null;
    // 从配置同步模式（rule=智能 / global=全局）
    _smartMode = config['mode']?.toString() != 'global';
    // 剥离 app 侧元数据（系统代理端口/模式/TUN 开关），不写入 YAML
    final tunMode = config.remove('_tunMode')?.toString() ?? 'auto';
    config.remove('_localPort');
    final clashPort =
        (config.remove('_clashApiPort') as num?)?.toInt() ?? 9090;
    final clashSecret = config.remove('_clashApiSecret')?.toString() ?? '';
    _api.options.baseUrl = 'http://127.0.0.1:$clashPort';
    if (clashSecret.isNotEmpty) {
      _api.options.headers['Authorization'] = 'Bearer $clashSecret';
    }
    // 序列化为 mihomo YAML（原生 libmihomo 只吃 Clash YAML）
    final configYaml = MihomoConfigBuilder.encode(config);
    final needTun = tunMode != 'off';
    // 前置检查：VPN 授权缺失/被撤销（重装、清数据、系统里关闭授权）时，
    // 直接在 Dart 侧给出类型化失败，避免走 15s 轮询超时才知道失败
    if (!await PermissionService.instance.isVpnPrepared()) {
      throw TypedConnError(
          ConnErrorKind.noVpnPermission, AppStrings.t('vpn_permission_needed'));
    }
    try {
      await _channel.invokeMethod('startVpn', {
        'configYaml': configYaml,
        'needTun': needTun,
      });
    } on PlatformException catch (e) {
      // start_failed（原生侧返回，如 Android 12+ 后台启动前台服务受限）：
      // 类型化后交给首页分场景引导（保持前台重试等）
      final msg = e.message?.toString() ?? '$e';
      if (e.code == 'start_failed') {
        throw TypedConnError(ConnErrorKind.backgroundStartBlocked, msg);
      }
      throw TypedConnError(ConnErrorKind.unknown,
          AppStrings.t('vpn_start_fail', {'err': msg}));
    } catch (e) {
      throw TypedConnError(
          ConnErrorKind.unknown, AppStrings.t('vpn_start_fail', {'err': '$e'}));
    }
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 15)) {
      try {
        final r = await _api.get('/version', options: Options(validateStatus: (s) => true));
        if (r.statusCode == 200) {
          _running = true;
          _startWatchdog();
          _startTrafficStream();
          return;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    }
    // 内核未就绪：主动清理原生侧（VpnService/内核可能正在慢启动或启动失败），
    // 避免「UI 报失败但 VPN 通知/隧道残留」的幽灵连接。
    // 顺带拉取内核日志尾部，把真实原因带给用户（而非笼统的超时）。
    var detail = '';
    try {
      final logs =
          await _channel.invokeMethod<String>('fetchKernelLogs') ?? '';
      if (logs.isNotEmpty) {
        final lines = logs.split('\n').where((l) => l.trim().isNotEmpty).toList();
        if (lines.length > 3) {
          detail = lines.sublist(lines.length - 3).join(' ');
        } else {
          detail = lines.join(' ');
        }
      }
    } catch (_) {}
    _lastError = AppStrings.t('kernel_timeout');
    try {
      await _channel.invokeMethod('stopVpn');
    } catch (_) {}
    throw TypedConnError(
      ConnErrorKind.kernelTimeout,
      detail.isEmpty ? _lastError! : '$_lastError：$detail',
    );
  }

  @override
  Future<void> stop() async {
    _running = false;
    _watchdog?.cancel();
    _watchdog = null;
    _trafficCancel?.cancel();
    _trafficCancel = null;
    try {
      await _channel.invokeMethod('stopVpn');
    } catch (_) {}
  }

  @override
  Future<void> switchMode(bool smart) async {
    _smartMode = smart;
    // mihomo: rule=智能 / global=全局，热切换不断网
    await _clash('PATCH', '/configs', {'mode': smart ? 'rule' : 'global'});
    if (!smart) {
      // 全局模式流量走内置 GLOBAL 组：把 GLOBAL 指向当前节点，避免线路跳变
      final tag = _lastNodeTag;
      if (tag != null) {
        try {
          await _clash('PUT', '/proxies/GLOBAL', {'name': tag});
        } catch (_) {}
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
    // mihomo PATCH /configs 支持 log-level 热更
    await _clash('PATCH', '/configs', {'log-level': level});
  }

  @override
  Future<int> testNodeDelay(String tag,
      {Duration timeout = const Duration(seconds: 5), String? url}) async {
    if (!_running) return -1;
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
      return -1;
    } catch (_) {
      return -1;
    }
  }

  Future<void> _clash(String method, String path, Object body) async {
    if (!_running) throw StateError('not running');
    await _api.request(path,
        data: body,
        options: Options(method: method, validateStatus: (s) => s != null && s >= 200 && s < 300));
  }

  bool _watchdogInFlight = false;

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdogFailures = 0;
    _watchdogInFlight = false;
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_running || _watchdogInFlight) return;
      _watchdogInFlight = true;
      try {
        bool ok;
        try {
          final r = await _api.get('/version',
              options: Options(validateStatus: (s) => true));
          ok = r.statusCode == 200;
        } catch (_) {
          ok = false;
        }
        if (ok) {
          _watchdogFailures = 0;
          return;
        }
        _watchdogFailures++;
        final nativeAlive = _watchdogFailures >= _watchdogDeadThreshold
            ? await _nativeVpnAlive()
            : true;
        final action = decideWatchdog(
          pollOk: false,
          consecutiveFailures: _watchdogFailures,
          deadThreshold: _watchdogDeadThreshold,
          nativeAlive: nativeAlive,
        );
        switch (action) {
          case WatchdogAction.healthy:
          case WatchdogAction.keepAlive:
            if (nativeAlive && _watchdogFailures >= _watchdogDeadThreshold) {
              _watchdogFailures = 0;
            }
            return;
          case WatchdogAction.declareDead:
            _onKernelDead();
        }
      } finally {
        _watchdogInFlight = false;
      }
    });
  }

  /// 向原生查询 VpnService.isRunning（内核真死亡时才为 false）。
  /// 查询本身异常时保守返回 true（宁可不断连，也不误杀存活隧道）。
  Future<bool> _nativeVpnAlive() async {
    try {
      return await _channel.invokeMethod<bool>('isVpnRunning') ?? true;
    } catch (_) {
      return true;
    }
  }

  void _onKernelDead() {
    _running = false;
    _watchdogFailures = 0;
    _lastError = AppStrings.t('kernel_exit');
    _trafficCancel?.cancel();
    AppLog.kernel('watchdog declared dead, failures=$_watchdogDeadThreshold');
    _onUnexpectedExit?.call();
  }

  void _startTrafficStream() {
    _trafficCancel?.cancel();
    _trafficCancel = CancelToken();
    _trafficBuf.clear();
    unawaited(_streamTraffic(_trafficCancel!));
  }

  Future<void> _streamTraffic(CancelToken cancel) async {
    while (_running && !cancel.isCancelled) {
      try {
        final resp = await _api.get('/traffic',
            cancelToken: cancel,
            options: Options(responseType: ResponseType.stream));
        final stream = resp.data.stream as Stream<List<int>>;
        await for (final chunk in stream) {
          if (cancel.isCancelled || !_running) break;
          _trafficBuf.addAll(chunk);
          if (_trafficBuf.length > 64 * 1024) _trafficBuf.removeRange(0, _trafficBuf.length - 4096);
          while (true) {
            final nl = _trafficBuf.indexOf(0x0A);
            if (nl < 0) break;
            final line = utf8.decode(_trafficBuf.sublist(0, nl)).trim();
            _trafficBuf.removeRange(0, nl + 1);
            if (line.isEmpty) continue;
            try {
              final obj = jsonDecode(line);
              if (obj is Map && obj['up'] is num && obj['down'] is num) {
                _onTraffic?.call(
                  (obj['up'] as num) / 1024 / 1024,
                  (obj['down'] as num) / 1024 / 1024,
                );
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
      if (!_running || cancel.isCancelled) break;
      await Future.delayed(const Duration(seconds: 2));
    }
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _trafficCancel?.cancel();
    _api.close(force: true);
    unawaited(stop());
  }
}
