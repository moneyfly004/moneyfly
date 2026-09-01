/// MoneyFly 后端接口常量（cboard-go /api/v1，XBoard 兼容）
class Endpoints {
  Endpoints._();

  /// 生产环境后端（可在开发时改为本地调试地址）
  static const String baseUrl = 'https://dy.moneyfly.top/api/v1';

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

  // 用户扩展
  static const changePassword = '/users/change-password';
  static const couponsMy = '/coupons/my';
}
