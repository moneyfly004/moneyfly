// 集成测试：真实启动 sing-box 内核，验证「点连接就能用」的核心链路。
//
// 运行条件（任一生效即可）：
//   1) 环境变量 MONEYFLY_SINGBOX 指向 sing-box 可执行文件
//   2) 仓库根 build/sing-box/sing-box 存在（tool/fetch_singbox.sh 获取）
// 不满足条件时自动跳过（CI 上桌面端不装内核二进制，避免误报失败）。
//
// 注意：本测试用 tunMode='off' 且关闭系统代理管理（manageSystemProxy=false），
// 不会改动系统代理/虚拟网卡。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/proxy_core_cli.dart';
import 'package:moneyfly/core/proxy/singbox_config.dart';

String _findBinary() {
  final env = Platform.environment['MONEYFLY_SINGBOX'];
  if (env != null && File(env).existsSync()) return env;
  return '${Directory.current.path}/build/sing-box/sing-box'
      '${Platform.isWindows ? '.exe' : ''}';
}

final binary = _findBinary();

ProxyNode _fakeNode() => ProxyNode(
      tag: '测试节点',
      type: 'vless',
      server: '127.0.0.1',
      port: 9, // 假地址：内核可启动，outbound 无需真实连通
      uuid: '00000000-0000-0000-0000-000000000000',
      countryCode: 'HK',
      raw: const {},
    );

Map<String, dynamic> _safeConfig() {
  final cfg = SingBoxConfigBuilder.build(
    nodes: [_fakeNode()],
    selectedTag: '测试节点',
    smartMode: true,
    tunMode: 'off', // 集成测试不创建虚拟网卡（需 root）
    ruleSetDir: ProxyCoreCli.workDir,
  );
  // 测试期间 app 不管理系统代理，避免改动真实系统代理
  ProxyCoreCli.manageSystemProxy = false;
  return cfg;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 默认用 mock HttpClient 拦截一切 HTTP（返回 400）；
  // 本集成测试需要真实访问内核 Clash API，复位为系统实现
  HttpOverrides.global = null;

  final hasBinary = File(binary).existsSync();
  final skip = hasBinary ? null : '未找到 sing-box 内核（tool/fetch_singbox.sh 获取后本地验证）';

  test('配置生成：含本地规则集路径与双 inbounds 结构', skip: skip, () {
    final cfg = _safeConfig();
    final ruleSets = cfg['route']['rule_set'] as List;
    expect(ruleSets, hasLength(2));
    expect(ruleSets[0]['type'], 'local'); // 内置规则，非远程
    expect(ruleSets[0]['path'], contains('geoip-cn.srs'));
    final inbounds = cfg['inbounds'] as List;
    expect(inbounds.any((i) => (i as Map)['type'] == 'mixed'), isTrue);
    expect(cfg['experimental']['clash_api']['external_controller'], '127.0.0.1:9090');
  });

  test('配置生成：tunMode off → 仅 mixed；bypassLan false → 内网段不放行', skip: skip, () {
    final cfgOff = SingBoxConfigBuilder.build(
        nodes: [_fakeNode()], selectedTag: '测试节点', smartMode: true, tunMode: 'off');
    final ibs = cfgOff['inbounds'] as List;
    expect(ibs.any((i) => (i as Map)['type'] == 'tun'), isFalse);

    final cfgLan = SingBoxConfigBuilder.build(
        nodes: [_fakeNode()],
        selectedTag: '测试节点',
        smartMode: false,
        tunMode: 'off',
        bypassLan: false);
    final rules = cfgLan['route']['rules'] as List;
    final global = rules.firstWhere((r) => (r as Map)['clash_mode'] == 'Global') as Map;
    final cidrs = global['ip_cidr'] as List;
    expect(cidrs, contains('127.0.0.0/8')); // 回环始终放行
    expect(cidrs, isNot(contains('192.168.0.0/16'))); // 内网不放行
  });

  test('端到端：启动内核 → Clash API 就绪 → 切模式 → 流量统计 → 停止', skip: skip, () async {
    final core = ProxyCoreCli();
    expect(core.isRunning, isFalse);

    try {
      // 启动
      await core.start(_safeConfig());
      expect(core.isRunning, isTrue);

      // 内置规则集已落盘
      final workDir = Directory(ProxyCoreCli.workDir);
      expect(File('${workDir.path}/geoip-cn.srs').existsSync(), isTrue,
          reason: '智能模式规则集应从 App 资产落盘到工作目录');
      expect(File('${workDir.path}/config.json').existsSync(), isTrue);

      // 热切模式（Clash API PATCH /configs）——Global ↔ Rule 不应抛错
      await core.switchMode(false);
      await core.switchMode(true);

      // 流量统计回调不抛（1s 流式推送）
      var trafficTicks = 0;
      core.onTraffic = (up, down) => trafficTicks++;
      await Future.delayed(const Duration(milliseconds: 2600));
      expect(trafficTicks, greaterThanOrEqualTo(1), reason: '/traffic 流应持续产出');

      // 异常退出回调（主动停止不应触发）
      var unexpected = 0;
      core.onUnexpectedExit = () => unexpected++;

      // 停止：进程干净退出
      await core.stop();
      await Future.delayed(const Duration(milliseconds: 600));
      expect(core.isRunning, isFalse);
      expect(unexpected, 0, reason: '主动断开不应视为异常退出');

      // 二次启动（幂等性：停止后可再次连接）
      await core.start(_safeConfig());
      expect(core.isRunning, isTrue);
      await core.stop();
    } finally {
      // 断言失败时确保内核停止，避免残留进程占用 2080/9090 污染其他测试
      if (core.isRunning) {
        await core.stop();
      }
    }
  });

  test('配置序列化：JSON 可解析且无动态端口冲突', skip: skip, () {
    final encoded = SingBoxConfigBuilder.encode(_safeConfig());
    final decoded = jsonDecode(encoded);
    expect(decoded, isA<Map>());
    final mixed = (decoded['inbounds'] as List)
        .firstWhere((i) => (i as Map)['type'] == 'mixed') as Map;
    expect(mixed['listen_port'], 2080);
  });
}
