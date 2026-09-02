package top.moneyfly.app.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import com.hiddify.core.libbox.CommandServer
import com.hiddify.core.libbox.CommandServerHandler
import com.hiddify.core.libbox.InterfaceUpdateListener
import com.hiddify.core.libbox.Libbox
import com.hiddify.core.libbox.LocalDNSTransport
import com.hiddify.core.libbox.NetworkInterfaceIterator
import com.hiddify.core.libbox.Notification as BoxNotification
import com.hiddify.core.libbox.OverrideOptions
import com.hiddify.core.libbox.PlatformInterface
import com.hiddify.core.libbox.ConnectionOwner
import com.hiddify.core.libbox.RoutePrefixIterator
import com.hiddify.core.libbox.SetupOptions
import com.hiddify.core.libbox.StringIterator
import com.hiddify.core.libbox.SystemProxyStatus
import com.hiddify.core.libbox.TunOptions
import com.hiddify.core.libbox.WIFIState
import top.moneyfly.app.MainActivity
import top.moneyfly.app.R
import java.io.File

class MoneyFlyVpnService : VpnService(), PlatformInterface, CommandServerHandler {
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

    private var commandServer: CommandServer? = null
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
        if (configJson != null && commandServer == null) {
            startBox(configJson)
        }
        return START_STICKY
    }

    private fun startBox(configJson: String) {
        try {
            val opts = SetupOptions().apply {
                basePath = filesDir.absolutePath
                workingPath = File(filesDir, "work").also { it.mkdirs() }.absolutePath
                tempPath = cacheDir.absolutePath
            }
            Libbox.setup(opts)

            val server = CommandServer(this, this)
            server.startOrReloadService(configJson, OverrideOptions())
            server.start()
            commandServer = server
            isRunning = true
        } catch (e: Exception) {
            isRunning = false
            commandServer = null
        }
    }

    @Synchronized
    private fun stopBox() {
        isRunning = false
        try { commandServer?.closeService() } catch (_: Exception) {}
        try { commandServer?.close() } catch (_: Exception) {}
        commandServer = null
        try { tunFd?.close() } catch (_: Exception) {}
        tunFd = null
    }

    // ---- PlatformInterface ----

    override fun autoDetectInterfaceControl(fd: Int) { protect(fd) }

    override fun openTun(options: TunOptions): Int {
        val builder = Builder()
            .setSession("MoneyFly")
            .setConfigureIntent(PendingIntent.getActivity(
                this, 0, Intent(this, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE))
            .setMtu(options.mtu)

        iterateAddresses(options.inet4Address) { addr, prefix ->
            builder.addAddress(addr, prefix)
        }
        iterateAddresses(options.inet6Address) { addr, prefix ->
            builder.addAddress(addr, prefix)
        }

        if (options.autoRoute) {
            iterateAddresses(options.inet4RouteAddress) { addr, prefix ->
                builder.addRoute(addr, prefix)
            }
            iterateAddresses(options.inet6RouteAddress) { addr, prefix ->
                builder.addRoute(addr, prefix)
            }
        } else {
            builder.addRoute("0.0.0.0", 0)
            builder.addRoute("::", 0)
        }

        try {
            val dns = options.getDNSServerAddress()
            if (dns != null && dns.value.isNotEmpty()) {
                builder.addDnsServer(dns.value)
            }
        } catch (_: Exception) {
            builder.addDnsServer("223.5.5.5")
        }

        builder.addDisallowedApplication(packageName)
        val pfd = builder.establish() ?: throw IllegalStateException("TUN establish failed")
        tunFd = pfd
        return pfd.detachFd()
    }

    private fun iterateAddresses(iter: RoutePrefixIterator?, block: (String, Int) -> Unit) {
        if (iter == null) return
        while (iter.hasNext()) {
            val prefix = iter.next()
            block(prefix.address(), prefix.prefix())
        }
    }

    override fun useProcFS(): Boolean = false
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun underNetworkExtension(): Boolean = false
    override fun includeAllNetworks(): Boolean = false
    override fun clearDNSCache() {}
    override fun readWIFIState(): WIFIState? = null
    override fun localDNSTransport(): LocalDNSTransport? = null
    override fun systemCertificates(): StringIterator? = null
    override fun getInterfaces(): NetworkInterfaceIterator? = null
    override fun sendNotification(notification: BoxNotification) {}
    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {}
    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {}
    override fun findConnectionOwner(ipProtocol: Int, sourceAddress: String, sourcePort: Int, destinationAddress: String, destinationPort: Int): ConnectionOwner? = null

    // ---- CommandServerHandler ----

    override fun serviceReload() {}
    override fun serviceStop() { stopBox(); stopSelf() }
    override fun getSystemProxyStatus(): SystemProxyStatus? = null
    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun writeDebugMessage(message: String) {}

    // ---- Notification ----

    private fun buildNotification(): Notification {
        createChannel()
        val pi = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            Notification.Builder(this, CHANNEL_ID) else
            @Suppress("DEPRECATION") Notification.Builder(this)
        return b.setContentTitle("MoneyFly")
            .setContentText("Secure connection active")
            .setSmallIcon(R.drawable.ic_stat_vpn)
            .setContentIntent(pi).setOngoing(true).build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "MoneyFly VPN", NotificationManager.IMPORTANCE_LOW))
        }
    }

    override fun onDestroy() { stopBox(); super.onDestroy() }
}
