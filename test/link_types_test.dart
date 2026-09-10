import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/proxy/mihomo_config.dart';
import 'package:moneyfly/core/services/subscription_service.dart';

void main() {
  ProxyNode one(String link) =>
      SubscriptionService.parseBase64Nodes(link).single;

  test('socks5:// base64(user:pass)@host:port', () {
    final n = one(
        'socks://cXh6Y2V4c2FyejppcHBtaXV5bW90cm1pdXA@direct.miyavip.vip:8001#%E5%B7%B4%E8%A5%BF');
    expect(n.type, 'socks5');
    expect(n.server, 'direct.miyavip.vip');
    expect(n.port, 8001);
    expect(n.raw['username'], 'qxzcexsarz');
    expect(n.raw['password'], 'ippmiuymotrmiup');
  });

  test('vless:// TCP TLS Vision（uuid + flow + fingerprint）', () {
    final n = one(
        'vless://1470437f-5071-4286-b47b-e42a4dba8a5e@my.icandoit.eu.org:10031?encryption=none&flow=xtls-rprx-vision&security=tls&sni=my.icandoit.eu.org&fp=chrome&type=tcp#V');
    expect(n.type, 'vless');
    expect(n.uuid, '1470437f-5071-4286-b47b-e42a4dba8a5e');
    expect(n.raw['tls'], true);
    expect(n.raw['servername'], 'my.icandoit.eu.org');
    expect(n.raw['flow'], 'xtls-rprx-vision');
    expect(n.raw['client-fingerprint'], 'chrome');
  });

  test('vless:// WS（network + ws-opts）', () {
    final n = one(
        'vless://1470437f-5071-4286-b47b-e42a4dba8a5e@my.icandoit.eu.org:41827?security=tls&sni=my.icandoit.eu.org&type=ws&host=my.icandoit.eu.org&path=%2Ffgmiws#V');
    expect(n.raw['network'], 'ws');
    expect((n.raw['ws-opts'] as Map)['path'], '/fgmiws');
    expect(((n.raw['ws-opts'] as Map)['headers'] as Map)['Host'], 'my.icandoit.eu.org');
  });

  test('vless:// Reality Vision（reality-opts）', () {
    final n = one(
        'vless://1470437f-5071-4286-b47b-e42a4dba8a5e@my.icandoit.eu.org:12698?security=reality&sni=my.icandoit.eu.org&pbk=sGUhoQe3Zf4mq3ntxA_byNVwkxy97_HCZZ0l8zEo9lM&sid=6ba85179e30d4fc2&type=tcp#VR');
    final ro = n.raw['reality-opts'] as Map;
    expect(ro['public-key'], 'sGUhoQe3Zf4mq3ntxA_byNVwkxy97_HCZZ0l8zEo9lM');
    expect(ro['short-id'], '6ba85179e30d4fc2');
  });

  test('vless:// Reality gRPC（grpc-opts）', () {
    final n = one(
        'vless://1470437f-5071-4286-b47b-e42a4dba8a5e@my.icandoit.eu.org:20564?security=reality&sni=s0.awsstatic.com&pbk=sGUhoQe3Zf4mq3ntxA_byNVwkxy97_HCZZ0l8zEo9lM&sid=6ba85179e30d4fc2&type=grpc&serviceName=grpc#VG');
    expect(n.raw['network'], 'grpc');
    expect((n.raw['grpc-opts'] as Map)['grpc-service-name'], 'grpc');
  });

  test('trojan://（password + sni + alpn）', () {
    final n = one(
        'trojan://1470437f-5071-4286-b47b-e42a4dba8a5e@my.icandoit.eu.org:29688?security=tls&sni=my.icandoit.eu.org&alpn=http%2F1.1&type=tcp#T');
    expect(n.type, 'trojan');
    expect(n.password, '1470437f-5071-4286-b47b-e42a4dba8a5e');
    expect(n.raw['sni'], 'my.icandoit.eu.org');
    expect(n.raw['alpn'], ['http/1.1']);
  });

  test('hysteria2://（password + sni）', () {
    final n = one(
        'hysteria2://1470437f-5071-4286-b47b-e42a4dba8a5e@my.icandoit.eu.org:40542?sni=my.icandoit.eu.org&insecure=0#H2');
    expect(n.type, 'hysteria2');
    expect(n.password, '1470437f-5071-4286-b47b-e42a4dba8a5e');
    expect(n.raw['sni'], 'my.icandoit.eu.org');
  });

  test('tuic://（uuid + password + alpn + congestion）', () {
    final n = one(
        'tuic://1470437f-5071-4286-b47b-e42a4dba8a5e%3A1470437f-5071-4286-b47b-e42a4dba8a5e@my.icandoit.eu.org:37667?sni=my.icandoit.eu.org&alpn=h3&congestion_control=cubic#TU');
    expect(n.type, 'tuic');
    expect(n.uuid, '1470437f-5071-4286-b47b-e42a4dba8a5e');
    expect(n.password, '1470437f-5071-4286-b47b-e42a4dba8a5e');
    expect(n.raw['alpn'], ['h3']);
    expect(n.raw['congestion-controller'], 'cubic');
  });

  test('anytls://（password + sni）', () {
    final n = one(
        'anytls://1470437f-5071-4286-b47b-e42a4dba8a5e@my.icandoit.eu.org:19160?security=tls&sni=my.icandoit.eu.org&type=tcp#A');
    expect(n.type, 'anytls');
    expect(n.password, '1470437f-5071-4286-b47b-e42a4dba8a5e');
    expect(n.raw['sni'], 'my.icandoit.eu.org');
  });

  test('vmess:// 生成标准 mihomo map（不再有 type=none 冲突）', () {
    const vm = 'vmess://ew0KICAidiI6ICIyIiwNCiAgInBzIjogInQiLA0KICAiYWRkIjogIm15LmljYW5kb2l0LmV1Lm9yZyIsDQogICJwb3J0IjogIjE4Mjg5IiwNCiAgImlkIjogIjE0NzA0MzdmIiwNCiAgImFpZCI6ICIwIiwNCiAgInNjeSI6ICJhdXRvIiwNCiAgIm5ldCI6ICJ3cyIsDQogICJ0eXBlIjogIm5vbmUiLA0KICAiaG9zdCI6ICJteS5pY2FuZG9pdC5ldS5vcmciLA0KICAicGF0aCI6ICIvemZvdSIsDQogICJ0bHMiOiAidGxzIiwNCiAgInNuaSI6ICJteS5pY2FuZG9pdC5ldS5vcmciDQp9';
    final n = one(vm);
    expect(n.type, 'vmess');
    expect(n.raw['type'], 'vmess'); // 关键：不是 none
    expect(n.raw['server'], 'my.icandoit.eu.org');
    expect(n.raw['uuid'], '1470437f');
    expect(n.raw['network'], 'ws');
    expect((n.raw['ws-opts'] as Map)['path'], '/zfou');
  });

  test('ssr://（base64url 主体 + obfsparam/remarks）', () {
    final n = one(
        'ssr://Y24xMC5zb21ldGhpbmdzdHJhbmdlcy5jb206ODMwMjpvcmlnaW46Y2hhY2hhMjAtaWV0ZjpodHRwX3NpbXBsZTpjR0Z6YzNkay8_b2Jmc3BhcmFtPU1qYzNPVFF0WW1GblpYbGhiSFV3TURFdVpHOTNibXh2WVdRdWJXbGpjbTl6YjJaMExtTnZiUSZwcm90b3BhcmFtPSZyZW1hcmtzPTVZLXc1cm0tTURJJmdyb3VwPVIyOVhaV0k');
    expect(n.type, 'ssr');
    expect(n.tag, '台湾02');
    expect(n.server, 'cn10.somethingstranges.com');
    expect(n.port, 8302);
    expect(n.cipher, 'chacha20-ietf');
    expect(n.password, 'passwd');
    expect(n.raw['protocol'], 'origin');
    expect(n.raw['obfs'], 'http_simple');
    expect(n.raw['obfs-param'], '27794-bageyalu001.download.microsoft.com');
  });

  test('hysteria:// v1（auth 在 query，无 userinfo）', () {
    final n = one(
        'hysteria://1.2.3.4:443?auth=pwd123&peer=example.com&insecure=1&upmbps=10&downmbps=50&obfs=xplus&obfsParam=obfspwd#H1');
    expect(n.type, 'hysteria');
    expect(n.password, 'pwd123');
    expect(n.raw['sni'], 'example.com');
    expect(n.raw['obfs'], 'xplus');
    expect(n.raw['obfs-param'], 'obfspwd');
    expect(n.raw['up'], 10);
    expect(n.raw['down'], 50);
  });

  test('wireguard://（base64 .conf）', () {
    final conf = base64Encode(utf8.encode(
        '[Interface]\nPrivateKey = pk\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = pubk\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n'));
    final n = one('wireguard://$conf#WG');
    expect(n.type, 'wireguard');
    expect(n.server, '1.2.3.4');
    expect(n.port, 51820);
    expect(n.raw['private-key'], 'pk');
    expect(n.raw['public-key'], 'pubk');
    expect(n.raw['ip'], '10.0.0.2/32');
  });

  test('所有类型都能生成 mihomo YAML（不崩溃、type 正确）', () {
    const links = [
      'socks://cXh6Y2V4c2FyejppcHBtaXV5bW90cm1pdXA@direct.miyavip.vip:8001#s1',
      'vless://1470437f-5071-4286-b47b-e42a4dba8a5e@h:10031?security=tls&sni=h#v1',
      'trojan://pwd@h:29688?security=tls&sni=h#t1',
      'hysteria2://pwd@h:40542?sni=h#h1',
      'tuic://u%3Ap@h:37667?alpn=h3#tu1',
      'anytls://pwd@h:19160?security=tls&sni=h#a1',
    ];
    final nodes = [
      for (final l in links) SubscriptionService.parseBase64Nodes(l).single,
    ];
    final cfg = MihomoConfigBuilder.build(
        nodes: nodes, selectedTag: nodes.first.tag, smartMode: true);
    final yaml = MihomoConfigBuilder.encode(cfg);
    expect(yaml, contains('type: socks5'));
    expect(yaml, contains('type: vless'));
    expect(yaml, contains('type: trojan'));
    expect(yaml, contains('type: hysteria2'));
    expect(yaml, contains('type: tuic'));
    expect(yaml, contains('type: anytls'));
  });

  // 真实内核校验（有本地 mihomo 时执行）
  final mihomo = _localMihomo();
  if (mihomo != null) {
    test('真实 mihomo -t 校验多协议配置', () {
      // wireguard 需要合法 32 字节 base64 私钥（测试用固定合法值）
      final wgConf = base64Encode(utf8.encode(
          '[Interface]\nPrivateKey = WZKDPOtKaVbPxSh8LWj5dsUzNk67OgOGPFFZ6EyLPok=\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = WjkI3yw1nhgeRwH7guNCAoFBrDlrg7BhQgtAGAmd+K4=\nEndpoint = 1.2.3.4:51820\nAllowedIPs = 0.0.0.0/0\n'));
      final links = [
        'socks://cXh6Y2V4c2FyejppcHBtaXV5bW90cm1pdXA@1.2.3.4:8001#s1',
        'vless://u@1.2.3.4:10031?security=tls&sni=example.com&type=tcp#v1',
        'trojan://pwd@1.2.3.4:29688?security=tls&sni=example.com#t1',
        'hysteria2://pwd@1.2.3.4:40542?sni=example.com#h1',
        'tuic://u%3Ap@1.2.3.4:37667?alpn=h3#tu1',
        'anytls://pwd@1.2.3.4:19160?security=tls&sni=example.com#a1',
        'ssr://Y24xMC5zb21ldGhpbmdzdHJhbmdlcy5jb206ODMwMjpvcmlnaW46Y2hhY2hhMjAtaWV0ZjpodHRwX3NpbXBsZTpjR0Z6YzNkay8_b2Jmc3BhcmFtPU1qYzNPVFF0WW1GblpYbGhiSFV3TURFdVpHOTNibXh2WVdRdWJXbGpjbTl6YjJaMExtTnZiUSZwcm90b3BhcmFtPSZyZW1hcmtzPTVZLXc1cm0tTURJJmdyb3VwPVIyOVhaV0k',
        'hysteria://1.2.3.4:443?auth=pwd123&peer=example.com&upmbps=10&downmbps=50#h1',
        'wireguard://$wgConf#wg1',
      ];
      final nodes = [
        for (final l in links) SubscriptionService.parseBase64Nodes(l).single,
      ];
      final cfg = MihomoConfigBuilder.build(
          nodes: nodes, selectedTag: nodes.first.tag, smartMode: true, geoReady: false);
      final tmp = Directory.systemTemp.createTempSync('mf_multi_t');
      File('${tmp.path}/config.yaml').writeAsStringSync(MihomoConfigBuilder.encode(cfg));
      final r = Process.runSync(mihomo, ['-d', tmp.path, '-t']);
      expect(r.exitCode, 0, reason: 'mihomo 必须接受多协议配置: ${r.stdout}\n${r.stderr}');
      tmp.deleteSync(recursive: true);
    });
  }
}

String? _localMihomo() {
  final env = Platform.environment['MONEYFLY_MIHOMO'];
  if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
  for (final p in ['mihomo-bin/mihomo-darwin-arm64', 'mihomo-bin/mihomo', 'build/mihomo/mihomo']) {
    if (File(p).existsSync()) return p;
  }
  return null;
}
