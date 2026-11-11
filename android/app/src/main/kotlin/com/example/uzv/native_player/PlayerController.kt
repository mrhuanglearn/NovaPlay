package com.example.uzv.native_player

import android.os.Handler
import android.os.Looper
import com.example.uzv.native_player.kernel.PlayerKernel
import com.example.uzv.native_player.kernel.TrackOption
import com.example.uzv.native_player.ui.DanmakuView
import com.example.uzv.native_player.ui.PlayerUiText
import org.json.JSONArray

/**
 * Playback state machine for one session. Mirrors the ask/answer protocol of the Pigeon API:
 * the controller asks Dart for an episode URL (`onEpisodeRequest`) and continues in [onSource].
 */
class PlayerController(
    private val request: OpenPlayerRequest,
    val kernel: PlayerKernel,
    private val danmakuView: DanmakuView,
    private val onClose: () -> Unit,
) : PlayerKernel.Listener {
    private val api get() = NativePlayerHost.flutterApi
    private val main = Handler(Looper.getMainLooper())
    var line = 0
        private set
    var episode = 0
        private set
    /**
     * Index of the source-level quality asked from Dart (SourcePayload.qualities). Survives episode changes and starts
     * from the one the watch history remembers (`startQualityIndex`).
     */
    var quality = request.startQualityIndex?.toInt()?.coerceAtLeast(0) ?: 0
        private set
    var qualityNames: List<String> = emptyList()
        private set
    private var requestId = 0
    private var pendingStartMs = request.startPositionSeconds * 1000L
    private var playback = request.playbackConfig
    private var danmaku = request.danmakuConfig
    private var closed = false

    /** 片头片尾 of this video: where the intro ends, and how long before the end the outro starts (0 = not marked). */
    private var introEndMs = 0L
    private var outroBeforeEndMs = 0L
    private var outroDone = false
    private val skipRanges = ArrayList<Pair<Long, Long>>()
    private var lastSkippedRangeIndex = -1

    /** Subtitles added with 加载字幕… for the episode that is playing. */
    private val extraSubtitles = ArrayList<SubtitleOption>()
    private var lastPayload: SourcePayload? = null

    private val heartbeat = object : Runnable {
        override fun run() {
            if (closed) return
            api.onHeartbeat(Heartbeat(request.sessionId, kernel.positionMs / 1000.0, kernel.durationMs / 1000.0)) {}
            maybeSkipOutro()
            main.postDelayed(this, 1000)
        }
    }

    init {
        kernel.listener = this
        kernel.fitMode = playback.fitMode
        applyTrackPreferences()
        danmakuView.configure(danmaku)
    }

    private fun applyTrackPreferences() {
        kernel.applySubtitlePreferences(playback.subtitleLang, playback.subtitleFontFamily, playback.subtitleFontsDir)
        kernel.applyAudioPreference(playback.audioLang)
    }

    /** What the controls show; set by the activity. Always called on the main thread. */
    interface UiListener {
        /** Episode, line, quality list or settings changed. */
        fun onChanged()

        /** A short notice at the top (正在切换至 第2集, 已跳过片段). */
        fun onNotice(text: String)

        /** A system toast (OBSERVED in 1.1.13: i2.P0.F is Toast.makeText(…, LENGTH_SHORT)); [long] for 3.5 s. */
        fun onToast(text: String, long: Boolean = false)
    }

    var uiListener: UiListener? = null

    /** idle | buffering | playing | paused | ended, as last reported by the kernel. */
    var state = "idle"
        private set

    /**
     * The message of the error layer, null while it is not shown. OBSERVED in 1.1.13: a failed episode request (W0.c.n)
     * and a kernel error (c2.K.t) both open it (i2.P0.A). Before 2026-11-10 neither was shown here, so a source that
     * failed (e.g. a cloud-drive login that ran out) left the page spinning at 0.0 KB/s for ever.
     */
    var error: String? = null
        private set

    /** The last request or the kernel failed and nothing is loading: no spinner, even after 取消 closed the layer. */
    var failed = false
        private set

    /** A source of this page reached the kernel at least once. */
    private var loaded = false

    private fun showError(message: String) {
        if (closed) return
        error = message
        failed = true
        uiListener?.onChanged()
    }

    /** 取消 on the error layer. */
    fun dismissError() {
        if (error == null) return
        error = null
        uiListener?.onChanged()
    }

    /** 重试 on the error layer: the same episode again, from where it stopped (or from where the page was to start). */
    fun retry() {
        error = null
        if (kernel.positionMs > 0) pendingStartMs = kernel.positionMs
        requestEpisode(line, episode, refreshDanmaku = false)
    }

    /** A toast a script sent while this page covers the app (DartActions.toast; the Flutter one would be hidden). */
    fun toast(message: String, long: Boolean) = main.post { if (!closed) uiListener?.onToast(message, long) }

    /**
     * Speed chosen in the player (starts at 播放器设置 → 默认倍速, or at the speed of the page this one replaces after a
     * kernel switch); a long press returns to it.
     */
    var currentSpeed = NativePlayerHost.takeCarriedSpeed() ?: playback.speed
        private set

    init {
        kernel.speed = currentSpeed.toFloat()
    }

    val playbackConfig get() = playback
    val hasPrevious get() = episode > 0
    val hasNext get() = episode + 1 < episodeNames().size
    val episodeName get() = episodeNames().getOrNull(episode)
    val qualityName get() = qualityNames.getOrNull(quality)
    val episodeCount get() = episodeNames().size

    fun setSpeed(v: Double) {
        currentSpeed = v
        kernel.speed = v.toFloat()
        uiListener?.onChanged()
    }

    /** 画面填充 chosen in the player is kept as the 播放器设置 value too. */
    fun setFitMode(mode: String) = updatePlayback(playback.copy(fitMode = mode))

    /**
     * A change made in the player's 设置 panel: applied to what is playing, saved as the 播放器设置 value (reported to Dart,
     * which writes player_config.json) and shown. Kernel / hardware decoding are applied by reloading the page instead
     * (see [reloadRequest]).
     */
    fun updatePlayback(next: PlaybackConfig) {
        val old = playback
        if (next == old) return
        playback = next
        if (old.fitMode != next.fitMode) kernel.fitMode = next.fitMode
        // a new default speed applies at once unless the speed was changed in the player
        if (old.speed != next.speed && currentSpeed == old.speed) {
            currentSpeed = next.speed
            kernel.speed = next.speed.toFloat()
        }
        if (old.subtitleLang != next.subtitleLang || old.audioLang != next.audioLang ||
            old.subtitleFontFamily != next.subtitleFontFamily || old.subtitleFontsDir != next.subtitleFontsDir
        ) applyTrackPreferences()
        reportPreferences()
        uiListener?.onChanged()
    }

    /** The request for a page that continues this one (same line, episode, quality and position) with [next]. */
    fun reloadRequest(next: PlaybackConfig = playback): OpenPlayerRequest = request.copy(
        playbackConfig = next,
        danmakuConfig = danmaku,
        startPositionSeconds = kernel.positionMs / 1000,
        startLineIndex = line.toLong(),
        startEpisodeIndex = episode.toLong(),
        startQualityIndex = quality.toLong(),
    )

    /** Stops this controller without telling Dart the page closed: another page takes over the same session. */
    fun detach() {
        if (closed) return
        closed = true
        main.removeCallbacks(heartbeat)
        kernel.release()
    }

    /** 播放器设置 → 切集提示: 正在切换至 第X集 when another episode starts. */
    private fun announceEpisode(index: Int, lineIndex: Int = line) {
        if (!playback.isShowEpisodeSwitchNotice) return
        val name = episodeNames(lineIndex).getOrNull(index) ?: return
        uiListener?.onNotice(PlayerUiText.switchingTo(name))
    }

    val autoPictureInPicture get() = playback.autoPictureInPicture
    val pauseOnBackground get() = playback.pauseOnBackground
    val title get() = request.title
    val danmakuEnabled get() = danmaku.enabled

    /** Episode list of the line that is playing now. Falls back to the request-level list for single-line requests. */
    fun episodeNames(lineIndex: Int = line): List<String> =
        (request.lines.getOrNull(lineIndex)?.episodes?.takeIf { it.isNotEmpty() } ?: request.episodes).map { it.episodeName }

    fun lineNames(): List<String> = request.lines.map { it.lineName }

    /** Set by the activity; invoked on the main thread when Dart answers a danmaku search / episode lookup. */
    var danmakuSearchListener: ((List<DanmakuSearchResultItem>) -> Unit)? = null
    var danmakuEpisodesListener: ((List<EpisodeItem>) -> Unit)? = null
    var danmakuCountListener: ((Int) -> Unit)? = null
    var onSkipIntro: ((Long) -> Unit)? = null
    var tmdbMatches: List<TmdbEpisodeItem> = request.tmdbEpisodes?.filterNotNull().orEmpty()
        private set
    val isLive: Boolean get() = request.epgProgrammes != null
    val epgProgrammes: List<EpgProgramme> get() = request.epgProgrammes?.filterNotNull().orEmpty()
    val loadedDanmakuCount: Int get() = danmakuView.commentCount

    fun start() {
        requestEpisode(request.startLineIndex.toInt(), request.startEpisodeIndex.toInt())
        main.postDelayed(heartbeat, 1000)
    }

    /** [refreshDanmaku] is false when only the quality changes: same episode, same comments. */
    fun requestEpisode(lineIndex: Int, episodeIndex: Int, refreshDanmaku: Boolean = true) {
        line = lineIndex
        episode = episodeIndex
        error = null
        failed = false
        outroDone = false
        if (refreshDanmaku) extraSubtitles.clear()
        val id = ++requestId
        api.onEpisodeRequest(EpisodeRequest(request.sessionId, id.toLong(), lineIndex.toLong(), episodeIndex.toLong(), quality.toLong())) {}
        if (refreshDanmaku) api.onDanmakuRequest(DanmakuRequest(request.sessionId, lineIndex.toLong(), episodeIndex.toLong())) {}
        uiListener?.onChanged()
    }

    /** Source-level quality: same episode, another URL. Dart resolves it again with the new index. */
    fun selectQuality(index: Int) {
        if (index !in qualityNames.indices || index == quality) return
        quality = index
        pendingStartMs = kernel.positionMs
        requestEpisode(line, episode, refreshDanmaku = false)
    }

    fun nextEpisode(): Boolean {
        val next = episode + 1
        if (next >= episodeNames().size) return false
        pendingStartMs = 0
        announceEpisode(next)
        requestEpisode(line, next)
        return true
    }

    fun previousEpisode(): Boolean {
        val prev = episode - 1
        if (prev < 0) return false
        pendingStartMs = 0
        announceEpisode(prev)
        requestEpisode(line, prev)
        return true
    }

    fun selectEpisode(index: Int) {
        if (index !in episodeNames().indices) return
        pendingStartMs = 0
        if (index != episode) announceEpisode(index)
        requestEpisode(line, index)
    }

    /** An episode picked in 选集 on another line: that line, that episode, from its start. */
    fun selectLineEpisode(lineIndex: Int, index: Int) {
        if (lineIndex !in request.lines.indices || index !in episodeNames(lineIndex).indices) return
        pendingStartMs = 0
        announceEpisode(index, lineIndex)
        requestEpisode(lineIndex, index)
    }

    /** Switching line keeps the episode number when the new line has it, otherwise starts at the first episode. */
    fun selectLine(index: Int) {
        if (index !in request.lines.indices || index == line) return
        val count = request.lines[index].episodes.size
        pendingStartMs = if (count > episode) kernel.positionMs else 0
        requestEpisode(index, if (count > episode) episode else 0)
    }

    // -- answers from Dart ----------------------------------------------------------------------
    fun onSource(payload: SourcePayload) = main.post {
        if (payload.requestId != requestId.toLong()) return@post // stale answer from a previous request
        if (!payload.success || payload.url == null) {
            // OBSERVED in 1.1.13 (W0.c.n): a toast with the message, then the error layer, except for a quality that
            // 未匹配 while an earlier source plays: that one keeps playing.
            val message = PlayerUiText.sourceFailed(payload.errorMessage)
            api.onErrorReported(ErrorReport(request.sessionId, message, true, null)) {}
            uiListener?.onToast(PlayerUiText.errorDetail(message))
            if (loaded && message.contains("未匹配")) { kernel.play(); return@post }
            showError(message)
            return@post
        }
        loaded = true
        qualityNames = payload.qualities.orEmpty().sortedBy { it.qualityIndex }.map { it.qualityName }
        // Dart clamps the index it was asked for; keep our remembered one in range too
        if (qualityNames.isNotEmpty()) quality = quality.coerceIn(0, qualityNames.size - 1)
        uiListener?.onChanged()
        lastPayload = payload
        // 跳过片头: an episode that would start inside the marked intro starts where it ends
        var start = pendingStartMs
        if (introEndMs > 0 && start < introEndMs) {
            val fromMs = start
            start = introEndMs
            if (playback.skipNotice) {
                uiListener?.onNotice(PlayerUiText.t("已跳过片头", "Intro skipped"))
                onSkipIntro?.invoke(fromMs)
            }
        }
        kernel.load(payload.url!!, payload.audioUrl, payload.headers.orEmpty(), start, payload.subtitles.orEmpty() + extraSubtitles)
        pendingStartMs = 0
    }

    /** 加载字幕…: the playing source again, at the same position, with one more subtitle (which becomes the shown one). */
    fun addSubtitle(url: String, name: String): Boolean {
        val payload = lastPayload ?: return false
        extraSubtitles.removeAll { it.url == url }
        extraSubtitles += SubtitleOption(url, name)
        kernel.load(payload.url!!, payload.audioUrl, payload.headers.orEmpty(), kernel.positionMs, payload.subtitles.orEmpty() + extraSubtitles)
        main.postDelayed({
            if (closed) return@postDelayed
            val i = kernel.subtitleTracks().indexOfLast { it.label.contains(name) }
            if (i >= 0) kernel.selectSubtitle(i)
        }, 1500)
        return true
    }

    fun onDanmaku(payload: DanmakuPayload) = main.post {
        val arr = JSONArray(payload.commentsJson)
        danmakuView.setComments((0 until arr.length()).map { arr.getJSONObject(it) }.map {
            DanmakuView.Comment(it.getDouble("t"), it.getInt("m"), it.getInt("c"), it.getString("x"))
        })
        danmakuCountListener?.invoke(danmakuView.commentCount)
    }

    fun onTmdbMatches(matches: List<TmdbEpisodeItem>) = main.post {
        tmdbMatches = matches
        uiListener?.onChanged()
    }
    fun onDanmakuSearchResults(results: List<DanmakuSearchResultItem>) = main.post { danmakuSearchListener?.invoke(results) }
    fun onDanmakuEpisodes(episodes: List<EpisodeItem>) = main.post { danmakuEpisodesListener?.invoke(episodes) }

    fun onRuntimeConfig(patch: RuntimeConfigPatch) = main.post {
        patch.playbackConfig?.let {
            playback = it
            currentSpeed = it.speed
            kernel.speed = it.speed.toFloat()
            kernel.fitMode = it.fitMode
            applyTrackPreferences()
            uiListener?.onChanged()
        }
        patch.danmakuConfig?.let { danmaku = it; danmakuView.configure(it) }
    }

    // -- user actions ---------------------------------------------------------------------------
    fun togglePause() { if (kernel.isPlaying) kernel.pause() else kernel.play() }
    fun seekTo(ms: Long) {
        val target = ms.coerceIn(0, kernel.durationMs)
        state = "buffering"
        uiListener?.onChanged()
        kernel.seekTo(target)
    }
    fun seekBy(deltaSeconds: Int) = seekTo(kernel.positionMs + deltaSeconds * 1000L)

    // -- subtitles / adaptive quality (answered by the kernel; nothing goes through Dart) -------------
    fun subtitleOptions(): List<TrackOption> = kernel.subtitleTracks()
    val subtitlesEnabled get() = kernel.subtitlesEnabled

    /** [index] -1 = off. Choosing a track that declares a language remembers it as the preferred subtitle language. */
    fun selectSubtitle(index: Int) {
        kernel.selectSubtitle(index)
        val lang = subtitleOptions().getOrNull(index)?.language?.takeIf { it.isNotBlank() } ?: return
        if (lang == playback.subtitleLang) return
        playback = playback.copy(subtitleLang = lang)
        applyTrackPreferences()
        reportPreferences()
    }

    fun audioOptions(): List<TrackOption> = kernel.audioTracks()
    val audioAuto get() = kernel.audioAuto

    /**
     * [index] -1 = the player's own choice, which also forgets the preferred audio language. A track that declares a
     * language becomes the preferred one (reported so it is kept); one that does not is only remembered by its label
     * inside the kernel, for the rest of this player.
     */
    fun selectAudio(index: Int) {
        kernel.selectAudio(index)
        val lang = if (index < 0) null else audioOptions().getOrNull(index)?.language?.takeIf { it.isNotBlank() }
        if (index >= 0 && lang == null) return
        if (lang == playback.audioLang) return
        playback = playback.copy(audioLang = lang)
        applyTrackPreferences()
        reportPreferences()
    }

    fun videoOptions(): List<TrackOption> = kernel.videoTracks()
    val videoAuto get() = kernel.videoAuto
    fun selectVideo(index: Int) = kernel.selectVideo(index)

    // -- danmaku panel (all answers come back through the listeners above) ------------------------
    fun danmakuPrompt(callback: (DanmakuPromptInfo?) -> Unit) {
        api.getDanmakuPromptInfo(request.sessionId) { r -> main.post { callback(r.getOrNull()) } }
    }

    fun searchDanmaku(keyword: String) { api.onDanmakuSearchRequest(DanmakuSearchRequest(request.sessionId, keyword)) {} }
    fun pickDanmakuAnime(animeId: Long) { api.onDanmakuEpisodesRequest(request.sessionId, animeId) {} }

    /** Dart resolves [index] against the anime picked last (same convention as the automatic request). */
    fun pickDanmakuEpisode(index: Int) {
        api.onDanmakuRequest(DanmakuRequest(request.sessionId, line.toLong(), index.toLong())) {}
    }

    fun setDanmakuEnabled(on: Boolean) {
        danmaku = danmaku.copy(enabled = on)
        danmakuView.configure(danmaku)
        reportPreferences()
    }

    val danmakuConfig get() = danmaku

    /** A change made in 弹幕 → 样式调节: shown at once; [save] false while a slider is still being dragged. */
    fun updateDanmaku(next: DanmakuConfig, save: Boolean = true) {
        danmaku = next
        danmakuView.configure(next)
        if (save) reportPreferences()
    }

    fun reportPreferences() {
        api.onPreferenceReported(PreferenceReport(request.sessionId, playback, danmaku)) {}
    }

    // -- kernel events --------------------------------------------------------------------------
    override fun onState(state: String) {
        main.post {
            this.state = state
            if (state == "playing") { failed = false; dismissError() } // the kernel got going again
            danmakuView.paused = state != "playing"
            uiListener?.onChanged()
            api.onStateChanged(StateEvent(request.sessionId, state)) {}
            if (state == "ended" && !nextEpisode()) close(completed = true)
        }
    }

    /** Kernels raise this only for errors that stop playback (OBSERVED in 1.1.13: c2.K.t opens the error layer). */
    override fun onError(message: String, code: Int?) {
        api.onErrorReported(ErrorReport(request.sessionId, message, false, code?.toLong())) {}
        main.post { showError(message) }
    }

    /**
     * 跳过片尾 (changelog 1.1.12: 播放到片尾结束点将直接切换至下一集): at the marked outro the next episode starts. The last
     * episode plays on to its end.
     */
    private fun maybeSkipOutro() {
        val pos = kernel.positionMs
        val dur = kernel.durationMs
        if (dur <= 0 || state != "playing") return
        for (i in skipRanges.indices) {
            val (startMs, endMs) = skipRanges[i]
            if (pos in startMs until endMs && lastSkippedRangeIndex != i) {
                lastSkippedRangeIndex = i
                kernel.seekTo(endMs)
                if (playback.skipNotice) {
                    uiListener?.onNotice(PlayerUiText.t("已跳过片段", "Section skipped"))
                    onSkipIntro?.invoke(pos)
                }
                return
            } else if (pos < startMs || pos >= endMs + 2000) {
                if (lastSkippedRangeIndex == i) lastSkippedRangeIndex = -1
            }
        }
        if (outroDone || outroBeforeEndMs <= 0) return
        val at = dur - outroBeforeEndMs
        if (at <= introEndMs || pos < at) return
        outroDone = true
        if (!hasNext) return
        // 播放器设置 → 跳过提示: a banner when a marked section is skipped
        if (playback.skipNotice) uiListener?.onNotice(PlayerUiText.t("已跳过片尾", "Outro skipped"))
        nextEpisode()
    }

    /**
     * 片头片尾 arrive as JSON from Dart (`headTailSectionsJson`):
     * `[{"type":"intro","endMs":N}, {"type":"outro","beforeEndMs":M}, {"type":"range","startMs":S,"endMs":E}]` (see lib/features/player/head_tail.dart).
     */
    fun applyHeadTail() {
        val json = request.headTailSectionsJson ?: return
        val arr = try { JSONArray(json) } catch (e: org.json.JSONException) { return }
        skipRanges.clear()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            when (o.optString("type")) {
                "intro" -> introEndMs = o.optLong("endMs")
                "outro" -> outroBeforeEndMs = o.optLong("beforeEndMs")
                "range" -> {
                    val s = o.optLong("startMs")
                    val e = o.optLong("endMs")
                    if (e > s && s >= 0) skipRanges.add(s to e)
                }
            }
        }
    }

    /** 记片头 / 记片尾 are offered for anything with a length (not for live channels). */
    val canMarkHeadTail get() = !isLive && kernel.durationMs > 0

    /** 记片头: the intro of this video ends here. */
    fun markIntro() {
        val pos = kernel.positionMs
        if (pos <= 0) return
        introEndMs = pos
        api.onHeadTailMarked(request.sessionId, "intro", pos / 1000.0) {}
        uiListener?.onToast(PlayerUiText.introMarked(pos))
    }

    /** 记片尾: the outro starts here, kept as time before the end; the next episode starts at once when there is one. */
    fun markOutro() {
        val dur = kernel.durationMs
        val before = dur - kernel.positionMs
        if (dur <= 0 || before <= 0) return
        outroBeforeEndMs = before
        outroDone = false
        api.onHeadTailMarked(request.sessionId, "outro", before / 1000.0) {}
        uiListener?.onToast(PlayerUiText.outroMarked(before))
    }

    fun close(completed: Boolean = false, finishActivity: Boolean = true) {
        if (closed) return
        closed = true
        main.removeCallbacks(heartbeat)
        api.onPageClosed(PageClosedEvent(request.sessionId, kernel.positionMs / 1000.0, completed)) {}
        kernel.release()
        if (finishActivity) onClose()
    }
}
