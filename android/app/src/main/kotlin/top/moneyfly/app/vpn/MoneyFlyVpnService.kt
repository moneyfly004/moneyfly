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
import top.moneyfly.app.MainActivity
import top.moneyfly.app.R
import top.moneyfly.libbox.BridgeOptions
import top.moneyfly.libbox.BridgeSession
import top.moneyfly.libbox.CommandServer
import top.moneyfly.libbox.CommandServerHandler
import top.moneyfly.libbox.ConnectionOwner
import top.moneyfly.libbox.InterfaceUpdateListener
import top.moneyfly.libbox.Libbox
import top.moneyfly.libbox.LocalDNSTransport
import top.moneyfly.libbox.NeighborUpdateListener
import top.moneyfly.libbox.NetworkInterface
import top.moneyfly.libbox.NetworkInterfaceIterator
import top.moneyfly.libbox.Notification as BoxNotification
import top.moneyfly.libbox.OverrideOptions
import top.moneyfly.libbox.PlatformInterface
import top.moneyfly.libbox.PlatformUser
import top.moneyfly.libbox.RoutePrefixIterator
import top.moneyfly.libbox.SetupOptions
import top.moneyfly.libbox.ShellSession
import top.moneyfly.libbox.StringIterator
import top.moneyfly.libbox.SystemProxyStatus
import top.moneyfly.libbox.TunOptions
import top.moneyfly.libbox.WIFIState
import java.io.File
import java.net.NetworkInterface as JavaNetworkInterface

/**
 * MoneyFly 的 Android VPN 服务：TUN 通道 + libmoneyfly（sing-box 1.14 核心，Go→Java 由 gomobile 生成）。
 *
 * 架构与 sing-box-for-android (SFA) 一致：
 *  - 本服务实现 [PlatformInterface]：Go 侧要开 TUN / 保护 socket 时回调到这里；
 *  - 同时实现 [CommandServerHandler]：Go 侧的服务启停 / 代理状态查询回传；
 *  - CommandServer 内部自带 Clash API（127.0.0.1:9090），Flutter 侧用它做
 *    模式热切换、节点热切换、实时流量统计。
 */
@Suppress("UNUSED_PARAMETER")
class MoneyFlyVpnService : VpnService(), PlatformInterface, CommandServerHandler {
    companion object {
        private const val TAG = "MoneyFlyVpnService"

        const val ACTION_START = "top.moneyfly.vpn.START"
        const val ACTION_STOP = "top.moneyfly.vpn.STOP"
        const val EXTRA_CONFIG = "config_json"
        const val CHANNEL_ID = "moneyfly_vpn_channel"
        private const val NOTIFY_ID = 1001

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var commandServer: CommandServer? = null
    private var tunPfd: ParcelFileDescriptor? = null

    /** 最近一次成功加载的 sing-box 配置（serviceReload 时重载用） */
    @Volatile
    private var currentConfig: String? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopBox()
                stopSelf()
                return START_NOT_STICKY
            }
        }
        startForeground(NOTIFY_ID, buildNotification())
        val configJson = intent?.getStringExtra(EXTRA_CONFIG)
        if (configJson != null && commandServer == null) {
            startBox(configJson)
        }
        return START_STICKY
    }

    @Synchronized
    private fun startBox(configJson: String) {
        try {
            if (commandServer == null) {
                // libmoneyfly 全局初始化只做一次（base/working/temp 目录）
                val opts = SetupOptions().apply {
                    basePath = filesDir.absolutePath
                    workingPath = File(filesDir, "work").also { it.mkdirs() }.absolutePath
                    tempPath = cacheDir.absolutePath
                }
                Libbox.setup(opts)
            }
            val server = CommandServer(this, this)
            server.start()
            server.startOrReloadService(configJson, OverrideOptions())
            commandServer = server
            currentConfig = configJson
            isRunning = true
            Log.d(TAG, "libmoneyfly service started")
        } catch (e: Exception) {
            Log.e(TAG, "startBox failed", e)
            isRunning = false
            currentConfig = null
            try {
                commandServer?.close()
            } catch (_: Exception) {}
            commandServer = null
        }
    }

    @Synchronized
    private fun stopBox() {
        isRunning = false
        currentConfig = null
        try {
            commandServer?.closeService()
        } catch (e: Exception) {
            Log.d(TAG, "closeService: ${e.message}")
        }
        try {
            commandServer?.close()
        } catch (_: Exception) {}
        commandServer = null
        try {
            tunPfd?.close()
        } catch (_: Exception) {}
        tunPfd = null
    }

    // ================= PlatformInterface =================

    override fun autoDetectInterfaceControl(fd: Int) {
        try {
            protect(fd)
        } catch (e: Exception) {
            Log.e(TAG, "protect failed", e)
        }
    }

    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true

    override fun useProcFS(): Boolean = false

    override fun underNetworkExtension(): Boolean = false

    override fun includeAllNetworks(): Boolean = false

    override fun usePlatformBridge(): Boolean = false

    override fun usePlatformShell(): Boolean = false

    override fun openTun(options: TunOptions): Int {
        if (prepare(this) != null) error("android: missing vpn permission")
        val builder =
            Builder()
                .setSession("MoneyFly")
                .setConfigureIntent(
                    PendingIntent.getActivity(
                        this, 0, Intent(this, MainActivity::class.java),
                        PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
                .setMtu(options.mtu)

        forEachPrefix(options.inet4Address) { address, prefix -> builder.addAddress(address, prefix) }
        forEachPrefix(options.inet6Address) { address, prefix -> builder.addAddress(address, prefix) }

        if (options.autoRoute) {
            // sing-box 已算好路由，精确下发（排除路由需 API29+ IpPrefix，
            // 运行时 Flutter 端 auto_route=false 走不到这里，保持 addRoute 即可）
            forEachPrefix(options.inet4RouteAddress) { address, prefix -> builder.addRoute(address, prefix) }
            forEachPrefix(options.inet6RouteAddress) { address, prefix -> builder.addRoute(address, prefix) }
        } else {
            // Flutter 端配置 tun.auto_route=false（路由交回平台侧）：
            // 走全量路由，保证所有流量进入 TUN
            builder.addRoute("0.0.0.0", 0)
            builder.addRoute("::", 0)
        }

        try {
            val dns = options.dnsServerAddress
            while (dns.hasNext()) {
                builder.addDnsServer(dns.next())
            }
        } catch (e: Exception) {
            Log.d(TAG, "dns server iterate: ${e.message}")
        }

        // 本应用自身流量不进入 TUN，保证控制通道（后端 API / Clash API）永远可用
        try {
            builder.addDisallowedApplication(packageName)
        } catch (e: Exception) {
            Log.d(TAG, "addDisallowedApplication failed: ${e.message}")
        }

        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        tunPfd = pfd
        return pfd.fd
    }

    private inline fun forEachPrefix(iter: RoutePrefixIterator?, block: (String, Int) -> Unit) {
        if (iter == null) return
        while (iter.hasNext()) {
            val prefix = iter.next()
            block(prefix.address(), prefix.prefix())
        }
    }

    override fun clearDNSCache() {}

    override fun readWIFIState(): WIFIState? = null

    override fun localDNSTransport(): LocalDNSTransport? = null

    override fun getInterfaces(): NetworkInterfaceIterator = EmptyNetworkInterfaceIterator()

    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {}

    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {}

    override fun startNeighborMonitor(listener: NeighborUpdateListener) {}

    override fun closeNeighborMonitor(listener: NeighborUpdateListener) {}

    @SuppressLint("MissingPermission")
    override fun findConnectionOwner(
        ipProtocol: Int,
        sourceAddress: String,
        sourcePort: Int,
        destinationAddress: String,
        destinationPort: Int,
    ): ConnectionOwner {
        // 非 API 29+ / 无法识别时返回空 owner（Go 侧按「找不到连接归属」处理，
        // 不影响基本 TUN 连接；per-app 路由未启用时此方法不会被调用）
        return ConnectionOwner()
    }

    override fun sendNotification(notification: BoxNotification) {}

    override fun cancelNotification(identifier: String, typeID: Int) {}

    override fun checkPlatformShell() {}

    override fun openShellSession(
        user: PlatformUser?,
        command: String?,
        environ: StringIterator?,
        term: String?,
        rows: Int,
        cols: Int,
    ): ShellSession = error("android: shell session not supported")

    override fun createBridge(options: BridgeOptions): BridgeSession =
        error("android: platform bridge not supported")

    override fun lookupUser(username: String): PlatformUser =
        error("android: user lookup not supported")

    override fun lookupSFTPServer(): String = error("android: sftp not supported")

    override fun readSystemSSHHostKey(): String = error("android: ssh host key not supported")

    override fun tailscaleHostname(): String =
        "${Build.MANUFACTURER} ${Build.MODEL}".trim()

    override fun registerMyInterface(name: String) {}

    // ================= CommandServerHandler =================

    override fun serviceReload() {
        val config = currentConfig ?: return
        try {
            commandServer?.startOrReloadService(config, OverrideOptions())
        } catch (e: Exception) {
            Log.e(TAG, "serviceReload failed", e)
        }
    }

    override fun serviceStop() {
        stopBox()
        stopSelf()
    }

    override fun getSystemProxyStatus(): SystemProxyStatus? = SystemProxyStatus()

    override fun setSystemProxyEnabled(isEnabled: Boolean) {}

    override fun writeDebugMessage(message: String) {
        Log.d(TAG, message)
    }

    override fun connectSSHAgent(): Int = 0

    override fun triggerNativeCrash() {}

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

    override fun onDestroy() {
        stopBox()
        super.onDestroy()
    }
}

/** 空接口迭代器：未启用「包含所有网络/接口监控」时的占位返回 */
private class EmptyNetworkInterfaceIterator : NetworkInterfaceIterator {
    override fun hasNext(): Boolean = false
    override fun next(): NetworkInterface = error("empty")
}
