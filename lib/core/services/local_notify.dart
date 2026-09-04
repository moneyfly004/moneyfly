import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../l10n/app_strings.dart';

/// 本地通知服务（到期提醒 / 连接异常）
class LocalNotify {
  LocalNotify._();
  static final LocalNotify instance = LocalNotify._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    try {
      const android = AndroidInitializationSettings('@drawable/ic_stat_vpn');
      const darwin = DarwinInitializationSettings();
      await _plugin.initialize(const InitializationSettings(
        android: android, macOS: darwin, iOS: darwin,
      ));
      _initialized = true;
    } catch (_) {
      // 测试环境或平台插件不可用时静默跳过
    }
  }

  Future<void> showExpiryWarning(int remainingDays) async {
    if (!_initialized) return;
    final title = AppStrings.t('expiry_notify_title');
    final body = AppStrings.t('expiry_notify_body', {'days': '$remainingDays'});
    await _plugin.show(
      2001,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'moneyfly_expiry', 'Subscription Expiry',
          importance: Importance.high, priority: Priority.high,
        ),
        macOS: const DarwinNotificationDetails(),
      ),
    );
  }

  Future<void> showReconnectFailed() async {
    if (!_initialized) return;
    await _plugin.show(
      2002,
      AppStrings.t('reconnect_fail_notify_title'),
      AppStrings.t('reconnect_fail_notify_body'),
      NotificationDetails(
        android: AndroidNotificationDetails(
          'moneyfly_conn', 'Connection Status',
          importance: Importance.defaultImportance,
        ),
        macOS: const DarwinNotificationDetails(),
      ),
    );
  }
}
