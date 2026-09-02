package top.moneyfly.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.TunOptions
import top.moneyfly.app.MainActivity
import top.moneyfly.app.R
import java.io.File

class MoneyFlyVpnService : VpnService(), PlatformInterface {
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

    private var boxService: Any? = null
    private var tunFd: ParcelFileDescriptor? = null

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
        if (configJson != null && boxService == null) {
            startBox(configJson)
        }
        return START_STICKY
    }

    private fun startBox(configJson: String) {
        try {
            extractRuleAssets()
            val svc = Libbox.newService(filesDir.absolutePath, configJson, this)
            svc.start()
            boxService = svc
            isRunning = true
        } catch (e: Exception) {
            isRunning = false
            boxService = null
        }
    }

    @Synchronized
    private fun stopBox() {
        isRunning = false
        try { boxService?.close() } catch (_: Exception) {}
        boxService = null
        try { tunFd?.close() } catch (_: Exception) {}
        tunFd = null
    }

    // ---- PlatformInterface ----

    override fun autoDetectInterfaceControl(fd: Int) {
        protect(fd)
    }

    override fun openTun(options: TunOptions): Int {
        val builder = Builder()
            .setSession("MoneyFly")
            .setConfigureIntent(PendingIntent.getActivity(
                this, 0, Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE))
            .setMtu(options.mtu)

        for (addr in options.inet4Address) {
            val parts = addr.split("/")
            builder.addAddress(parts[0], parts.getOrElse(1) { "32" }.toInt())
        }
        for (addr in options.inet6Address) {
            val parts = addr.split("/")
            builder.addAddress(parts[0], parts.getOrElse(1) { "128" }.toInt())
        }

        builder.addRoute("0.0.0.0", 0)
        builder.addRoute("::", 0)

        for (dns in options.dnsServer) {
            try { builder.addDnsServer(dns) } catch (_: Exception) {}
        }

        builder.addDisallowedApplication(packageName)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            builder.setBlocking(true)
        }

        val pfd = builder.establish() ?: throw IllegalStateException("TUN establish failed")
        tunFd = pfd
        return pfd.fd
    }

    override fun writeLog(message: String) {}
    override fun useProcFS(): Boolean = false
    override fun findConnectionOwner(ipProtocol: Int, sourceAddress: String, sourcePort: Int, destinationAddress: String, destinationPort: Int): Int = -1
    override fun packageNameByUid(uid: Int): String = ""
    override fun uidByPackageName(packageName: String): Int = -1

    private fun extractRuleAssets() {
        for (name in listOf("geoip-cn.srs", "geosite-cn.srs")) {
            val target = File(filesDir, name)
            if (target.exists() && target.length() > 0L) continue
            try {
                assets.open("flutter_assets/assets/rules/$name").use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (_: Exception) {}
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
            .setContentTitle("MoneyFly")
            .setContentText("Secure connection active")
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
        stopBox()
        super.onDestroy()
    }
}
