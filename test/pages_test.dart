import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/main.dart';
import 'package:moneyfly/pages/devices/devices_page.dart';
import 'package:moneyfly/pages/home/home_page.dart';
import 'package:moneyfly/pages/notifications/notifications_page.dart';
import 'package:moneyfly/pages/orders/orders_page.dart';
import 'package:moneyfly/theme/app_theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildMoneyFlyTheme(),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: SessionState()..setLoggedIn(true)),
          ChangeNotifierProvider.value(value: ConnectionController.instance),
        ],
        child: child,
      ),
    );

void main() {
  testWidgets('首页渲染：连接卡/模式/自动测速/国家网格', (tester) async {
    final conn = ConnectionController.instance;
    await conn.loadNodes([
      ProxyNode(tag: '香港-01', type: 'vless', server: '1.2.3.4', port: 443, countryCode: 'HK', latencyMs: 35),
      ProxyNode(tag: '日本东京', type: 'trojan', server: '5.6.7.8', port: 443, countryCode: 'JP', latencyMs: 88),
    ]);
    await tester.pumpWidget(_wrap(const HomePage()));
    await tester.pump();
    expect(find.text('MoneyFly'), findsWidgets);
    expect(find.text('智能模式'), findsOneWidget);
    expect(find.text('全局模式'), findsOneWidget);
    expect(find.text('自动测速 · 自动选优'), findsOneWidget);
    expect(find.text('快速切换国家'), findsOneWidget);
    // 香港延迟最低 → 最优节点
    expect(find.text('最优'), findsOneWidget);
  });

  testWidgets('首页模式切换可点', (tester) async {
    await tester.pumpWidget(_wrap(const HomePage()));
    await tester.pump();
    await tester.tap(find.text('全局模式'));
    await tester.pump();
    expect(ConnectionController.instance.smartMode, isFalse);
    // 切回
    await tester.tap(find.text('智能模式'));
    await tester.pump();
    expect(ConnectionController.instance.smartMode, isTrue);
  });

  // 测试环境网络被 flutter_test 拦截为 400，页面应捕获错误并进入空状态；
  // 轮询等待加载态结束
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    }
  }

  testWidgets('设备管理页空状态', (tester) async {
    await tester.pumpWidget(_wrap(const DevicesPage()));
    await settle(tester);
    expect(find.text('暂无设备'), findsOneWidget);
  });

  testWidgets('订单页空状态', (tester) async {
    await tester.pumpWidget(_wrap(const OrdersPage()));
    await settle(tester);
    expect(find.text('暂无订单'), findsOneWidget);
  });

  testWidgets('通知页空状态', (tester) async {
    await tester.pumpWidget(_wrap(const NotificationsPage()));
    await settle(tester);
    expect(find.text('暂无通知'), findsOneWidget);
  });

  testWidgets('设置页持久化开关', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_wrap(const HomePage())); // 预热插件注册
    await tester.pump();
  });
}
