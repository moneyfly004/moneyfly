// 集成测试：真实启动 mihomo 内核，验证「点连接就能用」的核心链路。
//
// 运行条件（任一生效即可）：
//   1) 环境变量 MONEYFLY_MIHOMO 指向 mihomo 可执行文件
//   2) 仓库根 build/mihomo/mihomo 存在（tool/fetch_mihomo.sh 获取）
// 不满足条件时自动跳过（CI 上桌面端不装内核二进制，避免误报失败）。
//
// 注意：本测试用 tunMode='off' 且关闭系统代理管理（manageSystemProxy=false），
// 不会改动系统代理/虚拟网卡。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/mihomo_config.dart';
import 'package:moneyfly/core/proxy/proxy_core_cli.dart';
import 'package:yaml/yaml.dart';

String _findBinary() {
  final env = Platform.environment['MONEYFLY_MIHOMO'];
  if (env != null && File(env).existsSync()) return env;
  return '${Directory.current.path}/build/mihomo/mihomo'
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
  final cfg = MihomoConfigBuilder.build(
    nodes: [_fakeNode()],
    selectedTag: '测试节点',
    smartMode: true,
    tunMode: 'off', // 集成测试不创建虚拟网卡（需 root）
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
  final skip = hasBinary ? null : '未找到 mihomo 内核（tool/fetch_mihomo.sh 获取后本地验证）';

  test('配置生成：mihomo YAML 基础结构', skip: skip, () {
    final cfg = _safeConfig();
    expect(cfg['mixed-port'], 2080);
    expect(cfg['external-controller'], '127.0.0.1:9090');
    expect(cfg['mode'], 'rule'); // 智能模式
    final rules = (cfg['rules'] as List).cast<String>();
    expect(rules.contains('GEOSITE,cn,DIRECT'), isTrue);
    expect(rules.last, 'MATCH,select');
  });

  test('配置生成：tunMode off → 无 tun 段；bypassLan false → 内网段不放行', skip: skip, () {
    final cfgOff = MihomoConfigBuilder.build(
        nodes: [_fakeNode()], selectedTag: '测试节点', smartMode: true, tunMode: 'off');
    expect(cfgOff.containsKey('tun'), isFalse);

    final cfgLan = MihomoConfigBuilder.build(
        nodes: [_fakeNode()],
        selectedTag: '测试节点',
        smartMode: false,
        tunMode: 'off',
        bypassLan: false);
    final rules = (cfgLan['rules'] as List).cast<String>();
    expect(rules.contains('IP-CIDR,127.0.0.0/8,DIRECT'), isTrue); // 回环始终放行
    expect(rules.any((r) => r.contains('192.168.0.0/16')), isFalse); // 内网不放行
  });

  test('端到端：启动内核 → Clash API 就绪 → 切模式 → 流量统计 → 停止', skip: skip, () async {
    final core = ProxyCoreCli();
    expect(core.isRunning, isFalse);

    try {
      // 启动
      await core.start(_safeConfig());
      expect(core.isRunning, isTrue);

      // 离线 geo 数据已就位 + config.yaml 已写入（mihomo 从 workDir 读默认文件名）
      final workDir = Directory(ProxyCoreCli.workDir);
      expect(File('${workDir.path}/config.yaml').existsSync(), isTrue);

      // 热切模式（Clash API PATCH /configs）——global ↔ rule 不应抛错
      await core.switchMode(false);
      await core.switchMode(true);

      // 流量统计回调（1s 流式推送；假节点无实际流量时 tick 可能为 0，
      // 仅验证回调注册不抛、不挂起——CI runner 无出站流量属正常）
      core.onTraffic = (up, down) {};
      await Future.delayed(const Duration(milliseconds: 2600));

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

  test('配置序列化：YAML 可解析且端口正确', skip: skip, () {
    final encoded = MihomoConfigBuilder.encode(_safeConfig());
    final decoded = loadYaml(encoded) as Map;
    expect(decoded['mixed-port'], 2080);
    expect(decoded['mode'], 'rule');
    // 元数据不得写入 YAML
    expect(decoded.containsKey('_localPort'), isFalse);
    expect(decoded.containsKey('_tunMode'), isFalse);
  });
}
