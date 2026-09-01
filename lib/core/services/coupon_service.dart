import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 优惠券服务
class CouponService {
  CouponService._();
  static final CouponService instance = CouponService._();

  /// 校验优惠码（返回折后金额与折扣信息）
  Future<Map<String, dynamic>> verify({
    required String code,
    required double amount,
    int? packageId,
  }) async {
    final data = await ApiClient.instance.post(Endpoints.couponsVerify, data: {
      'code': code.trim(),
      'amount': amount,
      'package_id': ?packageId,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  /// 我的优惠券
  Future<List<Coupon>> my() async {
    final data = await ApiClient.instance.get(Endpoints.couponsMy);
    if (data is! List) return [];
    return data.map((e) => Coupon.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }
}
