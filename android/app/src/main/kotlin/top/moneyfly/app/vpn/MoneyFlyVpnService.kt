package top.moneyfly.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import org.json.JSONObject
import top.moneyfly.app.MainActivity
import top.moneyfly.app.R
import java.io.File

/**
 * MoneyFly VPN 前台服务：系统级 VPN 通道 + 内置 sing-box 内核
 * 连接：解压二进制 → establish() 建 TUN → 注入 tun.fd → 跑 sing-box；
 * 断开：destroy 进程 + 关 fd + 移除 tunfd。
 */
class MoneyFlyVpnService : VpnService() {
    companion object {
        const val ACTION_START = "top.moneyfly.vpn.START"
        const val ACTION_STOP = "top.moneyfly.vpn.STOP"
        const val EXTRA_CONFIG = "config_json"
        const val CHANNEL_ID = "moneyfly_vpn_channel"
        private const val NOTIFY_ID = 1001

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var process: Process? = null
    private var fd: ParcelFileDescriptor? = null
    private val fdFile: File get() = File(filesDir, "tunfd")

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopCore()
                stopSelf()
                return START_NOT_STICKY
            }
        }
        startForeground(NOTIFY_ID, buildNotification())
        val configJson = intent?.getStringExtra(EXTRA_CONFIG)
        if (configJson != null && process == null) {
            startCore(configJson)
        }
        return START_STICKY
    }

    private fun startCore(configJson: String) {
        Thread {
            try {
                val binary = extractBinary()
                val pfd = establishTun() ?: throw IllegalStateException("建立 TUN 失败")
                fd = pfd
                fdFile.writeText(pfd.fd.toString())

                val cfg = JSONObject(configJson)
                val inbounds = cfg.optJSONArray("inbounds")
                if (inbounds != null) {
                    for (i in 0 until inbounds.length()) {
                        val ib = inbounds.getJSONObject(i)
                        if (ib.optString("type") == "tun") {
                            ib.put("fd", fdFile.absolutePath)
                            ib.put("auto_route", false)
                            ib.put("strict_route", false)
                        }
                    }
                }
                // 内置规则集落盘，并把远程 rule_set 替换为本地路径（国内直连 GitHub 被墙）
                extractRuleAssets()
                val route = cfg.optJSONObject("route")
                val ruleSets = route?.optJSONArray("rule_set")
                if (ruleSets != null) {
                    for (i in 0 until ruleSets.length()) {
                        val rs = ruleSets.getJSONObject(i)
                        val tag = rs.optString("tag")
                        if (rs.has("url") && tag.isNotEmpty()) {
                            rs.put("type", "local")
                            rs.put("format", "binary")
                            rs.put("path", File(filesDir, "$tag.srs").absolutePath)
                            rs.remove("url")
                            rs.remove("download_detour")
                        }
                    }
                }
                val cfgFile = File(filesDir, "config.json")
                cfgFile.writeText(cfg.toString())

                process = ProcessBuilder(binary, "run", "-c", cfgFile.absolutePath, "--disable-color")
                    .directory(filesDir)
                    .redirectErrorStream(true)
                    .start()
                isRunning = true

                val code = process!!.waitFor()
                isRunning = false
                process = null
            } catch (e: Exception) {
                isRunning = false
                process = null
            }
        }.start()
    }

    private fun stopCore() {
        try { process?.destroy() } catch (_: Exception) {}
        process = null
        isRunning = false
        try { fd?.close() } catch (_: Exception) {}
        fd = null
        fdFile.delete()
    }

    /** 从 assets 解压内置 geoip/geosite 规则集到 filesDir（幂等） */
    private fun extractRuleAssets() {
        for (name in listOf("geoip-cn.srs", "geosite-cn.srs")) {
            val target = File(filesDir, name)
            if (target.exists() && target.length() > 0L) continue
            try {
                assets.open("flutter_assets/assets/rules/$name").use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (_: Exception) {
                // 资产缺失时保留远程 url（builder 回退远程），不阻塞
            }
        }
    }

    private fun extractBinary(): String {
        val out = File(filesDir, "sing-box")
        if (!out.exists() || out.length() == 0L) {
            // 内核通过 jniLibs 按 ABI 打包（split-per-abi 时每个 APK 只含自己的二进制）
            val src = File(applicationInfo.nativeLibraryDir, "libsingbox.so")
            if (!src.exists()) throw IllegalStateException("未找到内置内核 libsingbox.so")
            src.copyTo(out, overwrite = true)
            out.setExecutable(true, false)
        }
        return out.absolutePath
    }

    private fun establishTun(): ParcelFileDescriptor? {
        return try {
            val builder = Builder()
                .setSession("MoneyFly 安全连接")
                .setConfigureIntent(PendingIntent.getActivity(
                    this, 0, Intent(this, MainActivity::class.java),
                    PendingIntent.FLAG_IMMUTABLE))
                .addAddress("10.8.0.2", 32)
                .addRoute("0.0.0.0", 0)
                .addDnsServer("223.5.5.5")
                .addDnsServer("1.1.1.1")
                .setMtu(1500)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                builder.setBlocking(true)
            }
            builder.establish()
        } catch (_: Exception) {
            null
        }
    }

    private fun buildNotification(): Notification {
        createChannel()
        val intent = Intent(this, MainActivity::class.java)
        val pi = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("MoneyFly 正在保护您的连接")
            .setContentText("已开启安全加速，点击查看详情")
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "MoneyFly VPN", NotificationManager.IMPORTANCE_LOW)
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        stopCore()
        super.onDestroy()
    }
}
