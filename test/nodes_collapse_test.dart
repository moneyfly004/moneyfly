// 节点列表：国家分组排序（热门置顶）+ 可折叠（默认展开，点头折叠/展开）
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/subscription_service.dart';
import 'package:moneyfly/pages/nodes/nodes_page.dart';
import 'package:moneyfly/theme/app_theme.dart';

Widget _wrap(Widget child) => MaterialApp(
      theme: buildMoneyFlyTheme(),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: ConnectionController.instance),
          ChangeNotifierProvider.value(value: AccountService.instance),
        ],
        child: child,
      ),
    );

Future<void> _pump(WidgetTester tester, Widget page) async {
  await tester.runAsync(() async {
    await tester.pumpWidget(page);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  testWidgets('节点列表：默认展开可见节点，点分组头折叠隐藏该国节点', (tester) async {
    final conn = ConnectionController.instance;
    await conn.loadNodes([
      ProxyNode(tag: '香港-01', type: 'vless', server: '1.1.1.1', port: 443, countryCode: 'HK', latencyMs: 30),
      ProxyNode(tag: '香港-02', type: 'vless', server: '1.1.1.2', port: 443, countryCode: 'HK', latencyMs: 45),
      ProxyNode(tag: '日本-01', type: 'trojan', server: '2.2.2.1', port: 443, countryCode: 'JP', latencyMs: 88),
    ]);
    for (final n in conn.nodes) {
      n.online = true;
    }
    await _pump(tester, _wrap(const NodesPage()));

    // 默认展开：节点可见
    expect(find.text('香港-01'), findsOneWidget);
    expect(find.text('香港-02'), findsOneWidget);
    expect(find.text('日本-01'), findsOneWidget);

    // 分组头存在（国名）
    expect(find.text('香港'), findsOneWidget);
    expect(find.text('日本'), findsOneWidget);

    // 点香港分组头 → 折叠，香港节点隐藏，日本不受影响
    await tester.tap(find.text('香港'));
    await tester.pumpAndSettle();
    expect(find.text('香港-01'), findsNothing);
    expect(find.text('香港-02'), findsNothing);
    expect(find.text('日本-01'), findsOneWidget); // 其它组仍展开
    expect(find.text('香港'), findsOneWidget); // 头还在

    // 再点 → 展开恢复
    await tester.tap(find.text('香港'));
    await tester.pumpAndSettle();
    expect(find.text('香港-01'), findsOneWidget);
    expect(find.text('香港-02'), findsOneWidget);
  });

  testWidgets('分组顺序：香港(热门)排在日本之前', (tester) async {
    final conn = ConnectionController.instance;
    // 故意乱序加入，验证 UI 排序
    await conn.loadNodes([
      ProxyNode(tag: '日本-01', type: 'trojan', server: '2.2.2.1', port: 443, countryCode: 'JP', latencyMs: 20),
      ProxyNode(tag: '香港-01', type: 'vless', server: '1.1.1.1', port: 443, countryCode: 'HK', latencyMs: 200),
    ]);
    for (final n in conn.nodes) {
      n.online = true;
    }
    await _pump(tester, _wrap(const NodesPage()));

    // 即便日本延迟更低，香港(热门第一)分组头仍在日本之前
    final hkY = tester.getTopLeft(find.text('香港')).dy;
    final jpY = tester.getTopLeft(find.text('日本')).dy;
    expect(hkY < jpY, isTrue, reason: '香港分组应排在日本之前（热门置顶）');
  });
}
