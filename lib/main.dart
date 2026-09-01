import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api/api_client.dart';
import 'core/proxy/proxy_core.dart';
import 'core/services/auth_service.dart';
import 'pages/auth/login_page.dart';
import 'pages/home/home_page.dart';
import 'pages/nodes/nodes_page.dart';
import 'pages/package/package_page.dart';
import 'pages/profile/profile_page.dart';
import 'theme/app_theme.dart';

/// 全局会话状态
class SessionState extends ChangeNotifier {
  bool loggedIn = false;

  Future<void> restore() async {
    final t = await ApiClient.readAccessToken();
    loggedIn = t != null && t.isNotEmpty;
    notifyListeners();
  }

  void setLoggedIn(bool v) {
    loggedIn = v;
    notifyListeners();
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MoneyFlyApp());
}

class MoneyFlyApp extends StatefulWidget {
  const MoneyFlyApp({super.key});

  @override
  State<MoneyFlyApp> createState() => _MoneyFlyAppState();
}

class _MoneyFlyAppState extends State<MoneyFlyApp> {
  final _session = SessionState();

  @override
  void initState() {
    super.initState();
    _session.restore();
    // 会话失效（refresh 失败）→ 强制回登录页
    ApiClient.instance.onSessionExpired(() {
      AuthService.instance.logout();
      _session.setLoggedIn(false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _session),
        ChangeNotifierProvider.value(value: ConnectionController.instance),
      ],
      child: MaterialApp(
        title: 'MoneyFly',
        debugShowCheckedModeBanner: false,
        theme: buildMoneyFlyTheme(),
        darkTheme: buildMoneyFlyTheme(),
        themeMode: ThemeMode.dark,
        home: const RootShell(),
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

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;

  static const _pages = [
    HomePage(),
    NodesPage(),
    PackagePage(),
    ProfilePage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_index],
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: MFColors.bg,
          border: Border(top: BorderSide(color: MFColors.line)),
        ),
        child: SafeArea(
          top: false,
          child: BottomNavigationBar(
            currentIndex: _index,
            onTap: (i) => setState(() => _index = i),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.home_outlined, size: 22),
                activeIcon: Icon(Icons.home, size: 22),
                label: '首页',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.dns_outlined, size: 22),
                activeIcon: Icon(Icons.dns, size: 22),
                label: '节点',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.payments_outlined, size: 22),
                activeIcon: Icon(Icons.payments, size: 22),
                label: '充值',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.person_outline, size: 22),
                activeIcon: Icon(Icons.person, size: 22),
                label: '我的',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
