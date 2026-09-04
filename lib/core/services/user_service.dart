import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 用户服务：我的信息 / 仪表盘
class UserService {
  UserService._();
  static final UserService instance = UserService._();

  /// 仪表盘会话内缓存：进入「我的」页只拉一次，切 tab 不重复刷新
  DashboardInfo? _dashboardCache;

  DashboardInfo? get cachedDashboard => _dashboardCache;

  /// 拉取仪表盘（[force] 强制刷新；默认命中缓存）
  Future<DashboardInfo> dashboard({bool force = false}) async {
    if (!force && _dashboardCache != null) return _dashboardCache!;
    final data = await ApiClient.instance.get(Endpoints.dashboardInfo);
    _dashboardCache =
        DashboardInfo.fromJson(Map<String, dynamic>.from(data as Map));
    return _dashboardCache!;
  }

  /// 登出 / 换号 / 套餐变更后清缓存，下次进入重新加载
  /// （防止上一账号的仪表盘数据残留到下一账号）
  void invalidateCache() {
    _dashboardCache = null;
  }

  Future<UserInfo> me() async {
    final data = await ApiClient.instance.get(Endpoints.me);
    return UserInfo.fromJson(Map<String, dynamic>.from(data as Map));
  }
}
