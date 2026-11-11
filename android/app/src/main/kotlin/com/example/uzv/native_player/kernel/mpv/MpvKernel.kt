package com.example.uzv.native_player.kernel.mpv

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import com.example.uzv.native_player.SubtitleOption
import com.example.uzv.native_player.kernel.MediaInfo
import com.example.uzv.native_player.kernel.PlayerKernel
import com.example.uzv.native_player.kernel.TrackOption
import com.example.uzv.native_player.ui.PlayerUiText

/**
 * The second back end (changelog 1.1.11 "MPV kernel"): libmpv rendering into a GLSurfaceView. Compiles and its logic is
 * unit-tested through [MpvCore]; NEVER RUN against a real libmpv or a GPU, and libmpv.so is not part of this repository.
 *
 * Throws IllegalStateException from the constructor when mpv cannot be created; the caller falls back to Exo.
 * A failure to create the OpenGL render context shows up later, as a player error (it can only be tried on the GL thread).
 */
class MpvKernel(context: Context, hwDecode: Boolean) : PlayerKernel {
    private val main = Handler(Looper.getMainLooper())
    override var listener: PlayerKernel.Listener? = null

    @Volatile private var released = false
    @Volatile private var renderReady = false
    private var pendingLoad: (() -> Unit)? = null // main thread only

    private val core = MpvCore(
        NativeMpvApi,
        object : MpvCore.Events {
            // PlayerController calls Flutter from these, which must happen on the main thread.
            override fun onState(state: String) { main.post { if (!released) listener?.onState(state) } }
            override fun onError(message: String, code: Int?) { main.post { if (!released) listener?.onError(PlayerUiText.kernelFailed("MPV", message), code) } }
        },
        requestRedraw = { if (::surface.isInitialized) surface.requestRender() },
    )
    private lateinit var surface: MpvSurfaceView

    init {
        core.start(MpvOptions.initialOptions(hwDecode))?.let { throw IllegalStateException(it) }
        surface = MpvSurfaceView(context, core, ::onRenderReady)
        MpvNative.setRenderUpdateListener { if (!released) surface.requestRender() }
    }

    override val view: View get() = surface

    /** GL thread. Playback is started only once a render context exists: vo=libmpv has nowhere to draw before that. */
    private fun onRenderReady(ok: Boolean) {
        main.post {
            if (released) return@post
            if (!ok) {
                listener?.onError(PlayerUiText.kernelFailed("MPV", "could not start OpenGL rendering: ${core.recentLog().ifEmpty { "no details from libmpv" }}"), null)
                return@post
            }
            renderReady = true
            pendingLoad?.invoke()
            pendingLoad = null
        }
    }

    override val positionMs: Long get() = (core.positionSec * 1000).toLong()
    override val durationMs: Long get() = (core.durationSec * 1000).toLong().coerceAtLeast(0)
    override var speed: Float
        get() = core.speed
        set(v) { core.speed = v }
    override var fitMode: String = "fit"
        set(v) {
            field = v
            core.setFit(v)
        }
    override val isPlaying: Boolean get() = core.isPlaying

    override fun load(url: String, audioUrl: String?, headers: Map<String, String>, startMs: Long, subtitles: List<SubtitleOption>) {
        val sidecars = subtitles.map { MpvSidecar(it.url, it.name, it.language) }
        val start = { core.load(url, audioUrl, headers, startMs, sidecars) }
        if (renderReady) start() else pendingLoad = start
    }

    override fun subtitleTracks(): List<TrackOption> = core.subtitleTracks()
    override fun selectSubtitle(index: Int) = core.selectSubtitle(index)
    override val subtitlesEnabled: Boolean get() = core.subtitlesEnabled

    // mpv exposes no adaptive variants as selectable tracks; quality switching is the app-level list of source qualities.
    override fun videoTracks(): List<TrackOption> = emptyList()
    override fun selectVideo(index: Int) = Unit
    override val videoAuto: Boolean get() = true

    override fun audioTracks(): List<TrackOption> = core.audioTracks()
    override fun selectAudio(index: Int) = core.selectAudio(index)
    override val audioAuto: Boolean get() = core.audioAuto
    override fun applyAudioPreference(language: String?) = core.applyAudioPreference(language)
    override fun applySubtitlePreferences(language: String?, fontFamily: String?, fontsDir: String?) =
        core.applySubtitlePreferences(language, fontFamily, fontsDir)

    override fun mediaInfo(): MediaInfo? = core.mediaInfo()
    override fun downloadSpeed(): Long? = core.downloadSpeed()
    override fun videoBitrate(): Long? = core.videoBitrate()

    override fun play() = core.setPaused(false)
    override fun pause() = core.setPaused(true)
    override fun seekTo(ms: Long) = core.seekTo(ms)

    /** Order matters: stop reading events, free the render context on the GL thread, only then destroy the core. */
    override fun release() {
        if (released) return
        released = true
        MpvNative.setRenderUpdateListener(null)
        pendingLoad = null
        core.stopEvents()
        surface.releaseRenderContext(1000)
        core.destroy()
    }
}
