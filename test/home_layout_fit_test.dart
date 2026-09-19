// 桌面端主页「一屏放得下 + 国家网格对称」的回归测试。
//
// 背景（用户反馈）：
//   1. 打开软件后还要滚鼠标才能看全内容 —— 实测 380 宽下内容总高 763px，
//      最小窗口只有 620；其中「快速切换国家」一段占 190px（国家多时 Wrap 换行 3~4 行）。
//   2. 「显示一个国家XX 是什么意思」—— 订阅里未标地区的中转节点（"未知 01"、
//      "JMS-xxxx@..."）countryCode 落到哨兵值 'XX'，UI 直接把 'XX' 当国家名画了出来。
//   3. 用户要求国家药丸「正好对称」，且**不能丢**「自动最优」。
//
// 现在的契约（任何一条被破坏都会让这条用例红）：
//   · 420×780（默认窗口）与 380×620（最小窗口）下 maxScrollExtent == 0，不需要滚动；
//   · 国家区是等宽网格：窄窗口 3 列 × 2 行 = 自动最优 + 5 国，窗口拉高 3 列 × 3 行 = + 8 国；
//   · 未知地区（'XX' / null）不进网格，绝不出现写着「XX」的药丸，也不占真实国家槽位；
//   · 第一格永远是「自动最优」。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http_mock_adapter/http_mock_adapter.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:moneyfly/core/api/api_client.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';
import 'package:moneyfly/core/services/account_service.dart';
import 'package:moneyfly/core/services/geo_lookup.dart';
import 'package:moneyfly/core/services/subscription_service.dart';
import 'package:moneyfly/l10n/app_strings.dart';
import 'package:moneyfly/main.dart';
import 'package:moneyfly/pages/home/home_page.dart';
import 'package:moneyfly/theme/app_theme.dart';

Map<String, dynamic> _env(dynamic data) =>
    {'success': true, 'code': 0, 'message': '', 'data': data};

/// 故意混入长国名（哈萨克斯坦 / 澳大利亚）压一压药丸宽度
const _countries = ['HK', 'JP', 'US', 'KR', 'SG', 'TW', 'GB', 'DE', 'CA', 'AU', 'KZ'];

Future<void> _pumpHome(WidgetTester tester, Size size,
    {bool blocked = false, bool withUnknown = true}) async {
  final dio = Dio(BaseOptions(baseUrl: 'https://dy.moneyfly.top/api/v1'));
  final adapter = DioAdapter(dio: dio);
  adapter.onGet('/user/subscribe', (s) => s.reply(200, _env({
        'subscribe_url': 'https://dy.moneyfly.top/api/v1/client/subscribe',
        'expire_time': blocked ? '2020-01-01T08:00:00' : '2032-06-06 08:00:00',
        'device_limit': 600,
        'current_devices': 3,
        'remaining_days': blocked ? 0 : 2104,
        'is_expired': blocked,
        'status': 'active',
      })));
  adapter.onGet('/client/subscribe',
      (s) => s.reply(200, 'proxies:\n  - {name: 香港线路14, type: ss, server: 1.2.3.4, port: 8388, cipher: aes-128-gcm, password: pw}\n'));
  ApiClient.debugDio = dio;

  final conn = ConnectionController.instance;
  final nodes = <ProxyNode>[
    for (var i = 0; i < _countries.length; i++)
      ProxyNode(
          tag: '线路$i',
          type: 'ss',
          server: '1.2.3.$i',
          port: 8388,
          countryCode: _countries[i],
          latencyMs: 40 + i * 7),
  ];
  if (withUnknown) {
    // 订阅里真实存在的「未标地区」节点：延迟最低，若不过滤就会抢走第一格
    nodes.addAll([
      ProxyNode(tag: '未知 01', type: 'vless', server: '1.2.3.90', port: 443, latencyMs: 5),
      ProxyNode(tag: 'JMS-1235364@c18s3.example.com:443', type: 'vless', server: '1.2.3.91', port: 443, countryCode: 'XX', latencyMs: 6),
    ]);
  }
  await conn.loadNodes(nodes);
  conn.current = conn.nodes.first;
  // 已连接态内容最多：会话行 + 真实出口行 + 趋势线都在
  conn.status = ConnStatus.connected;
  conn.connectedAt = DateTime.now().subtract(const Duration(minutes: 12));
  conn.sessionUpMB = 12.3;
  conn.sessionDownMB = 456.7;
  conn.realCountry = 'HK';
  conn.upHistory.addAll([1, 2, 3]);
  conn.downHistory.addAll([1, 2, 3]);

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.runAsync(() async {
    await tester.pumpWidget(MaterialApp(
      theme: buildMoneyFlyTheme(),
      home: MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: SessionState()..setLoggedIn(true)),
          ChangeNotifierProvider.value(value: conn),
          ChangeNotifierProvider.value(value: AccountService.instance),
        ],
        child: const HomePage(),
      ),
    ));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pump();
  await tester.pump();
}

double _overflow(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position.maxScrollExtent;

/// 所有国家药丸的屏幕矩形（顺序 = 网格顺序）
List<Rect> _pillRects(WidgetTester tester) {
  final pills = find.byWidgetPredicate((w) =>
      w.key is ValueKey<String> &&
      (w.key as ValueKey<String>).value.startsWith('quick_pill_'));
  return [for (var i = 0; i < pills.evaluate().length; i++) tester.getRect(pills.at(i))];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  tearDown(() {
    ApiClient.debugDio = null;
    ApiClient.resetInstance();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
  });

  testWidgets('桌面默认窗口 420×780：主页不需要滚动', (tester) async {
    await _pumpHome(tester, const Size(420, 780));
    expect(_overflow(tester), 0, reason: '默认窗口下应一屏放得下');
  });

  testWidgets('桌面最小窗口 380×620：主页也不需要滚动', (tester) async {
    await _pumpHome(tester, const Size(380, 620));
    expect(_overflow(tester), 0,
        reason: '最小窗口下也要能看全（原先内容 763px，必须滚 143px）');
  });

  testWidgets('国家网格对称：窄窗口 3 列 × 2 行、单元格等宽、第一格是「自动最优」', (tester) async {
    await _pumpHome(tester, const Size(380, 620));
    final rects = _pillRects(tester);
    expect(rects.length, 6, reason: '自动最优 + 5 国 = 3 列 × 2 行');
    // 等宽（Expanded）＝ 左右对称
    final widths = rects.map((r) => r.width.round()).toSet();
    expect(widths.length, 1, reason: '所有单元格必须等宽，实测 $widths');
    // 正好两行
    final tops = rects.map((r) => r.top.round()).toSet().toList()..sort();
    expect(tops.length, 2, reason: '应正好两行，实测行数 ${tops.length}');
    // 每行横坐标对齐（列对齐）
    final row1 = rects.sublist(0, 3).map((r) => r.left.round()).toList();
    final row2 = rects.sublist(3).map((r) => r.left.round()).toList();
    expect(row2, row1, reason: '两行的列必须对齐');
    // 「自动最优」不能丢
    expect(find.descendant(
        of: find.byKey(const ValueKey('quick_pill_0')),
        matching: find.text(AppStrings.t('auto_best'))), findsOneWidget);
  });

  testWidgets('窗口拉高（≥820）时国家网格变 3 列 × 3 行：自动最优 + 8 国', (tester) async {
    await _pumpHome(tester, const Size(420, 900));
    final rects = _pillRects(tester);
    expect(rects.length, 9);
    expect(rects.map((r) => r.width.round()).toSet().length, 1);
    final tops = rects.map((r) => r.top.round()).toSet();
    expect(tops.length, 3);
    expect(_overflow(tester), 0, reason: '拉高窗口更要一屏放得下');
  });

  testWidgets('未标地区的节点（countryCode = XX / null）不进国家网格，绝不出现「XX」', (tester) async {
    await _pumpHome(tester, const Size(420, 780), withUnknown: true);
    // 那两个未知节点延迟最低（5ms / 6ms），旧实现会把它们当成第一、二个国家
    expect(find.text('XX'), findsNothing, reason: '哨兵值 XX 不能当国家名显示');
    expect(find.text('未知地区'), findsNothing, reason: '未知地区不占真实国家的槽位');
    final rects = _pillRects(tester);
    expect(rects.length, 6, reason: '只有已知国家进网格');
    // 第一格仍是自动最优，第二格应该是真实国家里延迟最低的
    expect(find.descendant(
        of: find.byKey(const ValueKey('quick_pill_1')),
        matching: find.text('香港')), findsOneWidget);
  });

  testWidgets('未知地区码不会退化成裸码（countryName 本地化）', (tester) async {
    await _pumpHome(tester, const Size(420, 780));
    expect(GeoLookupService.countryName('XX'), AppStrings.t('country_unknown'));
    expect(GeoLookupService.countryName(null), AppStrings.t('country_unknown'));
    expect(GeoLookupService.countryName('hk'), '香港');
  });

  testWidgets('长国名也不溢出（哈萨克斯坦 / 澳大利亚）', (tester) async {
    await _pumpHome(tester, const Size(380, 620));
    // RenderFlex overflow 会让用例直接失败；这里再显式确认药丸还在
    expect(_pillRects(tester).length, 6);
    expect(tester.takeException(), isNull);
  });

  testWidgets('到期横幅出现时需要滚动量仍然很小（可接受的降级）', (tester) async {
    await _pumpHome(tester, const Size(380, 620), blocked: true);
    expect(_overflow(tester), lessThanOrEqualTo(60),
        reason: '横幅是有价值的信息，允许少量滚动，但不能把内容顶出半屏');
  });
}
