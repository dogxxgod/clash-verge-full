package io.github.clashverge.rev

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log

/**
 * Holds the Android VPN tunnel that the kernel (mihomo) consumes through
 * `tun.file-descriptor`. The descriptor is handed to Rust exactly once, so the
 * service never reads or writes the interface itself.
 */
class VpnTunService : VpnService() {
    companion object {
        private const val TAG = "VpnTunService"
        const val ACTION_START = "io.github.clashverge.rev.VPN_START"
        const val ACTION_STOP = "io.github.clashverge.rev.VPN_STOP"
        private const val NOTIFICATION_CHANNEL_ID = "clash_verge_vpn"
        private const val NOTIFICATION_ID = 1001

        init {
            try {
                System.loadLibrary("app_lib")
            } catch (t: Throwable) {
                Log.w(TAG, "Failed to load app_lib native library: ${t.message}")
            }
        }

        @JvmStatic
        external fun nativeOnTunEstablished(fd: Int)

        @JvmStatic
        external fun nativeOnTunRevoked()
    }

    private var tunInterface: ParcelFileDescriptor? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_START
        Log.i(TAG, "onStartCommand with action: $action")
        when (action) {
            ACTION_START -> startVpn()
            ACTION_STOP -> stopVpn()
        }
        return START_NOT_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "Clash Verge VPN",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Clash Verge VPN Service Notification"
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun createNotification(): Notification {
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Clash Verge")
            .setContentText("TUN mode is active")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun startVpn() {
        if (tunInterface != null) {
            Log.i(TAG, "VPN already running")
            return
        }

        try {
            startForeground(NOTIFICATION_ID, createNotification())
        } catch (t: Throwable) {
            Log.w(TAG, "startForeground error: ${t.message}")
        }

        val builder = Builder()
            .setSession("Clash Verge")
            .setMtu(9000)
            .addAddress("172.19.0.1", 30)
            .addRoute("0.0.0.0", 0)
            .addDnsServer("198.18.0.1")
            .addDnsServer("223.5.5.5")

        // IPv6 configuration
        try {
            builder.addAddress("fdfe:dcba:9876::1", 126)
            builder.addRoute("::", 0)
        } catch (t: Throwable) {
            Log.w(TAG, "IPv6 setup skipped: ${t.message}")
        }

        // Loop prevention: exclude our own application package so that
        // mihomo's outbound proxy connections bypass the VPN TUN.
        try {
            builder.addDisallowedApplication(packageName)
            Log.i(TAG, "Self-package excluded from VPN: $packageName")
        } catch (e: PackageManager.NameNotFoundException) {
            Log.e(TAG, "Could not find self package name", e)
        }

        val pfd = builder.establish()
        if (pfd == null) {
            Log.e(TAG, "Failed to establish VPN interface: Builder.establish() returned null")
            stopSelf()
            return
        }

        tunInterface = pfd
        val fd = pfd.detachFd()
        Log.i(TAG, "VPN established with fd: $fd")
        nativeOnTunEstablished(fd)
    }

    private fun stopVpn() {
        Log.i(TAG, "Stopping VPN...")
        nativeOnTunRevoked()
        try {
            tunInterface?.close()
        } catch (t: Throwable) {
            Log.w(TAG, "Error closing TUN interface: ${t.message}")
        }
        tunInterface = null
        stopForeground(true)
        stopSelf()
    }

    override fun onRevoke() {
        Log.i(TAG, "VPN revoked by system or user")
        stopVpn()
        super.onRevoke()
    }

    override fun onDestroy() {
        Log.i(TAG, "VpnTunService onDestroy")
        stopVpn()
        super.onDestroy()
    }
}
