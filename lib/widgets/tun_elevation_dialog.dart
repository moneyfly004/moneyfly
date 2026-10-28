import 'dart:io';

import 'package:flutter/material.dart';

import '../core/platform/elevation.dart';
import '../core/services/settings_store.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// 「TUN 需要管理员权限」对话框（首页三态开关与设置页「强制 TUN」共用）。
///
/// 为什么必须有这一步：Windows 上非管理员开 TUN，内核只会打一行
/// `configure tun interface: Access is denied.` 然后退出，用户看到的报错
/// 与真实原因无关（甚至会被误导去查 CPU/杀毒）。与其让用户先失败再猜，
/// 不如在选择 TUN 的那一刻就把「要不要以管理员身份重启」问清楚。
///
/// 返回值：
///  - true  = 已安排 UAC 重启（调用方应延迟片刻后 `exit(0)`，让新实例接管）；
///  - false = 用户取消，或当前平台无法自动提权（macOS）。
Future<bool> requestTunElevation(BuildContext context) async {
  if (Elevation.isElevated) return true;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      backgroundColor: MFColors.card2,
      title: Text(AppStrings.t('tun_admin_title'),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      content: Text(
        Platform.isMacOS
            ? AppStrings.t('tun_admin_body_mac')
            : AppStrings.t('tun_admin_body_win'),
        style: TextStyle(fontSize: 12.5, color: MFColors.txt2, height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(AppStrings.t('tun_admin_cancel'),
              style: TextStyle(color: MFColors.txt2, fontSize: 12.5)),
        ),
        // 只有 Windows 能自动提权（UAC runas）。macOS 的自动提权需要装特权
        // 助手，当前版本没做 —— 不给按钮，避免点了没反应。
        if (Platform.isWindows)
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppStrings.t('tun_admin_relaunch'),
                style: const TextStyle(fontSize: 12.5)),
          ),
      ],
    ),
  );
  if (confirmed != true) return false;
  final ok = await Elevation.relaunchElevated();
  if (!ok) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.t('tun_admin_fail'))),
      );
    }
    return false;
  }
  // 重启后要「接着把用户想做的事做完」：把 TUN 写进设置，并留一个一次性标记，
  // 让新实例启动拿到线路后自动发起连接（否则用户还得再点一次连接。
  // Clash Party 的 --admin-restart-for-tun 就是干这件事的）。
  try {
    await SettingsStore.instance.update((s) {
      s['tunMode'] = 'force';
      s['pendingTunConnect'] = true;
    });
  } catch (_) {}
  return true;
}
