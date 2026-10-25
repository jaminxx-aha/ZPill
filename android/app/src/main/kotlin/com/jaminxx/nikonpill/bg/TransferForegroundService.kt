package com.jaminxx.nikonpill.bg

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder

/**
 * NikonPill 传输前台服务(Android 平台)。
 *
 * BgPlugin.ensureRunning → startForegroundService 拉起本服务;服务立即
 * startForeground(dataSync 类型)挂常驻通知,让队列非空期间的批量传输
 * 在退后台后继续。stop = BgPlugin.stop → stopService,通知随之消失。
 *
 * dataSync 前台类型要求(targetSdk 34+):manifest 声明
 * FOREGROUND_SERVICE + FOREGROUND_SERVICE_DATA_SYNC 权限与
 * android:foregroundServiceType="dataSync";Android 12+ 从后台
 * startForegroundService 会抛 ForegroundServiceStartNotAllowedException,
 * 由 BgPlugin 捕获后按契约降级为「仅前台传输」。
 * Android 15 起 dataSync 累计 6h/24h 限额,超时系统自行停服,可接受
 * (本应用单次批量远小于该量级)。
 *
 * minSdk 29:NotificationChannel / startForeground 三参重载均免版本分支。
 */
class TransferForegroundService : Service() {
    companion object {
        const val ACTION_START = "com.jaminxx.nikonpill.bg.START"
        private const val CHANNEL_ID = "nikonpill_transfer"
        private const val NOTIF_ID = 42
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIF_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.getNotificationChannel(CHANNEL_ID) ?: nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "照片传输",
                NotificationManager.IMPORTANCE_LOW,
            )
        )
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(com.jaminxx.nikonpill.R.mipmap.ic_launcher)
            .setContentTitle("正在传输照片")
            .setContentText("NikonPill 正在后台接收相机照片")
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()
    }
}
