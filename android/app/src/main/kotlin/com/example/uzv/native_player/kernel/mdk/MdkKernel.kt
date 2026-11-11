package com.example.uzv.native_player.kernel.mdk

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import com.example.uzv.native_player.SubtitleOption
import com.example.uzv.native_player.kernel.MediaInfo
import com.example.uzv.native_player.kernel.PlayerKernel
import com.example.uzv.native_player.kernel.TrackOption
import com.example.uzv.native_player.ui.PlayerUiText
import java.util.concurrent.atomic.AtomicLong

/**
 * The MDK back end (UZN 1.1.7: 播放内核 → MDK (MDK)). MDK decodes (AMediaCodec, or FFmpeg with 硬件加速 off) and draws
 * into the SurfaceView's window on its own render thread. The page, controls and panels are the same as for Exo and
 * MPV; only this adapter differs.
 *
 * Not available from MDK's C API and so left at the PlayerKernel defaults: the download speed (the buffering line
 * shows the original's `0.0 KB/s` fallback) and adaptive video variants (quality is the app-level source list).
 * INFERRED (names OBSERVED in UZN 1.1.7's Dart code, values chosen here): the avio / avformat properties in [load].
 */
class MdkKernel(context: Context, hwDecode: Boolean) : PlayerKernel {
    private val main = Handler(Looper.getMainLooper())
    private val id = nextId.incrementAndGet()
    private val handle: Long = MdkNative.create(id, hwDecode).also { if (it == 0L) throw IllegalStateException("MDK player could not be created") }
    @Volatile private var released = false
    override var listener: PlayerKernel.Listener? = null

    private var state = 0
    private var status = 0
    private var lastReported = ""
    private var sidecars: List<SubtitleOption> = emptyList()
    private var externalSubtitle = -1
    private var subtitleChoice = -2 // -2 = not chosen yet (the preferred language may pick), -1 = off
    private var audioChoice = -1
    private var preferredAudio: String? = null
    private var preferredSubtitle: String? = null
    private var tracksApplied = false
    private var lastEventError: String? = null

    private val surface = SurfaceView(context).apply {
        holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(h: SurfaceHolder) = Unit
            override fun surfaceChanged(h: SurfaceHolder, format: Int, width: Int, height: Int) {
                if (!released) MdkNative.setSurface(handle, h.surface, width, height)
            }
            override fun surfaceDestroyed(h: SurfaceHolder) {
                if (!released) MdkNative.setSurface(handle, null, -1, -1)
            }
        })
    }

    init {
        MdkNative.register(id) { kind, a, b, text -> main.post { onEvent(kind, a, b, text) } }
    }

    private fun onEvent(kind: Int, a: Int, @Suppress("UNUSED_PARAMETER") b: Int, text: String?) {
        if (released) return
        when (kind) {
            1 -> state = a
            2 -> {
                status = a
                // Invalid = the media cannot be played: the one MDK error that stops playback. The page opens its error
                // layer on onError, so the events below (MDK also reports e.g. a hardware decoder it then replaces by
                // FFmpeg) are only kept to explain it.
                if (a and MdkStates.INVALID != 0) {
                    listener?.onError(PlayerUiText.kernelFailed("MDK", lastEventError ?: "the media could not be opened"), null)
                }
                if (a and 4 != 0 && !tracksApplied) { tracksApplied = true; applyTrackPreferences() }
            }
            3 -> if (a < 0) {
                val (category, detail) = (text ?: "").let { it.substringBefore('\t') to it.substringAfter('\t', "") }
                lastEventError = "$category: ${detail.ifEmpty { "error $a" }}"
            }
        }
        val s = MdkStates.kernelState(state, status)
        if (s != lastReported) {
            lastReported = s
            listener?.onState(s)
        }
    }

    override val view: View get() = surface
    override val positionMs: Long get() = if (released) 0 else MdkNative.position(handle).coerceAtLeast(0)
    override val durationMs: Long get() = if (released) 0 else MdkNative.duration(handle).coerceAtLeast(0)
    override var speed: Float = 1f
        set(v) { field = v; if (!released) MdkNative.setPlaybackRate(handle, v) }
    override var fitMode: String = "fit"
        set(v) { field = v; if (!released) MdkNative.setAspectRatio(handle, MdkStates.aspect(v)) }
    override val isPlaying: Boolean get() = MdkStates.kernelState(state, status) == "playing"

    override fun load(url: String, audioUrl: String?, headers: Map<String, String>, startMs: Long, subtitles: List<SubtitleOption>) {
        MdkStates.headers(headers)?.let { MdkNative.setProperty(handle, "avio.headers", it) }
        MdkNative.setProperty(handle, "avio.reconnect", "1")
        MdkNative.setProperty(handle, "avio.reconnect_delay_max", "7")
        // HLS sources often disguise their segments (.jpg/.png); ffmpeg refuses them unless these are relaxed
        MdkNative.setProperty(handle, "avformat.extension_picky", "0")
        MdkNative.setProperty(handle, "avformat.allowed_segment_extensions", "ALL")
        MdkNative.setMedia(handle, url, -1)
        if (!audioUrl.isNullOrBlank()) MdkNative.setMedia(handle, audioUrl, 1)
        sidecars = subtitles
        externalSubtitle = -1
        tracksApplied = false
        lastEventError = null
        status = 0
        MdkNative.setAspectRatio(handle, MdkStates.aspect(fitMode))
        MdkNative.setPlaybackRate(handle, speed)
        MdkNative.prepare(handle, startMs.coerceAtLeast(0))
        MdkNative.setState(handle, 1)
    }

    private fun embedded(type: Int): List<Map<String, String>> =
        if (released) emptyList() else MdkNative.tracks(handle, type).map(MdkStates::metadata)

    override fun subtitleTracks(): List<TrackOption> {
        val inner = embedded(3).mapIndexed { i, m ->
            TrackOption(MdkStates.trackLabel(m, i), subtitleChoice == i, m["language"])
        }
        val outer = sidecars.mapIndexed { i, s ->
            TrackOption(s.name ?: s.language ?: "Subtitle ${i + 1}", subtitleChoice == inner.size + i, s.language)
        }
        return inner + outer
    }

    override fun selectSubtitle(index: Int) {
        val inner = embedded(3).size
        subtitleChoice = index
        when {
            index < 0 -> {
                MdkNative.setActiveTracks(handle, 3, IntArray(0))
                if (externalSubtitle >= 0) { MdkNative.setMedia(handle, "", 3); externalSubtitle = -1 }
            }
            index < inner -> {
                if (externalSubtitle >= 0) { MdkNative.setMedia(handle, "", 3); externalSubtitle = -1 }
                MdkNative.setActiveTracks(handle, 3, intArrayOf(index))
            }
            else -> sidecars.getOrNull(index - inner)?.let {
                externalSubtitle = index - inner
                MdkNative.setMedia(handle, it.url, 3)
                MdkNative.setActiveTracks(handle, 3, intArrayOf(0))
            }
        }
    }

    override val subtitlesEnabled: Boolean get() = subtitleChoice >= 0

    override fun videoTracks(): List<TrackOption> = emptyList()
    override fun selectVideo(index: Int) = Unit
    override val videoAuto: Boolean get() = true

    override fun audioTracks(): List<TrackOption> =
        embedded(1).mapIndexed { i, m -> TrackOption(MdkStates.trackLabel(m, i), audioChoice == i, m["language"]) }

    override fun selectAudio(index: Int) {
        audioChoice = index
        MdkNative.setActiveTracks(handle, 1, if (index < 0) intArrayOf(0) else intArrayOf(index))
    }

    override val audioAuto: Boolean get() = audioChoice < 0

    override fun applyAudioPreference(language: String?) { preferredAudio = language }

    override fun applySubtitlePreferences(language: String?, fontFamily: String?, fontsDir: String?) { preferredSubtitle = language }

    /** Once per load, when the tracks are known: the preferred audio / subtitle language, if a track declares it. */
    private fun applyTrackPreferences() {
        preferredAudio?.let { lang ->
            val i = audioTracks().indexOfFirst { it.language.equals(lang, ignoreCase = true) || it.language?.startsWith(lang, ignoreCase = true) == true }
            if (i >= 0 && audioChoice < 0) selectAudio(i)
        }
        if (subtitleChoice == -2) preferredSubtitle?.let { lang ->
            val i = subtitleTracks().indexOfFirst { it.language.equals(lang, ignoreCase = true) || it.language?.startsWith(lang, ignoreCase = true) == true }
            if (i >= 0) selectSubtitle(i)
        }
    }

    override fun mediaInfo(): MediaInfo? {
        if (released) return null
        val v = MdkNative.videoInfo(handle) ?: return null
        if (v[0] <= 0 || v[1] <= 0) return null
        return MediaInfo(v[0].toInt(), v[1].toInt(), v[2], MdkNative.videoCodec(handle))
    }

    override fun videoBitrate(): Long? {
        if (released) return null
        return MdkNative.videoInfo(handle)?.get(3)?.toLong()?.takeIf { it > 0 }
    }

    override fun play() { if (!released) MdkNative.setState(handle, 1) }
    override fun pause() { if (!released) MdkNative.setState(handle, 2) }
    override fun seekTo(ms: Long) {
        if (released) return
        status = (status or MdkStates.BUFFERING) and MdkStates.BUFFERED.inv()
        if (lastReported != "buffering") {
            lastReported = "buffering"
            listener?.onState("buffering")
        }
        MdkNative.seek(handle, ms.coerceAtLeast(0))
    }

    override fun release() {
        if (released) return
        released = true
        MdkNative.unregister(id)
        MdkNative.destroy(handle)
    }

    companion object {
        private val nextId = AtomicLong()
    }
}
