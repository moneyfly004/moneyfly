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
  bool useMrsRuleSet = false,
}) =>
    MihomoConfigBuilder.build(
      nodes: [_node()],
      selectedTag: '测试节点',
      smartMode: true,
      tunMode: tunMode,
      bypassLan: bypassLan,
      tunAutoRoute: tunAutoRoute,
      tunFdInjected: tunFdInjected,
      useMrsRuleSet: useMrsRuleSet,
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

  // iOS 专用：GEOSITE,cn 会用 succinct 匹配器把 11 万条域名建成内存索引，
  // 启动期一次申请约 74MB 堆（本机实测）—— iOS 扩展内存上限只有几十 MB，
  // 真机表现是内核起来 ~200ms 被系统杀掉且无任何日志。改用 .mrs 规则集
  // （zstd 直查，实测堆 +2MB、规则数 111021）后启动内存才回到扩展能承受的范围。
  group('iOS .mrs 规则集（替代 GEOSITE,cn）', () {
    test('开启后：规则用 RULE-SET,cn，并声明 file/mrs 规则集', () {
      final cfg = _build(tunMode: 'auto', tunFdInjected: true, useMrsRuleSet: true);
      final rules = (cfg['rules'] as List).cast<String>();
      expect(rules, contains('RULE-SET,cn,DIRECT'));
      expect(rules.any((r) => r.startsWith('GEOSITE,')), isFalse);
      // GEOIP,CN 成本很低（实测 +6MB），保留
      expect(rules, contains('GEOIP,CN,DIRECT'));

      final providers = cfg['rule-providers'] as Map;
      final cn = providers['cn'] as Map;
      expect(cn['type'], 'file');
      expect(cn['behavior'], 'domain');
      expect(cn['format'], 'mrs');
      // 相对路径：内核按 homeDir 解析（扩展把 cn.mrs 放到自己的 homeDir）
      expect(cn['path'], 'cn.mrs');
    });

    test('默认（Android/桌面）仍是 GEOSITE,cn，且不写 rule-providers', () {
      final cfg = _build(tunMode: 'auto');
      final rules = (cfg['rules'] as List).cast<String>();
      expect(rules, contains('GEOSITE,cn,DIRECT'));
      expect(rules.any((r) => r.startsWith('RULE-SET,')), isFalse);
      expect(cfg.containsKey('rule-providers'), isFalse);
    });

    test('geoReady=false（离线数据缺失）时不写规则集，也不写 GEOSITE', () {
      final cfg = MihomoConfigBuilder.build(
        nodes: [_node()],
        selectedTag: '测试节点',
        smartMode: true,
        tunMode: 'auto',
        tunFdInjected: true,
        useMrsRuleSet: true,
        geoReady: false,
      );
      final rules = (cfg['rules'] as List).cast<String>();
      expect(rules.any((r) => r.startsWith('GEOSITE,')), isFalse);
      expect(rules.any((r) => r.startsWith('RULE-SET,')), isFalse);
      expect(cfg.containsKey('rule-providers'), isFalse);
    });
  });
}
