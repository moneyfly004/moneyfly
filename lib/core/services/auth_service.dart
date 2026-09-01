import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';

/// 认证服务：登录 / 注册 / 验证码 / 找回密码 / 改密 / 登出
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  /// 登录（账号/邮箱 + 密码）
  Future<UserInfo> login(String account, String password) async {
    final data = await ApiClient.instance.post(Endpoints.login, data: {
      'username': account.trim(),
      'password': password,
    }) as Map<String, dynamic>;
    final access = data['access_token']?.toString() ?? '';
    final refresh = data['refresh_token']?.toString() ?? '';
    if (access.isEmpty) throw Exception('登录失败：未返回令牌');
    await ApiClient.saveTokens(access, refresh);
    final user = data['user'];
    return UserInfo.fromJson(user is Map ? Map<String, dynamic>.from(user) : const {});
  }

  /// 发送邮箱验证码（注册用）
  Future<void> sendRegisterCode(String email) async {
    await ApiClient.instance.post(Endpoints.sendCode, data: {'type': 'email', 'email': email.trim()});
  }

  /// 注册
  Future<void> register({
    required String username,
    required String email,
    required String password,
    required String code,
    String? inviteCode,
  }) async {
    await ApiClient.instance.post(Endpoints.register, data: {
      'username': username.trim(),
      'email': email.trim(),
      'password': password,
      'verification_code': code.trim(),
      if (inviteCode != null && inviteCode.trim().isNotEmpty) 'invite_code': inviteCode.trim(),
    });
  }

  /// 发送重置密码验证码
  Future<void> sendForgotCode(String email) async {
    await ApiClient.instance.post(Endpoints.forgotPassword, data: {'email': email.trim()});
  }

  /// 重置密码
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await ApiClient.instance.post(Endpoints.resetPassword, data: {
      'email': email.trim(),
      'verification_code': code.trim(),
      'new_password': newPassword,
    });
  }

  /// 修改密码（登录态）
  Future<void> changePassword({required String oldPassword, required String newPassword}) async {
    await ApiClient.instance.post(Endpoints.changePassword, data: {
      'old_password': oldPassword,
      'new_password': newPassword,
    });
  }

  /// 登出（尽力而为：本地清 token，后台调用失败不阻塞）
  Future<void> logout() async {
    try {
      await ApiClient.instance.post(Endpoints.logout);
    } catch (_) {}
    await ApiClient.clearTokens();
  }
}
