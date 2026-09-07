package top.moneyfly.app.vpn

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import org.json.JSONObject
import top.moneyfly.app.MainActivity
import top.moneyfly.app.R
import top.moneyfly.mihomelib.Mihomelib
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

/**
 * MoneyFly 的 Android VPN 服务：VpnService + libmihomo（官方 MetaCubeX/mihomo
 * v1.19.30 经 gomobile bind 的进程内库，CI 编译自官方源码，无 fork）。
 *
 * 架构与桌面端对齐：
 *  - Flutter 侧生成 mihomo Clash YAML，经 MethodChannel 传给本服务；
 *  - 非 root 全局代理的关键：本服务用 VpnService.establish() 建立 TUN 拿到 fd，
 *    把 fd 注入内核（tun.file-descriptor），mihomo 直接用该 fd 收发包；
 *  - 地址/路由/DNS 由 VpnService 全量下发（172.19.0.1/30 + 0.0.0.0/0），
 *    内核配置里 auto-route=false，避免非 root 改路由表；
 *  - 内核自带 Clash API（external-controller 127.0.0.1:9090），Flutter 侧用它
 *    做模式/节点热切换、实时流量统计 —— 与桌面端完全同一套 Dart 代码。
 */
@Suppress("UNUSED_PARAMETER")
class MoneyFlyVpnService : VpnService() {
    companion object {
        private const val TAG = "MoneyFlyVpnService"

        const val ACTION_START = "top.moneyfly.vpn.START"
        const val ACTION_STOP = "top.moneyfly.vpn.STOP"
        const val EXTRA_CONFIG = "config_yaml"
        const val EXTRA_NEED_TUN = "need_tun"
        const val CHANNEL_ID = "moneyfly_vpn_channel"
        private const val NOTIFY_ID = 1001

        /** TUN 网段（与 mihomo 配置的 fake-ip/dns 逻辑配套，参考 Clash Meta for Android） */
        private const val TUN_GATEWAY = "172.19.0.1"
        private const val TUN_PREFIX = 30
        /** 虚拟 DNS：系统 DNS 查询发往它 → 进入 TUN → 内核 dns-hijack 接管（fake-ip） */
        private const val TUN_DNS = "172.19.0.2"

        @Volatile
        var isRunning: Boolean = false
            private set

        /** 最近一次内核启动失败的原因（Dart 侧超时后读取，用于精确定位） */
        @Volatile
        var lastStartError: String? = null
            private set

        /** 内置内核版本（任何时候可读，用于设置页「内核管理」） */
        fun kernelVersion(): String =
            try {
                Mihomelib.version() ?: ""
            } catch (e: Exception) {
                Log.w(TAG, "kernelVersion: ${e.message}")
                ""
            }

        /** 自上次调用以来的内核日志增量（「内核日志」实时页轮询） */
        fun fetchKernelLogs(): String =
            try {
                Mihomelib.logs() ?: ""
            } catch (e: Exception) {
                Log.w(TAG, "fetchKernelLogs: ${e.message}")
                ""
            }
    }

    /** TUN fd：establish 后 detach 交给内核，所有权归内核（Stop 时内核自关）。
     *  Kotlin 侧绝不再 close —— Android fdsan 检测 double-close 会直接崩溃。 */
    private var tunFd: Int = 0

    /** 内核启动/停止串行化（gomobile 调用需避免并发；Start 内部有锁，这里防重入） */
    private val coreExecutor = Executors.newSingleThreadExecutor()

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val configYaml = intent?.getStringExtra(EXTRA_CONFIG)
        when (intent?.action) {
            ACTION_STOP -> {
                coreExecutor.execute {
                    stopBox()
                    stopForegroundCompat()
                    stopSelf()
                }
                return START_NOT_STICKY
            }
            // 无配置的启动来源：BootReceiver（开机自启）/ 系统因 START_STICKY
            // 重启 service。此时没有内核配置，绝不能常驻空转 —— 否则出现
            // 「前台通知挂着但内核没跑」（幽灵连接）。前台服务先 startForeground
            // 满足系统约束（Android 12+ 5s 限制），随后延迟自停；若期间 Dart
            // 侧自动连接发来带配置的 START，则被新任务替代。
            ACTION_START -> {
                if (configYaml == null) {
                    startForeground(NOTIFY_ID, buildNotification())
                    coreExecutor.execute {
                        try {
                            Thread.sleep(1500)
                        } catch (_: InterruptedException) {}
                        if (!Mihomelib.running() && !isRunning) {
                            stopForegroundCompat()
                            stopSelf()
                        }
                    }
                    return START_NOT_STICKY
                }
            }
        }
        // START_STICKY 重启（intent == null）：无配置可恢复，直接结束
        if (intent == null) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIFY_ID, buildNotification())
        // 走到这里必须带配置（when 里已处理无配置的 START）；防御性兜底
        val cfg = configYaml
        if (cfg == null) {
            stopForegroundCompat()
            stopSelf()
            return START_NOT_STICKY
        }
        val needTun = intent?.getBooleanExtra(EXTRA_NEED_TUN, true) ?: true
        coreExecutor.execute {
            try {
                startBox(cfg, needTun)
            } catch (e: Exception) {
                Log.e(TAG, "startBox failed", e)
                isRunning = false
                stopForegroundCompat()
                stopSelf()
            }
        }
        return START_STICKY
    }
    @Synchronized
    private fun startBox(configYaml: String, needTun: Boolean) {
        // 竞态处理：Dart 断开后立刻重连时，旧内核可能还在停止中
        // （running=true 但用户已发起新连接）。此时不能「忽略」——
        // 否则旧内核随后停掉，新连接轮询超时。语义：收到新的启动请求
        // 且内核还在跑 → 先停旧内核再按新配置启动（重启）。
        if (Mihomelib.running()) {
            Log.d(TAG, "收到新启动请求，先停止旧内核再重启")
            try {
                Mihomelib.stop() // 内核 stop 时自行关闭其持有的 TUN fd
            } catch (e: Exception) {
                Log.w(TAG, "stop old kernel: ${e.message}")
            }
            tunFd = 0
        }
        try {
            // 1) 内核工作目录（config.yaml 由 mihomo 内部管理；geo 数据落这里）
            val workDir = File(filesDir, "work")
            workDir.mkdirs()

            // 2) 离线分流数据从 Flutter assets 同步（幂等：已存在且非空则跳过）。
            //    缺文件时内核仍能启动（智能规则降级在 Dart 侧处理），仅警告。
            syncGeoAssets(workDir)

            // 3) 需要全局代理时建立 TUN；fd detach 后注入内核（tun.file-descriptor）。
            //    detach 后 fd 所有权归内核，Kotlin 不再 close（避免 fdsan double-close）。
            var fd = 0
            if (needTun) {
                val pfd = establishTun()
                fd = pfd.detachFd()
                tunFd = fd
            }

            // 4) 启动内核（阻塞直到配置解析完成/失败；listener 异步运行）
            Mihomelib.start(
                workDir.absolutePath,
                configYaml.toByteArray(Charsets.UTF_8),
                fd,
            )
            isRunning = true
            lastStartError = null
            Log.i(TAG, "libmihomo started (tunFd=$fd, version=${Mihomelib.version()})")
        } catch (e: Exception) {
            // 记录真实原因（供 Dart 读取展示），再上抛。
            // fd 不在此 close：detach 后若内核未接管，由 wrapper 在失败路径兜底关闭；
            // 若内核已接管，其 Shutdown 会自关 —— 这里 close 任何一次都可能 double-close。
            lastStartError = e.message ?: e.javaClass.simpleName
            Log.e(TAG, "startBox failed: $lastStartError")
            tunFd = 0
            isRunning = false
            throw e
        }
    }

    @Synchronized
    private fun stopBox() {
        isRunning = false
        try {
            Mihomelib.stop() // 内核 Shutdown 自行关闭 TUN fd
        } catch (e: Exception) {
            Log.d(TAG, "stop: ${e.message}")
        }
        tunFd = 0
    }

    /** 建立 TUN：地址 172.19.0.1/30 + 全量路由 + 虚拟 DNS 172.19.0.2。
     *  按 Flutter 侧「按 App 分流/排除」设置决定哪些应用进入 TUN：
     *   - all（默认）：仅本应用自身不走 VPN（控制通道直连）
     *   - selected（仅以下应用走代理）：allowed = 勾选 + 本应用
     *   - denied（排除以下应用）：disallowed = 勾选（不含本应用，本应用始终直连） */
    @SuppressLint("MissingPermission")
    private fun establishTun(): ParcelFileDescriptor {
        if (prepare(this) != null) {
            throw IllegalStateException("android: missing vpn permission")
        }
        val builder =
            Builder()
                .setSession("MoneyFly")
                .setConfigureIntent(
                    PendingIntent.getActivity(
                        this, 0, Intent(this, MainActivity::class.java),
                        PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
                .setMtu(1500)
                .addAddress(TUN_GATEWAY, TUN_PREFIX)
                // 全量路由：除应用自身外的所有流量进入 TUN（App 控制通道保持直连）
                .addRoute("0.0.0.0", 0)
                // IPv6 全量路由:避免 v4 全接管而 v6 走系统直连造成的地址族泄漏
                .addRoute("::", 0)
                // 虚拟 DNS：Android 的 DNS 查询发给它 → 进 TUN → 内核 hijack 处理 fake-ip
                .addDnsServer(TUN_DNS)
        applyAccessControl(builder)
        return builder.establish()
            ?: throw IllegalStateException("android: the application is not prepared or is revoked")
    }

    private fun applyAccessControl(builder: VpnService.Builder) {
        val (mode, apps) = readAccessSettings()
        try {
            when (mode) {
                "selected" -> {
                    // 仅勾选应用走代理；本应用始终放行（控制通道/登录 API）
                    (apps + packageName).forEach { builder.addAllowedApplication(it) }
                }
                "denied" -> {
                    // 排除勾选应用；本应用自身也排除（直连控制通道）
                    (apps - packageName).forEach { builder.addDisallowedApplication(it) }
                    builder.addDisallowedApplication(packageName)
                }
                else -> {
                    // 全部走代理：仅本应用自身不走（避免控制通道进隧道死锁）
                    builder.addDisallowedApplication(packageName)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "applyAccessControl: ${e.message}")
        }
    }

    /** 从 Flutter 设置读取访问控制（SharedPreferences 的 moneyfly_settings_v1 JSON） */
    private fun readAccessSettings(): Pair<String, List<String>> {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
            val raw = prefs.getString("flutter.moneyfly_settings_v1", null)
            if (raw == null) return "all" to emptyList()
            val json = JSONObject(raw)
            val mode = json.optString("accessControlMode", "all")
            val arr = json.optJSONArray("accessControlApps")
            val apps = mutableListOf<String>()
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    arr.optString(i).takeIf { it.isNotBlank() }?.let { apps.add(it) }
                }
            }
            mode to apps
        } catch (_: Exception) {
            "all" to emptyList()
        }
    }

    /** 从 Flutter assets 复制 geo 数据（APK 内路径 flutter_assets/assets/rules/...） */
    private fun syncGeoAssets(dir: File) {
        val names = listOf("country.mmdb", "geosite.dat")
        for (name in names) {
            val target = File(dir, name)
            if (target.exists() && target.length() > 0) continue
            try {
                assets.open("flutter_assets/assets/rules/$name").use { input ->
                    FileOutputStream(target).use { output -> input.copyTo(output) }
                }
                Log.d(TAG, "geo asset synced: $name -> ${target.absolutePath}")
            } catch (e: Exception) {
                Log.w(TAG, "geo asset $name 复制失败（智能模式 CN 分流会降级）: ${e.message}")
            }
        }
    }

    // ================= Foreground notification =================

    private fun buildNotification(): Notification {
        createChannel()
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE,
        )
        val b =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }
        return b.setContentTitle("MoneyFly")
            .setContentText("Secure connection active")
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID, "MoneyFly VPN", NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        // stopService / 系统回收都会走到这里：移除前台通知并停内核
        stopForegroundCompat()
        coreExecutor.execute {
            stopBox()
        }
        coreExecutor.shutdown()
        super.onDestroy()
    }
}
