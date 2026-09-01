import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 用户服务：我的信息 / 仪表盘
class UserService {
  UserService._();
  static final UserService instance = UserService._();

  Future<DashboardInfo> dashboard() async {
    final data = await ApiClient.instance.get(Endpoints.dashboardInfo);
    return DashboardInfo.fromJson(Map<String, dynamic>.from(data as Map));
  }

  Future<UserInfo> me() async {
    final data = await ApiClient.instance.get(Endpoints.me);
    return UserInfo.fromJson(Map<String, dynamic>.from(data as Map));
  }
}
