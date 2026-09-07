import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/models.dart';
import '../services/account_service.dart';
import '../services/app_log.dart';
import '../services/geo_lookup.dart';
import '../services/local_notify.dart';
import '../services/local_paths.dart';
import '../services/settings_store.dart';
import '../services/speed_tester.dart';
import 'geo_assets.dart';
import 'proxy_core_android.dart';
import 'proxy_core_cli.dart';
import 'mihomo_config.dart';
import 'system_proxy.dart';
import '../../l10n/app_strings.dart';
import 'conn_error.dart';
export 'conn_error.dart';

/// 后台 isolate 入口：构建 mihomo YAML 配置。compute 要求顶层/静态函数。
Map<String, dynamic> _buildConfigInIsolate(Map<String, dynamic> args) {
  final proxies = (args['proxies'] as List).cast<Map<String, dynamic>>();
  final nodes = proxies.map((m) => ProxyNode.fromClashMap(m)).toList();
  return MihomoConfigBuilder.build(
    nodes: nodes,
    selectedTag: args['selectedTag'] as String,
    smartMode: args['smartMode'] as bool,
    dns: args['dns'] as String,
    tunMode: args['tunMode'] as String,
    bypassLan: args['bypassLan'] as bool,
    localPort: (args['localPort'] as num?)?.toInt() ?? 2080,
    clashApiPort: (args['clashApiPort'] as num?)?.toInt() ?? 9090,
    geoReady: args['geoReady'] != false,
    logLevel: args['logLevel']?.toString() ?? 'warning',
    dnsMode: args['dnsMode']?.toString() ?? 'auto',
    tunStack: args['tunStack']?.toString() ?? 'gvisor',
    bypassDomains: (args['bypassDomains'] as List?)?.cast<String>() ?? const [],
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

/// 代理核心抽象：各平台实现（macOS/Windows/Linux 走 mihomo CLI 子进程；
/// Android 走原生 VpnService + libmihomo gomobile 库）
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

  /// 热更内核日志级别（debug/info/warning/error）。未连接时为 no-op。
  Future<void> setKernelLogLevel(String level) async {}

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

/// iOS 暂未接入内核的占位实现
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
  Future<void> setKernelLogLevel(String level) async {}
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

  /// Android 模式切换中（自动断开重连期间）：UI 显示「正在切换模式…」
  /// 并禁用模式/连接按钮，避免用户误以为没反应再点触发竞态
  bool switchingMode = false;

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
    // 同时清除持久化的手动选择：此后连接不再恢复旧节点，走全局自动选优
    unawaited(_clearPersistedSelection());
    notifyListeners();
    if (status == ConnStatus.connected && autoTest) {
      await _autoSpeedTestAndSwitch(_epoch, forceBest: true);
    }
  }

  /// 设置写队列：持久化读改写串行化，避免并发 load→save 丢最后意图
  Future<void> _settingsWriteQueue = Future.value();

  Future<void> _enqueueSettingsWrite(
      void Function(Map<String, dynamic>) mutate) {
    final run = _settingsWriteQueue.then((_) async {
      try {
        final s = await SettingsStore.instance.load();
        mutate(s);
        await SettingsStore.instance.save(s);
      } catch (_) {}
    });
    _settingsWriteQueue = run.catchError((_) {});
    return run;
  }

  /// 持久化「用户手动选择的节点」到设置（重启后由 connect 恢复）
  Future<void> _persistSelection(ProxyNode node) =>
      _enqueueSettingsWrite((s) => s['lastSelectedTag'] = node.tag);

  Future<void> _clearPersistedSelection() =>
      _enqueueSettingsWrite((s) => s.remove('lastSelectedTag'));

  /// 从设置恢复上次手动选择的节点（仅当节点仍存在于当前订阅时）
  Future<ProxyNode?> _restoreLastSelection(List<ProxyNode> list) async {
    try {
      final s = await SettingsStore.instance.load();
      final tag = s['lastSelectedTag']?.toString();
      if (tag == null || tag.isEmpty) return null;
      for (final n in list) {
        if (n.tag == tag) return n;
      }
    } catch (_) {}
    return null;
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

  /// 各平台内核工作目录（geo 数据与 config 同目录，mihomo 按默认文件名加载）：
  /// - 桌面：CLI workDir（系统临时目录 moneyfly_core）
  /// - Android/iOS：filesDir/work（MoneyFlyVpnService 同一内核目录）
  Future<String?> _geoWorkDir() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final support = await LocalPaths.supportDir(); // Android = filesDir
      if (support == null) return null;
      return '${support.path}/work';
    }
    return ProxyCoreCli.workDir;
  }

  Future<void> loadNodes(List<ProxyNode> list) async {
    nodes = _carryMeasuredLatency(list, nodes);
    _retargetCurrent();
    notifyListeners();
  }

  /// 列表整体替换后，把 current 重指向同 tag 的新实例（消除陈旧引用：
  /// 否则 current 停留在旧实例，延迟/在线状态与列表长期不一致）；
  /// 当前 tag 已不在新列表 → 清 current，并联动清理已失效的国家锁。
  void _retargetCurrent() {
    final c = current;
    if (c == null) return;
    for (final n in nodes) {
      if (n.tag == c.tag) {
        current = n;
        return;
      }
    }
    current = null;
    _dropLockIfCountryGone();
  }

  /// 锁定国家已无任何节点（订阅下架/换源）→ 解除锁，
  /// 避免 UI 显示"锁定 A"但自动选优/回落逻辑已悄悄离开该国。
  void _dropLockIfCountryGone() {
    final lc = lockedCountry;
    if (lc == null) return;
    if (!nodes.any(
        (n) => (n.countryCode?.toUpperCase() ?? 'XX') == lc)) {
      lockedCountry = null;
    }
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
  /// 空列表：账号受限（到期/停用/禁用）时订阅已失效 → 清空展示，绝不显示老
  /// 配置；正常账号的空列表多为解析失败/临时抖动 → 保留可用线路（离线兜底）。
  Future<void> applySubscriptionNodes(List<ProxyNode> fresh) async {
    if (fresh.isEmpty) {
      final acc = AccountService.instance;
      if (acc.loaded && acc.isBlocked) {
        nodes = [];
        current = null;
        lockedCountry = null; // 受限清空：同时解除失效的国家锁
        notifyListeners();
      }
      return;
    }
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
    _retargetCurrent();
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
    // 等待上一次断开(内核停止)真正完成，再启动新内核 —— 避免
    // disconnect 的 stop() 与本次 start() 并发：旧 stop 的
    // POST /shutdown / 系统代理 restore 可能误关刚就绪的新内核/新代理
    final pendingStop = _stopInFlight;
    if (pendingStop != null) {
      try {
        await pendingStop;
      } catch (_) {}
    }
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
    // Android 必须走 TUN：平台没有桌面那种「系统代理」机制，若用户曾把
    // tunMode 设成 off，连接后内核只监听本地 mixed 端口、App 流量根本不进
    // 隧道 —— 表现为「已连接但没网」。移动端强制 auto。
    final effectiveTunMode = (Platform.isAndroid || Platform.isIOS)
        ? 'auto'
        : (settings['tunMode']?.toString() ?? defaultTunMode);
    final tunMode = effectiveTunMode;
    final bypassLan = settings['bypassLan'] != false;
    final intervalMin = (settings['testIntervalMin'] as num?)?.toInt() ?? 30;
    if (epoch != _epoch) return;

    status = ConnStatus.connecting;
    error = null;
    errorKind = ConnErrorKind.none;
    _acquireWakeLock();
    notifyListeners();

    // 选连接节点：优先恢复「上次手动选择的节点」（跨重启/断开重连都保持
    // 固定国家不跳）→ 其次延迟最优 → 再次首个在线节点兜底。
    if (current == null) {
      final remembered = await _restoreLastSelection(nodes);
      if (remembered != null) {
        current = remembered;
        // 恢复后继续锁定该国家：后台测速/自动选优只在该国范围，绝不乱跳
        lockedCountry ??= remembered.countryCode;
      }
    }
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
      if (epoch != _epoch) return;
      // 离线 Geo 数据落盘（智能模式 CN 分流）：
      // - 桌面端：落到内核 workDir（mihomo -d 默认文件名加载）
      // - Android：落到 filesDir/work（与 VpnService 同一内核目录；原生层的
      //   assets 复制保留为启动兜底，此处 Dart 幂等复制为准，保证就绪状态
      //   真实可判）
      // 数据源是打包进 App 的 assets/rules/*（CI 构建时下载），这里是本地
      // 复制、零网络；落盘失败（内置文件缺失/IO 异常）→ geoReady=false →
      // 智能规则降级为全代理：内核不会因缺文件联网下载 geo，启动不被网络
      // 拖慢、不会失败。
      final geoReady =
          await GeoAssets.materialize(preferDir: await _geoWorkDir());
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
        'geoReady': geoReady,
        'logLevel': settings['kernelLogLevel']?.toString() ?? 'warning',
        'dnsMode': settings['dnsMode']?.toString() ?? 'auto',
        'tunStack': settings['tunStack']?.toString() ?? 'gvisor',
        'bypassDomains': (settings['bypassDomains'] as List?)?.cast<String>() ?? const [],
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
      // 内核就绪后回放一次「当前节点」到对应组（select=智能 / GLOBAL=全局）：
      // - 全局模式：内核内置 GLOBAL 组默认选中 proxies 首个节点，与用户预选
      //   (可能在列表中间)不一致 → 出口跳到别的线路，必须回放纠正；
      // - 智能模式：connect 期间(connecting 窗口)用户切换了节点只改了 current，
      //   内核 select 组仍是配置默认项，同样回放纠正 → 「选了谁就走谁」。
      if (current != null) {
        try {
          await _core.switchNode(current!.tag);
        } catch (_) {
          // 组指向失败不阻塞连接(自动测速/手动切换可再纠正)
        }
      }
      // 后台测速：不阻塞连接，完成后在同国范围内择优。
      // forceBest:false —— 尊重用户已选节点/已锁国家：当前节点在线且未明显
      // 劣化（<100ms）就不切换，避免「刚手动选的节点被无条件换掉→出口 IP
      // 跳动」；若用户从未选择过，current 即全局最优，行为与原先一致。
      if (runSpeedTest && autoTest) {
        unawaited(_autoSpeedTestAndSwitch(epoch, forceBest: false));
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
      // （仅对未分类错误做文本映射；类型化错误已带明确语义，不再改写。
      //  Android 的错误都是类型化/平台语义的，不走这里的桌面管理员文案）
      if (typedErr == null &&
          (Platform.isMacOS || Platform.isWindows) &&
          (tunMode == 'force' || tunMode == 'auto')) {
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

  /// 经内核并发测各节点延迟（限流，避免一次性打爆内核）。
  /// 测速在**副本**上进行：绝不把结果就地写进传入列表的元素 —— 否则
  /// 断开/切网瞬间在途测速会把 UI 正在用的节点整批标成 offline（epoch
  /// 守卫只能阻止"整体替换"，挡不住"元素已被逐个改写"）。
  Future<List<ProxyNode>> _testViaKernel(List<ProxyNode> nodes,
      {void Function(int done, int total)? onProgress}) async {
    if (nodes.isEmpty) return nodes;
    final result = [for (final n in nodes) n.clone()];
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

  /// 在 [tested] 中按 lockedCountry 过滤后选延迟最优节点。
  /// 锁定国家无候选/无在线节点时返回 null（宁可不切换，也绝不跨国家跳）。
  ProxyNode? selectBestRespectingLock(List<ProxyNode> tested) {
    if (lockedCountry == null) return SpeedTester.selectBest(tested);
    final candidates = tested
        .where((n) => (n.countryCode?.toUpperCase() ?? 'XX') == lockedCountry)
        .toList();
    return SpeedTester.selectBest(candidates);
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
      _retargetCurrent(); // 列表整体替换后 current 重指向新实例
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

  /// 在途的内核停止任务（disconnect/resetForLogout 发起）。
  /// connect 前 await 它，保证「旧内核停干净 + 系统代理已恢复」之后
  /// 新内核才启动 —— 杜绝停/启并发（旧 stop 关掉新内核/误关新代理）。
  Future<void>? _stopInFlight;

  Future<void> disconnect() async {
    _epoch++;
    AppLog.conn('disconnect requested');
    _reconnectTimer?.cancel();
    _bgTestTimer?.cancel();
    _releaseWakeLock();
    status = ConnStatus.disconnecting;
    notifyListeners();
    _clearState();
    final stopFut = _core.stop().catchError((_) {});
    _stopInFlight = stopFut;
    try {
      await stopFut;
    } catch (_) {}
    if (identical(_stopInFlight, stopFut)) _stopInFlight = null;
    notifyListeners();
  }

  Future<void> resetForLogout() async {
    _epoch++;
    _reconnectTimer?.cancel();
    _bgTestTimer?.cancel();
    _clearState();
    // 登出/切号：清掉持久化的节点选择，避免旧账号的固定线路残留到新账号
    unawaited(_clearPersistedSelection());
    final stopFut = _core.stop().catchError((_) {});
    _stopInFlight = stopFut;
    try {
      await stopFut;
    } catch (_) {}
    if (identical(_stopInFlight, stopFut)) _stopInFlight = null;
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
    if (userInitiated) {
      lockedCountry = node.countryCode;
      // 持久化用户手动选择：跨重启 / 断开重连后恢复（固定国家不跳的前提）
      unawaited(_persistSelection(node));
    }
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
    if (status != ConnStatus.connected || !_core.isRunning) return;
    if (Platform.isAndroid) {
      if (switchingMode) return; // 切换中忽略再次点击
      // Android 内核以 embed(cmfa)模式运行：Clash API 禁 PATCH /configs(405)，
      // 无法热切模式 → 自动断开并以新模式重连（1~2s）。
      // 参考：mihomo cmfa 构建 SetEmbedMode(true) 禁 update/patch configs。
      switchingMode = true;
      notifyListeners();
      unawaited(_modeRestartByReconnect());
      return;
    }
    try {
      await _core.switchMode(smart);
    } catch (e) {
      AppLog.error('mode switch failed: $e');
      error = AppStrings.t('mode_switch_fail', {'err': '$e'});
      errorKind = ConnErrorKind.none;
      notifyListeners();
    }
  }

  /// Android 模式切换：断开后立即用当前（新）模式重连。
  Future<void> _modeRestartByReconnect() async {
    // 断开会清 lockedCountry（_clearState），但模式切换只是重启内核，
    // 用户锁定的国家/线路不应丢 —— 先记住，重连后若未恢复则补回。
    final keepLock = lockedCountry;
    final keepTag = current?.tag;
    try {
      await disconnect();
    } catch (_) {}
    try {
      if (status == ConnStatus.disconnected && nodes.isNotEmpty) {
        await connect();
      }
    } catch (_) {}
    // connect 已按持久化记忆恢复 lastSelectedTag 与锁；无记忆时用 keepLock 补
    if (lockedCountry == null && keepLock != null) {
      final stillHas = nodes
          .any((n) => (n.countryCode?.toUpperCase() ?? 'XX') == keepLock);
      if (stillHas) lockedCountry = keepLock;
    }
    if (current == null && keepTag != null) {
      for (final n in nodes) {
        if (n.tag == keepTag) {
          current = n;
          break;
        }
      }
    }
    switchingMode = false;
    notifyListeners();
  }

  /// 热更内核日志级别（「内核日志」实时页用）：连接时即时生效并持久化，
  /// 下次连接按该级别启动。
  Future<void> setKernelLogLevel(String level) async {
    if (!Platform.isAndroid) {
      // 桌面内核可热更 log-level；Android embed 模式禁 PATCH(405)，
      // 仅保存设置，下次连接按该级别启动
      try {
        if (status == ConnStatus.connected && _core.isRunning) {
          await _core.setKernelLogLevel(level);
        }
      } catch (_) {}
    }
    try {
      final s = await SettingsStore.instance.load();
      s['kernelLogLevel'] = level;
      await SettingsStore.instance.save(s);
    } catch (_) {}
  }

  /// 网络环境变化（WiFi↔蜂窝切换）：已连接且内核在跑时，不重启内核，
  /// 仅重新测速选优（内核的 TCP/UDP 连接会自动恢复，重启反而断流）。
  /// 自动测速开关关闭时不做任何自动切换（切网不换用户当前线路）。
  void onNetworkChanged() {
    if (status != ConnStatus.connected || !_core.isRunning) return;
    if (!autoTest) return;
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
  /// 受 [autoTest] 门控：用户关闭「自动测速/自动切换」后，不再周期性测速与
  /// 自动换节点（手动「重新测速」与节点页测速不受影响）。
  void _startBackgroundTest(int intervalMin) {
    _bgTestTimer?.cancel();
    if (intervalMin <= 0 || !autoTest) return;
    _bgTestTimer = Timer.periodic(Duration(minutes: intervalMin), (_) async {
      if (status != ConnStatus.connected || nodes.isEmpty || !_core.isRunning) return;
      if (!autoTest) return;
      final tested = await testAllNodes(nodes);
      if (status != ConnStatus.connected || !autoTest) return;
      nodes = tested;
      _retargetCurrent(); // 列表整体替换后 current 重指向新实例
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
