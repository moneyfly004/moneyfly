package top.moneyfly.moneyfly_vpn.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import top.moneyfly.moneyfly_vpn.MainActivity
import top.moneyfly.moneyfly_vpn.R
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * MoneyFly VPN 前台服务（系统级 VPN 通道，防杀后台核心）
 *
 * 阶段 3 接入 sing-box（libcore）后，这里把 TUN 文件描述符交给内核读写；
 * 当前为骨架：建立 TUN 接口 + 前台通知 + START_STICKY 保活，
 * 保证「VpnService 授权 → 前台服务 → 通知」链路可用、进程不被系统杀死。
 */
class MoneyFlyVpnService : VpnService() {
    companion object {
        const val ACTION_START = "top.moneyfly.vpn.START"
        const val ACTION_STOP = "top.moneyfly.vpn.STOP"
        const val CHANNEL_ID = "moneyfly_vpn_channel"
        private const val NOTIFY_ID = 1001

        private var fd: ParcelFileDescriptor? = null
        var isRunning: Boolean = false
            private set
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
        }
        startForeground(NOTIFY_ID, buildNotification())
        if (fd == null) {
            fd = establishTun()
        }
        isRunning = true
        // START_STICKY：系统杀死后自动重建服务，保证隧道尽量不被中断
        return START_STICKY
    }

    private fun establishTun(): ParcelFileDescriptor? {
        return try {
            val builder = Builder()
                .setSession("MoneyFly 安全连接")
                .setConfigureIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
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
            val channel = NotificationChannel(CHANNEL_ID, "MoneyFly VPN", NotificationManager.IMPORTANCE_LOW)
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    override fun onDestroy() {
        isRunning = false
        try {
            fd?.close()
        } catch (_: Exception) {}
        fd = null
        super.onDestroy()
    }
}
