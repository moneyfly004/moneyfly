import 'package:flutter_test/flutter_test.dart';
import 'package:moneyfly/core/models/models.dart';

void main() {
  group('PayMethod 解析（实测后端返回 key 字段）', () {
    test('key=alipay 识别为支付宝', () {
      final m = PayMethod.fromJson({'id': 1, 'key': 'alipay', 'name': '支付宝', 'status': 1});
      expect(m.isAlipay, isTrue);
      expect(m.name, '支付宝');
    });
    test('key=yipay_wxpay 识别为微信', () {
      final m = PayMethod.fromJson({'id': 2, 'key': 'yipay_wxpay', 'name': '易支付-微信'});
      expect(m.isWechat, isTrue);
      expect(m.isAlipay, isFalse);
    });
    test('key=usdt 识别为加密货币', () {
      final m = PayMethod.fromJson({'id': 3, 'key': 'usdt', 'name': 'USDT 加密货币'});
      expect(m.isCrypto, isTrue);
    });
    test('兼容旧 pay_type 字段', () {
      final m = PayMethod.fromJson({'id': 4, 'pay_type': 'alipay', 'name': '支付宝'});
      expect(m.isAlipay, isTrue);
    });
  });

  group('设备解析', () {
    test('remark/设备名/在线状态', () {
      final d = DeviceInfo.fromJson({
        'id': 11, 'device_name': 'iPhone', 'os_name': 'iOS', 'os_version': '18',
        'ip_address': '1.2.3.4', 'location': '广东', 'is_active': true,
        'access_count': 5, 'remark': '我的手机', 'last_seen': '2026-09-01 12:00:00',
      });
      expect(d.remark, '我的手机');
      expect(d.displayName, 'iPhone');
      expect(d.isActive, isTrue);
    });
  });

  group('订单解析', () {
    test('状态与金额', () {
      final o = OrderItem.fromJson({
        'id': 9, 'order_no': 'MF202609011234', 'amount': 49.9, 'final_amount': 44.9,
        'status': 'paid', 'package': {'name': '季付套餐'}, 'created_at': '2026-09-01 12:00:00',
      });
      expect(o.statusLabel, '已支付');
      expect(o.packageName, '季付套餐');
      expect(o.finalAmount, 44.9);
    });
    test('OrderStatus 解析', () {
      final s = OrderStatus.fromJson({'order_no': 'X', 'status': 'paid', 'amount': 19.9, 'final_amount': 19.9, 'type': 'order'});
      expect(s.isPaid, isTrue);
    });
  });

  group('优惠券折扣', () {
    test('百分比折扣', () {
      final c = Coupon.fromJson({'code': 'VIP50', 'discount_type': 'percent', 'discount_value': 50});
      expect(c.applyTo(100), closeTo(50, 0.01));
    });
    test('固定金额折扣', () {
      final c = Coupon.fromJson({'code': 'OFF10', 'discount_type': 'fixed', 'discount_value': 10});
      expect(c.applyTo(49.9), closeTo(39.9, 0.01));
    });
    test('折扣不低于 0.01', () {
      final c = Coupon.fromJson({'code': 'OFF999', 'discount_type': 'fixed', 'discount_value': 999});
      expect(c.applyTo(10), 0.01);
    });
  });

  group('仪表盘解析', () {
    test('余额字符串兼容', () {
      final d = DashboardInfo.fromJson({
        'username': 'test', 'email': 't@t.com', 'balance': '12.50',
        'online_devices': 2, 'total_devices': 3, 'subscription_status': 'active',
        'expire_time': '2026-11-30 00:00:00', 'remaining_days': 89,
      });
      expect(d.balance, 12.5);
      expect(d.hasSubscription, isTrue);
    });
  });
}
