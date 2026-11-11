package com.example.uzv.native_player.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.example.uzv.native_player.NativePlayerActivity
import com.example.uzv.native_player.NativePlayerHost

/**
 * Foreground "media playback" service that backs the notification-bar / lock-screen controls (changelog 1.1.9).
 * OBSERVED declarations: exported=false, foregroundServiceType=mediaPlayback, onStartCommand/onTaskRemoved/onBind
 * overrides, a separate non-exported PlaybackCommandReceiver (no intent filter -> addressed via PendingIntents).
 */
class PlaybackNotificationService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val fallbackTitle = applicationInfo.loadLabel(packageManager).toString().ifBlank { "NovaPlay" }
        val title = intent?.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() } ?: fallbackTitle
        ensureChannel()
        val notification = build(title)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        NativePlayerHost.controller?.close()
        stopSelf()
    }

    private fun build(title: String): Notification {
        fun action(cmd: String, label: String, icon: Int) = NotificationCompat.Action(
            icon, label,
            PendingIntent.getBroadcast(
                this, cmd.hashCode(),
                Intent(this, PlaybackCommandReceiver::class.java).setAction(cmd),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(
                PendingIntent.getActivity(
                    this, 0, Intent(this, NativePlayerActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                    PendingIntent.FLAG_IMMUTABLE,
                ),
            )
            .addAction(action(PlaybackCommandReceiver.ACTION_BACK, "-10s", android.R.drawable.ic_media_rew))
            .addAction(action(PlaybackCommandReceiver.ACTION_TOGGLE, "Play/Pause", android.R.drawable.ic_media_pause))
            .addAction(action(PlaybackCommandReceiver.ACTION_FORWARD, "+10s", android.R.drawable.ic_media_ff))
            .addAction(action(PlaybackCommandReceiver.ACTION_NEXT, "Next", android.R.drawable.ic_media_next))
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL_ID) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ID, "Playback", NotificationManager.IMPORTANCE_LOW))
        }
    }

    companion object {
        private const val CHANNEL_ID = "uzv_playback"
        private const val NOTIFICATION_ID = 4001
        private const val EXTRA_TITLE = "title"

        fun start(context: Context, title: String) {
            val i = Intent(context, PlaybackNotificationService::class.java).putExtra(EXTRA_TITLE, title)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(i) else context.startService(i)
        }

        fun stop(context: Context) { context.stopService(Intent(context, PlaybackNotificationService::class.java)) }
    }
}
