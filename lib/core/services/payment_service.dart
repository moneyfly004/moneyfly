import '../api/api_client.dart';
import '../api/endpoints.dart';
import 'order_service.dart';
import '../models/models.dart';

/// 支付服务：支付方式列表 + 状态轮询
class PaymentService {
  PaymentService._();
  static final PaymentService instance = PaymentService._();

  Future<List<PayMethod>> methods() async {
    final data = await ApiClient.instance.get(Endpoints.paymentMethods);
    if (data is! List) return [];
    final list = data.map((e) => PayMethod.fromJson(Map<String, dynamic>.from(e as Map))).toList();
    list.sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return list;
  }

  /// 轮询订单状态直到 paid / 超时
  /// [timeout] 默认 15 分钟，[interval] 默认 2.5 秒
  Future<OrderStatus> pollUntilPaid(
    String orderNo, {
    Duration timeout = const Duration(minutes: 15),
    Duration interval = const Duration(milliseconds: 2500),
    void Function(int seconds)? onTick,
  }) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      onTick?.call(sw.elapsed.inSeconds);
      try {
        final s = await OrderService.instance.status(orderNo);
        if (s.isPaid) return s;
        if (s.status == 'cancelled' || s.status == 'expired' || s.status == 'failed') return s;
      } catch (_) {
        // 网络抖动继续轮询
      }
      await Future.delayed(interval);
    }
    throw TimeoutException('支付超时，请稍后在订单记录中继续支付');
  }
}

class TimeoutException implements Exception {
  final String message;
  TimeoutException(this.message);
  @override
  String toString() => message;
}
