import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/proxy/mihomo_config.dart';
import 'package:moneyfly/core/services/subscription_service.dart';

/// 订阅解析回归测试。
///
/// 这一组用例来自一次真实故障：用户反馈「订阅里的节点一个都测不了速」，
/// 排查发现整份订阅被解析成 **0 个节点**，且没有任何报错。三个独立缺陷：
///
/// 1. Dart 的 `base64.normalize` 遇到任何非 base64 字符（含换行/空格）
///    **直接抛 FormatException**（它只做 URL-safe 字母表归一化，不剥离空白），
///    而机场订阅响应体几乎都在末尾带 `\n`、长串还会按 76 字符折行 ——
///    异常被 `catch (_) {}` 吞掉后，代码拿 base64 原文逐行当链接解析，
///    全部落空 → 0 节点。
/// 2. `hy2://` 是 hysteria2 的通用简写，旧实现只认 `hysteria2://`，
///    整份订阅里的 hy2 节点被静默丢弃。
/// 3. 复用 hysteria2 解析器时按 `'hysteria2://'.length`(12) 切前缀去切
///    `hy2://` 的链接(6)，多切 6 个字符 → UUID 密码被截断，节点永远连不上。
void main() {
  const hy2 =
      'hy2://b07db61f-a207-4508-97f5-68182991c2d6@152.69.220.212:35000'
      '?sni=api.push.apple.com&insecure=0#%E6%96%B0%E5%8A%A0%E5%9D%A1-1';
  const vlessReality =
      'vless://11111111-2222-3333-4444-555555555555@203.10.96.138:443'
      '?security=reality&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=fd26d49a&fp=ios'
      '&flow=xtls-rprx-vision&type=tcp&sni=www.apple.com#%E7%BE%8E%E5%9B%BD-1';
  const vlessWs =
      'vless://11111111-2222-3333-4444-666666666666@pq.aws48.yydjc.top:443'
      '?security=tls&type=ws&path=%2Fws&host=cdn.example.com&sni=cdn.example.com'
      '#%E6%97%A5%E6%9C%AC-1';

  final plain = [hy2, vlessReality, vlessWs].join('\n');
  String b64(String s) => base64.encode(utf8.encode(s));

  test('base64 订阅体末尾带换行时必须解出全部节点（核心回归）', () {
    // 机场响应体真实形态：一整行 base64 + 结尾换行
    final body = '${b64(plain)}\n';
    final nodes = SubscriptionService.parseBase64Nodes(body);
    expect(nodes.length, 3, reason: '末尾换行曾导致整份订阅解析成 0 节点');
    expect(nodes.where((n) => n.type == 'hysteria2').length, 1);
    expect(nodes.where((n) => n.type == 'vless').length, 2);
    // 走完整入口同样要正确（parseClashYaml 对非 YAML 文本回退到链接解析）
    expect(SubscriptionService.parseClashYaml(body).length, 3);
  });

  test('base64 折行 / 无填充 / CRLF 都要能解', () {
    final long = b64(plain);
    final wrapped = StringBuffer();
    for (var i = 0; i < long.length; i += 76) {
      wrapped.writeln(long.substring(i, (i + 76).clamp(0, long.length)));
    }
    expect(SubscriptionService.parseBase64Nodes(wrapped.toString()).length, 3,
        reason: '76 字符折行是面板导出常态');
    expect(SubscriptionService.parseBase64Nodes(long.replaceAll('=', '')).length,
        3, reason: '部分面板去掉 = 填充');
    expect(
        SubscriptionService.parseBase64Nodes('${b64(plain)}\r\n\r\n'.trim())
            .length,
        3);
    // 首尾空白 + BOM
    expect(SubscriptionService.parseBase64Nodes('\uFEFF ${b64(plain)} \n').length,
        3);
  });

  test('hy2:// 简写按 hysteria2 解析，且密码不被截断', () {
    final n = SubscriptionService.parseBase64Nodes(hy2).single;
    expect(n.type, 'hysteria2');
    expect(n.server, '152.69.220.212');
    expect(n.port, 35000);
    // 截断 bug 会得到 '1f-a207-...'（少了前 6 个字符）
    expect(n.raw['password'], 'b07db61f-a207-4508-97f5-68182991c2d6');
    expect(n.password, 'b07db61f-a207-4508-97f5-68182991c2d6');
    expect(n.sni, 'api.push.apple.com');
  });

  test('hy2:// 与 hysteria2:// 得到完全一致的节点', () {
    final short = SubscriptionService.parseBase64Nodes(hy2).single;
    final long = SubscriptionService.parseBase64Nodes(
            hy2.replaceFirst('hy2://', 'hysteria2://'))
        .single;
    expect(short.raw, long.raw);
  });

  test('vless reality 的 pbk/sid/flow 映射到内核字段', () {
    final n = SubscriptionService.parseBase64Nodes(vlessReality).single;
    expect(n.raw['tls'], true);
    expect(n.raw['reality-opts']['public-key'],
        'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0');
    expect(n.raw['reality-opts']['short-id'], 'fd26d49a');
    expect(n.raw['client-fingerprint'], 'ios');
    expect(n.raw['flow'], 'xtls-rprx-vision');
  });

  test('base64(Clash YAML) 也要能解析', () {
    final yaml = 'proxies:\n'
        '  - {name: A, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: p}\n'
        '  - {name: B, type: vless, server: 5.6.7.8, port: 443, uuid: u, tls: true}\n';
    expect(SubscriptionService.parseClashYaml('${b64(yaml)}\n').length, 2);
  });

  test('UDP+TLS 协议默认放宽证书校验，可关闭，且不影响 TCP 协议', () {
    final nodes = SubscriptionService.parseBase64Nodes(b64(plain));
    Map<String, dynamic> cfgFor({required bool relax}) =>
        MihomoConfigBuilder.build(
          nodes: nodes,
          selectedTag: nodes.first.tag,
          smartMode: true,
          tunMode: 'off',
          clashApiSecret: 't',
          geoReady: false,
          udpSkipCertVerify: relax,
        );
    List<Map<String, dynamic>> proxiesOf(Map<String, dynamic> cfg, String type) =>
        (cfg['proxies'] as List)
            .cast<Map<String, dynamic>>()
            .where((p) => p['type'] == type)
            .toList();

    final on = cfgFor(relax: true);
    expect(proxiesOf(on, 'hysteria2').single['skip-cert-verify'], true,
        reason: 'hy2 使用伪装 SNI，证书不可能匹配，校验开着必然连不上');
    expect(proxiesOf(on, 'vless').every((p) => p['skip-cert-verify'] != true),
        true, reason: 'TCP+TLS 协议证书校验照旧，不得被顺手放宽');

    final off = cfgFor(relax: false);
    expect(proxiesOf(off, 'hysteria2').single['skip-cert-verify'], isNot(true));
  });

  test('生成的配置能被内核加载（有本地内核时）', () {
    final mihomo = _localMihomo();
    if (mihomo == null) {
      markTestSkipped('未提供本地 mihomo 内核（MONEYFLY_MIHOMO / mihomo-bin/）');
      return;
    }
    final nodes = SubscriptionService.parseBase64Nodes('${b64(plain)}\n');
    final cfg = MihomoConfigBuilder.build(
      nodes: nodes,
      selectedTag: nodes.first.tag,
      smartMode: true,
      tunMode: 'off',
      localPort: 27899,
      clashApiPort: 29099,
      clashApiSecret: 'secret',
      geoReady: false,
    );
    expect(cfg['proxies'], hasLength(3));
    final tmp = Directory.systemTemp.createTempSync('mf_b64_');
    File('${tmp.path}/config.yaml')
        .writeAsStringSync(MihomoConfigBuilder.encode(cfg));
    final r = Process.runSync(mihomo, ['-d', tmp.path, '-t']);
    expect(r.exitCode, 0, reason: '内核必须接受配置: ${r.stdout}\n${r.stderr}');
    tmp.deleteSync(recursive: true);
  });
}

String? _localMihomo() {
  final env = Platform.environment['MONEYFLY_MIHOMO'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
  for (final p in [
    'mihomo-bin/mihomo-darwin-arm64',
    'mihomo-bin/mihomo',
    'build/mihomo/mihomo',
  ]) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
