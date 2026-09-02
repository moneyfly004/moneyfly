import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'proxy_core.dart';

/// Android 内核：通过 MethodChannel 驱动 VpnService（内含 sing-box 子进程），
/// 切模式/切节点走本地 Clash API（与桌面端一致，热更新不断网）。
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
    if (_running) throw StateError('内核已在运行');
    _lastError = null;
    try {
      // Android 原生端期望 JSON 字符串（非 Map），写入文件后传给 sing-box
      final configJson = jsonEncode(config);
      await _channel.invokeMethod('startVpn', {'config': configJson});
    } catch (e) {
      _lastError = '启动 VPN 服务失败：$e';
      throw UnsupportedError(_lastError!);
    }
    // 等 Clash API 就绪（sing-box 子进程启动完成）
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 12)) {
      try {
        final r = await _api.get('/version', options: Options(validateStatus: (s) => true));
        if (r.statusCode == 200) {
          _running = true;
          _startWatchdog();
          return;
        }
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    }
    _lastError = '内核启动超时（12s）';
    throw UnsupportedError(_lastError!);
  }

  @override
  Future<void> stop() async {
    _watchdog?.cancel();
    _watchdog = null;
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
    if (!_running) throw StateError('内核未运行');
    await _api.request(path,
        data: body,
        options: Options(method: method, validateStatus: (s) => s != null && s >= 200 && s < 300));
  }

  /// 看门狗：每 3s 探活 Clash API，内核异常退出时触发重连回调
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!_running) return;
      try {
        final r = await _api.get('/version', options: Options(validateStatus: (s) => true));
        if (r.statusCode != 200) {
          _running = false;
          _lastError = '内核异常退出';
          _onUnexpectedExit?.call();
        }
      } catch (_) {
        _running = false;
        _lastError = '内核异常退出';
        _onUnexpectedExit?.call();
      }
    });
  }

  @override
  void dispose() {
    _watchdog?.cancel();
    _api.close(force: true);
    unawaited(stop());
  }
}
