import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/services/subscribe_url_failover.dart';

void main() {
  group('SubscribeUrlFailover', () {
    const primary =
        'https://dy.moneyfly.top/api/v1/client/subscribe?token=abc123&type=clash';
    const backup1 =
        'https://moneyfly.dpdns.org/api/v1/client/subscribe?token=abc123&type=clash';
    const backup2 =
        'https://sub.moneyfly.dpdns.org/api/v1/client/subscribe?token=abc123&type=clash';
    const otherToken =
        'https://new.moneyfly.dpdns.org/api/v1/client/subscribe?token=zzz999&type=clash';

    test('tokenOf：取出订阅 token，取不到返回空串', () {
      expect(SubscribeUrlFailover.tokenOf(primary), 'abc123');
      expect(SubscribeUrlFailover.tokenOf('https://x/y?type=clash&token=t1'), 't1');
      expect(SubscribeUrlFailover.tokenOf('https://x/y'), '');
      expect(SubscribeUrlFailover.tokenOf(''), '');
    });

    test('候选顺序：上次成功的优先 → 主地址 → 备用地址（去重）', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        backups: const [backup1, backup2, backup1],
        preferred: backup2,
      );
      expect(list, [backup2, primary, backup1]);
    });

    test('上次成功的地址若属于另一份订阅（token 不同）则忽略', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        backups: const [backup1],
        preferred: otherToken,
      );
      expect(list, [primary, backup1]);
    });

    test('备用地址 token 与主地址不一致时跳过（防止串号）', () {
      final list = SubscribeUrlFailover.candidates(
        primary: primary,
        backups: const [backup1, otherToken],
      );
      expect(list, [primary, backup1]);
    });

    test('主地址连接失败 → 自动换备用地址并回调成功地址', () async {
      final tried = <String>[];
      final ok = await SubscribeUrlFailover.fetchFirst(
        primary: primary,
        backups: const [backup1, backup2],
        fetch: (url) async {
          tried.add(url);
          if (url == primary) throw Exception('connection refused');
          if (url == backup1) throw Exception('connection timeout');
          return 'proxies: []';
        },
      );
      expect(tried, [primary, backup1, backup2], reason: '应依次尝试，直到成功');
      expect(ok.url, backup2);
      expect(ok.raw, 'proxies: []');
    });

    test('上次成功的地址会被优先尝试（不再先撞打不开的主域名）', () async {
      final tried = <String>[];
      final ok = await SubscribeUrlFailover.fetchFirst(
        primary: primary,
        backups: const [backup1, backup2],
        preferred: backup2,
        fetch: (url) async {
          tried.add(url);
          return 'proxies: []';
        },
      );
      expect(tried, [backup2]);
      expect(ok.url, backup2);
    });

    test('连上了但返回的不是订阅内容（拦截页）→ 继续换下一个地址', () async {
      final tried = <String>[];
      final ok = await SubscribeUrlFailover.fetchFirst(
        primary: primary,
        backups: const [backup1],
        fetch: (url) async {
          tried.add(url);
          return url == primary ? '<html>该网站不可访问</html>' : 'proxies:\n  - name: a';
        },
        looksUsable: (raw) => !raw.contains('<html'),
      );
      expect(tried, [primary, backup1]);
      expect(ok.url, backup1);
    });

    test('返回空内容也视为失败 → 换下一个地址', () async {
      final ok = await SubscribeUrlFailover.fetchFirst(
        primary: primary,
        backups: const [backup1],
        fetch: (url) async => url == primary ? '   \n' : 'proxies: []',
      );
      expect(ok.url, backup1);
    });

    test('全部地址失败 → 抛出最后一个异常（如实报错，不返回空订阅）', () async {
      await expectLater(
        SubscribeUrlFailover.fetchFirst(
          primary: primary,
          backups: const [backup1, backup2],
          fetch: (url) async => throw Exception('fail:$url'),
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('maxAttempts 限制尝试次数（避免用户长时间等待）', () async {
      final tried = <String>[];
      await expectLater(
        SubscribeUrlFailover.fetchFirst(
          primary: primary,
          backups: const [backup1, backup2],
          maxAttempts: 2,
          fetch: (url) async {
            tried.add(url);
            throw Exception('fail');
          },
        ),
        throwsA(isA<Exception>()),
      );
      expect(tried.length, 2);
    });
  });
}
