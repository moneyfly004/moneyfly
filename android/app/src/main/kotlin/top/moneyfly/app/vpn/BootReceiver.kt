package top.moneyfly.app.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/**
 * 开机自启：用户开启「启动时自动连接」后，开机时拉起 VPN 服务
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == "android.intent.action.QUICKBOOT_POWERON") {
            if (!readAutoConnect(context)) return
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

    /**
     * 读取 Flutter 端设置（FlutterSharedPreferences → flutter.moneyfly_settings_v1 JSON）
     * 与 SettingsStore._defaults 对齐：解析失败按默认值 true 处理
     */
    private fun readAutoConnect(context: Context): Boolean {
        return try {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val raw = prefs.getString("flutter.moneyfly_settings_v1", null) ?: return true
            JSONObject(raw).optBoolean("autoConnect", true)
        } catch (_: Exception) {
            true
        }
    }
}
