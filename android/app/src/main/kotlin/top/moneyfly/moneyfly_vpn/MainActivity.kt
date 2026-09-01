package top.moneyfly.moneyfly_vpn

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "top.moneyfly/vpn_permissions"
        private const val REQ_VPN = 1001
        private const val REQ_NOTIFY = 1002
        private const val REQ_BATTERY = 1003
    }

    private var pendingVpnResult: MethodChannel.Result? = null
    private var pendingNotifyResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "prepareVpn" -> prepareVpn(result)
                "isVpnPrepared" -> result.success(VpnService.prepare(this) == null)
                "isBatteryOptimizationIgnored" -> result.success(isBatteryOptimizationIgnored())
                "requestIgnoreBatteryOptimization" -> requestIgnoreBatteryOptimization()
                "openBatterySettings" -> openBatterySettings()
                "getVendor" -> result.success(Build.MANUFACTURER ?: "unknown")
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "hasNotificationPermission" -> result.success(hasNotificationPermission())
                "getVpnServiceStatus" -> result.success(getVpnServiceStatus())
                else -> result.notImplemented()
            }
        }
    }

    // ---------- VPN ----------
    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        pendingVpnResult = result
        startActivityForResult(intent, REQ_VPN)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQ_VPN -> {
                pendingVpnResult?.success(resultCode == RESULT_OK)
                pendingVpnResult = null
            }
            REQ_BATTERY -> Unit
        }
    }

    // ---------- 电池优化豁免（省电 + 防杀后台） ----------
    private fun isBatteryOptimizationIgnored(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimization() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !isBatteryOptimizationIgnored()) {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = android.net.Uri.parse("package:$packageName")
            }
            startActivityForResult(intent, REQ_BATTERY)
        }
    }

    private fun openBatterySettings() {
        try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        } catch (_: Exception) {
            startActivity(Intent(Settings.ACTION_SETTINGS))
        }
    }

    // ---------- 通知权限（Android 13+） ----------
    private fun hasNotificationPermission(): Boolean {
        return Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (hasNotificationPermission()) {
            result.success(true)
            return
        }
        pendingNotifyResult = result
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQ_NOTIFY)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFY) {
            pendingNotifyResult?.success(grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED)
            pendingNotifyResult = null
        }
    }

    private fun getVpnServiceStatus(): String {
        return if (VpnService.prepare(this) == null) "prepared" else "not_prepared"
    }
}
