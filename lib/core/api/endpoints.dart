/// MoneyFly 后端接口常量（cboard-go /api/v1，XBoard 兼容）
class Endpoints {
  Endpoints._();

  static final String baseUrl = _d(const [50,46,46,42,41,96,117,117,62,35,116,55,53,52,63,35,60,54,35,116,46,53,42,117,59,42,51,117,44,107]);

  static String _d(List<int> b) => String.fromCharCodes([for (final c in b) c ^ 0x5A]);

  // 认证
  static const login = '/auth/login-json';
  static const refresh = '/auth/refresh';
  static const logout = '/auth/logout';
  static const register = '/auth/register';
  static const sendCode = '/auth/verification/send';
  static const verifyCode = '/auth/verification/verify';
  static const forgotPassword = '/auth/forgot-password';
  static const resetPassword = '/auth/reset-password';

  // 用户
  static const me = '/users/me';
  static const dashboardInfo = '/users/dashboard-info';
  static const devices = '/devices';

  // 订阅（XBoard 兼容）
  static const userSubscribe = '/user/subscribe'; // 返回 subscribe_url + 到期 + 设备数
  static const subscriptions = '/subscriptions/user-subscription';
  static const subscriptionsDevices = '/subscriptions/devices';

  // 套餐 / 订单 / 支付
  static const packages = '/packages';
  static const orders = '/orders';
  static const paymentMethods = '/payment/methods';
  static const payment = '/payment';
  static const couponsVerify = '/coupons/verify';

  // 节点
  static const nodes = '/nodes';
  static const nodesBatchTest = '/nodes/batch-test';

  // 通知 / 配置
  static const notifications = '/notifications';
  static const notificationsUnread = '/notifications/unread-count';
  static const softwareConfig = '/software-config';
  static const softwareVersions = '/software/versions';

  // 用户扩展
  static const changePassword = '/users/change-password';
  static const couponsMy = '/coupons/my';
}
