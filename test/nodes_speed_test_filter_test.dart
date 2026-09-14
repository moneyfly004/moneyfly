// 节点列表：搜索/筛选后点「测速」，只测筛选出的节点，不测全部。
//
// 回归背景：旧实现无论是否筛选都调用 retestAll → 用户筛出 5 个节点点测速，
// 实际把上千个节点全测一遍，白等且看不到想要的对比结果。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/proxy/proxy_core_cli.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/subscription_service.dart';
import 'package:moneyfly/l10n/app_strings.dart';
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

/// 未筛选的节点延迟哨兵值：若它们被「顺手全测」，值会被改写成 -1。
const sentinel = 4321;

ProxyNode _node(String tag, String server, String country) => ProxyNode(
      tag: tag,
      type: 'vless',
      server: server,
      port: 9, // 本机关闭端口：TCP 探测立即失败，测试快且结果确定为 -1
      countryCode: country,
      latencyMs: sentinel,
    )..online = true;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProxyCoreCli.manageSystemProxy = false;
  });
  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  testWidgets('筛选后再测速：只测筛选出的节点，其余节点状态原样保留', (tester) async {
    final conn = ConnectionController.instance;
    conn.current = null;
    final nodes = [
      _node('日本-01', '127.0.0.1', 'JP'),
      _node('日本-02', '127.0.0.1', 'JP'),
      _node('美国-01', '127.0.0.1', 'US'),
      _node('美国-02', '127.0.0.1', 'US'),
    ];
    await conn.loadNodes(nodes);

    await tester.runAsync(() async {
      await tester.pumpWidget(_wrap(const NodesPage()));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();

    // 搜索「日本」→ 列表只剩 2 个节点
    await tester.enterText(find.byType(TextField).first, '日本');
    // 搜索框有 300ms 防抖（fake timer）：必须 pump 时钟才会真正生效
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 点 ⚡ 测速
    final btn = find.textContaining('⚡');
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)));
    await tester.pump();

    final jp = conn.nodes.where((n) => n.tag.startsWith('日本')).toList();
    final us = conn.nodes.where((n) => n.tag.startsWith('美国')).toList();

    // 筛选出的节点确实被测了（本机 9 端口关闭 → 判失败，不再是哨兵值）
    expect(jp.every((n) => n.latencyMs == -1 || n.latencyMs != sentinel), true,
        reason: '筛选出的日本节点应被真实测速');
    // 未筛选的节点必须原封不动（旧实现会把它们一起测掉 → 变成 -1）
    expect(us.map((n) => n.latencyMs).toList(), everyElement(sentinel),
        reason: '未出现在筛选结果里的节点不该被测速');
    expect(us.every((n) => n.online), true,
        reason: '未测节点不得被标成离线');

    // 列表顺序/内容不受影响：仍是 4 个节点
    expect(conn.nodes, hasLength(4));
  });

  testWidgets('未筛选（搜索框为空）时仍然测速全部节点', (tester) async {
    final conn = ConnectionController.instance;
    conn.current = null;
    await conn.loadNodes([
      _node('香港-01', '127.0.0.1', 'HK'),
      _node('香港-02', '127.0.0.1', 'HK'),
    ]);

    await tester.runAsync(() async {
      await tester.pumpWidget(_wrap(const NodesPage()));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pump();

    final btn = find.textContaining('⚡');
    await tester.tap(btn);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)));
    await tester.pump();

    expect(conn.nodes.every((n) => n.latencyMs != sentinel), true,
        reason: '无筛选时应测全部节点');
    // 兜底：本地化文案存在（避免 {n} 占位符漏配导致显示异常）
    expect(AppStrings.t('speed_done_filtered', {'n': '2'}), contains('2'));
  });
}
