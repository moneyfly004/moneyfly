import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/main.dart';
import 'package:moneyfly/pages/devices/devices_page.dart';
import 'package:moneyfly/pages/home/home_page.dart';
import 'package:moneyfly/pages/notifications/notifications_page.dart';
import 'package:moneyfly/pages/orders/orders_page.dart';
import 'package:moneyfly/theme/app_theme.dart';

/// 信封包装（与后端一致）
Map<String, dynamic> env(dynamic data) => {
      'success': true,
      'code': 0,
      'message': '',
      'data': data,
    };

Dio mockDio(void Function(DioAdapter adapter) routes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  dio.httpClientAdapter = adapter;
  routes(adapter);
  return dio;
}

/// 在真实异步区构建页面并等待 mock 请求完成
Future<void> pumpPage(WidgetTester tester, Widget page) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(page);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pump();
  await tester.pump();
}

/// 点击后等待异步刷新完成（tap 在真实异步区内执行）
Future<void> tapSettle(WidgetTester tester, Finder finder) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    await Future<void>.delayed(const Duration(milliseconds: 150));
  });
  await tester.pumpAndSettle();
}

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
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
  });

  group('首页', () {
    testWidgets('渲染连接卡/模式/自动测速/国家网格', (tester) async {
      final conn = ConnectionController.instance;
      await conn.loadNodes([
        ProxyNode(tag: '香港-01', type: 'vless', server: '1.2.3.4', port: 443, countryCode: 'HK', latencyMs: 35),
        ProxyNode(tag: '日本东京', type: 'trojan', server: '5.6.7.8', port: 443, countryCode: 'JP', latencyMs: 88),
      ]);
      await tester.pumpWidget(_wrap(const HomePage()));
      await tester.pump();
      expect(find.text('智能模式'), findsOneWidget);
      expect(find.text('全局模式'), findsOneWidget);
      expect(find.text('自动测速 · 自动选优'), findsOneWidget);
      expect(find.text('快速切换国家'), findsOneWidget);
      expect(find.text('最优'), findsOneWidget);
    });

    testWidgets('模式切换点击生效', (tester) async {
      await tester.pumpWidget(_wrap(const HomePage()));
      await tester.pump();
      await tester.tap(find.text('全局模式'));
      await tester.pump();
      expect(ConnectionController.instance.smartMode, isFalse);
      await tester.tap(find.text('智能模式'));
      await tester.pump();
      expect(ConnectionController.instance.smartMode, isTrue);
    });
  });

  group('设备管理', () {
    testWidgets('空状态', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/devices', (s) => s.reply(200, env([])));
      });
      await pumpPage(tester, _wrap(const DevicesPage()));
      expect(find.text('暂无设备'), findsOneWidget);
    });

    testWidgets('列表渲染 + 删除确认弹窗', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/devices', (s) => s.reply(200, env([
          {
            'id': 11, 'device_name': 'iPhone 15', 'os_name': 'iOS', 'os_version': '18.0',
            'ip_address': '1.2.3.4', 'location': '广东', 'is_active': true,
            'access_count': 5, 'remark': '我的手机', 'last_seen': '2026-09-01 12:00:00',
            'device_type': 'phone', 'device_model': '', 'device_brand': 'Apple',
            'software_name': 'MoneyFly', 'software_version': '1.0.0', 'is_allowed': true,
            'first_seen': '', 'last_access': '', 'created_at': '', 'subscription_id': 1,
          },
        ])));
        a.onDelete('/devices/11', (s) => s.reply(200, env(null)));
      });
      await pumpPage(tester, _wrap(const DevicesPage()));
      expect(find.text('我的手机'), findsOneWidget); // 备注优先显示
      expect(find.text('在线'), findsOneWidget);
      // 点删除 → 确认弹窗
      await tester.tap(find.text('删除'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // 弹窗文案使用设备名（displayName，多行内容用 textContaining）
      expect(find.textContaining('确定删除「iPhone 15」吗？'), findsOneWidget);
      // 点取消 → 弹窗关闭
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('确定删除「iPhone 15」吗？'), findsNothing);
    });
  });

  group('订单', () {
    testWidgets('列表渲染状态徽标', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/orders', (s) => s.reply(200, env([
          {
            'id': 9, 'order_no': 'MF202609011234', 'amount': 49.9, 'final_amount': 44.9,
            'status': 'paid', 'type': 'order', 'package': {'name': '季付套餐'},
            'payment_method_name': '支付宝', 'created_at': '2026-09-01 12:00:00',
          },
          {
            'id': 10, 'order_no': 'MF202609011235', 'amount': 19.9, 'final_amount': 19.9,
            'status': 'pending', 'type': 'order', 'package': {'name': '月付套餐'},
            'created_at': '2026-09-01 12:05:00',
          },
        ])));
      });
      await pumpPage(tester, _wrap(const OrdersPage()));
      expect(find.text('季付套餐'), findsOneWidget);
      expect(find.text('已支付'), findsOneWidget);
      expect(find.text('待支付'), findsOneWidget);
      expect(find.text('继续支付'), findsOneWidget);
      expect(find.text('取消订单'), findsOneWidget);
    });

    testWidgets('取消订单二次确认', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/orders', (s) => s.reply(200, env([
          {
            'id': 10, 'order_no': 'MF202609011235', 'amount': 19.9, 'final_amount': 19.9,
            'status': 'pending', 'type': 'order', 'package': {'name': '月付套餐'},
            'created_at': '2026-09-01 12:05:00',
          },
        ])));
        a.onPost('/orders/MF202609011235/cancel', (s) => s.reply(200, env(null)));
      });
      await pumpPage(tester, _wrap(const OrdersPage()));
      await tester.tap(find.text('取消订单'));
      await tester.pump();
      expect(find.text('确定取消这笔待支付订单吗？'), findsOneWidget);
      await tester.tap(find.text('再想想'));
      await tester.pump();
      expect(find.text('确定取消这笔待支付订单吗？'), findsNothing);
    });
  });

  group('通知', () {
    testWidgets('列表 + 全部已读', (tester) async {
      ApiClient.debugDio = mockDio((a) {
        a.onGet('/notifications', (s) => s.reply(200, env([
          {'id': 1, 'title': '套餐即将到期', 'content': '您的套餐还剩 3 天到期，请及时续费。', 'type': 'system', 'is_read': false, 'created_at': '2026-09-01 10:00:00'},
          {'id': 2, 'title': '新公告', 'content': '欢迎使用 MoneyFly。', 'type': 'announcement', 'is_read': true, 'created_at': '2026-09-01 09:00:00'},
        ])));
        a.onPut('/notifications/read-all', (s) => s.reply(200, env(null)));
      });
      await pumpPage(tester, _wrap(const NotificationsPage()));
      expect(find.text('套餐即将到期'), findsOneWidget);
      expect(find.text('新公告'), findsOneWidget);
      expect(find.text('全部已读'), findsOneWidget);
      // 点击「全部已读」→ 应显示成功反馈（证明 PUT 调用链完成）
      await tester.runAsync(() async {
        await tester.tap(find.text('全部已读'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      expect(find.text('已全部标记为已读'), findsOneWidget);
    });
  });
}
