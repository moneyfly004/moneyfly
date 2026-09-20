// TUN 配置生成：局域网在路由层排除。
//
// 背景：bypassLan 原本只在**规则层**给局域网写 DIRECT 规则，TUN 的 auto-route
// 仍然把局域网包先抓进虚拟网卡再靠规则绕回。对 NAS / 网络打印机 / mDNS、SSDP
// 局域网发现 / 局域网联机，多绕一跳会变慢甚至找不到设备。这里断言路由层排除
// 与 bypassLan 语义一致，且不会被移动端（auto-route=false）误加。
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/mihomo_config.dart';

ProxyNode _node() => ProxyNode(
      tag: '测试节点',
      type: 'vless',
      server: '127.0.0.1',
      port: 9,
      uuid: '00000000-0000-0000-0000-000000000000',
      countryCode: 'HK',
      raw: const {},
    );

Map<String, dynamic> _build({
  String tunMode = 'off',
  bool bypassLan = true,
  bool tunAutoRoute = false,
  bool tunFdInjected = false,
}) =>
    MihomoConfigBuilder.build(
      nodes: [_node()],
      selectedTag: '测试节点',
      smartMode: true,
      tunMode: tunMode,
      bypassLan: bypassLan,
      tunAutoRoute: tunAutoRoute,
      tunFdInjected: tunFdInjected,
    );

void main() {
  group('TUN 段生成', () {
    test('关闭时完全没有 tun 段', () {
      expect(_build(tunMode: 'off').containsKey('tun'), isFalse);
    });

    test('桌面 TUN（auto-route=true）+ bypassLan → 路由层排除局域网', () {
      final tun = _build(tunMode: 'auto', tunAutoRoute: true)['tun'] as Map;
      expect(tun['enable'], isTrue);
      expect(tun['auto-route'], isTrue);
      final excludes = (tun['route-exclude-address'] as List).cast<String>();
      expect(excludes, contains('192.168.0.0/16'));
      expect(excludes, contains('10.0.0.0/8'));
      expect(excludes, contains('172.16.0.0/12'));
      expect(excludes, contains('169.254.0.0/16'));
      expect(excludes, contains('224.0.0.0/4'));
      expect(excludes, contains('127.0.0.0/8'));
    });

    test('bypassLan=false（用户明确要局域网走代理）→ 不排除', () {
      final tun = _build(tunMode: 'force', bypassLan: false, tunAutoRoute: true)
          ['tun'] as Map;
      expect(tun.containsKey('route-exclude-address'), isFalse);
    });

    test('移动端（auto-route=false，路由由系统下发）→ 不写排除项', () {
      final tun = _build(tunMode: 'auto', tunAutoRoute: false)['tun'] as Map;
      expect(tun.containsKey('route-exclude-address'), isFalse);
      // 但 DNS 劫持仍然要有（移动端 TUN 也要接管解析）
      expect(tun['dns-hijack'], ['any:53']);
    });

    test('force 模式与 auto 模式生成同构的 tun 段（差别在是否设系统代理）', () {
      final a = _build(tunMode: 'auto', tunAutoRoute: true)['tun'] as Map;
      final f = _build(tunMode: 'force', tunAutoRoute: true)['tun'] as Map;
      expect(f['enable'], a['enable']);
      expect(f['auto-route'], a['auto-route']);
      expect(f['route-exclude-address'], a['route-exclude-address']);
    });
  });

  group('fd 注入（iOS socketpair 桥）的 Darwin 专属开关', () {
    // 真机根因：iOS 16.4+ 的 NEPacketTunnelFlow 不再暴露 utun fd，客户端只能用
    // socketpair 自己造一个；而 mihomo 在 Darwin 上默认 recvmsgx=true，建 TUN 时
    // 会对 fd 做 utun 专属 setsockopt(UTUN_OPT_MAX_PENDING_PACKETS) → 非 utun fd
    // 直接失败：「Start TUN listening error: ... operation not supported on socket」。
    // 表现就是扩展日志停在「调用 MihomelibStart…」之后再无下文、内核永远起不来。
    test('fd 注入时关掉 recvmsgx，并把 MTU 与扩展下发的 1500 对齐', () {
      final cfg = _build(tunMode: 'auto', tunFdInjected: true);
      final tun = cfg['tun'] as Map<String, dynamic>;
      expect(tun['recvmsgx'], false,
          reason: '开着 recvmsgx 内核会在建 TUN 时对非 utun fd 做 setsockopt 而启动失败');
      expect(tun['mtu'], 1500,
          reason: '不写 MTU 内核按默认 9000 生成报文，超过隧道 MTU 的包会被丢弃');
    });

    test('非 fd 注入（Android / 桌面）不写这些 Darwin 专属键', () {
      final cfg = _build(tunMode: 'auto', tunFdInjected: false);
      final tun = cfg['tun'] as Map<String, dynamic>;
      expect(tun.containsKey('recvmsgx'), isFalse,
          reason: 'Android 是 Linux 侧实现、桌面由内核自建接口，都该用内核默认值');
      expect(tun.containsKey('mtu'), isFalse);
    });
  });
}
