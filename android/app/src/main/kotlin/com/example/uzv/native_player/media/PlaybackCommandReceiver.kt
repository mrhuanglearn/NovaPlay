package com.example.uzv.native_player.media

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.example.uzv.native_player.NativePlayerHost

/** Routes notification button presses to the running [com.example.uzv.native_player.PlayerController]. */
class PlaybackCommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val c = NativePlayerHost.controller ?: return
        when (intent.action) {
            ACTION_TOGGLE -> c.togglePause()
            ACTION_FORWARD -> c.seekBy(10)
            ACTION_BACK -> c.seekBy(-10)
            ACTION_NEXT -> c.nextEpisode()
        }
    }

    companion object {
        const val ACTION_TOGGLE = "com.example.uzv.playback.TOGGLE"
        const val ACTION_FORWARD = "com.example.uzv.playback.FORWARD"
        const val ACTION_BACK = "com.example.uzv.playback.BACK"
        const val ACTION_NEXT = "com.example.uzv.playback.NEXT"
    }
}
