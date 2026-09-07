import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'core/api/api_client.dart';
import 'core/proxy/proxy_core.dart';
import 'core/services/account_service.dart';
import 'core/services/app_data_cleaner.dart';
import 'core/services/auth_service.dart';
import 'core/services/app_log.dart';
import 'core/services/crash_logger.dart';
import 'core/services/local_notify.dart';
import 'core/services/network_monitor.dart';
import 'core/services/subscription_scheduler.dart';
import 'core/services/tray_service.dart';
import 'core/services/update_service.dart';
import 'core/services/settings_store.dart';
import 'core/services/win_single_instance.dart';
import 'l10n/app_strings.dart';
import 'pages/auth/login_page.dart';
import 'pages/home/home_page.dart';
import 'pages/nodes/nodes_page.dart';
import 'pages/package/package_page.dart';
import 'pages/profile/profile_page.dart';
import 'theme/app_theme.dart';
import 'theme/theme_controller.dart';

/// 全局会话状态
class SessionState extends ChangeNotifier {
  bool loggedIn = false;

  Future<void> restore() async {
    // 「自动登录」开关关闭时，不恢复登录态（见 login_page.setAutoLogin）
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('moneyfly_auto_login') == false) {
      loggedIn = false;
      notifyListeners();
      return;
    }
    final t = await ApiClient.readAccessToken();
    loggedIn = t != null && t.isNotEmpty;
    notifyListeners();
  }

  void setLoggedIn(bool v) {
    loggedIn = v;
    notifyListeners();
  }
}

/// 全局导航 key：会话失效/退出登录时清空路由栈，自动回到登录窗口
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  // Windows 单实例：重复双击/重复启动时只保留一个进程。
  // 检测到已有实例 → 唤醒其窗口后本进程立即退出（必须在创建任何窗口前）。
  if (WinSingleInstance.ensure()) {
    exit(0);
  }
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端窗口管理（关闭=隐藏到托盘，不退出进程）
  if (!Platform.environment.containsKey('FLUTTER_TEST') &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    windowManager.setPreventClose(true);
    windowManager.setTitle('MoneyFly');
    windowManager.setMinimumSize(const Size(380, 620));
  }
  // UA + 设备信息必须在首个 API 请求前就绪（登录 UA 不再为裸版本号）
  await UpdateService.instance.init();
  // 全新安装检测：卸载残留/数据被清 → 清空旧配置、旧 token、旧缓存，
  // 保证重装后必须重新登录并重新拉取订阅（不沿用旧配置）；版本升级 →
  // 仅清理旧版本拉到的订阅缓存（下次启动强制重拉）。
  await AppDataCleaner.cleanupOnLaunch();
  AppLog.log('APP', 'launched v${UpdateInfo.currentVersion}, ${Platform.operatingSystem}');
  runApp(const MoneyFlyApp());
}

class MoneyFlyApp extends StatefulWidget {
  const MoneyFlyApp({super.key});

  @override
  State<MoneyFlyApp> createState() => _MoneyFlyAppState();
}

class _MoneyFlyAppState extends State<MoneyFlyApp> with WidgetsBindingObserver, WindowListener {
  final _session = SessionState();
  bool _wasLoggedIn = false;

  static bool get _isDesktopRuntime =>
      !Platform.environment.containsKey('FLUTTER_TEST') &&
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isDesktopRuntime) {
      windowManager.addListener(this);
      TrayService.instance.init(
        showWindow: () async {
          await windowManager.show();
          await windowManager.focus();
        },
        quit: _quitApp,
      );
    }
    // 登录态变化 → 启停「定时更新订阅」（登录后每 30 分钟静默拉订阅覆盖旧配置，
    // 登出/会话失效即停）
    _session.addListener(_onSessionChanged);
    _session.restore();
    // 启动时应用持久化设置（自动测速 / 断线重连 / 默认模式）+ 恢复主题
    SettingsStore.instance
        .load()
        .then(ConnectionController.instance.applySettings)
        .catchError((_) {});
    ThemeController.instance.restore();
    // 崩溃日志（设置开关控制）
    CrashLogger.init();
    // 本地通知初始化（到期提醒 / 连接异常）
    LocalNotify.instance.init();
    // 网络变化监听（WiFi↔蜂窝切换自动重连）
    NetworkMonitor.instance.start();
    // 会话失效（refresh 失败）→ 清空路由栈强制回登录页
    // （push 在栈上的设置/订单等页面会残留盖住登录页，需先 pop 到根）
    ApiClient.instance.onSessionExpired(() {
      AuthService.instance.logout();
      rootNavigatorKey.currentState?.popUntil((r) => r.isFirst);
      _session.setLoggedIn(false);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_isDesktopRuntime) {
      windowManager.removeListener(this);
    }
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  /// 防重复退出/关闭处理
  bool _quitting = false;

  /// 真正退出：先断开连接（停内核 + 恢复系统代理，避免残留内核占端口/
  /// cache 锁导致下次启动失败），再关闭窗口并结束进程。
  Future<void> _quitApp() async {
    if (_quitting) return;
    _quitting = true;
    try {
      final c = ConnectionController.instance;
      if (c.status != ConnStatus.disconnected) {
        await c.disconnect();
      }
    } catch (_) {}
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {}
    // 兜底：某些平台 close 只关窗口不结束进程
    exit(0);
  }

  @override
  void onWindowClose() async {
    // 点右上角 X（macOS 红点 / Windows ×）→ 询问：最小化常驻 还是 退出
    // 注意：本 State 在 MaterialApp 之上，绝不能用自己的 context 弹窗
    // （Navigator.of 向上找不到 Navigator → showDialog 抛异常 → 旧代码无
    // 兜底 → 弹窗从未出现，而窗口又被 preventClose 拦截 = 「点 X 没反应」）。
    // 必须用 rootNavigatorKey.currentContext（MaterialApp 的 Navigator）。
    if (!mounted || _quitting) return;
    AppLog.log('APP', 'window close requested');
    try {
      // 启动极早期(路由未就绪)点 X：等一帧让 Navigator 可用
      if (rootNavigatorKey.currentContext == null) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        if (!mounted || _quitting) return;
      }
      // 取完立即使用(同一同步段,无跨 async gap)
      final navCtx = rootNavigatorKey.currentContext;
      if (navCtx == null || !navCtx.mounted) {
        // 没有可用的 Navigator(异常状态)：兜底最小化，避免"点了没反应"
        AppLog.error('onWindowClose: navigator not ready, hide to tray');
        await windowManager.hide();
        return;
      }
      final act = await showDialog<String>(
        context: navCtx,
        barrierDismissible: true,
        builder: (ctx) => AlertDialog(
          backgroundColor: MFColors.card2,
          title: Text(AppStrings.t('close_ask_title'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: Text(AppStrings.t('close_ask_body'),
              style: TextStyle(
                  fontSize: 13.5, color: MFColors.txt2, height: 1.6)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(AppStrings.t('cancel'))),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'hide'),
              child: Text(AppStrings.t('minimize_tray_btn'),
                  style: TextStyle(color: MFColors.txt)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'quit'),
              child: Text(AppStrings.t('quit_app_btn'),
                  style: TextStyle(color: MFColors.red)),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (act == 'hide') {
        // 最小化到托盘：常驻后台（内核/代理保持连接）
        await windowManager.hide();
      } else if (act == 'quit') {
        await _quitApp();
      }
      // act == null（点弹窗外/取消）→ 保持窗口，什么都不做
    } catch (e) {
      // 弹窗失败兜底：最小化到托盘而非"点了没反应"
      AppLog.error('onWindowClose dialog failed: $e');
      try {
        await windowManager.hide();
      } catch (_) {}
    }
  }

  void _onSessionChanged() {
    final v = _session.loggedIn;
    if (v == _wasLoggedIn) return;
    _wasLoggedIn = v;
    if (v) {
      // 登录后启动「每 30 分钟静默刷新订阅」：重判账号状态(到期/禁用/设备满)
      // + 覆盖本地订阅缓存，运行期间节点/线路保持最新、受限即时生效
      SubscriptionScheduler.instance.start();
    } else {
      // 登出停掉定时刷新，避免残留定时器
      SubscriptionScheduler.instance.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台自动补一次静默刷新(距上次成功 ≥10 分钟才拉,避免 JWT 抖动)
    if (state == AppLifecycleState.resumed) {
      SubscriptionScheduler.instance.onAppResumed();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _session),
        ChangeNotifierProvider.value(value: ConnectionController.instance),
        ChangeNotifierProvider.value(value: ThemeController.instance),
        ChangeNotifierProvider.value(value: LocaleController.instance),
        // 账号可用状态（到期/设备满/禁用）——首页横幅、连接门禁、我的页共用
        ChangeNotifierProvider.value(value: AccountService.instance),
      ],
      child: Consumer<ThemeController>(
        builder: (context, themeCtrl, _) =>
            Consumer<LocaleController>(
          builder: (context, locale, _) => MaterialApp(
            title: AppStrings.t('app_name'),
            debugShowCheckedModeBanner: false,
            navigatorKey: rootNavigatorKey,
            theme: buildMoneyFlyTheme(brightness: Brightness.light),
            darkTheme: buildMoneyFlyTheme(brightness: Brightness.dark),
            themeMode: themeCtrl.mode,
            locale: locale.lang == 'en' ? const Locale('en') : const Locale('zh'),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('zh'), Locale('en')],
            home: RootShell(),
          ),
        ),
      ),
    );
  }
}

/// 未登录 → 登录页；已登录 → 主壳
class RootShell extends StatelessWidget {
  const RootShell({super.key});

  @override
  Widget build(BuildContext context) {
    final loggedIn = context.select((SessionState s) => s.loggedIn);
    return loggedIn ? const MainShell() : const LoginPage();
  }
}

/// 全局主标签索引（供首页/我的等页面一键跳转「充值」tab）
final ValueNotifier<int> mainTabIndex = ValueNotifier<int>(0);

/// 主导航四个目的地（首页/节点/套餐/我的）——
/// 宽屏 NavigationRail 与窄屏 BottomNavigationBar 共用同一份定义，
/// 保证两套导航文案/图标一致；label 复用现有 AppStrings key
/// （home / nodes_title / purchase_title / profile_title），无需新增文案。
typedef _MainNavEntry = ({String labelKey, IconData icon, IconData activeIcon});

const List<_MainNavEntry> _mainNavEntries = [
  (labelKey: 'home', icon: Icons.home_outlined, activeIcon: Icons.home),
  (labelKey: 'nodes_title', icon: Icons.dns_outlined, activeIcon: Icons.dns),
  (labelKey: 'purchase_title', icon: Icons.payments_outlined, activeIcon: Icons.payments),
  (labelKey: 'profile_title', icon: Icons.person_outline, activeIcon: Icons.person),
];

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  /// 已访问过的 tab（懒构建 + 保活：切 tab 不重建、不动画闪烁）
  final Set<int> _visited = {0};

  static const _pageCount = 4;
  late final _pages = <Widget>[
    const HomePage(),
    const NodesPage(),
    const PackagePage(),
    const ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();
    mainTabIndex.addListener(_onExternalTabSwitch);
  }

  @override
  void dispose() {
    mainTabIndex.removeListener(_onExternalTabSwitch);
    super.dispose();
  }

  void _onExternalTabSwitch() {
    final i = mainTabIndex.value;
    if (i != _index && i >= 0 && i < _pageCount) {
      setState(() {
        _index = i;
        _visited.add(i);
      });
    }
  }

  void _onTap(int i) {
    mainTabIndex.value = i;
    setState(() {
      _index = i;
      _visited.add(i);
    });
  }

  /// 宽屏(≥840)切换为左侧 NavigationRail 的临界宽度；窗口默认尺寸不改，
  /// 仅按当前布局宽度响应（窗口管理器只设了最小 380×620）。
  static const double _railBreakpoint = 840;

  @override
  Widget build(BuildContext context) {
    // 响应式导航：宽屏 → 左侧 NavigationRail；窄屏 → 保持底部 BottomNavigationBar。
    // 两套导航共用 _index/_visited/_pages 与 _onTap/IndexedStack 保活逻辑，
    // 页面状态不因布局切换而重建；mainTabIndex 外部跳转（mainTabIndex.value = 2）
    // 依旧通过 _onExternalTabSwitch 生效，与布局无关。
    final wide = MediaQuery.sizeOf(context).width >= _railBreakpoint;
    final tabBody = _buildTabBody();
    return Scaffold(
      body: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildNavigationRail(),
                Expanded(child: tabBody),
              ],
            )
          : tabBody,
      bottomNavigationBar: wide ? null : _buildBottomNavigationBar(),
    );
  }

  /// 主内容区（IndexedStack 保活已访问页面；未访问的用占位避免登录瞬间并发
  /// 拉取；TickerMode 停用非活动 Tab 的动画 ticker → 省电省 CPU）。
  /// 宽/窄两种导航共用这一份内容，切到宽屏时由 Expanded 铺满 rail 右侧。
  Widget _buildTabBody() {
    return IndexedStack(
      index: _index,
      children: [
        for (var i = 0; i < _pageCount; i++)
          _visited.contains(i)
              ? TickerMode(
                  enabled: i == _index,
                  child: _pages[i],
                )
              : const SizedBox.shrink(),
      ],
    );
  }

  /// 窄屏底部导航（原有外观与文案保持不变）
  Widget _buildBottomNavigationBar() {
    return Container(
      decoration: BoxDecoration(
        color: MFColors.bg,
        border: Border(top: BorderSide(color: MFColors.line)),
      ),
      child: SafeArea(
        top: false,
        child: BottomNavigationBar(
          currentIndex: _index,
          onTap: _onTap,
          items: [
            for (final e in _mainNavEntries)
              BottomNavigationBarItem(
                icon: Icon(e.icon, size: 22),
                activeIcon: Icon(e.activeIcon, size: 22),
                label: AppStrings.t(e.labelKey),
              ),
          ],
        ),
      ),
    );
  }

  /// 宽屏左侧 NavigationRail：4 个 destination 与底部导航同源（图标/文案一致），
  /// 配色沿用底部导航语义（选中 brandLight / 未选中 txt3）。
  Widget _buildNavigationRail() {
    return Container(
      decoration: BoxDecoration(
        color: MFColors.bg,
        border: Border(right: BorderSide(color: MFColors.line)),
      ),
      child: NavigationRail(
        backgroundColor: Colors.transparent,
        selectedIndex: _index,
        onDestinationSelected: _onTap,
        labelType: NavigationRailLabelType.all,
        indicatorColor: MFColors.brand.withValues(alpha: .12),
        selectedIconTheme: IconThemeData(color: MFColors.brandLight),
        unselectedIconTheme: IconThemeData(color: MFColors.txt3),
        selectedLabelTextStyle: TextStyle(
            color: MFColors.brandLight, fontSize: 12, fontWeight: FontWeight.w500),
        unselectedLabelTextStyle:
            TextStyle(color: MFColors.txt3, fontSize: 12),
        destinations: [
          for (final e in _mainNavEntries)
            NavigationRailDestination(
              icon: Icon(e.icon),
              selectedIcon: Icon(e.activeIcon),
              label: Text(AppStrings.t(e.labelKey)),
            ),
        ],
      ),
    );
  }
}
