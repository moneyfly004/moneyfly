// mihomo 配置生成器测试：结构断言 + （有本地内核时）真实内核 -t 校验与 Clash API 行为验证
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/mihomo_config.dart';
import 'package:yaml/yaml.dart';

/// 定位本地 mihomo 二进制（MONEYFLY_MIHOMO 或 mihomo-bin/ 或 build/mihomo/）
String? _localMihomo() {
  final env = Platform.environment['MONEYFLY_MIHOMO'];
  if (env != null && File(env).existsSync()) return env;
  for (final p in [
    'mihomo-bin/mihomo-darwin-arm64',
    'mihomo-bin/mihomo',
    'build/mihomo/mihomo',
  ]) {
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  ProxyNode mkNode(String type,
          {String tag = '', Map<String, dynamic> raw = const {}}) =>
      ProxyNode(
        tag: tag.isEmpty ? '$type-1' : tag,
        type: type,
        server: '1.2.3.4',
        port: 443,
        uuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        password: 'pass123',
        cipher: 'aes-128-gcm',
        tls: true,
        sni: 'sni.example.com',
        countryCode: 'HK',
        raw: raw,
      );

  final vlessNode = mkNode('vless');

  test('基础结构: mixed-port/external-controller/secret/元数据', () {
    final cfg = MihomoConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect(cfg['mixed-port'], 2080);
    expect(cfg['external-controller'], '127.0.0.1:9090');
    expect(cfg['secret'], isNotEmpty);
    expect(cfg['secret'], cfg['_clashApiSecret']);
    expect(cfg['_localPort'], 2080);
    expect(cfg['_clashApiPort'], 9090);
    expect(cfg['proxies'], isA<List>());
  });

  test('智能模式: mode=rule + CN 直连规则; 全局模式: mode=global', () {
    final smart = MihomoConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    final global = MihomoConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: false);
    expect(smart['mode'], 'rule');
    expect(global['mode'], 'global');
    final rules = (smart['rules'] as List).cast<String>();
    expect(rules.contains('GEOSITE,cn,DIRECT'), isTrue);
    expect(rules.contains('GEOIP,CN,DIRECT'), isTrue);
    expect(rules.last, 'MATCH,select');
    // 全局模式也有基础规则（本地/局域网直连），但内核 mode=global 全走 GLOBAL 组
    expect((global['rules'] as List).length, greaterThan(0));
  });

  test('geoReady=false 时智能规则降级为全代理（geo 缺失也能起内核）', () {
    final cfg = MihomoConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        geoReady: false);
    final rules = (cfg['rules'] as List).cast<String>();
    expect(rules.any((r) => r.contains('GEOIP,CN')), isFalse);
    expect(rules.any((r) => r.contains('GEOSITE,cn')), isFalse);
    expect(rules.last, 'MATCH,select');
  });

  test('select 组: 默认节点排首位（mihomo select 启动选中第一项）', () {
    final a = mkNode('vless', tag: 'A-node');
    final b = mkNode('ss', tag: 'B-node');
    final cfg = MihomoConfigBuilder.build(
        nodes: [a, b], selectedTag: 'B-node', smartMode: true);
    final groups = (cfg['proxy-groups'] as List).cast<Map>();
    final select = groups.firstWhere((g) => g['name'] == 'select');
    expect((select['proxies'] as List).first, 'B-node');
    // 完整成员: 默认节点 + 其余节点 + DIRECT（无重复）
    final members = (select['proxies'] as List).cast<String>();
    expect(members.toSet().length, members.length, reason: '成员不得重复');
    expect(members.contains('DIRECT'), isTrue);
  });

  test('面板伪节点被过滤（server 空 / port 0）', () {
    final fake = ProxyNode(
        tag: '📢官网',
        type: 'vless',
        server: '',
        port: 0,
        countryCode: 'XX',
        raw: const {'name': '📢官网', 'type': 'vless'});
    final cfg = MihomoConfigBuilder.build(
        nodes: [fake, vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect((cfg['proxies'] as List).length, 1);
  });

  test('TUN 模式: 生成 tun 段(file-descriptor 由原生注入), 桌面 off 无 tun', () {
    final tun = MihomoConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        tunMode: 'auto');
    expect(tun['tun'], isA<Map>());
    final t = tun['tun'] as Map;
    expect(t['enable'], true);
    expect(t['stack'], 'gvisor');
    expect(t['auto-route'], false, reason: '路由由 VpnService 全量下发');
    expect(t.containsKey('file-descriptor'), isFalse,
        reason: 'fd 由原生注入，不在 Dart 侧写死');

    final off = MihomoConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    expect(off.containsKey('tun'), isFalse);
  });

  test('DNS: TUN 模式 fake-ip; 桌面无 listen/fake-ip', () {
    final tun = MihomoConfigBuilder.build(
        nodes: [vlessNode],
        selectedTag: vlessNode.tag,
        smartMode: true,
        tunMode: 'auto');
    expect((tun['dns'] as Map)['enhanced-mode'], 'fake-ip');
    final off = MihomoConfigBuilder.build(
        nodes: [vlessNode], selectedTag: vlessNode.tag, smartMode: true);
    final dns = off['dns'] as Map;
    expect(dns.containsKey('enhanced-mode'), isFalse);
    expect(dns.containsKey('listen'), isFalse, reason: '桌面 dns 不监听端口');
  });

  test('YAML 编码: 特殊字符节点名被正确引用且可被 yaml 解析', () {
    final tricky = ProxyNode(
        tag: '香港#1: 直连 [测试] {VIP}, true',
        type: 'ss',
        server: '1.1.1.1',
        port: 8388,
        password: 'p@ss:word,with#specials',
        cipher: 'aes-256-gcm',
        countryCode: 'HK',
        raw: const {
          'name': '香港#1: 直连 [测试] {VIP}, true',
          'type': 'ss',
          'server': '1.1.1.1',
          'port': 8388,
          'password': 'p@ss:word,with#specials',
          'cipher': 'aes-256-gcm',
        });
    final cfg = MihomoConfigBuilder.build(
        nodes: [tricky], selectedTag: tricky.tag, smartMode: true);
    final yamlText = MihomoConfigBuilder.encode(cfg);
    // yaml 包可解析且节点名完整保留
    final parsed = loadYaml(yamlText) as Map;
    final proxies = (parsed['proxies'] as List).cast<Map>();
    expect(proxies.single['name'], tricky.tag);
    expect(proxies.single['password'], 'p@ss:word,with#specials');
    final groups = (parsed['proxy-groups'] as List).cast<Map>();
    final select = groups.firstWhere((g) => g['name'] == 'select');
    expect((select['proxies'] as List), contains(tricky.tag));
  });

  // ===== 真实内核验证（有本地 mihomo 二进制时执行）=====
  final mihomo = _localMihomo();
  final skipMsg =
      mihomo == null ? '未找到本地 mihomo 内核（可用 MONEYFLY_MIHOMO 指定）' : null;

  test('真实内核 -t 校验生成的 YAML 合法', skip: skipMsg, () {
    // 覆盖全协议 + 特殊字符名 + TUN 段的配置
    final nodes = [
      mkNode('vless',
          raw: {
            'reality-opts': {'public-key': 'IRuRAh9SiCCSn1VUOIewPuI6ipsgOqYl5jMqOW1lCtM', 'short-id': '00112233'},
            'client-fingerprint': 'chrome'
          }),
      mkNode('vmess', raw: {'alterId': 0, 'network': 'ws', 'ws-opts': {'path': '/p'}}),
      mkNode('trojan', tag: '节点#1 [HK]'),
      mkNode('ss'),
      mkNode('ssr',
          raw: {
            'cipher': 'aes-128-cfb',
            'obfs': 'http_simple',
            'obfs-param': 'www.bing.com',
            'protocol': 'auth_aes128_md5'
          }),
      mkNode('hysteria2', raw: {'obfs': 'salamander', 'obfs-password': 'op'}),
      mkNode('tuic', raw: {'congestion-controller': 'bbr'}),
      mkNode('anytls'),
    ];
    final cfg = MihomoConfigBuilder.build(
        nodes: nodes, selectedTag: 'trojan-1', smartMode: true, tunMode: 'auto');
    final yamlText = MihomoConfigBuilder.encode(cfg);
    final tmp = Directory.systemTemp.createTempSync('mf_mihomo_t');
    try {
      File('${tmp.path}/config.yaml').writeAsStringSync(yamlText);
      final r = Process.runSync(mihomo!, ['-d', tmp.path, '-t'],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      debugPrint('mihomo -t stdout: ${r.stdout}');
      debugPrint('mihomo -t stderr: ${r.stderr}');
      expect(r.exitCode, 0, reason: '配置必须被 mihomo 接受: ${r.stderr}');
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  test('真实内核 Clash API: GLOBAL/select 组 + mode 热切换 + 切节点', skip: skipMsg,
      () async {
    final nodes = [mkNode('vless', tag: 'n1'), mkNode('ss', tag: 'n2')];
    final cfg = MihomoConfigBuilder.build(
        nodes: nodes, selectedTag: 'n1', smartMode: true);
    final yamlText = MihomoConfigBuilder.encode(cfg);
    final tmp = Directory.systemTemp.createTempSync('mf_mihomo_run');
    final apiPort = 19090 + (DateTime.now().millisecondsSinceEpoch % 1000);
    final dio = Dio();
    try {
      // 用替换端口的方式生成运行配置（避免 9090 与其它测试/系统冲突）
      final runYaml = yamlText.replaceAll('127.0.0.1:9090', '127.0.0.1:$apiPort');
      File('${tmp.path}/config.yaml').writeAsStringSync(runYaml);
      // 配置含随机 secret，后续所有 API 请求需带 Bearer 头
      final secret = (loadYaml(runYaml) as Map)['secret'] as String;
      dio.options.headers['Authorization'] = 'Bearer $secret';
      final proc = await Process.start(mihomo!, ['-d', tmp.path],
          environment: {'PATH': Platform.environment['PATH'] ?? ''});
      proc.stdout.transform(utf8.decoder).listen((_) {});
      proc.stderr.transform(utf8.decoder).listen((_) {});
      final api = 'http://127.0.0.1:$apiPort';
      // 等 /version 就绪
      var ready = false;
      for (var i = 0; i < 100; i++) {
        try {
          final r = await dio.get('$api/version',
              options: Options(validateStatus: (s) => true));
          if (r.statusCode == 200) {
            ready = true;
            break;
          }
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 100));
      }
      expect(ready, isTrue, reason: '内核 10s 内未就绪');
      final v = await dio.get('$api/version');
      debugPrint('内核版本: ${v.data}');

      // GLOBAL 与 select 组都存在
      final px = await dio.get('$api/proxies');
      final pxMap = (px.data as Map)['proxies'] as Map;
      expect(pxMap.containsKey('GLOBAL'), isTrue);
      expect(pxMap.containsKey('select'), isTrue);
      expect((pxMap['GLOBAL'] as Map)['type'], 'Selector');

      // 默认智能模式下 select 已选中 n1（列表首位即默认）
      final selNow = (pxMap['select'] as Map)['now'];
      expect(selNow, 'n1');

      // 热切节点: PUT /proxies/select n2
      await dio.put('$api/proxies/select',
          data: {'name': 'n2'},
          options: Options(validateStatus: (s) => true));
      await Future.delayed(const Duration(milliseconds: 200));
      final px2 = await dio.get('$api/proxies');
      expect(((px2.data as Map)['proxies'] as Map)['select']['now'], 'n2');

      // 热切模式: rule → global（PATCH /configs）
      await dio.patch('$api/configs',
          data: {'mode': 'global'},
          options: Options(validateStatus: (s) => true));
      await Future.delayed(const Duration(milliseconds: 200));
      final cfgs = await dio.get('$api/configs');
      expect((cfgs.data as Map)['mode'], 'global');
      // global 下把 GLOBAL 组切到 n2
      await dio.put('$api/proxies/GLOBAL',
          data: {'name': 'n2'},
          options: Options(validateStatus: (s) => true));
      await Future.delayed(const Duration(milliseconds: 200));
      final px3 = await dio.get('$api/proxies');
      expect(((px3.data as Map)['proxies'] as Map)['GLOBAL']['now'], 'n2');

      // 切回 rule
      await dio.patch('$api/configs',
          data: {'mode': 'rule'},
          options: Options(validateStatus: (s) => true));
      await Future.delayed(const Duration(milliseconds: 200));
      final cfgs2 = await dio.get('$api/configs');
      expect((cfgs2.data as Map)['mode'], 'rule');

      proc.kill();
      await proc.exitCode;
    } finally {
      dio.close(force: true);
      tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
