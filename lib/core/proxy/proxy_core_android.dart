import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_strings.dart';
import 'proxy_core.dart';

/// Android 内核：通过 MethodChannel 驱动 VpnService + libbox（sing-box 共享库），
/// 切模式/切节点走 Clash API 热更新，流量统计从 /traffic 流拉取。
class ProxyCoreAndroid extends ProxyCore {
  static const _channel = MethodChannel('top.moneyfly/vpn_core');
  static const clashApi = 'http://127.0.0.1:9090';

  final Dio _api = Dio(BaseOptions(
    baseUrl: clashApi,
    connectTimeout: const Duration(seconds: 3),
    receiveTimeout: const Duration(seconds: 3),
  ));

  bool _running = false;
  String? _lastError;
  VoidCallback? _onUnexpectedExit;
  void Function(double upMbps, double downMbps)? _onTraffic;
  Timer? _watchdog;
  CancelToken? _trafficCancel;
  final List<int> _trafficBuf = [];

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
    config.remove('_tunMode');
    final inbounds = config['inbounds'];
    if (inbounds is List) {
      for (final ib in inbounds) {
        if (ib is Map && ib['type'] == 'tun') {
          ib['auto_route'] = false;
          ib['strict_route'] = false;
          ib['stack'] = 'gvisor';
        }
      }
    }
    try {
      await _channel.invokeMethod('startVpn', {'config': jsonEncode(config)});
    } catch (e) {
      _lastError = AppStrings.t('vpn_start_fail', {'err': '$e'});
      throw UnsupportedError(_lastError!);
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
    _lastError = AppStrings.t('kernel_timeout');
    throw UnsupportedError(_lastError!);
  }

  @override
  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
    _trafficCancel?.cancel();
    _trafficCancel = null;
    try {
      await _channel.invokeMethod('stopVpn');
    } catch (_) {}
    _running = false;
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
    if (!_running) throw StateError('not running');
    await _api.request(path,
        data: body,
        options: Options(method: method, validateStatus: (s) => s != null && s >= 200 && s < 300));
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!_running) return;
      try {
        final r = await _api.get('/version', options: Options(validateStatus: (s) => true));
        if (r.statusCode != 200) _onKernelDead();
      } catch (_) {
        _onKernelDead();
      }
    });
  }

  void _onKernelDead() {
    _running = false;
    _lastError = AppStrings.t('kernel_exit');
    _trafficCancel?.cancel();
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
