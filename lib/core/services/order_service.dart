import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 订单服务：创建 / 支付 / 状态 / 取消 / 列表
class OrderService {
  OrderService._();
  static final OrderService instance = OrderService._();

  /// 创建订单，返回 {id, order_no, amount, ...}
  Future<Map<String, dynamic>> create({required int packageId, String? couponCode}) async {
    final data = await ApiClient.instance.post(Endpoints.orders, data: {
      'package_id': packageId,
      'coupon_code': (couponCode != null && couponCode.trim().isNotEmpty) ? couponCode.trim() : null,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  /// 发起支付，返回二维码内容等
  Future<PaymentResult> pay({required int orderId, required int paymentMethodId}) async {
    final data = await ApiClient.instance.post(Endpoints.payment, data: {
      'order_id': orderId,
      'payment_method_id': paymentMethodId,
    });
    return PaymentResult.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// 查询订单状态（后端会顺带做支付状态回查）
  Future<OrderStatus> status(String orderNo) async {
    final data = await ApiClient.instance.get('${Endpoints.orders}/$orderNo/status');
    return OrderStatus.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<void> cancel(String orderNo) async {
    await ApiClient.instance.post('${Endpoints.orders}/$orderNo/cancel');
  }

  /// 订单列表（后端支持 page/size/status 过滤）
  Future<List<OrderItem>> list({int page = 1, int size = 50, String? status}) async {
    final data = await ApiClient.instance.get(Endpoints.orders, query: {
      'page': page,
      'size': size,
      'status': ?status,
    });
    // 实测：/orders 返回分页对象 {orders:[...], page, pages, size, total}，兼容裸数组
    final list = data is List ? data : (data is Map ? data['orders'] : null);
    if (list is! List) return [];
    return list.map((e) => OrderItem.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }
}
