// 「更新订阅拿不到节点」的原因分类与健壮性回归。
//
// 真实工单（2026-09-21）：套餐到期 → 用户在设备管理里删光了设备 → 续费一年 →
// 打开软件更新订阅没有节点。当时客户端对这条链路是**全静默**的：到期、未开通、
// 订阅被停用、后端没给订阅地址、后端返回故障页……全都只返回空列表，用户只看到
// 一句「订阅中没有可用节点」，既不知道原因，也不知道下一步做什么。
//
// 这里锁定三件事：
//   1) 原因分类正确（决定 UI 给哪个出口：续费 / 设备管理 / 重新登录 / 重试）；
//   2) 「不是订阅内容」的正文不会清空用户已有线路（后端故障页不该毁掉节点）；
//   3) 设备列表能认出「本机」（删本机 = 把自己踢下线，必须能提示）。
import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';
import 'package:moneyfly/core/services/subscription_service.dart';
import 'package:moneyfly/pages/devices/devices_page.dart';

SubscriptionInfo _info({
  String url = 'https://sub.example.com/link?token=abc',
  bool expired = false,
  bool active = true,
  String status = 'active',
  int deviceLimit = 3,
  int devices = 1,
  int remainingDays = 365,
  DateTime? expireTime,
}) =>
    SubscriptionInfo(
      subscribeUrl: url,
      expireTime: expireTime ?? DateTime.now().add(Duration(days: remainingDays)),
      deviceLimit: deviceLimit,
      currentDevices: devices,
      remainingDays: remainingDays,
      isExpired: expired,
      status: status,
      isActive: active,
    );

void main() {
  group('classifyFromInfo：订阅信息 → 原因', () {
    test('正常订阅没有原因', () {
      expect(SubscriptionService.classifyFromInfo(_info()), isNull);
    });

    test('到期 → expired（UI 给「去续费」）', () {
      expect(SubscriptionService.classifyFromInfo(_info(expired: true)),
          SubscribeIssue.expired);
    });

    test('订阅被停用 → subscriptionDisabled（优先级高于到期）', () {
      expect(
          SubscriptionService.classifyFromInfo(
              _info(active: false, expired: true)),
          SubscribeIssue.subscriptionDisabled);
    });

    test('status 非 active 也判为停用（大小写不敏感）', () {
      expect(SubscriptionService.classifyFromInfo(_info(status: 'Active')),
          isNull);
      expect(SubscriptionService.classifyFromInfo(_info(status: 'suspended')),
          SubscribeIssue.subscriptionDisabled);
    });

    test('设备数达上限 → deviceFull（UI 给「设备管理」）', () {
      expect(
          SubscriptionService.classifyFromInfo(
              _info(deviceLimit: 3, devices: 3)),
          SubscribeIssue.deviceFull);
    });

    test('有套餐但没下发订阅地址 → noSubscribeUrl（异常，给「重新登录」）', () {
      expect(SubscriptionService.classifyFromInfo(_info(url: '')),
          SubscribeIssue.noSubscribeUrl);
    });

    test('真没套餐（无到期时间/剩余天数）→ noSubscription（给「去开通」）', () {
      final s = SubscriptionInfo(
        subscribeUrl: '',
        deviceLimit: 0,
        currentDevices: 0,
        remainingDays: 0,
        isExpired: false,
        status: 'active',
      );
      expect(SubscriptionService.classifyFromInfo(s),
          SubscribeIssue.noSubscription);
    });
  });

  group('classifyFromError：错误文案 → 原因', () {
    test('设备被移除/踢下线 → deviceKicked（唯一恢复路径是重新登录）', () {
      for (final msg in const [
        '此设备已被移除并踢下线，请重新登录',
        'Device has been removed',
        'you have been kicked',
      ]) {
        expect(SubscriptionService.classifyFromError(msg),
            SubscribeIssue.deviceKicked,
            reason: msg);
      }
    });

    test('账号被禁用 → accountDisabled', () {
      expect(SubscriptionService.classifyFromError('账户已被禁用，无法使用服务'),
          SubscribeIssue.accountDisabled);
    });

    test('设备数量已达上限 → deviceFull', () {
      expect(SubscriptionService.classifyFromError('设备数量已达上限（3/3）'),
          SubscribeIssue.deviceFull);
      expect(SubscriptionService.classifyFromError('device limit reached'),
          SubscribeIssue.deviceFull);
    });

    test('其余（超时/网络/5xx）→ network（可重试）', () {
      for (final msg in const ['连接超时', 'SocketException: failed host lookup',
        'Internal Server Error']) {
        expect(SubscriptionService.classifyFromError(msg),
            SubscribeIssue.network, reason: msg);
      }
    });
  });

  group('looksLikeSubscription：区分「订阅」与「后端故障页」', () {
    test('常见订阅形态都认得', () {
      // base64 订阅（内含节点链接）
      const b64 =
          'c3M6Ly9ZV1Z6TFRJMU5pMW5ZMjA2TVRJeU16UTFOamM0T1E9PUAxLjIuMy40OjgzODg=';
      expect(SubscriptionService.looksLikeSubscription(b64), isTrue);
      // Clash YAML
      expect(
          SubscriptionService.looksLikeSubscription(
              'mixed-port: 7890\nproxies:\n  - {name: a}'),
          isTrue);
      // 明文节点链接
      expect(SubscriptionService.looksLikeSubscription('vmess://eyJhIjoxfQ=='),
          isTrue);
      // JSON
      expect(SubscriptionService.looksLikeSubscription('{"data":[]}'), isTrue);
    });

    test('HTML / 故障页 / 跳登录一律不认（不能被它清空线路）', () {
      for (final raw in const [
        '<!DOCTYPE html><html><body>502 Bad Gateway</body></html>',
        '<html><head><title>Sign in</title></head></html>',
        'Service Temporarily Unavailable',
      ]) {
        expect(SubscriptionService.looksLikeSubscription(raw), isFalse,
            reason: raw);
      }
    });

    test('空正文不算「异常内容」（空订阅单独处理）', () {
      expect(SubscriptionService.looksLikeSubscription(''), isFalse);
      expect(SubscriptionService.looksLikeSubscription('   \n  '), isFalse);
    });
  });

  group('设备列表认出「本机」', () {
    DeviceInfo dev({required String model, required String brand}) => DeviceInfo(
          id: 1,
          deviceName: 'iPhone',
          deviceType: 'mobile',
          deviceModel: model,
          deviceBrand: brand,
          ipAddress: '',
          location: '',
          osName: 'iOS',
          osVersion: '16.6.1',
          softwareName: 'MoneyFly',
          softwareVersion: '2.2.15',
          isActive: true,
          isAllowed: true,
          lastSeen: '',
          lastAccess: '',
          firstSeen: '',
          accessCount: 0,
          remark: '',
        );

    const headers = {
      'X-MF-Device-Model': 'iPhone14,3',
      'X-MF-Device-Brand': 'Apple',
    };

    test('机型一致 → 是本机', () {
      expect(isCurrentDeviceEntry(dev(model: 'iPhone14,3', brand: 'Apple'),
          headers), isTrue);
    });

    test('其它设备 → 不是本机', () {
      expect(isCurrentDeviceEntry(dev(model: 'Windows PC', brand: 'PC'),
          headers), isFalse);
    });

    test('没有设备头（拿不到本机信息）→ 不误判', () {
      expect(isCurrentDeviceEntry(dev(model: 'iPhone14,3', brand: 'Apple'), {}),
          isFalse);
    });
  });
}
