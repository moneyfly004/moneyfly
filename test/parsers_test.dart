import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/services/subscription_service.dart';

void main() {
  group('Clash YAML 解析', () {
    test('解析 proxies 节点列表', () {
      const yaml = '''
proxies:
  - name: 香港-01 · 大带宽
    type: vless
    server: 1.2.3.4
    port: 443
    uuid: 12345678-1234-1234-1234-123456789abc
    network: ws
    ws-opts:
      path: /ws
      headers:
        Host: hk01.example.com
    tls: true
  - name: 日本东京
    type: trojan
    server: 5.6.7.8
    port: 8443
    password: secret123
''';
      final nodes = SubscriptionService.parseClashYaml(yaml);
      expect(nodes.length, 2);
      expect(nodes[0].type, 'vless');
      expect(nodes[0].server, '1.2.3.4');
      expect(nodes[0].port, 443);
      expect(nodes[0].countryCode, 'HK'); // 从名称推断
      expect(nodes[0].wsPath, '/ws');
      expect(nodes[0].host, 'hk01.example.com');
      expect(nodes[1].type, 'trojan');
      expect(nodes[1].countryCode, 'JP');
    });

    test('空/非法内容返回空列表', () {
      expect(SubscriptionService.parseClashYaml(''), isEmpty);
      expect(SubscriptionService.parseClashYaml('not yaml at all {{{'), isEmpty);
    });
  });

  group('base64 订阅解析', () {
    test('解析 vless/trojan 链接', () {
      // vless://uuid@host:port?type=ws&path=%2Fws&security=tls#名称
      final vless = 'vless://12345678-1234-1234-1234-123456789abc@1.2.3.4:443?type=ws&path=%2Fws&security=tls#%E9%A6%99%E6%B8%AF-01';
      final trojan = 'trojan://secret@5.6.7.8:443?sni=jp.example.com#%E6%97%A5%E6%9C%AC';
      final nodes = SubscriptionService.parseBase64Nodes('$vless\n$trojan');
      expect(nodes.length, 2);
      expect(nodes[0].type, 'vless');
      expect(nodes[0].server, '1.2.3.4');
      expect(nodes[0].tag, '香港-01');
      expect(nodes[1].type, 'trojan');
      expect(nodes[1].password, 'secret');
      expect(nodes[1].sni, 'jp.example.com');
    });

    test('vmess 链接解析', () {
      final vmessPayload = 'eyJhZGQiOiI5LjkuOS45IiwicG9ydCI6ODQ0MywiaWQiOiJhYmNkLWVmZ2giLCJ0eXBlIjoibm9uZSIsInBzIjoiVk1lc3MtVGVzdCJ9';
      // {"add":"9.9.9.9","port":8443,"id":"abcd-efgh","type":"none","ps":"VMess-Test"}
      final nodes = SubscriptionService.parseBase64Nodes('vmess://$vmessPayload');
      expect(nodes.length, 1);
      expect(nodes[0].type, 'vmess');
      expect(nodes[0].server, '9.9.9.9');
      expect(nodes[0].port, 8443);
      expect(nodes[0].uuid, 'abcd-efgh');
    });
  });
}
