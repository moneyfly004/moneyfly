package top.moneyfly.app

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
import top.moneyfly.app.vpn.MoneyFlyVpnService
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "top.moneyfly/vpn_permissions"
        private const val CORE_CHANNEL = "top.moneyfly/vpn_core"
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
                "requestIgnoreBatteryOptimization" -> {
                    requestIgnoreBatteryOptimization()
                    result.success(true) // 必须回调，否则 Dart 侧 await 永久挂起、阻塞连接
                }
                "openBatterySettings" -> {
                    openBatterySettings()
                    result.success(true)
                }
                "getVendor" -> result.success(Build.MANUFACTURER ?: "unknown")
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "hasNotificationPermission" -> result.success(hasNotificationPermission())
                "getVpnServiceStatus" -> result.success(getVpnServiceStatus())
                else -> result.notImplemented()
            }
        }

        // 核心控制通道：启动/停止 VPN（mihomo 内核由 VpnService 托管）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CORE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> {
                        val configYaml = call.argument<String>("configYaml")
                        val needTun = call.argument<Boolean>("needTun") ?: true
                        if (configYaml.isNullOrEmpty()) {
                            result.error("no_config", "缺少配置", null)
                            return@setMethodCallHandler
                        }
                        val intent = Intent(this, MoneyFlyVpnService::class.java).apply {
                            action = MoneyFlyVpnService.ACTION_START
                            putExtra(MoneyFlyVpnService.EXTRA_CONFIG, configYaml)
                            putExtra(MoneyFlyVpnService.EXTRA_NEED_TUN, needTun)
                        }
                        try {
                            // Android 12+ 后台启动前台服务受限：若连接瞬间 App 被系统页
                            // （如电池豁免框）挤到后台，这里会抛异常 —— 必须回传真实
                            // 原因，否则 Dart 侧只能等到 15s 轮询超时（表现为「连接不生效」）
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error(
                                "start_failed",
                                "无法启动 VPN 服务：${e.message ?: e.javaClass.simpleName}",
                                null,
                            )
                        }
                    }
                    "stopVpn" -> {
                        // 用 stopService 而非 startService(ACTION_STOP)：
                        // 断连可能发生在 App 后台（看门狗判死自动清理/重连失败），
                        // Android 8+ 后台 startService 会被系统禁止抛异常；
                        // stopService 停止「已在运行的服务」不受后台限制，
                        // 会触发 onDestroy → 内核停止 + TUN 释放。
                        try {
                            stopService(Intent(this, MoneyFlyVpnService::class.java))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error(
                                "stop_failed",
                                "无法停止 VPN 服务：${e.message ?: e.javaClass.simpleName}",
                                null,
                            )
                        }
                    }
                    "isVpnRunning" -> result.success(MoneyFlyVpnService.isRunning)
                    "kernelVersion" -> result.success(MoneyFlyVpnService.kernelVersion())
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
