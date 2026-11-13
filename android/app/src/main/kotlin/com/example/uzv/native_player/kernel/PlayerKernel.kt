package com.example.uzv.native_player.kernel

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.MergingMediaSource
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import androidx.media3.ui.SubtitleView
import com.example.uzv.native_player.SubtitleOption

/** What the activity needs from a decoding back end. The shipped app has two: Exo and MPV (changelog 1.1.11). */
interface PlayerKernel {
    val view: View
    val positionMs: Long
    val durationMs: Long
    var speed: Float

    /** 'fit' | 'fill' | 'zoom' (PlaybackConfig.fitMode). */
    var fitMode: String
    val isPlaying: Boolean
    fun load(url: String, audioUrl: String?, headers: Map<String, String>, startMs: Long, subtitles: List<SubtitleOption> = emptyList())

    /** Text tracks of the current media (embedded and sidecar), in the order [selectSubtitle] indexes them. */
    fun subtitleTracks(): List<TrackOption>

    /** Index into [subtitleTracks], or -1 for "off". */
    fun selectSubtitle(index: Int)
    val subtitlesEnabled: Boolean

    /** Adaptive video variants of the current media (HLS/DASH), best first; indexes match [selectVideo]. */
    fun videoTracks(): List<TrackOption>

    /** Index into [videoTracks], or -1 for automatic adaptive selection. */
    fun selectVideo(index: Int)
    val videoAuto: Boolean

    /** Audio tracks of the current media (several languages / commentary), in the order [selectAudio] indexes them. */
    fun audioTracks(): List<TrackOption>

    /** Index into [audioTracks], or -1 for the player's own choice. */
    fun selectAudio(index: Int)
    val audioAuto: Boolean

    /** Preferred audio language (PlaybackConfig.audioLang); null = none. */
    fun applyAudioPreference(language: String?)

    /** Subtitle look and language preference (PlaybackConfig.subtitle*). */
    fun applySubtitlePreferences(language: String?, fontFamily: String?, fontsDir: String?)
    fun play()
    fun pause()
    fun seekTo(ms: Long)
    fun release()
    var listener: Listener?

    /** Size, frame rate and codec of the playing video, or null before the first frame is known. */
    fun mediaInfo(): MediaInfo? = null

    /** Download speed in bytes/s, or null when unknown (OBSERVED in the original: mpv `cache-speed`; Exo: bandwidth estimate / 8, http(s) only). */
    fun downloadSpeed(): Long? = null

    /** Video bitrate in bits/s, or null when unknown (mpv `video-bitrate`; Exo: the video format's bitrate). */
    fun videoBitrate(): Long? = null

    interface Listener {
        fun onState(state: String) // idle | buffering | playing | paused | ended
        fun onError(message: String, code: Int?)
    }
}

class ExoKernel(private val context: Context) : PlayerKernel {
    private val bandwidth = DefaultBandwidthMeter.Builder(context).build()
    private val player = ExoPlayer.Builder(context)
        .setBandwidthMeter(bandwidth)
        .setWakeMode(C.WAKE_MODE_NETWORK)
        .build()
    private var currentUrl = ""
    private val playerView = PlayerView(context).also {
        it.player = player
        it.useController = false
        it.keepScreenOn = true
    }
    override val view: View get() = playerView
    override var listener: PlayerKernel.Listener? = null

    private var preferredTextLanguage: String? = null

    /** Label of the track the user picked last; looked up again after every load (see [applyDefaultTextOnce]). */
    private var chosenTextLabel: String? = null
    private var textAutoApplied = false

    private var preferredAudioLanguage: String? = null
    private var chosenAudioLabel: String? = null
    private var audioAutoApplied = false

    init {
        player.addListener(object : Player.Listener {
            override fun onTracksChanged(tracks: Tracks) {
                applyDefaultTextOnce()
                applyPreferredAudioOnce()
            }

            override fun onPlaybackStateChanged(state: Int) {
                syncState()
            }

            override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                syncState()
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (player.playbackState == Player.STATE_READY) syncState()
            }

            override fun onPlayerError(error: PlaybackException) {
                listener?.onError("ExoPlayer 播放失败 [${error.errorCodeName}] ${error.message.orEmpty()}".trim(), error.errorCode)
            }
        })
    }

    private fun syncState() {
        listener?.onState(
            when (player.playbackState) {
                Player.STATE_BUFFERING -> "buffering"
                Player.STATE_ENDED -> "ended"
                Player.STATE_READY -> if (player.playWhenReady) "playing" else "paused"
                else -> "idle"
            },
        )
    }

    override fun mediaInfo(): MediaInfo? {
        val f = player.videoFormat ?: return null
        if (f.width <= 0 || f.height <= 0) return null
        val codec = f.sampleMimeType ?: f.codecs // PlayerUiText.codecName turns it into H.264 / HEVC / …
        return MediaInfo(f.width, f.height, if (f.frameRate > 0) f.frameRate.toDouble() else 0.0, codec)
    }

    override fun downloadSpeed(): Long? {
        val scheme = Uri.parse(currentUrl).scheme?.lowercase()
        if (scheme != "http" && scheme != "https") return null
        return bandwidth.bitrateEstimate.takeIf { it > 0 }?.div(8)
    }

    override fun videoBitrate(): Long? = player.videoFormat?.bitrate?.takeIf { it > 0 }?.toLong()

    override val positionMs get() = player.currentPosition
    override val durationMs get() = player.duration.coerceAtLeast(0)
    override var speed: Float
        get() = player.playbackParameters.speed
        set(v) = player.setPlaybackSpeed(v)
    override val isPlaying get() = player.isPlaying
    override var fitMode: String = "fit"
        set(v) {
            field = v
            playerView.resizeMode = when (v) {
                "fill" -> AspectRatioFrameLayout.RESIZE_MODE_FILL
                "zoom" -> AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                else -> AspectRatioFrameLayout.RESIZE_MODE_FIT
            }
        }

    override fun load(url: String, audioUrl: String?, headers: Map<String, String>, startMs: Long, subtitles: List<SubtitleOption>) {
        // Overrides outlive the media item. Drop them so "auto" really is the state of the new item; the "text off"
        // switch (setTrackTypeDisabled) is kept on purpose: someone who turned subtitles off wants them off next episode too.
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .clearOverridesOfType(C.TRACK_TYPE_VIDEO)
            .clearOverridesOfType(C.TRACK_TYPE_TEXT)
            .clearOverridesOfType(C.TRACK_TYPE_AUDIO)
            .build()
        textAutoApplied = false
        audioAutoApplied = false
        currentUrl = url

        val http = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setDefaultRequestProperties(headers)
            .setTransferListener(bandwidth)
        // DefaultDataSource also reads file:// (downloaded episodes) and content:// besides http(s).
        val factory = DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http).setTransferListener(bandwidth))
        var first = true
        val sidecars = subtitles.mapNotNull { s ->
            val mime = TrackLabels.subtitleMime(s.url, s.mimeType) ?: return@mapNotNull null // unknown format: Exo could not parse it
            MediaItem.SubtitleConfiguration.Builder(Uri.parse(s.url))
                .setMimeType(mime)
                .setLanguage(s.language)
                .setLabel(s.name)
                .setSelectionFlags(if (first) C.SELECTION_FLAG_DEFAULT else 0)
                .build()
                .also { first = false }
        }
        val item = MediaItem.Builder().setUri(url).setSubtitleConfigurations(sidecars).build()
        val video: MediaSource = factory.createMediaSource(item)
        // DASH sources with a separate audio stream: merge so the video is not silent (changelog 1.1.0).
        val source = if (audioUrl.isNullOrEmpty()) video else MergingMediaSource(video, factory.createMediaSource(MediaItem.fromUri(audioUrl)))
        player.setMediaSource(source, startMs)
        player.prepare()
        player.playWhenReady = true
    }

    // -- subtitles ----------------------------------------------------------------------------
    private fun textEntries(): List<Pair<Tracks.Group, Int>> =
        player.currentTracks.groups.filter { it.type == C.TRACK_TYPE_TEXT }
            .flatMap { g -> (0 until g.length).filter { g.isTrackSupported(it) }.map { g to it } }

    override val subtitlesEnabled: Boolean
        get() = !player.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT) &&
            textEntries().any { (g, i) -> g.isTrackSelected(i) }

    override fun subtitleTracks(): List<TrackOption> = textEntries().mapIndexed { n, (g, i) ->
        val f = g.getTrackFormat(i)
        TrackOption(TrackLabels.textLabel(f.label, f.language, n), g.isTrackSelected(i), f.language)
    }

    override fun selectSubtitle(index: Int) {
        // "Off" needs no memory: setTrackTypeDisabled persists on its own. A track is remembered by label (and, via
        // preferredTextLanguage, by language) because the overrides are cleared on every load.
        chosenTextLabel = if (index < 0) chosenTextLabel else textEntries().getOrNull(index)?.let { (g, i) -> g.getTrackFormat(i).label }
        applyText(index)
    }

    private fun applyText(index: Int) {
        val b = player.trackSelectionParameters.buildUpon()
        if (index < 0) {
            b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, true)
        } else {
            val (g, i) = textEntries().getOrNull(index) ?: return
            b.setTrackTypeDisabled(C.TRACK_TYPE_TEXT, false).setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, i))
        }
        player.trackSelectionParameters = b.build()
    }

    /**
     * Exo shows no sidecar subtitle unless told to, and `load` clears the overrides, so after every load (new episode,
     * quality switch) the track is chosen again: the one the user picked (by label), else the preferred language, else
     * the default-flagged one. If the user turned subtitles off, they stay off.
     */
    private fun applyDefaultTextOnce() {
        if (textAutoApplied) return
        if (player.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_TEXT)) return
        val entries = textEntries()
        if (entries.isEmpty()) return
        textAutoApplied = true
        val formats = entries.map { (g, i) -> g.getTrackFormat(i) }
        val pick = TrackLabels.chooseDefaultText(
            formats.map { it.label },
            formats.map { it.language },
            formats.map { it.selectionFlags and C.SELECTION_FLAG_DEFAULT != 0 },
            chosenTextLabel,
            preferredTextLanguage,
        )
        if (pick >= 0) applyText(pick)
    }

    override fun applySubtitlePreferences(language: String?, fontFamily: String?, fontsDir: String?) {
        preferredTextLanguage = language?.takeIf { it.isNotBlank() }
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setPreferredTextLanguage(preferredTextLanguage)
            .build()
        val typeface = TrackLabels.findFont(fontsDir, fontFamily)?.let { runCatching { Typeface.createFromFile(it) }.getOrNull() }
            ?: fontFamily?.takeIf { it.isNotBlank() }?.let { Typeface.create(it, Typeface.NORMAL) }
        playerView.subtitleView?.apply {
            setStyle(CaptionStyleCompat(Color.WHITE, Color.TRANSPARENT, Color.TRANSPARENT, CaptionStyleCompat.EDGE_TYPE_OUTLINE, Color.BLACK, typeface))
            setApplyEmbeddedStyles(true) // Exo's SSA/ASS parser is basic (no libass): colours and simple positions only
            setApplyEmbeddedFontSizes(true)
            setFractionalTextSize(SubtitleView.DEFAULT_TEXT_SIZE_FRACTION)
        }
    }

    // -- audio tracks -------------------------------------------------------------------------
    private fun audioEntries(): List<Pair<Tracks.Group, Int>> =
        player.currentTracks.groups.filter { it.type == C.TRACK_TYPE_AUDIO }
            .flatMap { g -> (0 until g.length).filter { g.isTrackSupported(it) }.map { g to it } }

    override val audioAuto: Boolean
        get() = player.trackSelectionParameters.overrides.values.none { it.type == C.TRACK_TYPE_AUDIO }

    override fun audioTracks(): List<TrackOption> = audioEntries().mapIndexed { n, (g, i) ->
        val f = g.getTrackFormat(i)
        TrackOption(TrackLabels.audioLabel(f.label, f.language, f.channelCount, n), g.isTrackSelected(i), f.language)
    }

    override fun selectAudio(index: Int) {
        chosenAudioLabel = if (index < 0) null else audioEntries().getOrNull(index)?.let { (g, i) -> g.getTrackFormat(i).label }
        applyAudio(index)
    }

    private fun applyAudio(index: Int) {
        val b = player.trackSelectionParameters.buildUpon()
        if (index < 0) {
            b.clearOverridesOfType(C.TRACK_TYPE_AUDIO)
        } else {
            val (g, i) = audioEntries().getOrNull(index) ?: return
            b.setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, i))
        }
        player.trackSelectionParameters = b.build()
    }

    /** `load` clears the overrides, so a chosen track is looked up again (label, then language) once the tracks are known. */
    private fun applyPreferredAudioOnce() {
        if (audioAutoApplied) return
        val entries = audioEntries()
        if (entries.size < 2) return // nothing to choose between yet
        audioAutoApplied = true
        val formats = entries.map { (g, i) -> g.getTrackFormat(i) }
        val pick = TrackLabels.chooseAudio(formats.map { it.label }, formats.map { it.language }, chosenAudioLabel, preferredAudioLanguage)
        if (pick >= 0 && !entries[pick].let { (g, i) -> g.isTrackSelected(i) }) applyAudio(pick)
    }

    override fun applyAudioPreference(language: String?) {
        preferredAudioLanguage = language?.takeIf { it.isNotBlank() }
        player.trackSelectionParameters = player.trackSelectionParameters.buildUpon()
            .setPreferredAudioLanguage(preferredAudioLanguage)
            .build()
    }

    // -- adaptive video quality ---------------------------------------------------------------
    // One ordering for both listing and selection: sorted in only one of them would make a tap hit the wrong track.
    private fun videoEntries(): List<Pair<Tracks.Group, Int>> =
        player.currentTracks.groups.filter { it.type == C.TRACK_TYPE_VIDEO }
            .flatMap { g -> (0 until g.length).filter { g.isTrackSupported(it) }.map { g to it } }
            .sortedWith(
                compareByDescending<Pair<Tracks.Group, Int>> { (g, i) -> g.getTrackFormat(i).height }
                    .thenByDescending { (g, i) -> g.getTrackFormat(i).bitrate },
            )

    override val videoAuto: Boolean
        get() = player.trackSelectionParameters.overrides.values.none { it.type == C.TRACK_TYPE_VIDEO }

    override fun videoTracks(): List<TrackOption> = videoEntries().mapIndexed { n, (g, i) ->
        val f = g.getTrackFormat(i)
        TrackOption(TrackLabels.videoLabel(f.height, f.bitrate, n), !videoAuto && g.isTrackSelected(i))
    }

    override fun selectVideo(index: Int) {
        val b = player.trackSelectionParameters.buildUpon()
        if (index < 0) {
            b.clearOverridesOfType(C.TRACK_TYPE_VIDEO)
        } else {
            val (g, i) = videoEntries().getOrNull(index) ?: return
            b.setOverrideForType(TrackSelectionOverride(g.mediaTrackGroup, i))
        }
        player.trackSelectionParameters = b.build()
    }

    override fun play() { player.play() }
    override fun pause() { player.pause() }
    override fun seekTo(ms: Long) {
        listener?.onState("buffering")
        player.seekTo(ms)
    }
    override fun release() { player.release() }
}
