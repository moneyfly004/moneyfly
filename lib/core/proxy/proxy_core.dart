import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/models.dart';
import '../services/account_service.dart';
import '../services/app_log.dart';
import '../services/geo_lookup.dart';
import '../services/local_notify.dart';
import '../services/settings_store.dart';
import '../services/speed_tester.dart';
import 'proxy_core_android.dart';
import 'proxy_core_cli.dart';
import 'rule_assets.dart';
import 'singbox_config.dart';
import 'system_proxy.dart';
import '../../l10n/app_strings.dart';
import 'conn_error.dart';
export 'conn_error.dart';

/// 后台 isolate 入口：构建 sing-box JSON 配置（800+ outbound 时 ~50-100ms，
/// 放后台避免阻塞 UI 线程导致连接按钮卡顿）。compute 要求顶层/静态函数。
Map<String, dynamic> _buildConfigInIsolate(Map<String, dynamic> args) {
  final proxies = (args['proxies'] as List).cast<Map<String, dynamic>>();
  final nodes = proxies.map((m) => ProxyNode.fromClashMap(m)).toList();
  return SingBoxConfigBuilder.build(
    nodes: nodes,
    selectedTag: args['selectedTag'] as String,
    smartMode: args['smartMode'] as bool,
    dns: args['dns'] as String,
    tunMode: args['tunMode'] as String,
    bypassLan: args['bypassLan'] as bool,
    localPort: (args['localPort'] as num?)?.toInt() ?? 2080,
    clashApiPort: (args['clashApiPort'] as num?)?.toInt() ?? 9090,
    ruleSetDir: args['ruleSetDir'] as String?,
  );
}

/// 连接状态
enum ConnStatus { disconnected, disconnecting, testing, connecting, connected, reconnecting, error }

/// 速率快照（流量统计 1s 一次，独立于 ConnectionController 的通知）
class SpeedSnapshot {
  const SpeedSnapshot({this.upMbps = 0, this.downMbps = 0});
  final double upMbps;
  final double downMbps;
}

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

  /// 通过内核测节点延迟(ms)：走 Clash API /proxies/{tag}/delay，用真实协议+
  /// 隧道实测，UDP(hysteria2/tuic)与被墙 TCP 节点都能测准。失败/未运行返回 -1。
  /// [url] 测速探测地址（设置页可改，默认 gstatic 204）。
  Future<int> testNodeDelay(String tag,
      {Duration timeout = const Duration(seconds: 5), String? url});

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
  @override
  Future<void> start(Map<String, dynamic> config) async =>
      throw UnsupportedError('当前平台内核未接入');
  @override
  Future<void> stop() async {}
  @override
  Future<void> switchMode(bool smart) async {}
  @override
  Future<void> switchNode(String tag) async {}
  @override
  Future<int> testNodeDelay(String tag,
      {Duration timeout = const Duration(seconds: 5), String? url}) async => -1;
  @override
  bool get isRunning => false;
  @override
  String? get lastError => '当前平台的内核尚未接入';
  @override
  VoidCallback? get onUnexpectedExit => null;
  @override
  set onUnexpectedExit(VoidCallback? cb) {}
  @override
  void Function(double, double)? get onTraffic => null;
  @override
  set onTraffic(void Function(double, double)? cb) {}
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

  /// 最近一次连接失败的类型（首页错误区按类型给不同引导；非错误态为 none）
  ConnErrorKind errorKind = ConnErrorKind.none;

  /// 测速探测地址（设置页可改；内核 delay 测试用，默认谷歌 204）
  static const defaultTestUrl = 'http://www.gstatic.com/generate_204';
  String testUrl = defaultTestUrl;
  bool smartMode = true;
  bool autoTest = true;
  bool autoReconnect = true;
  String? lastSpeedTestTime;
  /// 用户是否手动切换过模式（智能/全局）。
  /// true 后 applySettings 不再用设置里的 defaultMode 覆盖（首页选择优先）。
  bool _modeUserSet = false;

  /// 用户手动选定的国家码（快速切换国家 / 节点选择器手动切换后锁定）。
  /// 非 null 时，后台测速和自动选优只在该国家范围内切换，不会跳到其他国家。
  /// 首次连接（自动选最优）/ disconnect / resetForLogout / unlockCountry 时清空。
  String? lockedCountry;

  /// 解除国家锁定，回到全局自动选优。已连接时立刻测速并切换到全局最优。
  Future<void> unlockCountry() async {
    lockedCountry = null;
    notifyListeners();
    if (status == ConnStatus.connected && autoTest) {
      await _autoSpeedTestAndSwitch(_epoch, forceBest: true);
    }
  }

  /// 后台测速中（已连接状态下并行测速；不阻塞连接，仅用于 UI 提示）
  bool speedTesting = false;

  /// 实时速率（MB/s）——由内核 /traffic 1s 推送。
  /// 用独立 ValueNotifier：每秒更新只通知速率监听者（首页速率卡片），
  /// 不触发整个 ConnectionController 重建（避免首页每秒全量 rebuild）。
  double upSpeedMbps = 0;
  double downSpeedMbps = 0;
  final ValueNotifier<SpeedSnapshot> speedNotifier = ValueNotifier(const SpeedSnapshot());

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
    final u = s['testUrl']?.toString();
    if (u != null && u.trim().isNotEmpty) testUrl = u.trim();
    // 仅在用户未手动切过模式时应用 defaultMode，避免首页选择被设置页静默重置
    if (!_modeUserSet) {
      if (s['defaultMode'] == 'global') {
        smartMode = false;
      } else if (s['defaultMode'] == 'smart') {
        smartMode = true;
      }
    }
    notifyListeners();
  }

  /// 首页自动测速开关（带通知，保证 UI 即时刷新；持久化，重启后保留）
  void setAutoTest(bool v) {
    autoTest = v;
    notifyListeners();
    // 合并持久化（不丢其他设置项）
    unawaited(() async {
      try {
        final s = await SettingsStore.instance.load();
        s['autoTest'] = v;
        await SettingsStore.instance.save(s);
      } catch (_) {}
    }());
  }

  Timer? _reconnectTimer;
  Timer? _bgTestTimer;
  Timer? _wakeLockTimer;
  int _reconnectCount = 0;
  int _epoch = 0;
  bool _autoConnectTried = false;

  Future<void> loadNodes(List<ProxyNode> list) async {
    nodes = _carryMeasuredLatency(list, nodes);
    if (current != null && !nodes.any((n) => n.tag == current!.tag)) {
      current = null;
    }
    notifyListeners();
  }

  /// 新列表节点若本身无测速结果（latencyMs<0），且旧列表存在同 tag 且测过
  /// 延迟（latencyMs>=0），则沿用旧测速值 —— 测速结果保留到下次真正测速，
  /// 不被订阅/配置刷新冲掉。自带测速结果的新节点（内核/纯 TCP 回填）不动。
  List<ProxyNode> _carryMeasuredLatency(
      List<ProxyNode> fresh, List<ProxyNode> prev) {
    if (fresh.isEmpty || prev.isEmpty) return fresh;
    final prevByTag = <String, ProxyNode>{for (final n in prev) n.tag: n};
    for (final n in fresh) {
      if (n.latencyMs >= 0) continue;
      final old = prevByTag[n.tag];
      if (old != null && old.latencyMs >= 0) n.latencyMs = old.latencyMs;
    }
    return fresh;
  }

  /// 订阅定时/启动刷新结果接入（覆盖旧节点配置）。
  ///
  /// 已连接且当前线路不在新订阅列表中时保持现状不替换：内核仍按旧配置运行，
  /// 直接替换会让 UI 丢掉当前线路或被误判离线、打断正在使用的连接；
  /// 连接建立过程中（connecting/testing 等瞬态）也不动列表，避免与 connect()
  /// 读取当前节点竞态；断开状态下则无条件覆盖。
  Future<void> applySubscriptionNodes(List<ProxyNode> fresh) async {
    if (fresh.isEmpty) return; // 空列表不覆盖：避免清空用户可用线路
    if (status == ConnStatus.connecting ||
        status == ConnStatus.testing ||
        status == ConnStatus.reconnecting ||
        status == ConnStatus.disconnecting) {
      return;
    }
    if (status == ConnStatus.connected &&
        current != null &&
        !fresh.any((n) => n.tag == current!.tag)) {
      return;
    }
    await loadNodes(fresh);
  }

  /// 更新测速结果（节点页独立测速后调用，替换当前展示列表）
  void updateTestedNodes(List<ProxyNode> tested) {
    nodes = tested;
    if (current != null && !nodes.any((n) => n.tag == current!.tag)) {
      current = null;
    }
    notifyListeners();
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

  /// WakeLock：连接/重连时短暂持有（<5s），防止 Doze 打断握手
  void _acquireWakeLock() {
    if (!Platform.isAndroid) return;
    _wakeLockTimer?.cancel();
    try { WakelockPlus.enable(); } catch (_) {}
    _wakeLockTimer = Timer(const Duration(seconds: 5), _releaseWakeLock);
  }

  void _releaseWakeLock() {
    _wakeLockTimer?.cancel();
    _wakeLockTimer = null;
    if (!Platform.isAndroid) return;
    try { WakelockPlus.disable(); } catch (_) {}
  }

  /// 连接（Hiddify 模式）：立即启动内核 → 已连接 → 后台自动测速切换最优节点。
  /// 测速绝不阻塞连接：点连接立刻生效，测速在后台并行，完成后自动切换更优节点。
  /// [fromReconnect] 由断线重连调度发起：失败时继续重试（不中断重连链）。
  /// _epoch 守卫：连接过程中用户断开/再次连接时，旧流程的结果不再覆盖状态
  Future<void> connect({bool runSpeedTest = true, bool fromReconnect = false}) async {
    // 账号门禁：到期 / 设备满 / 被禁用 / 未开通 —— 一律不允许建立 VPN。
    // 放在最前，自动连接、断线重连、首页点连接都走同一道拦截；
    // 会话内已判定过（AccountService.loaded）才生效，内核 e2e 直连不受影响。
    final acc = AccountService.instance;
    if (acc.loaded && acc.isBlocked) {
      status = ConnStatus.disconnected;
      error = acc.blockText;
      errorKind = ConnErrorKind.none;
      notifyListeners();
      return;
    }
    if (nodes.isEmpty) {
      error = AppStrings.t('no_available_nodes');
      errorKind = ConnErrorKind.none;
      notifyListeners();
      return;
    }
    // 已连接时再次触发连接（首页「重新测速」「自动最优」）＝仅重新测速选优，
    // 不重启内核 —— 否则 start() 抛「内核已在运行」，误置错误态并还原系统代理，
    // 造成内核仍在运行但系统流量中断。
    if (status == ConnStatus.connected && _core.isRunning) {
      await retest();
      return;
    }
    final epoch = ++_epoch;
    _reconnectTimer?.cancel();
    // 重连时确保旧内核已停干净（上次 start 可能半途失败留下残留进程）
    if (_core.isRunning) {
      try { await _core.stop(); } catch (_) {}
    }
    // 从设置读取内核启动参数。smartMode / autoTest / autoReconnect 是运行时
    // 状态（启动时 applySettings 同步、设置页/首页开关即时更新），连接时不再
    // 用 defaultMode 覆盖，避免用户在首页的选择被静默重置。
    final settings = await SettingsStore.instance.load();
    final dns = settings['dns']?.toString() ?? '223.5.5.5';
    // 本机代理监听端口（设置页可改，默认 2080）：mixed 入站 + 系统代理共同指向
    final localPort = (settings['localPort'] as num?)?.toInt() ?? 2080;
    // Clash API 端口（设置页可改，默认 9090）：内核管理通道（切节点/测速/流量）
    final clashApiPort = (settings['clashApiPort'] as num?)?.toInt() ?? 9090;
    // 测速探测地址（设置页可改，默认 gstatic 204）
    final u = settings['testUrl']?.toString();
    if (u != null && u.trim().isNotEmpty) testUrl = u.trim();
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
    errorKind = ConnErrorKind.none;
    _acquireWakeLock();
    notifyListeners();

    // 优先选延迟最优（已有测速数据时）；否则先连可用节点，后台测速后自动切最优
    final best = SpeedTester.selectBest(nodes);
    current ??= best ?? nodes.firstWhere((n) => n.online, orElse: () => nodes.first);
    if (epoch != _epoch) return;
    if (current == null) {
      status = ConnStatus.error;
      error = AppStrings.t('all_nodes_offline');
      errorKind = ConnErrorKind.none;
      notifyListeners();
      return;
    }

    try {
      // 内置规则集落盘（智能模式的 CN 分流；所有平台都落地本地文件，
      // 避免回退 GitHub 远程下载在国内超时导致内核起不来）。
      // 桌面端落到内核 workDir；移动端落到 app 私有目录。失败则回退远程。
      final ruleDir = await RuleAssets.materialize(
        preferDir: (Platform.isAndroid || Platform.isIOS)
            ? null
            : ProxyCoreCli.workDir,
      );
      if (epoch != _epoch) return;
      final cfg = await compute(_buildConfigInIsolate, {
        'proxies': [for (final n in nodes) n.raw],
        'selectedTag': current!.tag,
        'smartMode': smartMode,
        'dns': dns,
        'tunMode': tunMode,
        'bypassLan': bypassLan,
        'localPort': localPort,
        'clashApiPort': clashApiPort,
        'ruleSetDir': ruleDir,
      });
      await _core.start(cfg);
      if (epoch != _epoch) {
        // 连接建立期间用户已断开/发起新连接：内核此刻才起来，若直接 return
        // 会残留一个「在跑但 UI 显示已断开」的孤儿内核（流量仍走、再连报
        // 「内核已在运行」）。必须立刻停掉。
        unawaited(_core.stop());
        return;
      }
      status = ConnStatus.connected;
      _reconnectCount = 0;
      AppLog.conn('connected via ${current?.tag} (${current?.type})');
      // 后台测速：不阻塞连接，完成后自动切最优（测速期间保持已连接）
      if (runSpeedTest && autoTest) {
        unawaited(_autoSpeedTestAndSwitch(epoch, forceBest: true));
      }
      _startBackgroundTest(intervalMin);
      unawaited(refreshRealCountry()); // 实测真实出口国家
    } catch (e) {
      if (epoch != _epoch) return;
      _releaseWakeLock();
      status = ConnStatus.error;
      AppLog.error('connect failed: $e');
      final TypedConnError? typedErr = e is TypedConnError ? e : null;
      errorKind = typedErr?.kind ?? ConnErrorKind.unknown;
      var errMsg = typedErr?.message ??
          (e is UnsupportedError ? _core.lastError ?? e.message : e.toString());
      // TUN 模式需要管理员权限（macOS/Windows），给出明确提示
      // （仅对未分类错误做文本映射；类型化错误已带明确语义，不再改写）
      if (typedErr == null && (tunMode == 'force' || tunMode == 'auto')) {
        final errLower = errMsg?.toLowerCase() ?? '';
        if (errLower.contains('permission') || errLower.contains('operation not permitted') ||
            errLower.contains('access') || errLower.contains('tun')) {
          errMsg = Platform.isMacOS
              ? AppStrings.t('tun_need_admin_mac')
              : AppStrings.t('tun_need_admin_win');
        }
      }
      error = errMsg;
      // 注意：这里不再手动 restore 系统代理 —— 代理生命周期绑定内核
      // 启停（ProxyCoreCli.start/stop），且失败路径的异步 restore 可能与
      // 下一次重连成功后的 apply 交错，出现「已连接但系统代理被误关」；
      // 系统代理异常时由连接期的保活巡检自动恢复（见 SystemProxyManager）。
      // 重连链不中断：重连发起的连接失败 → 继续调度下一次重试（最多 3 次）
      if (fromReconnect && autoReconnect && _reconnectCount < 3) {
        _scheduleReconnect();
      }
    }
    notifyListeners();
  }

  /// 统一测速入口：
  /// - 已连接(内核在跑)→ 走内核 Clash API delay，真实协议+隧道实测，
  ///   UDP(hysteria2/tuic)与被墙 TCP 节点都能测准（裸 TCP 直连对这些必失败）。
  /// - 未连接 → 回退纯 TCP 探测（SpeedTester），至少给个可达性参考。
  Future<List<ProxyNode>> testAllNodes(List<ProxyNode> list,
      {void Function(int done, int total)? onProgress}) async {
    if (status == ConnStatus.connected && _core.isRunning) {
      return _testViaKernel(list, onProgress: onProgress);
    }
    return SpeedTester.instance.testAll(list, onProgress: onProgress);
  }

  /// 经内核并发测各节点延迟（限流，避免一次性打爆内核）
  Future<List<ProxyNode>> _testViaKernel(List<ProxyNode> nodes,
      {void Function(int done, int total)? onProgress}) async {
    if (nodes.isEmpty) return nodes;
    final result = List<ProxyNode>.of(nodes);
    var nextIdx = 0;
    var done = 0;
    const maxConcurrent = 16;

    Future<void> worker() async {
      while (true) {
        final idx = nextIdx;
        if (idx >= result.length) break;
        nextIdx++;
        final ms = await _core.testNodeDelay(result[idx].tag, url: testUrl);
        result[idx].latencyMs = ms;
        result[idx].online = ms >= 0;
        done++;
        onProgress?.call(done, result.length);
      }
    }

    final count = result.length < maxConcurrent ? result.length : maxConcurrent;
    await Future.wait(List.generate(count, (_) => worker()));
    return result;
  }

  /// 在 [tested] 中按 lockedCountry 过滤后选延迟最优节点
  ProxyNode? selectBestRespectingLock(List<ProxyNode> tested) {
    if (lockedCountry == null) return SpeedTester.selectBest(tested);
    final candidates = tested.where((n) => n.countryCode == lockedCountry).toList();
    return SpeedTester.selectBest(candidates.isNotEmpty ? candidates : tested);
  }

  /// 手动重新测速并切换最优（首页「重新测速/自动最优」在已连接时走这里；
  /// 只测速+热切换节点，不重启内核、不断网）
  Future<void> retest() async {
    if (nodes.isEmpty || speedTesting) return;
    await _autoSpeedTestAndSwitch(_epoch, forceBest: true);
  }

  /// 后台测速 + 自动切换最优节点（不阻塞连接；测速中保持已连接状态，
  /// UI 通过 speedTesting 标记显示「测速中」）。
  /// 尊重 [lockedCountry]：用户手动选了国家后，只在该国范围内选最优。
  Future<void> _autoSpeedTestAndSwitch(int epoch, {bool forceBest = false}) async {
    speedTesting = true;
    notifyListeners();
    try {
      final tested = await testAllNodes(nodes);
      if (epoch != _epoch) return;
      nodes = tested;
      final best = selectBestRespectingLock(tested);
      lastSpeedTestTime = _now();
      if (best != null && status == ConnStatus.connected && _core.isRunning) {
        if (forceBest) {
          await switchNode(best, userInitiated: false);
        } else {
          final cur = current;
          if (cur == null) {
            await switchNode(best, userInitiated: false);
          } else {
            final curOnline =
                nodes.firstWhere((n) => n.tag == cur.tag, orElse: () => cur);
            if (!curOnline.online ||
                (best.latencyMs >= 0 && curOnline.latencyMs >= 0 &&
                    best.latencyMs < curOnline.latencyMs - 100)) {
              await switchNode(best, userInitiated: false);
            }
          }
        }
      }
    } catch (_) {
      // 测速失败不影响已建立的连接
    } finally {
      speedTesting = false;
      notifyListeners();
    }
  }

  void _clearState() {
    speedTesting = false;
    upSpeedMbps = 0;
    downSpeedMbps = 0;
    speedNotifier.value = const SpeedSnapshot();
    status = ConnStatus.disconnected;
    error = null;
    errorKind = ConnErrorKind.none;
    realCountry = null;
    lockedCountry = null;
  }

  Future<void> disconnect() async {
    _epoch++;
    AppLog.conn('disconnect requested');
    _reconnectTimer?.cancel();
    _bgTestTimer?.cancel();
    _releaseWakeLock();
    status = ConnStatus.disconnecting;
    notifyListeners();
    _clearState();
    try {
      await _core.stop();
    } catch (_) {}
    notifyListeners();
  }

  Future<void> resetForLogout() async {
    _epoch++;
    _reconnectTimer?.cancel();
    _bgTestTimer?.cancel();
    _clearState();
    try {
      await _core.stop();
    } catch (_) {}
    nodes = [];
    current = null;
    _autoConnectTried = false;
    notifyListeners();
  }

  /// 切换节点（热切换；失败则提示；成功后重测真实出口国家）。
  /// [userInitiated] 用户手动切换（首页国家/节点选择器）→ 锁定该国家，
  /// 后台测速不再跳到其他国家；自动选优调用时传 false 不改锁定状态。
  Future<void> switchNode(ProxyNode node, {bool userInitiated = true}) async {
    current = node;
    if (userInitiated) lockedCountry = node.countryCode;
    notifyListeners();
    if (status == ConnStatus.connected && _core.isRunning) {
      try {
        await _core.switchNode(node.tag);
        realCountry = null;
        unawaited(refreshRealCountry());
      } catch (e) {
        error = AppStrings.t('node_switch_fail', {'err': '$e'});
        errorKind = ConnErrorKind.none;
        notifyListeners();
      }
    }
  }

  /// 切换模式（智能/全局）
  Future<void> toggleMode(bool smart) async {
    _modeUserSet = true;
    smartMode = smart;
    notifyListeners();
    if (status == ConnStatus.connected && _core.isRunning) {
      try {
        await _core.switchMode(smart);
      } catch (e) {
        error = AppStrings.t('mode_switch_fail', {'err': '$e'});
        errorKind = ConnErrorKind.none;
        notifyListeners();
      }
    }
  }

  /// 网络环境变化（WiFi↔蜂窝切换）：已连接且内核在跑时，不重启内核，
  /// 仅重新测速选优（内核的 TCP/UDP 连接会自动恢复，重启反而断流）。
  void onNetworkChanged() {
    if (status != ConnStatus.connected || !_core.isRunning) return;
    unawaited(retest());
  }

  /// 内核异常退出回调：未连接/用户主动断开时忽略，否则走重连或放弃
  void onDisconnectedUnexpectedly() {
    AppLog.kernel('unexpected exit, status=$status, autoReconnect=$autoReconnect, count=$_reconnectCount');
    if (status != ConnStatus.connected && status != ConnStatus.reconnecting) {
      return; // 用户主动断开/未连接时不重连
    }
    if (!autoReconnect || _reconnectCount >= 3) {
      status = ConnStatus.disconnected;
      error = autoReconnect ? AppStrings.t('reconnect_exhausted') : AppStrings.t('disconnected_hint');
      errorKind = ConnErrorKind.none;
      unawaited(SystemProxyManager.restore());
      LocalNotify.instance.showReconnectFailed();
      notifyListeners();
      return;
    }
    _scheduleReconnect();
  }

  /// 调度下一次重连（onDisconnectedUnexpectedly 与重连失败共用，
  /// 保证链条连续：第 1 次失败 → 第 2 次 → 第 3 次 → 放弃）
  void _scheduleReconnect() {
    status = ConnStatus.reconnecting;
    notifyListeners();
    _reconnectCount++;
    final delay = [1, 2, 5][(_reconnectCount - 1).clamp(0, 2)];
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
        Duration(seconds: delay), () => connect(runSpeedTest: true, fromReconnect: true));
  }

  void _onTraffic(double upMbps, double downMbps) {
    upSpeedMbps = upMbps;
    downSpeedMbps = downMbps;
    // 只更新速率快照，不 notifyListeners —— 首页速率卡片用
    // ValueListenableBuilder(speedNotifier) 局部刷新，整页不重建
    speedNotifier.value = SpeedSnapshot(upMbps: upMbps, downMbps: downMbps);
  }

  /// 后台定时测速（设置 testIntervalMin；仅已连接时运行，断开即停 → 省电）。
  /// 尊重 [lockedCountry]：用户手动选了国家后，只在该国范围内切换。
  void _startBackgroundTest(int intervalMin) {
    _bgTestTimer?.cancel();
    if (intervalMin <= 0) return;
    _bgTestTimer = Timer.periodic(Duration(minutes: intervalMin), (_) async {
      if (status != ConnStatus.connected || nodes.isEmpty || !_core.isRunning) return;
      final tested = await testAllNodes(nodes);
      if (status != ConnStatus.connected) return;
      nodes = tested;
      final best = selectBestRespectingLock(tested);
      final cur = current;
      if (best == null || cur == null) return;
      final curOnline = nodes.firstWhere(
          (n) => n.tag == cur.tag, orElse: () => cur);
      if (!curOnline.online ||
          (best.latencyMs >= 0 && curOnline.latencyMs >= 0 &&
              best.latencyMs < curOnline.latencyMs - 100)) {
        await switchNode(best, userInitiated: false);
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
    _wakeLockTimer?.cancel();
    _core.dispose();
    super.dispose();
  }
}
