import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/geo_lookup.dart';
import '../services/settings_store.dart';
import '../services/speed_tester.dart';
import 'proxy_core_android.dart';
import 'proxy_core_cli.dart';
import 'singbox_config.dart';
import 'system_proxy.dart';

/// 连接状态
enum ConnStatus { disconnected, testing, connecting, connected, reconnecting, error }

/// 代理核心抽象：各平台实现（macOS/Windows/Linux 走 sing-box CLI；Android 待 libcore）
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

  /// 内核异常退出（非主动断开）回调 → 控制器自动重连
  VoidCallback? get onUnexpectedExit;
  set onUnexpectedExit(VoidCallback? cb);

  /// 实时速率回调（MB/s）
  void Function(double upMbps, double downMbps)? get onTraffic;
  set onTraffic(void Function(double upMbps, double downMbps)? cb);

  /// 释放资源
  void dispose();
}

/// 平台内核工厂
class ProxyCoreFactory {
  static ProxyCore create() {
    if (Platform.isAndroid) return ProxyCoreAndroid();
    if (Platform.isIOS) return _UnavailableCore();
    return ProxyCoreCli();
  }
}

/// Android 占位实现（VpnService 骨架已就绪，待 libcore aar 接入）
class _UnavailableCore implements ProxyCore {
  bool _running = false;
  String? _error = '当前平台的内核尚未接入：Android 需 libcore（下一阶段）；桌面端已内置 sing-box。';

  @override
  Future<void> start(Map<String, dynamic> config) async {
    _error = '当前平台的内核尚未接入：Android 需 libcore（下一阶段）；桌面端已内置 sing-box。';
    throw UnsupportedError('当前平台内核未接入');
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

  @override
  VoidCallback? get onUnexpectedExit => null;

  @override
  set onUnexpectedExit(VoidCallback? cb) {}

  @override
  void Function(double upMbps, double downMbps)? get onTraffic => null;

  @override
  set onTraffic(void Function(double upMbps, double downMbps)? cb) {}

  @override
  void dispose() {}
}

/// 全局连接控制器：状态机 + 自动测速选优 + 断线重连 + 后台测速
class ConnectionController extends ChangeNotifier {
  ConnectionController._() {
    _core.onUnexpectedExit = onDisconnectedUnexpectedly;
    _core.onTraffic = _onTraffic;
  }
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
  String protocolFilter = 'all'; // all / vless / trojan

  /// 后台测速中（已连接状态下并行测速；不阻塞连接，仅用于 UI 提示）
  bool speedTesting = false;

  /// 实时速率（MB/s）——由内核 /traffic 1s 推送
  double upSpeedMbps = 0;
  double downSpeedMbps = 0;

  /// 真实出口国家码（连接后通过隧道 IP 定位实测，非节点名猜测）
  String? realCountry;
  bool _geoLookingUp = false;

  /// 连接成功后实测出口国家（失败静默，不阻塞连接）
  Future<void> refreshRealCountry() async {
    if (_geoLookingUp || status != ConnStatus.connected) return;
    _geoLookingUp = true;
    try {
      final code = await GeoLookupService.instance.lookupViaProxy();
      if (status == ConnStatus.connected) {
        realCountry = code;
        notifyListeners();
      }
    } finally {
      _geoLookingUp = false;
    }
  }

  /// 从设置项同步连接行为（设置页 / 启动时调用）
  void applySettings(Map<String, dynamic> s) {
    if (s['autoTest'] is bool) autoTest = s['autoTest'] as bool;
    if (s['autoReconnect'] is bool) autoReconnect = s['autoReconnect'] as bool;
    if (s['defaultMode'] == 'global') {
      smartMode = false;
    } else if (s['defaultMode'] == 'smart') {
      smartMode = true;
    }
    final pf = s['protocolFilter']?.toString() ?? 'all';
    if (pf == 'vless' || pf == 'trojan' || pf == 'all') protocolFilter = pf;
    notifyListeners();
  }

  /// 首页自动测速开关（带通知，保证 UI 即时刷新）
  void setAutoTest(bool v) {
    autoTest = v;
    notifyListeners();
  }

  Timer? _reconnectTimer;
  Timer? _bgTestTimer;
  int _reconnectCount = 0;
  int _epoch = 0;
  bool _autoConnectTried = false;

  Future<void> loadNodes(List<ProxyNode> list) {
    // 协议过滤（设置 → 节点列表实际效果）
    nodes = protocolFilter == 'all'
        ? list
        : list.where((n) => n.type == protocolFilter).toList();
    if (current != null && !nodes.any((n) => n.tag == current!.tag)) {
      current = null;
    }
    notifyListeners();
    return Future.value();
  }

  /// 启动时自动连接（设置 autoConnect=true 时由首页在订阅加载完成后调用，仅一次）
  Future<void> autoConnectIfEnabled() async {
    if (_autoConnectTried || status != ConnStatus.disconnected) return;
    _autoConnectTried = true;
    final s = await SettingsStore.instance.load();
    if (s['autoConnect'] == true && nodes.isNotEmpty) {
      await connect();
    }
  }

  /// 连接（Hiddify 模式）：立即启动内核 → 已连接 → 后台自动测速切换最优节点。
  /// 测速绝不阻塞连接：点连接立刻生效，测速在后台并行，完成后自动切换更优节点。
  /// _epoch 守卫：连接过程中用户断开/再次连接时，旧流程的结果不再覆盖状态
  Future<void> connect({bool runSpeedTest = true}) async {
    if (nodes.isEmpty) {
      error = '没有可用节点，请先刷新订阅';
      notifyListeners();
      return;
    }
    final epoch = ++_epoch;
    _reconnectTimer?.cancel();
    // 从设置读取连接行为（设置 → 实际效果）
    final settings = await SettingsStore.instance.load();
    autoTest = settings['autoTest'] == true;
    autoReconnect = settings['autoReconnect'] == true;
    final dns = settings['dns']?.toString() ?? '223.5.5.5';
    final defaultMode = settings['defaultMode']?.toString() ?? 'smart';
    smartMode = defaultMode != 'global';
    // 桌面端（macOS/Windows）默认「仅系统代理」：TUN 需要 root 权限，
    // 默认开启会导致用户一点连接就失败（operation not permitted）；
    // Android 默认「TUN + 系统代理双通道」：VpnService 授权后 TUN 接管全部流量。
    final defaultTunMode = (Platform.isAndroid || Platform.isIOS) ? 'auto' : 'off';
    final tunMode = settings['tunMode']?.toString() ?? defaultTunMode;
    final bypassLan = settings['bypassLan'] != false;
    final intervalMin = (settings['testIntervalMin'] as num?)?.toInt() ?? 30;
    if (epoch != _epoch) return;

    status = ConnStatus.connecting;
    error = null;
    notifyListeners();

    // 立即选定节点：优先当前选中（用户手动选的/上次最优），否则第一个在线节点。
    // 不做任何测速等待 —— 内核立刻启动，连接即刻生效。
    current ??= nodes.firstWhere((n) => n.online, orElse: () => nodes.first);
    if (epoch != _epoch) return;
    if (current == null) {
      status = ConnStatus.error;
      error = '所有节点均不可用';
      notifyListeners();
      return;
    }

    try {
      final cfg = SingBoxConfigBuilder.build(
        nodes: nodes,
        selectedTag: current!.tag,
        smartMode: smartMode,
        dns: dns,
        tunMode: tunMode,
        bypassLan: bypassLan,
        ruleSetDir: Platform.isAndroid || Platform.isIOS ? null : ProxyCoreCli.workDir,
      );
      await _core.start(cfg);
      if (epoch != _epoch) return;
      status = ConnStatus.connected;
      _reconnectCount = 0;
      // 后台测速：不阻塞连接，完成后自动切最优（测速期间保持已连接）
      if (runSpeedTest && autoTest) {
        unawaited(_autoSpeedTestAndSwitch(epoch));
      }
      _startBackgroundTest(intervalMin);
      unawaited(refreshRealCountry()); // 实测真实出口国家
    } catch (e) {
      if (epoch != _epoch) return;
      status = ConnStatus.error;
      error = e is UnsupportedError ? _core.lastError ?? e.message : e.toString();
      // 内核启动失败但系统代理可能已设置 → 恢复，避免残留指向死端口
      if (SystemProxyManager.isApplied) {
        unawaited(SystemProxyManager.restore());
      }
    }
    notifyListeners();
  }

  /// 后台测速 + 自动切换最优节点（不阻塞连接；测速中保持已连接状态，
  /// UI 通过 speedTesting 标记显示「测速中」）
  Future<void> _autoSpeedTestAndSwitch(int epoch) async {
    speedTesting = true;
    notifyListeners();
    try {
      final tested = await SpeedTester.instance.testAll(nodes);
      if (epoch != _epoch) return;
      nodes = tested;
      final best = SpeedTester.selectBest(tested);
      lastSpeedTestTime = _now();
      if (best != null && status == ConnStatus.connected) {
        final cur = current;
        final curOnline =
            nodes.firstWhere((n) => n.tag == cur?.tag, orElse: () => cur!);
        // 仅在最优节点明显更好（快 100ms 以上）或当前节点离线时切换，
        // 避免频繁切换造成抖动。
        if (cur == null ||
            !curOnline.online ||
            (best.latencyMs >= 0 && curOnline.latencyMs >= 0 &&
                best.latencyMs < curOnline.latencyMs - 100)) {
          await switchNode(best);
        }
      }
    } catch (_) {
      // 测速失败不影响已建立的连接
    } finally {
      if (epoch == _epoch) {
        speedTesting = false;
        notifyListeners();
      }
    }
  }

  Future<void> disconnect() async {
    _epoch++; // 使在途的 connect 流程失效（“取消连接”语义）
    _reconnectTimer?.cancel();
    _bgTestTimer?.cancel();
    speedTesting = false;
    upSpeedMbps = 0;
    downSpeedMbps = 0;
    await _core.stop();
    status = ConnStatus.disconnected;
    error = null;
    realCountry = null;
    notifyListeners();
  }

  /// 切换节点（热切换；失败则提示；成功后重测真实出口国家）
  Future<void> switchNode(ProxyNode node) async {
    current = node;
    notifyListeners();
    if (status == ConnStatus.connected) {
      try {
        await _core.switchNode(node.tag);
        realCountry = null;
        unawaited(refreshRealCountry());
      } catch (e) {
        error = '节点热切换失败：$e';
        notifyListeners();
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
      } catch (e) {
        error = '模式切换失败：$e';
        notifyListeners();
      }
    }
  }

  /// 断线重连调度（内核异常退出时由 core 回调）
  void onDisconnectedUnexpectedly() {
    if (status != ConnStatus.connected && status != ConnStatus.reconnecting) {
      return; // 用户主动断开/未连接时不重连
    }
    if (!autoReconnect || _reconnectCount >= 3) {
      status = ConnStatus.disconnected;
      error = autoReconnect ? '重连 3 次仍失败，已断开' : '连接已断开';
      // 内核已死且不再重连 → 必须恢复系统代理，否则残留指向死端口，
      // 整个系统流量中断（设置页「断线自动重连」关闭或重连超限时必现）
      unawaited(SystemProxyManager.restore());
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

  void _onTraffic(double upMbps, double downMbps) {
    upSpeedMbps = upMbps;
    downSpeedMbps = downMbps;
    notifyListeners();
  }

  /// 后台定时测速（设置 testIntervalMin；仅已连接时运行，断开即停 → 省电）
  void _startBackgroundTest(int intervalMin) {
    _bgTestTimer?.cancel();
    if (intervalMin <= 0) return;
    _bgTestTimer = Timer.periodic(Duration(minutes: intervalMin), (_) async {
      if (status != ConnStatus.connected || nodes.isEmpty) return;
      final tested = await SpeedTester.instance.testAll(nodes);
      if (status != ConnStatus.connected) return;
      nodes = tested;
      final best = SpeedTester.selectBest(tested);
      final cur = current;
      if (best == null || cur == null) return;
      // 当前节点劣化（离线 或 比最优慢 100ms 以上）→ 静默切到更优节点
      final curOnline = nodes.firstWhere(
          (n) => n.tag == cur.tag, orElse: () => cur);
      if (!curOnline.online ||
          (best.latencyMs >= 0 && curOnline.latencyMs >= 0 &&
              best.latencyMs < curOnline.latencyMs - 100)) {
        await switchNode(best);
      }
      lastSpeedTestTime = _now();
      notifyListeners();
    });
  }

  String _now() {
    final t = DateTime.now();
    return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _bgTestTimer?.cancel();
    _core.dispose();
    super.dispose();
  }
}
