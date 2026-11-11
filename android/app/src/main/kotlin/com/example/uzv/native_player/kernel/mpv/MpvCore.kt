package com.example.uzv.native_player.kernel.mpv

import com.example.uzv.native_player.kernel.MediaInfo
import com.example.uzv.native_player.kernel.TrackLabels
import com.example.uzv.native_player.kernel.TrackOption

/** A sidecar subtitle handed to mpv with `sub-add` once the file is open. */
data class MpvSidecar(val url: String, val name: String?, val language: String?)

/**
 * The playback logic of the MPV kernel without any Android class: option setup, the event loop, the state machine, track
 * selection and the per-file reset. [MpvKernel] adds the GL surface and the PlayerKernel interface on top.
 *
 * Threading: commands come from the UI thread, events are processed on one background thread (or by [pump] in tests).
 * [Events] is called on whichever thread produced the change; the kernel moves it to the main thread.
 */
class MpvCore(
    private val api: MpvApi,
    private val events: Events,
    private val requestRedraw: () -> Unit = {},
) {
    interface Events {
        fun onState(state: String) // idle | buffering | playing | paused | ended
        fun onError(message: String, code: Int?)
    }

    @Volatile
    var handle = 0L
        private set

    @Volatile
    var positionSec = 0.0
        private set

    @Volatile
    var durationSec = 0.0
        private set

    @Volatile private var userPaused = false
    @Volatile private var cacheStall = false
    @Volatile private var seeking = false
    @Volatile private var loaded = false
    @Volatile private var loading = false
    @Volatile private var eof = false

    /** True between `load` and the START_FILE of the new file: an END_FILE seen in that window belongs to the old file. */
    @Volatile private var awaitingStart = false
    @Volatile private var running = false
    private var lastState = "idle"
    private var thread: Thread? = null

    private var sidecars: List<MpvSidecar> = emptyList()
    private var externalAudio = false
    private var pendingAudioAdd: String? = null // only when the `audio-files` option was refused
    private var userAgentTouched = false
    private var referrerTouched = false
    private var defaultUserAgent: String? = null // what mpv reports right after initialize

    // What the user picked, remembered across loads (mpv keeps `sid`/`aid` per file, the app keeps the intent).
    @Volatile private var subtitlesOff = false
    private var chosenTextLabel: String? = null
    private var chosenAudioLabel: String? = null
    private var preferredTextLanguage: String? = null
    private var preferredAudioLanguage: String? = null

    val isPlaying: Boolean get() = computeState() == "playing"
    val state: String get() = computeState()

    /**
     * Creates and initialises the core. Returns null on success, otherwise a message for the user; the handle is
     * released again in that case. [startThread] = false lets tests drive the loop with [pump].
     */
    fun start(options: List<Pair<String, String>>, startThread: Boolean = true): String? {
        val h = api.create()
        if (h == 0L) return "libmpv is not available (${api.lastLogMessages().trim().ifEmpty { "create() returned null" }})"
        for ((name, value) in options) {
            val rc = api.setPropertyString(h, name, value)
            if (rc < 0 && name == "vo") { // without the render API vo nothing can be shown
                api.destroy(h)
                return "mpv rejected vo=$value: ${api.errorString(rc)}"
            }
        }
        val rc = api.initialize(h)
        if (rc < 0) {
            api.destroy(h)
            return "mpv_initialize failed: ${api.errorString(rc)}"
        }
        handle = h
        defaultUserAgent = api.getPropertyString(h, "user-agent")?.takeIf { it.isNotEmpty() }
        api.requestLogMessages(h, "warn")
        api.observeProperty(h, OBS_TIME_POS, "time-pos", MpvFormat.DOUBLE)
        api.observeProperty(h, OBS_DURATION, "duration", MpvFormat.DOUBLE)
        api.observeProperty(h, OBS_PAUSE, "pause", MpvFormat.FLAG)
        api.observeProperty(h, OBS_CACHE_STALL, "paused-for-cache", MpvFormat.FLAG)
        running = true
        if (startThread) {
            thread = Thread({ while (running && pump(1.0)) Unit }, "mpv-events").also { it.isDaemon = true; it.start() }
        }
        return null
    }

    // -- playback ------------------------------------------------------------------------------------------------------

    fun load(url: String, audioUrl: String?, headers: Map<String, String>, startMs: Long, sidecars: List<MpvSidecar>) {
        val h = handle
        if (h == 0L) return
        this.sidecars = sidecars
        externalAudio = !audioUrl.isNullOrEmpty()
        awaitingStart = true
        loaded = false
        loading = true
        eof = false
        cacheStall = false
        seeking = false
        userPaused = false // a new file always starts playing (Exo: playWhenReady = true); `pause` is a sticky option in mpv
        positionSec = startMs.coerceAtLeast(0) / 1000.0
        durationSec = 0.0

        val ho = MpvOptions.headerOptions(headers)
        setList(h, "http-header-fields", ho.fields)
        // User-Agent / Referer are only touched when a request sets them, or to undo an earlier request's value:
        // an empty user-agent would reach ffmpeg as an empty header instead of mpv's own default.
        if (ho.userAgent != null) {
            api.setPropertyString(h, "user-agent", ho.userAgent)
            userAgentTouched = true
        } else if (userAgentTouched) {
            api.setPropertyString(h, "user-agent", defaultUserAgent.orEmpty())
            userAgentTouched = false
        }
        if (ho.referrer != null) {
            api.setPropertyString(h, "referrer", ho.referrer)
            referrerTouched = true
        } else if (referrerTouched) {
            api.setPropertyString(h, "referrer", "")
            referrerTouched = false
        }
        // Separate audio stream (DASH): handed over before playback starts so the video is not silent for a moment.
        val audioRc = setList(h, "audio-files", listOfNotNull(audioUrl?.takeIf { it.isNotEmpty() }))
        pendingAudioAdd = if (audioRc < 0 && !audioUrl.isNullOrEmpty()) audioUrl else null
        // sid/aid are sticky options in mpv: start every file from "auto" (or "no" if the user turned subtitles off).
        api.setPropertyString(h, "sid", if (subtitlesOff) "no" else "auto")
        api.setPropertyString(h, "aid", "auto")
        api.setProperty(h, "pause", MpvFormat.FLAG, 0.0)
        // The start position is passed as a per-file option of `loadfile` (mpv >= 0.38: url, flags, index, options), the
        // documented way; a global `start` would also stick to later files. Note (2026-11-10, Waydroid): mpv can only start
        // in the middle when the server answers Range requests; on one that does not, it starts at 0 (Exo reads up to the
        // position instead).
        val rc = api.command(h, arrayOf("loadfile", url, "replace", "-1", "start=${MpvOptions.startValue(startMs)}"))
        if (rc < 0) {
            loading = false
            awaitingStart = false
            events.onError("mpv loadfile failed: ${api.errorString(rc)}", rc)
        }
        publishState()
    }

    /**
     * Replaces a list option (http-header-fields, audio-files) item by item with `change-list clr` + `append`: every
     * command argument is a separate C string, so nothing in an item (commas, colons, `%`, quotes) needs escaping and
     * mpv's list-syntax parser is never involved. Returns the first error code, or 0.
     */
    private fun setList(h: Long, name: String, items: List<String>): Int {
        var rc = api.command(h, arrayOf("change-list", name, "clr", ""))
        for (item in items) {
            val r = api.command(h, arrayOf("change-list", name, "append", item))
            if (rc >= 0 && r < 0) rc = r
        }
        return rc
    }

    /** `video-params` of the playing file plus mpv's frame-rate estimate; null until mpv knows the video size. */
    fun mediaInfo(): MediaInfo? {
        val h = handle
        if (h == 0L || !loaded) return null
        val w = api.getProperty(h, "video-params/w", MpvFormat.INT64)
        val ht = api.getProperty(h, "video-params/h", MpvFormat.INT64)
        if (w.isNaN() || ht.isNaN() || w <= 0 || ht <= 0) return null
        val fps = api.getProperty(h, "estimated-vf-fps", MpvFormat.DOUBLE).takeUnless { it.isNaN() }
            ?: api.getProperty(h, "container-fps", MpvFormat.DOUBLE).takeUnless { it.isNaN() } ?: 0.0
        return MediaInfo(w.toInt(), ht.toInt(), fps, api.getPropertyString(h, "video-format"))
    }

    /** `cache-speed` in bytes/s (OBSERVED in the original, g2.g.m). */
    fun downloadSpeed(): Long? = number("cache-speed")?.toLong()

    /** `video-bitrate` in bits/s (OBSERVED in the original, g2.g.l). */
    fun videoBitrate(): Long? = number("video-bitrate")?.toLong()

    private fun number(name: String): Double? {
        val h = handle
        if (h == 0L || !loaded) return null
        return api.getProperty(h, name, MpvFormat.DOUBLE).takeUnless { it.isNaN() }
    }

    fun setPaused(paused: Boolean) {
        val h = handle
        if (h == 0L) return
        api.setProperty(h, "pause", MpvFormat.FLAG, if (paused) 1.0 else 0.0)
        userPaused = paused // optimistic; the observed property confirms it
        publishState()
    }

    fun seekTo(ms: Long) {
        val h = handle
        if (h == 0L) return
        val sec = ms.coerceAtLeast(0) / 1000.0
        seeking = true
        api.command(h, arrayOf("seek", String.format(java.util.Locale.ROOT, "%.3f", sec), "absolute"))
        positionSec = sec
        publishState()
    }

    var speed: Float
        get() {
            val h = handle
            val v = if (h == 0L) Double.NaN else api.getProperty(h, "speed", MpvFormat.DOUBLE)
            return if (v.isNaN() || v <= 0) 1f else v.toFloat()
        }
        set(v) {
            val h = handle
            if (h != 0L && v > 0f) api.setProperty(h, "speed", MpvFormat.DOUBLE, v.toDouble())
        }

    fun setFit(mode: String) {
        val h = handle
        if (h == 0L) return
        val (keepAspect, panscan) = MpvOptions.fit(mode)
        api.setProperty(h, "keepaspect", MpvFormat.FLAG, if (keepAspect) 1.0 else 0.0)
        api.setProperty(h, "panscan", MpvFormat.DOUBLE, panscan)
        requestRedraw()
    }

    // -- tracks --------------------------------------------------------------------------------------------------------

    private fun tracks(type: String): List<MpvTrack> {
        val h = handle
        if (h == 0L) return emptyList()
        return MpvOptions.parseTracks { api.getPropertyString(h, it) }.filter { it.type == type }
    }

    fun subtitleTracks(): List<TrackOption> = tracks("sub").mapIndexed { n, t ->
        TrackOption(TrackLabels.textLabel(t.title, t.lang, n), t.selected, t.lang)
    }

    val subtitlesEnabled: Boolean get() = !subtitlesOff && tracks("sub").any { it.selected }

    fun selectSubtitle(index: Int) {
        val h = handle
        if (h == 0L) return
        if (index < 0) {
            subtitlesOff = true // stays off for the next episode as well, like Exo's disabled track type
            api.setPropertyString(h, "sid", "no")
            return
        }
        val track = tracks("sub").getOrNull(index) ?: return
        subtitlesOff = false
        chosenTextLabel = track.title
        api.setProperty(h, "sid", MpvFormat.INT64, track.id.toDouble())
    }

    fun audioTracks(): List<TrackOption> = tracks("audio").mapIndexed { n, t ->
        TrackOption(TrackLabels.audioLabel(t.title, t.lang, t.channels, n), t.selected, t.lang)
    }

    val audioAuto: Boolean get() = chosenAudioLabel == null

    fun selectAudio(index: Int) {
        val h = handle
        if (h == 0L) return
        if (index < 0) {
            chosenAudioLabel = null
            api.setPropertyString(h, "aid", "auto")
            return
        }
        val track = tracks("audio").getOrNull(index) ?: return
        chosenAudioLabel = track.title.orEmpty().ifEmpty { null }
        api.setProperty(h, "aid", MpvFormat.INT64, track.id.toDouble())
    }

    fun applyAudioPreference(language: String?) {
        preferredAudioLanguage = language?.takeIf { it.isNotBlank() }
        val h = handle
        if (h != 0L) api.setPropertyString(h, "alang", preferredAudioLanguage.orEmpty())
    }

    fun applySubtitlePreferences(language: String?, fontFamily: String?, fontsDir: String?) {
        preferredTextLanguage = language?.takeIf { it.isNotBlank() }
        val h = handle
        if (h == 0L) return
        api.setPropertyString(h, "slang", preferredTextLanguage.orEmpty())
        api.setPropertyString(h, "sub-font", fontFamily?.takeIf { it.isNotBlank() }.orEmpty())
        api.setPropertyString(h, "sub-fonts-dir", fontsDir?.takeIf { it.isNotBlank() }.orEmpty())
        requestRedraw()
    }

    /**
     * After FILE_LOADED: add the sidecar subtitles, then reselect what the user picked for the previous file (label,
     * then language, then the default-flagged track), as the Exo kernel does. mpv's own `slang`/`alang` auto-selection
     * has already run; this only corrects it where the user's memory says otherwise.
     */
    private fun onFileLoaded() {
        val h = handle
        if (h == 0L) return
        pendingAudioAdd?.let { api.command(h, arrayOf("audio-add", it, "select")) }
        pendingAudioAdd = null
        for (s in sidecars) {
            val args = arrayOf("sub-add", s.url, "auto", s.name.orEmpty(), s.language.orEmpty())
            api.command(h, args) // a rejected sidecar (unsupported format, 404) must not stop the others
        }
        applyTrackPreferences()
    }

    private fun applyTrackPreferences() {
        val h = handle
        if (h == 0L) return
        val subs = tracks("sub")
        if (!subtitlesOff && subs.isNotEmpty()) {
            val firstExternal = subs.indexOfFirst { it.external }
            val pick = TrackLabels.chooseDefaultText(
                subs.map { it.title },
                subs.map { it.lang },
                subs.mapIndexed { i, t -> t.isDefault || i == firstExternal },
                chosenTextLabel,
                preferredTextLanguage,
            )
            if (pick >= 0 && !subs[pick].selected) api.setProperty(h, "sid", MpvFormat.INT64, subs[pick].id.toDouble())
        }
        val audio = tracks("audio")
        if (externalAudio) {
            audio.firstOrNull { it.external }?.let { if (!it.selected && chosenAudioLabel == null) api.setProperty(h, "aid", MpvFormat.INT64, it.id.toDouble()) }
        }
        if (audio.size >= 2) {
            val pick = TrackLabels.chooseAudio(audio.map { it.title }, audio.map { it.lang }, chosenAudioLabel, preferredAudioLanguage)
            if (pick >= 0 && !audio[pick].selected) api.setProperty(h, "aid", MpvFormat.INT64, audio[pick].id.toDouble())
        }
    }

    // -- events --------------------------------------------------------------------------------------------------------

    /** Handles one event (waiting up to [timeoutSec]). Returns false after SHUTDOWN or when the core is gone. */
    fun pump(timeoutSec: Double): Boolean {
        val h = handle
        if (h == 0L) return false
        val ev = api.waitEvent(h, timeoutSec)
        if (ev.size < 4) return true
        when (ev[0]) {
            MpvEvent.SHUTDOWN -> {
                running = false
                return false
            }
            MpvEvent.START_FILE -> awaitingStart = false
            MpvEvent.FILE_LOADED -> {
                loaded = true
                loading = false
                onFileLoaded()
                publishState()
            }
            MpvEvent.END_FILE -> onEndFile(ev[1], ev[3])
            MpvEvent.SEEK -> {
                seeking = true
                publishState()
            }
            MpvEvent.PLAYBACK_RESTART -> {
                seeking = false
                publishState()
            }
            MpvEvent.PROPERTY_CHANGE -> onProperty(h, ev[2].toLong(), ev[3])
            else -> Unit // log messages are buffered natively
        }
        return true
    }

    private fun onEndFile(error: Int, reason: Int) {
        if (awaitingStart) return // the previous file finishing after a new load() was issued
        loaded = false
        when (reason) {
            MpvEndReason.EOF -> {
                eof = true
                loading = false
            }
            MpvEndReason.ERROR -> {
                loading = false
                val detail = api.lastLogMessages().trim().lines().filter { it.isNotBlank() }.takeLast(2).joinToString(" | ")
                events.onError(api.errorString(error) + if (detail.isEmpty()) "" else " ($detail)", error)
            }
            else -> return // STOP / QUIT / REDIRECT: our own loadfile or stop
        }
        publishState()
    }

    private fun onProperty(h: Long, userData: Long, format: Int) {
        val name = when (userData) {
            OBS_TIME_POS -> "time-pos"
            OBS_DURATION -> "duration"
            OBS_PAUSE -> "pause"
            OBS_CACHE_STALL -> "paused-for-cache"
            else -> return
        }
        if (format == MpvFormat.NONE) return // unavailable (between files): keep the last known value
        when (userData) {
            OBS_TIME_POS -> api.getProperty(h, name, MpvFormat.DOUBLE).takeUnless { it.isNaN() }?.let { positionSec = it }
            OBS_DURATION -> durationSec = api.getProperty(h, name, MpvFormat.DOUBLE).takeUnless { it.isNaN() || it < 0 } ?: durationSec
            OBS_PAUSE -> {
                userPaused = api.getProperty(h, name, MpvFormat.FLAG) > 0.5
                publishState()
            }
            OBS_CACHE_STALL -> {
                cacheStall = api.getProperty(h, name, MpvFormat.FLAG) > 0.5
                publishState()
            }
        }
    }

    private fun computeState(): String = when {
        eof -> "ended"
        !loaded -> if (loading) "buffering" else "idle"
        cacheStall || seeking -> "buffering"
        userPaused -> "paused"
        else -> "playing"
    }

    @Synchronized
    private fun publishState() {
        val s = computeState()
        if (s != lastState) {
            lastState = s
            events.onState(s)
        }
    }

    // -- teardown --------------------------------------------------------------------------------------------------------

    /** Step 1 of teardown: no more events are read after this returns. */
    fun stopEvents() {
        val h = handle
        running = false
        if (h != 0L) api.wakeup(h)
        thread?.let { if (it !== Thread.currentThread()) it.join(2000) }
        thread = null
    }

    /**
     * Step 3 of teardown (after [stopEvents], and after the render context was freed): destroys the core. The handle
     * reads 0 immediately; mpv_terminate_destroy itself can block while network streams close, so it runs on its own thread.
     */
    fun destroy(background: Boolean = true) {
        val h = handle
        if (h == 0L) return
        handle = 0
        if (background) Thread({ api.destroy(h) }, "mpv-destroy").start() else api.destroy(h)
    }

    // -- render context (called by the GL renderer on the GL thread) -------------------------------------------------------

    fun createRenderContext(): Long {
        val h = handle
        return if (h == 0L) 0L else api.renderContextCreate(h)
    }

    fun freeRenderContext(ctx: Long) {
        if (ctx != 0L) api.renderContextFree(ctx)
    }

    fun render(ctx: Long, width: Int, height: Int) {
        if (ctx != 0L) api.render(ctx, width, height)
    }

    /** Recent warnings / errors from mpv ("[prefix] text" lines), for the message when rendering cannot start. */
    fun recentLog(): String = api.lastLogMessages().trim()

    private companion object {
        const val OBS_TIME_POS = 1L
        const val OBS_DURATION = 2L
        const val OBS_PAUSE = 3L
        const val OBS_CACHE_STALL = 4L
    }
}
