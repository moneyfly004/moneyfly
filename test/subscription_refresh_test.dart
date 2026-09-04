import 'package:flutter_test/flutter_test.dart';

import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core.dart';

/// 订阅定时/启动刷新结果接入（applySubscriptionNodes）行为测试：
/// 保证「覆盖旧节点配置」不会误伤正在使用的连接/正在建立的连接。
void main() {
  ProxyNode node(String tag) => ProxyNode(
        tag: tag,
        type: 'ss',
        server: '1.2.3.4',
        port: 8388,
        raw: const {'type': 'ss', 'server': '1.2.3.4', 'port': 8388},
      );

  tearDown(() {
    // 复位单例状态，避免污染其它用例
    final c = ConnectionController.instance;
    c.status = ConnStatus.disconnected;
    c.nodes = [];
    c.current = null;
  });

  test('断开状态：新订阅整体覆盖旧节点配置', () async {
    final c = ConnectionController.instance;
    c.nodes = [node('old-1'), node('old-2')];
    c.current = node('old-1');

    await c.applySubscriptionNodes([node('new-1'), node('new-2')]);

    expect(c.nodes.map((n) => n.tag), ['new-1', 'new-2']);
    expect(c.current, isNull); // 旧线路已不在新订阅中
  });

  test('已连接且当前线路仍在 → 列表整体替换为新订阅', () async {
    final c = ConnectionController.instance;
    c.status = ConnStatus.connected;
    c.nodes = [node('hk-1'), node('hk-2')];
    c.current = node('hk-1');

    await c.applySubscriptionNodes([node('hk-1'), node('jp-9')]);

    expect(c.nodes.map((n) => n.tag), ['hk-1', 'jp-9']);
    expect(c.current!.tag, 'hk-1'); // 当前线路保留
  });

  test('已连接但当前线路不在新订阅 → 保持现状不打断连接', () async {
    final c = ConnectionController.instance;
    c.status = ConnStatus.connected;
    c.nodes = [node('hk-old')];
    c.current = node('hk-old');

    await c.applySubscriptionNodes([node('jp-new')]);

    // 不替换：内核仍按旧配置运行，避免当前线路被误判离线/中断
    expect(c.nodes.map((n) => n.tag), ['hk-old']);
    expect(c.current!.tag, 'hk-old');
  });

  test('连接建立过程中（connecting）不动列表，避免与 connect 竞态', () async {
    final c = ConnectionController.instance;
    c.status = ConnStatus.connecting;
    c.nodes = [node('pick-me')];
    c.current = node('pick-me');

    await c.applySubscriptionNodes([node('other')]);

    expect(c.nodes.map((n) => n.tag), ['pick-me']);
  });

  test('空列表不覆盖（避免清空用户可用线路）', () async {
    final c = ConnectionController.instance;
    c.nodes = [node('a')];

    await c.applySubscriptionNodes([]);

    expect(c.nodes.map((n) => n.tag), ['a']);
  });
}
