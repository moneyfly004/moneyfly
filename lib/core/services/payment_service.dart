import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 支付服务：支付方式列表（订单状态轮询由 PaymentQrDialog 统一处理，避免双份逻辑漂移）
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
}
