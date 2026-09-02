import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';
import '../proxy/proxy_core.dart';
import 'account_service.dart';
import 'settings_store.dart';
import 'subscription_service.dart';

/// 认证服务：登录 / 注册 / 验证码 / 找回密码 / 改密 / 登出
class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  /// 登录（账号/邮箱 + 密码）
  ///
  /// 登录成功后立刻拉取一次订阅信息并判定账号状态（到期 / 设备满 / 禁用 /
  /// 未开通），让主页在展示前就已知道真实状态——而不是等首页异步拉订阅后才
  /// 判断。该判定失败不阻塞登录（网络抖动时由首页横幅/连接门禁兜底）。
  Future<UserInfo> login(String account, String password) async {
    final data = await ApiClient.instance.post(Endpoints.login, data: {
      'username': account.trim(),
      'password': password,
    }) as Map<String, dynamic>;
    final access = data['access_token']?.toString() ?? '';
    final refresh = data['refresh_token']?.toString() ?? '';
    if (access.isEmpty) throw Exception('登录失败：未返回令牌');
    await ApiClient.saveTokens(access, refresh);
    // 立即判定到期/超限/禁用（禁止账号后端在登录接口即拦截，不会走到这里）
    try {
      await AccountService.instance.refresh(force: true);
    } catch (_) {}
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
  /// 后端字段为 current_password + new_password（曾误用 old_password 导致永远失败）
  Future<void> changePassword({required String oldPassword, required String newPassword}) async {
    await ApiClient.instance.post(Endpoints.changePassword, data: {
      'current_password': oldPassword,
      'new_password': newPassword,
    });
  }

  /// 登出（尽力而为：本地清 token，后台调用失败不阻塞）
  ///
  /// 同时清空本账号残留：账号状态判定、订阅节点缓存、连接器状态与内核，
  /// 否则下一账号登录后会看到上一个账号的节点/到期状态（切号误判）。
  Future<void> logout() async {
    try {
      // _noSessionExpired：logout 自身 401 不触发会话过期回调，
      // 避免「401→refresh失败→logout→401」无限递归循环
      await ApiClient.instance
          .post(Endpoints.logout, extra: {'_noSessionExpired': true});
    } catch (_) {}
    await ApiClient.clearTokens();
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
    try {
      await ConnectionController.instance.resetForLogout();
    } catch (_) {}
    // 登出后重置 autoConnect，防止下次登录自动连接
    try {
      final s = await SettingsStore.instance.load();
      s['autoConnect'] = false;
      await SettingsStore.instance.save(s);
    } catch (_) {}
  }
}
