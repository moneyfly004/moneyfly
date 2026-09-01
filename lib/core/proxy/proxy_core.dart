import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'singbox_config.dart';

/// 连接状态
enum ConnStatus { disconnected, testing, connecting, connected, reconnecting, error }

/// 代理核心抽象：阶段 3 接入 sing-box 时实现平台通道
abstract class ProxyCore {
  /// 启动内核并加载配置
  Future<void> start(Map<String, dynamic> config);

  /// 停止内核（断开）
  Future<void> stop();

  /// 热切换模式（智能/全局）——走 Clash API，不断网
  Future<void> switchMode(bool smart);

  /// 热切换节点——走 Clash API 改 selector
  Future<void> switchNode(String tag);

  /// 当前是否运行中
  bool get isRunning;

  /// 最近一次错误
  String? get lastError;
}

/// 平台内核工厂（阶段 3 替换为真实实现）
class ProxyCoreFactory {
  static ProxyCore create() => _UnavailableCore();
}

/// 未接入内核时的占位实现：明确提示，不静默失败
class _UnavailableCore implements ProxyCore {
  bool _running = false;
  String? _error = '代理内核尚未接入（阶段 3：sing-box）。当前为演示模式，无法建立真实隧道。';

  @override
  Future<void> start(Map<String, dynamic> config) async {
    _error = '代理内核尚未接入（阶段 3：sing-box）。当前为演示模式，无法建立真实隧道。';
    throw UnsupportedError('代理内核未接入');
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<void> switchMode(bool smart) async {}

  @override
  Future<void> switchNode(String tag) async {}

  @override
  bool get isRunning => _running;

  @override
  String? get lastError => _error;
}

/// 全局连接控制器：状态机 + 自动测速选优 + 断线重连
class ConnectionController extends ChangeNotifier {
  ConnectionController._();
  static final ConnectionController instance = ConnectionController._();

  final ProxyCore _core = ProxyCoreFactory.create();

  ConnStatus status = ConnStatus.disconnected;
  List<ProxyNode> nodes = [];
  ProxyNode? current;
  String? error;
  bool smartMode = true;
  bool autoTest = true;
  bool autoReconnect = true;
  String? lastSpeedTestTime;

  Timer? _reconnectTimer;
  int _reconnectCount = 0;

  Future<void> loadNodes(List<ProxyNode> list) {
    nodes = list;
    notifyListeners();
    return Future.value();
  }

  /// 连接：测速（可选）→ 选最优 → 启动内核
  Future<void> connect({bool runSpeedTest = true}) async {
    if (nodes.isEmpty) {
      error = '没有可用节点，请先刷新订阅';
      notifyListeners();
      return;
    }
    status = ConnStatus.testing;
    error = null;
    notifyListeners();

    if (runSpeedTest && autoTest) {
      final tested = await SpeedTester.instance.testAll(nodes);
      nodes = tested;
      final best = SpeedTester.selectBest(tested);
      if (best != null) current = best;
      lastSpeedTestTime = _now();
    } else {
      current ??= nodes.firstWhere((n) => n.online, orElse: () => nodes.first);
    }
    if (current == null) {
      status = ConnStatus.error;
      error = '所有节点均不可用';
      notifyListeners();
      return;
    }

    status = ConnStatus.connecting;
    notifyListeners();
    try {
      final cfg = SingBoxConfigBuilder.build(
        nodes: nodes,
        selectedTag: current!.tag,
        smartMode: smartMode,
      );
      await _core.start(cfg);
      status = ConnStatus.connected;
      _reconnectCount = 0;
    } catch (e) {
      status = ConnStatus.error;
      error = e is UnsupportedError ? _core.lastError ?? e.message : e.toString();
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _reconnectTimer?.cancel();
    await _core.stop();
    status = ConnStatus.disconnected;
    notifyListeners();
  }

  /// 切换节点（热切换；失败则提示）
  Future<void> switchNode(ProxyNode node) async {
    current = node;
    notifyListeners();
    if (status == ConnStatus.connected) {
      try {
        await _core.switchNode(node.tag);
      } catch (_) {
        // 阶段 3 前无真实内核，仅更新选中
      }
    }
  }

  /// 切换模式（智能/全局）
  Future<void> toggleMode(bool smart) async {
    smartMode = smart;
    notifyListeners();
    if (status == ConnStatus.connected) {
      try {
        await _core.switchMode(smart);
      } catch (_) {}
    }
  }

  /// 断线重连调度（阶段 3 接内核断线回调时调用）
  void onDisconnectedUnexpectedly() {
    if (!autoReconnect || _reconnectCount >= 3) {
      status = ConnStatus.disconnected;
      notifyListeners();
      return;
    }
    status = ConnStatus.reconnecting;
    notifyListeners();
    _reconnectCount++;
    final delay = [1, 2, 5][(_reconnectCount - 1).clamp(0, 2)];
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delay), () => connect(runSpeedTest: true));
  }

  String _now() {
    final t = DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    super.dispose();
  }
}

/// 节点测速工具（供 ConnectionController 使用）
class SpeedTester {
  SpeedTester._();
  static final SpeedTester instance = SpeedTester._();

  static const _connectTimeout = Duration(seconds: 5);
  static const _probeCount = 3;
  static const _maxConcurrent = 12;

  Future<int> testOne(ProxyNode node) async {
    final samples = <int>[];
    for (var i = 0; i < _probeCount; i++) {
      final sw = Stopwatch()..start();
      try {
        final socket = await Socket.connect(node.server, node.port, timeout: _connectTimeout);
        await socket.close();
        sw.stop();
        samples.add(sw.elapsedMilliseconds);
      } catch (_) {
        return -1;
      }
    }
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  Future<List<ProxyNode>> testAll(List<ProxyNode> nodes, {void Function(int, int)? onProgress}) async {
    final result = List<ProxyNode>.of(nodes);
    final queue = List<int>.generate(result.length, (i) => i);
    var done = 0;

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final idx = queue.removeLast();
        final ms = await testOne(result[idx]);
        result[idx].latencyMs = ms;
        result[idx].online = ms >= 0;
        done++;
        onProgress?.call(done, result.length);
      }
    }

    final count = result.isEmpty ? 1 : (result.length < _maxConcurrent ? result.length : _maxConcurrent);
    await Future.wait(List.generate(count, (_) => worker()));
    return result;
  }

  static ProxyNode? selectBest(List<ProxyNode> nodes) {
    final online = nodes.where((n) => n.online && n.latencyMs >= 0).toList();
    if (online.isEmpty) return null;
    online.sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
    return online.first;
  }

  static Map<String, int> bestLatencyByCountry(List<ProxyNode> nodes) {
    final map = <String, int>{};
    for (final n in nodes) {
      if (!n.online || n.latencyMs < 0) continue;
      final code = n.countryCode ?? 'XX';
      final cur = map[code];
      if (cur == null || n.latencyMs < cur) map[code] = n.latencyMs;
    }
    return map;
  }
}
