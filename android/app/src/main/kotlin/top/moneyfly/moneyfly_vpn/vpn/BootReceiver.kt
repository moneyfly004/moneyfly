package top.moneyfly.moneyfly_vpn.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机自启：用户开启「启动时自动连接」后，开机时拉起 VPN 服务
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            // 读取用户设置（与 Flutter 端 shared_preferences 对齐：moneyfly_settings_v1 JSON）
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val raw = prefs.getString("flutter.moneyfly_settings_v1", null)
            val autoConnect = raw?.contains("\"autoConnect\":true") ?: true
            if (autoConnect) {
                val service = Intent(context, MoneyFlyVpnService::class.java).apply {
                    action = MoneyFlyVpnService.ACTION_START
                }
                try {
                    context.startForegroundService(service)
                } catch (_: Exception) {
                    context.startService(service)
                }
            }
        }
    }
}
