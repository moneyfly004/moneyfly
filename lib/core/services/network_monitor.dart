import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../proxy/proxy_core.dart';

/// 网络变化监听：WiFi↔蜂窝切换 / 断网→恢复时通知 ConnectionController
/// 触发快速重连（3s 去抖，避免切换瞬间连续触发）
class NetworkMonitor {
  NetworkMonitor._();
  static final NetworkMonitor instance = NetworkMonitor._();

  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _debounce;
  List<ConnectivityResult>? _prev;

  void start() {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return;
    stop();
    _sub = Connectivity().onConnectivityChanged.listen(_onChange);
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _debounce?.cancel();
    _debounce = null;
    _prev = null;
  }

  void _onChange(List<ConnectivityResult> results) {
    if (_prev != null && !listEquals(results, _prev) && !results.contains(ConnectivityResult.none)) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 3), () {
        ConnectionController.instance.onNetworkChanged();
      });
    }
    _prev = results;
  }
}
