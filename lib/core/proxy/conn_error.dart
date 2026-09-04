/// 连接失败类型与 UI 指引（纯 Dart，无 Flutter 依赖，可单测）。
///
/// 背景：安卓端"连不上"的原因五花八门（缺 VPN 授权 / 通知被拒 / Android 12+
/// 后台启动前台服务受限 / 内核未就绪…），如果只给一串字符串，用户和客服都
/// 说不清是什么问题。把失败**类型化**后，UI 可以按类型给出不同的引导按钮
/// 与文案（如"去授权 VPN"、"允许通知"、"保持前台重试"）。
library;

enum ConnErrorKind {
  /// 无错误（正常/未连接）
  none,

  /// 未分类的普通错误（沿用通用"重试"）
  unknown,

  /// Android：VPN 授权缺失或已被撤销（VpnService.prepare 需要重新授权）
  noVpnPermission,

  /// Android 13+：通知权限被拒绝（前台服务通知被系统抑制）
  noNotificationPermission,

  /// Android 12+：后台启动前台服务受限（点连接瞬间 App 被挤到后台）
  backgroundStartBlocked,

  /// 内核启动后 Clash API 未在限定时间内就绪
  kernelTimeout,

  /// 看门狗判定内核死亡 / 内核异常退出
  kernelExited,
}

/// 携带类型的连接异常（内核/平台层上抛，ConnectionController 捕获后落位
/// [ConnectionController.error] 与 [ConnectionController.errorKind]）
class TypedConnError implements Exception {
  final ConnErrorKind kind;
  final String message;
  const TypedConnError(this.kind, this.message);

  @override
  String toString() => message;
}

/// 按失败类型给出 UI 指引（纯函数，供首页错误区渲染，便于单测）：
/// - [showGrantVpn]：显示"授权 VPN 权限"按钮（授权成功后再重连）
/// - [showGrantNotify]：显示"允许通知"按钮（允许后再重连）
/// - [showRetry]：显示普通"重试"按钮
/// - [foregroundHint]：是否提示"请保持 App 在前台后重试"
class ConnErrorUi {
  const ConnErrorUi({
    required this.showGrantVpn,
    required this.showGrantNotify,
    required this.showRetry,
    required this.foregroundHint,
  });

  final bool showGrantVpn;
  final bool showGrantNotify;
  final bool showRetry;
  final bool foregroundHint;
}

ConnErrorUi guideForConnError(ConnErrorKind kind) => switch (kind) {
      // 无错误态：不显示任何引导按钮
      ConnErrorKind.none => const ConnErrorUi(
          showGrantVpn: false, showGrantNotify: false, showRetry: false, foregroundHint: false),
      ConnErrorKind.noVpnPermission => const ConnErrorUi(
          showGrantVpn: true, showGrantNotify: false, showRetry: false, foregroundHint: false),
      ConnErrorKind.noNotificationPermission => const ConnErrorUi(
          showGrantVpn: false, showGrantNotify: true, showRetry: false, foregroundHint: false),
      ConnErrorKind.backgroundStartBlocked => const ConnErrorUi(
          showGrantVpn: false, showGrantNotify: false, showRetry: true, foregroundHint: true),
      _ => const ConnErrorUi(
          showGrantVpn: false, showGrantNotify: false, showRetry: true, foregroundHint: false),
    };
