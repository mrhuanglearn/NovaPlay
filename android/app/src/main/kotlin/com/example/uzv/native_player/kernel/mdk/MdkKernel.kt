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
class MdkKernel(context: Context, private val hwDecode: Boolean) : PlayerKernel {
    private val appContext = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var id = nextId.incrementAndGet()
    @Volatile private var handle: Long = MdkNative.create(id, hwDecode).also { if (it == 0L) throw IllegalStateException("MDK player could not be created") }
    @Volatile private var released = false
    override var listener: PlayerKernel.Listener? = null

    private var hasLoaded = false
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
    private var displayW = 0
    private var displayH = 0
    private var surface: SurfaceView? = null
    private var attachedSurface: android.view.Surface? = null
    private var surfaceW = 0
    private var surfaceH = 0

    override fun attachActivity(activityContext: Context): View {
        surface?.let { return it }
        return SurfaceView(activityContext).apply {
            keepScreenOn = true
            holder.setKeepScreenOn(true)
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(h: SurfaceHolder) = Unit
                override fun surfaceChanged(h: SurfaceHolder, format: Int, width: Int, height: Int) {
                    attachedSurface = h.surface
                    surfaceW = width
                    surfaceH = height
                    val cur = handle
                    if (!released && cur != 0L) MdkNative.setSurface(cur, h.surface, width, height)
                }
                override fun surfaceDestroyed(h: SurfaceHolder) {
                    attachedSurface = null
                    surfaceW = 0
                    surfaceH = 0
                    val cur = handle
                    if (!released && cur != 0L) MdkNative.setSurface(cur, null, -1, -1)
                }
            })
        }.also { surface = it }
    }

    init {
        registerEvents(id)
    }

    private fun registerEvents(regId: Long) {
        MdkNative.register(regId) { kind, a, b, text ->
            main.post { if (!released && id == regId) onEvent(kind, a, b, text) }
        }
    }

    /** Detaches window producer synchronously so the next handle can bind cleanly, then frees native memory off the UI thread. */
    private fun destroyAsync(oldId: Long, oldHandle: Long) {
        if (oldHandle == 0L) return
        MdkNative.unregister(oldId)
        MdkNative.setState(oldHandle, 0)
        MdkNative.setSurface(oldHandle, null, -1, -1)
        Thread({ MdkNative.destroy(oldHandle) }, "mdk-destroy").apply {
            isDaemon = true
            start()
        }
    }

    private fun onEvent(kind: Int, a: Int, @Suppress("UNUSED_PARAMETER") b: Int, text: String?) {
        val cur = handle
        if (released || cur == 0L) return
        when (kind) {
            1 -> state = a
            2 -> {
                status = a
                // Invalid = the media cannot be played: the one MDK error that stops playback. The page opens its error
                // layer on onError, so the events below (MDK also reports e.g. a hardware decoder it then replaces by
                // FFmpeg) are only kept to explain it.
                if (a and MdkStates.INVALID != 0) {
                    listener?.onError(PlayerUiText.kernelFailed("MDK", lastEventError ?: "the media could not be opened"), null)
                    return
                }
                if (a and 4 != 0 && !tracksApplied) { tracksApplied = true; applyTrackPreferences() }
            }
            3 -> if (a < 0) {
                val (category, detail) = (text ?: "").let { it.substringBefore('\t') to it.substringAfter('\t', "") }
                lastEventError = "$category: ${detail.ifEmpty { "error $a" }}"
            }
        }
        // Only query videoInfo once the current media is LOADED so queued events from a previous episode cannot leak old sizes.
        if (status and 4 != 0 && (displayW <= 0 || kind == 2 || kind == 3)) {
            val v = MdkNative.videoInfo(cur)
            if (v != null) {
                val w = Math.round(v[0]).toInt()
                val h = Math.round(v[1]).toInt()
                if (w > 0 && h > 0 && (w != displayW || h != displayH)) {
                    displayW = w
                    displayH = h
                    listener?.onVideoSizeChanged(w, h)
                }
            }
        }
        val s = MdkStates.kernelState(state, status)
        if (s != lastReported) {
            lastReported = s
            listener?.onState(s)
        }
    }

    override val view: View get() = surface ?: attachActivity(appContext)
    override val positionMs: Long get() = handle.let { cur -> if (released || cur == 0L) 0 else MdkNative.position(cur).coerceAtLeast(0) }
    override val durationMs: Long get() = handle.let { cur -> if (released || cur == 0L) 0 else MdkNative.duration(cur).coerceAtLeast(0) }
    override var speed: Float = 1f
        set(v) { field = v; val cur = handle; if (!released && cur != 0L) MdkNative.setPlaybackRate(cur, v) }
    override var fitMode: String = "fit"
        set(v) { field = v; val cur = handle; if (!released && cur != 0L) MdkNative.setAspectRatio(cur, MdkStates.aspect(v)) }
    override val isPlaying: Boolean get() = MdkStates.kernelState(state, status) == "playing"

    override fun load(url: String, audioUrl: String?, headers: Map<String, String>, startMs: Long, subtitles: List<SubtitleOption>, autoPlay: Boolean) {
        if (released) return
        if (hasLoaded) {
            // Recreate native handle on reload: libmdk MediaControl::prepare() deadlocks the main thread if VideoFrameQueue is paused.
            val oldId = id
            val oldHandle = handle
            handle = 0L
            destroyAsync(oldId, oldHandle)
            val next = nextId.incrementAndGet()
            val nextHandle = MdkNative.create(next, hwDecode)
            if (nextHandle == 0L) {
                listener?.onError(PlayerUiText.kernelFailed("MDK", "MDK player could not be recreated"), null)
                return
            }
            id = next
            handle = nextHandle
            registerEvents(next)
            val surf = attachedSurface
            if (surf != null && surf.isValid && surfaceW > 0 && surfaceH > 0) {
                MdkNative.setSurface(nextHandle, surf, surfaceW, surfaceH)
            }
        }
        val cur = handle
        if (cur == 0L) return
        hasLoaded = true
        MdkNative.setState(cur, 0)
        MdkStates.headers(headers)?.let { MdkNative.setProperty(cur, "avio.headers", it) }
        MdkNative.setProperty(cur, "avio.reconnect", "1")
        MdkNative.setProperty(cur, "avio.reconnect_delay_max", "7")
        MdkNative.setProperty(cur, "avio.rw_timeout", "10000000")
        // HLS sources often disguise their segments (.jpg/.png); ffmpeg refuses them unless these are relaxed
        MdkNative.setProperty(cur, "avformat.extension_picky", "0")
        MdkNative.setProperty(cur, "avformat.allowed_segment_extensions", "ALL")
        MdkNative.setMedia(cur, url, -1)
        if (!audioUrl.isNullOrBlank()) MdkNative.setMedia(cur, audioUrl, 1)
        sidecars = subtitles
        externalSubtitle = -1
        tracksApplied = false
        lastEventError = null
        lastReported = ""
        state = 0
        status = 0
        displayW = 0
        displayH = 0
        MdkNative.setAspectRatio(cur, MdkStates.aspect(fitMode))
        MdkNative.setPlaybackRate(cur, speed)
        MdkNative.prepare(cur, startMs.coerceAtLeast(0))
        MdkNative.setState(cur, if (autoPlay) 1 else 2)
    }

    private fun embedded(type: Int): List<Map<String, String>> {
        val cur = handle
        return if (released || cur == 0L) emptyList() else MdkNative.tracks(cur, type).map(MdkStates::metadata)
    }

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
        val cur = handle
        if (released || cur == 0L) return
        val inner = embedded(3).size
        subtitleChoice = index
        when {
            index < 0 -> {
                MdkNative.setActiveTracks(cur, 3, IntArray(0))
                if (externalSubtitle >= 0) { MdkNative.setMedia(cur, "", 3); externalSubtitle = -1 }
            }
            index < inner -> {
                if (externalSubtitle >= 0) { MdkNative.setMedia(cur, "", 3); externalSubtitle = -1 }
                MdkNative.setActiveTracks(cur, 3, intArrayOf(index))
            }
            else -> sidecars.getOrNull(index - inner)?.let {
                externalSubtitle = index - inner
                MdkNative.setMedia(cur, it.url, 3)
                MdkNative.setActiveTracks(cur, 3, intArrayOf(0))
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
        val cur = handle
        if (released || cur == 0L) return
        audioChoice = index
        MdkNative.setActiveTracks(cur, 1, if (index < 0) intArrayOf(0) else intArrayOf(index))
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
        if (subtitleChoice == -2) {
            val langPick = preferredSubtitle?.let { lang ->
                subtitleTracks().indexOfFirst { it.language.equals(lang, ignoreCase = true) || it.language?.startsWith(lang, ignoreCase = true) == true }
                    .takeIf { it >= 0 }
            }
            val pick = langPick ?: if (sidecars.isNotEmpty()) embedded(3).size else -1
            if (pick >= 0) selectSubtitle(pick)
        }
    }

    override fun mediaInfo(): MediaInfo? {
        val cur = handle
        if (released || cur == 0L || (status and 4) == 0 || displayW <= 0 || displayH <= 0) return null
        val v = MdkNative.videoInfo(cur)
        val fps = v?.getOrNull(2)?.takeIf { it > 0.0 } ?: 0.0
        return MediaInfo(displayW, displayH, fps, MdkNative.videoCodec(cur))
    }

    override fun videoBitrate(): Long? {
        val cur = handle
        if (released || cur == 0L) return null
        return MdkNative.videoInfo(cur)?.get(3)?.toLong()?.takeIf { it > 0 }
    }

    override fun play() { val cur = handle; if (!released && cur != 0L) MdkNative.setState(cur, 1) }
    override fun pause() { val cur = handle; if (!released && cur != 0L) MdkNative.setState(cur, 2) }
    override fun seekTo(ms: Long) {
        val cur = handle
        if (released || cur == 0L) return
        status = (status or MdkStates.BUFFERING) and MdkStates.BUFFERED.inv()
        if (lastReported != "buffering") {
            lastReported = "buffering"
            listener?.onState("buffering")
        }
        MdkNative.seek(cur, ms.coerceAtLeast(0))
    }

    override fun release() {
        if (released) return
        released = true
        val oldId = id
        val oldHandle = handle
        handle = 0L
        attachedSurface = null
        destroyAsync(oldId, oldHandle)
    }

    companion object {
        private val nextId = AtomicLong()
    }
}
