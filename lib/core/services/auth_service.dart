import '../api/api_client.dart';
import '../api/endpoints.dart';
import '../models/models.dart';
import '../proxy/proxy_core.dart';
import '../../theme/theme_controller.dart';
import 'account_service.dart';
import 'app_data_cleaner.dart';
import 'crash_logger.dart';
import 'subscription_scheduler.dart';
import 'subscription_service.dart';
import 'user_service.dart';

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

  /// 登出 = 出厂级本地重置（尽力而为：后台调用失败不阻塞）。
  ///
  /// 客户退出账号后必须**删除原来的配置文件**，保证下次（换号/重登）从零
  /// 拉取订阅，看不到上一个账号的任何残留：
  /// 1. 断开内核并删除磁盘上的节点/内核配置、规则集、订阅缓存、日志、
  ///    token 与全部偏好（AppDataCleaner，保留 install_id —— 它只随卸载消失）；
  /// 2. 清空内存残留：账号状态判定、订阅节点缓存、仪表盘缓存、连接器状态；
  /// 3. 停掉「定时更新订阅」调度器；主题回系统默认、崩溃日志开关复位。
  Future<void> logout() async {
    try {
      // _noSessionExpired：logout 自身 401 不触发会话过期回调，
      // 避免「401→refresh失败→logout→401」无限递归循环
      await ApiClient.instance
          .post(Endpoints.logout, extra: {'_noSessionExpired': true});
    } catch (_) {}
    // 先停内核再删文件：Windows 上运行中的内核会锁住 config.json/规则集
    try {
      await ConnectionController.instance.resetForLogout();
    } catch (_) {}
    AccountService.instance.reset();
    SubscriptionService.instance.clearCache();
    UserService.instance.invalidateCache();
    SubscriptionScheduler.instance.stop();
    // 磁盘出厂清理（token/偏好/订阅缓存/内核目录/日志），保留 install_id
    await AppDataCleaner.wipeForLogout();
    // 内存态收尾：主题回系统默认（偏好已在上面清空，下次启动即出厂）；
    // 语言保持当前会话不变（持久化偏好已清，下次启动跟随设备语言）
    ThemeController.instance.setTheme('system');
    CrashLogger.setEnabled(false);
  }
}
