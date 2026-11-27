package com.example.uzv.native_player.kernel.mpv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvCoreTest {
    private class Recorder : MpvCore.Events {
        val states = mutableListOf<String>()
        val errors = mutableListOf<Pair<String, Int?>>()
        val videoSizes = mutableListOf<Pair<Int, Int>>()
        override fun onState(state: String) { states += state }
        override fun onError(message: String, code: Int?) { errors += message to code }
        override fun onVideoSizeChanged(width: Int, height: Int) { videoSizes += width to height }
    }

    private val api = FakeMpvApi()
    private val rec = Recorder()
    private var redraws = 0
    private val core = MpvCore(api, rec) { redraws++ }

    private fun started(): MpvCore {
        assertNull(core.start(MpvOptions.initialOptions(true), startThread = false))
        api.calls.clear()
        return core
    }

    private fun pumpAll() { while (api.events.isNotEmpty()) core.pump(0.0) }

    private fun load(url: String = "http://v/1.m3u8", audio: String? = null, headers: Map<String, String> = emptyMap(), startMs: Long = 0, sidecars: List<MpvSidecar> = emptyList()) =
        core.load(url, audio, headers, startMs, sidecars)

    private fun playing() {
        load()
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
    }

    private fun track(id: Int, type: String, lang: String? = null, title: String? = null, selected: Boolean = false, def: Boolean = false, external: Boolean = false, channels: Int = 0) =
        MpvTrack(id, type, lang, title, selected, def, external, channels, 0)

    // -- start ---------------------------------------------------------------------------------------------------------

    @Test
    fun startAppliesOptionsBeforeInitializeThenObserves() {
        assertNull(core.start(listOf("vo" to "libmpv", "hwdec" to "no"), startThread = false))
        assertEquals(
            listOf(
                "create", "set:vo=libmpv", "set:hwdec=no", "initialize", "log:warn",
                "observe:1:time-pos:5", "observe:2:duration:5", "observe:3:pause:3", "observe:4:paused-for-cache:3",
            ),
            api.calls,
        )
    }

    @Test
    fun startFailuresReleaseTheHandleAndExplain() {
        api.createResult = 0
        api.logText = "[uzv_mpv] dlopen failed"
        assertTrue(core.start(emptyList(), startThread = false)!!.contains("dlopen failed"))

        val api2 = FakeMpvApi().also { it.initializeResult = -3 }
        val m = MpvCore(api2, rec).start(listOf("vo" to "libmpv"), startThread = false)
        assertEquals("mpv_initialize failed: err-3", m)
        assertTrue(api2.calls.contains("destroy"))

        val api3 = FakeMpvApi().also { it.rejectedProperties += "vo" }
        assertEquals("mpv rejected vo=libmpv: err-5", MpvCore(api3, rec).start(listOf("vo" to "libmpv"), startThread = false))
        assertTrue(api3.calls.contains("destroy"))
        assertFalse(api3.calls.contains("initialize"))
    }

    @Test
    fun anOptionMpvDoesNotKnowIsNotFatal() {
        api.rejectedProperties += "ytdl"
        assertNull(core.start(listOf("vo" to "libmpv", "ytdl" to "no"), startThread = false))
    }

    // -- load ------------------------------------------------------------------------------------------------------------

    @Test
    fun loadSetsPerFileOptionsBeforeLoadfile() {
        started()
        load(url = "http://v/a", audio = "http://v/a.m4a", headers = mapOf("User-Agent" to "UA", "Referer" to "http://r", "Cookie" to "c=1"), startMs = 12_500)
        val loadIndex = api.calls.indexOf("cmd:loadfile|http://v/a|replace|-1|start=12.500")
        assertTrue(api.calls.toString(), loadIndex > 0)
        val before = api.calls.subList(0, loadIndex)
        assertTrue(before.contains("cmd:change-list|http-header-fields|clr|"))
        assertTrue(before.contains("cmd:change-list|http-header-fields|append|Cookie: c=1"))
        assertTrue(before.contains("set:user-agent=UA"))
        assertTrue(before.contains("set:referrer=http://r"))
        assertTrue(before.contains("cmd:change-list|audio-files|clr|"))
        assertTrue(before.contains("cmd:change-list|audio-files|append|http://v/a.m4a")) // the url's colons and slashes need no quoting
        assertTrue(before.contains("set:sid=auto"))
        assertTrue(before.contains("set:aid=auto"))
        assertTrue(before.contains("setp:pause=3:0.0"))
        assertFalse(api.calls.any { it.startsWith("set:start=") }) // a global `start` was ignored by mpv 0.41
        assertEquals(listOf("buffering"), rec.states)
        assertEquals(12.5, core.positionSec, 0.0)
    }

    @Test
    fun headerValuesWithCommasAndPercentSignsAreOneItemEach() {
        started()
        load(headers = mapOf("Cookie" to "a=1,b=%5%2; c=\"x\"", "X-Two" to "y"))
        val appends = api.calls.filter { it.startsWith("cmd:change-list|http-header-fields|append|") }
        assertEquals(
            listOf("cmd:change-list|http-header-fields|append|Cookie: a=1,b=%5%2; c=\"x\"", "cmd:change-list|http-header-fields|append|X-Two: y"),
            appends,
        )
    }

    @Test
    fun loadWithoutHeadersClearsTheStickyOnesAndRestoresTheDefaultUserAgent() {
        api.strings["user-agent"] = "libmpv-default"
        started()
        load(headers = mapOf("User-Agent" to "UA", "Referer" to "http://r", "Cookie" to "c=1"), audio = "http://a/1.m4a")
        assertEquals("UA", api.strings["user-agent"])
        api.calls.clear()
        load()
        assertEquals("libmpv-default", api.strings["user-agent"]) // not "": that would be sent as an empty User-Agent
        assertEquals("", api.strings["referrer"])
        assertTrue(api.calls.contains("cmd:change-list|http-header-fields|clr|"))
        assertTrue(api.calls.contains("cmd:change-list|audio-files|clr|"))
        assertFalse(api.calls.any { it.startsWith("cmd:change-list|http-header-fields|append") || it.startsWith("cmd:change-list|audio-files|append") })
    }

    @Test
    fun userAgentAndReferrerAreLeftAloneWhenNoRequestEverSetThem() {
        started()
        load()
        load(headers = mapOf("Cookie" to "c=1"))
        assertFalse(api.calls.any { it.startsWith("set:user-agent") || it.startsWith("set:referrer") })
    }

    @Test
    fun aRejectedLoadfileIsReportedAndLeavesTheCoreIdle() {
        started()
        api.rejectedCommands += "loadfile"
        load()
        assertEquals(listOf("mpv loadfile failed: err-12" to -12), rec.errors)
        assertEquals("idle", core.state)
    }

    @Test
    fun loadBeforeStartIsIgnored() {
        load()
        assertTrue(api.calls.isEmpty())
    }

    // -- state machine ---------------------------------------------------------------------------------------------------

    @Test
    fun stateFollowsLoadPauseAndCache() {
        started()
        playing()
        assertEquals(listOf("buffering", "playing"), rec.states)
        assertTrue(core.isPlaying)

        api.numbers["pause"] = 1.0
        api.property(3, MpvFormat.FLAG)
        pumpAll()
        assertEquals("paused", core.state)

        api.numbers["paused-for-cache"] = 1.0
        api.property(4, MpvFormat.FLAG)
        pumpAll()
        assertEquals("buffering", core.state)

        api.numbers["paused-for-cache"] = 0.0
        api.numbers["pause"] = 0.0
        api.property(4, MpvFormat.FLAG)
        api.property(3, MpvFormat.FLAG)
        pumpAll()
        assertEquals(listOf("buffering", "playing", "paused", "buffering", "paused", "playing"), rec.states)
    }

    @Test
    fun statesAreOnlyReportedWhenTheyChange() {
        started()
        playing()
        api.numbers["pause"] = 0.0
        api.property(3, MpvFormat.FLAG)
        api.property(3, MpvFormat.FLAG)
        pumpAll()
        assertEquals(listOf("buffering", "playing"), rec.states)
    }

    @Test
    fun setPausedIsReflectedAtOnce() {
        started()
        playing()
        core.setPaused(true)
        assertTrue(api.calls.contains("setp:pause=3:1.0"))
        assertEquals("paused", core.state)
        core.setPaused(false)
        assertEquals("playing", core.state)
    }

    @Test
    fun endOfFileMeansEnded() {
        started()
        playing()
        api.event(MpvEvent.END_FILE, extra = MpvEndReason.EOF)
        pumpAll()
        assertEquals("ended", core.state)
        assertEquals("ended", rec.states.last())
        assertTrue(rec.errors.isEmpty())
    }

    @Test
    fun aPlaybackErrorIsReportedWithMpvsOwnWords() {
        started()
        playing()
        api.logText = "[ffmpeg] http: HTTP error 403\n[cplayer] Failed to open http://v/1.m3u8.\n"
        api.event(MpvEvent.END_FILE, error = -13, extra = MpvEndReason.ERROR)
        pumpAll()
        assertEquals(1, rec.errors.size)
        assertEquals(-13, rec.errors[0].second)
        assertEquals("err-13 ([ffmpeg] http: HTTP error 403 | [cplayer] Failed to open http://v/1.m3u8.)", rec.errors[0].first)
        assertEquals("idle", core.state)
    }

    @Test
    fun stopAndRedirectEndEventsAreIgnored() {
        started()
        playing()
        for (reason in listOf(MpvEndReason.STOP, MpvEndReason.QUIT, MpvEndReason.REDIRECT)) api.event(MpvEvent.END_FILE, extra = reason)
        pumpAll()
        assertTrue(rec.errors.isEmpty())
        assertFalse(rec.states.contains("ended"))
    }

    @Test
    fun theOldFilesEndEventAfterANewLoadDoesNotEndTheNewOne() {
        started()
        playing()
        load(url = "http://v/2.m3u8") // episode switch; mpv still delivers the old file's END_FILE first
        api.event(MpvEvent.END_FILE, extra = MpvEndReason.EOF)
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertEquals("playing", core.state)
        assertFalse(rec.states.contains("ended"))
    }

    @Test
    fun aNewLoadStartsPlayingEvenAfterEndOrPause() {
        started()
        playing()
        core.setPaused(true)
        api.event(MpvEvent.END_FILE, extra = MpvEndReason.EOF)
        pumpAll()
        load()
        assertEquals("buffering", core.state)
        assertTrue(api.calls.contains("setp:pause=3:0.0"))
    }

    @Test
    fun positionAndDurationTrackTheProperties() {
        started()
        playing()
        api.numbers["time-pos"] = 61.25
        api.property(1)
        api.numbers["duration"] = 1400.0
        api.property(2)
        pumpAll()
        assertEquals(61.25, core.positionSec, 0.0)
        assertEquals(1400.0, core.durationSec, 0.0)
        api.property(1, MpvFormat.NONE) // unavailable between files: the last value stays
        pumpAll()
        assertEquals(61.25, core.positionSec, 0.0)
    }

    @Test
    fun seekIsAbsoluteAndMovesThePositionImmediately() {
        started()
        playing()
        core.seekTo(90_500)
        assertTrue(api.calls.contains("cmd:seek|90.500|absolute"))
        assertEquals(90.5, core.positionSec, 0.0)
        assertEquals("buffering", core.state)
        api.event(MpvEvent.PLAYBACK_RESTART)
        pumpAll()
        assertEquals("playing", core.state)
    }

    @Test
    fun speedDefaultsToOneAndFollowsTheProperty() {
        started()
        assertEquals(1f, core.speed, 0f)
        core.speed = 1.5f
        assertEquals(1.5, api.numbers["speed"]!!, 0.0)
        assertEquals(1.5f, core.speed, 0f)
    }

    @Test
    fun fitModesSetKeepaspectAndPanscanAndRedraw() {
        started()
        core.setFit("zoom")
        core.setFit("fill")
        assertTrue(api.calls.containsAll(listOf("setp:keepaspect=3:1.0", "setp:panscan=5:1.0", "setp:keepaspect=3:0.0", "setp:panscan=5:0.0")))
        assertEquals(2, redraws)
    }

    // -- sidecar files and tracks ------------------------------------------------------------------------------------------

    @Test
    fun sidecarSubtitlesAreAddedAfterTheFileLoadedAndOneBadOneDoesNotStopTheRest() {
        started()
        load(sidecars = listOf(MpvSidecar("http://s/1.srt", "中文", "zh"), MpvSidecar("http://s/2.ass", null, null)))
        assertFalse(api.calls.any { it.startsWith("cmd:sub-add") })
        api.rejectedTargets += "http://s/1.srt" // the first sidecar is refused (404, unsupported format): the second must still be added
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertEquals(
            listOf("cmd:sub-add|http://s/1.srt|auto|中文|zh", "cmd:sub-add|http://s/2.ass|auto||"),
            api.calls.filter { it.startsWith("cmd:sub-add") },
        )
    }

    @Test
    fun aRefusedAudioFilesOptionFallsBackToAudioAdd() {
        started()
        api.rejectedTargets += "audio-files" // this mpv has no such option / no change-list
        load(audio = "http://a/1.m4a")
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertTrue(api.calls.contains("cmd:audio-add|http://a/1.m4a|select"))
    }

    @Test
    fun externalAudioIsSelectedWhenMpvDidNotDoItItself() {
        started()
        api.setTracks(track(1, "video", selected = true), track(1, "audio", lang = "und", selected = false, external = true), track(2, "audio", selected = true))
        load(audio = "http://a/1.m4a")
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertTrue(api.calls.contains("setp:aid=4:1.0"))
    }

    @Test
    fun defaultSubtitleIsTheFirstSidecarWhenNothingElseDecides() {
        started()
        api.setTracks(track(1, "sub", lang = "ja", title = "Embedded"), track(2, "sub", title = "Side", external = true))
        load()
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertTrue(api.calls.toString(), api.calls.contains("setp:sid=4:2.0"))
    }

    @Test
    fun asyncRemoteSidecarSubtitleAppearingByPlaybackRestartGetsSelected() {
        started()
        api.setTracks(track(1, "sub", lang = "ja", title = "Embedded", selected = true))
        load(sidecars = listOf(MpvSidecar("http://127.0.0.1:2333/sub?id=1", "中文字幕", "zh")))
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        // Remote HTTP sub-add finishes and populates track list right before PLAYBACK_RESTART:
        api.setTracks(track(1, "sub", lang = "ja", title = "Embedded", selected = true), track(2, "sub", lang = "zh", title = "中文字幕", external = true))
        api.event(MpvEvent.PLAYBACK_RESTART)
        pumpAll()
        assertTrue(api.calls.toString(), api.calls.contains("setp:sid=4:2.0"))
    }

    @Test
    fun preferredLanguageDecidesTheSubtitle() {
        started()
        core.applySubtitlePreferences("zh-CN", "Noto Sans", "/fonts")
        assertEquals("zh-CN", api.strings["slang"])
        assertEquals("Noto Sans", api.strings["sub-font"])
        assertEquals("/fonts", api.strings["sub-fonts-dir"])
        api.setTracks(track(1, "sub", lang = "en", title = "English", def = true), track(2, "sub", lang = "chi", title = "Chinese"))
        load()
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertTrue(api.calls.toString(), api.calls.contains("setp:sid=4:2.0"))
    }

    @Test
    fun theUsersSubtitleChoiceSurvivesTheNextEpisodeByLabel() {
        started()
        api.setTracks(track(1, "sub", lang = "en", title = "English", selected = true), track(2, "sub", lang = "ja", title = "Japanese"))
        core.selectSubtitle(1)
        assertTrue(api.calls.contains("setp:sid=4:2.0"))
        // next episode: tracks come in another order and mpv's own choice is track 1
        api.setTracks(track(1, "sub", lang = "ja", title = "Japanese"), track(2, "sub", lang = "en", title = "English", selected = true))
        api.calls.clear()
        load()
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertTrue(api.calls.toString(), api.calls.contains("setp:sid=4:1.0"))
    }

    @Test
    fun subtitlesTurnedOffStayOffForTheNextEpisode() {
        started()
        api.setTracks(track(1, "sub", lang = "en", title = "English", def = true))
        core.selectSubtitle(-1)
        assertEquals("no", api.strings["sid"])
        assertFalse(core.subtitlesEnabled)
        api.calls.clear()
        load()
        assertTrue(api.calls.contains("set:sid=no"))
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertFalse(api.calls.any { it.startsWith("setp:sid") })
        core.selectSubtitle(0)
        assertTrue(api.calls.contains("setp:sid=4:1.0"))
        load()
        assertTrue(api.calls.last { it.startsWith("set:sid=") } == "set:sid=auto")
    }

    @Test
    fun subtitleListUsesReadableLabels() {
        started()
        api.setTracks(track(1, "video", selected = true), track(1, "sub", lang = "eng", title = "Commentary", selected = true), track(2, "sub", lang = "jpn"), track(3, "sub"))
        val subs = core.subtitleTracks()
        assertEquals(listOf("Commentary · English", "Japanese", "Subtitle 3"), subs.map { it.label })
        assertEquals(listOf(true, false, false), subs.map { it.selected })
        assertTrue(core.subtitlesEnabled)
    }

    @Test
    fun audioTrackSelectionAndPreference() {
        started()
        core.applyAudioPreference("ja")
        assertEquals("ja", api.strings["alang"])
        api.setTracks(
            track(1, "audio", lang = "zho", title = "国语", selected = true, channels = 2),
            track(2, "audio", lang = "jpn", title = "日语", channels = 6),
        )
        load()
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertTrue(api.calls.toString(), api.calls.contains("setp:aid=4:2.0"))
        assertTrue(core.audioAuto)

        assertEquals(listOf("国语 · Chinese · stereo", "日语 · Japanese · 5.1"), core.audioTracks().map { it.label })
        core.selectAudio(0)
        assertFalse(core.audioAuto)
        assertTrue(api.calls.contains("setp:aid=4:1.0"))
        core.selectAudio(-1)
        assertTrue(core.audioAuto)
        assertEquals("auto", api.strings["aid"])
    }

    @Test
    fun aSingleAudioTrackIsLeftAlone() {
        started()
        api.setTracks(track(1, "audio", lang = "jpn", selected = true))
        load()
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertFalse(api.calls.any { it.startsWith("setp:aid") })
    }

    // -- teardown and render context -------------------------------------------------------------------------------------------

    @Test
    fun teardownStopsEventsThenDestroysAndLaterCallsAreNoOps() {
        started()
        core.stopEvents()
        assertEquals(listOf("wakeup"), api.calls)
        core.destroy(background = false)
        assertEquals(listOf("wakeup", "destroy"), api.calls)
        assertEquals(0L, core.handle)
        api.calls.clear()
        load()
        core.setPaused(true)
        core.seekTo(1000)
        core.setFit("zoom")
        core.selectSubtitle(0)
        core.destroy(background = false)
        assertTrue(api.calls.isEmpty())
        assertFalse(core.pump(0.0))
    }

    @Test
    fun shutdownEventEndsThePump() {
        started()
        api.event(MpvEvent.SHUTDOWN)
        assertFalse(core.pump(0.0))
    }

    @Test
    fun renderContextCallsPassThroughOnlyForLiveContexts() {
        started()
        assertEquals(77L, core.createRenderContext())
        core.render(77, 1280, 720)
        core.render(0, 1, 1)
        core.freeRenderContext(77)
        core.freeRenderContext(0)
        assertEquals(listOf("rcreate", "render:77:1280x720", "rfree:77"), api.calls)
    }

    // OBSERVED in the original (g2.g.m / g2.g.l): the speed is mpv's `cache-speed` (bytes/s), the bitrate `video-bitrate`
    // (bits/s); NaN (property not available) means unknown.
    @Test
    fun downloadSpeedAndBitrateComeFromMpvProperties() {
        started()
        assertNull("nothing loaded yet", core.downloadSpeed())
        load()
        api.numbers["cache-speed"] = 1024.0
        assertEquals("live speed visible while initial buffering before FILE_LOADED", 1024L, core.downloadSpeed())
        api.numbers.remove("cache-speed")
        playing()
        assertNull(core.downloadSpeed())
        assertNull(core.videoBitrate())
        api.numbers["cache-speed"] = 2048.0
        api.numbers["video-bitrate"] = 1_500_000.0
        assertEquals(2048L, core.downloadSpeed())
        assertEquals(1_500_000L, core.videoBitrate())
    }

    @Test
    fun theEventThreadRunsAndStopsCleanly() {
        val api2 = FakeMpvApi()
        val c = MpvCore(api2, rec)
        assertNull(c.start(emptyList()))
        api2.event(MpvEvent.FILE_LOADED)
        api2.numbers["time-pos"] = 5.0
        api2.property(1)
        val deadline = System.currentTimeMillis() + 3000
        while (c.positionSec != 5.0 && System.currentTimeMillis() < deadline) Thread.sleep(5)
        assertEquals(5.0, c.positionSec, 0.0)
        c.stopEvents()
        c.destroy(background = false)
        assertTrue(api2.calls.contains("destroy"))
    }

    @Test
    fun mediaInfoPrefersDisplayParamsAndEmitsOnLoadAndVideoReconfig() {
        started()
        api.numbers["video-params/w"] = 1920.0
        api.numbers["video-params/h"] = 1080.0
        api.numbers["video-params/rotate"] = 90.0
        load(url = "http://v/1.mp4")
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertEquals(1080 to 1920, core.mediaInfo()?.let { it.width to it.height })
        assertEquals(listOf(1080 to 1920), rec.videoSizes)

        // Same size on VIDEO_RECONFIG does not duplicate
        api.event(MpvEvent.VIDEO_RECONFIG)
        pumpAll()
        assertEquals(listOf(1080 to 1920), rec.videoSizes)

        // video-out-params/dw,dh wins over video-params/dw,dh and w,h
        api.numbers["video-params/dw"] = 1080.0
        api.numbers["video-params/dh"] = 1920.0
        api.numbers["video-out-params/dw"] = 720.0
        api.numbers["video-out-params/dh"] = 1280.0
        api.event(MpvEvent.VIDEO_RECONFIG)
        pumpAll()
        assertEquals(720 to 1280, core.mediaInfo()?.let { it.width to it.height })
        assertEquals(listOf(1080 to 1920, 720 to 1280), rec.videoSizes)

        // New load resets lastVideoSize so the next file emits again
        load(url = "http://v/2.mp4")
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertEquals(listOf(1080 to 1920, 720 to 1280, 720 to 1280), rec.videoSizes)
    }

    @Test
    fun mediaInfoAppliesRotateToOutParamsAndDemuxRotationBeforeReconfig() {
        started()
        // At FILE_LOADED before VIDEO_RECONFIG, only w/h and demux-rotation are populated.
        api.numbers["video-params/w"] = 1280.0
        api.numbers["video-params/h"] = 720.0
        api.numbers["current-tracks/video/demux-rotation"] = 270.0
        load(url = "http://v/rot270.mp4")
        api.event(MpvEvent.START_FILE)
        api.event(MpvEvent.FILE_LOADED)
        pumpAll()
        assertEquals(720 to 1280, core.mediaInfo()?.let { it.width to it.height })

        // Even though libmpv keeps dwidth/dheight and dw/dh unrotated, video-out-params/rotate swaps them cleanly.
        api.numbers["dwidth"] = 1280.0
        api.numbers["dheight"] = 720.0
        api.numbers["video-out-params/dw"] = 1280.0
        api.numbers["video-out-params/dh"] = 720.0
        api.numbers["video-out-params/rotate"] = 270.0
        api.event(MpvEvent.VIDEO_RECONFIG)
        pumpAll()
        assertEquals(720 to 1280, core.mediaInfo()?.let { it.width to it.height })
        assertEquals(listOf(720 to 1280), rec.videoSizes)
    }

    @Test
    fun eventsFakeWithoutVideoSizeOverrideCompilesAndRuns() {
        val minEvents = object : MpvCore.Events {
            override fun onState(state: String) {}
            override fun onError(message: String, code: Int?) {}
        }
        val api2 = FakeMpvApi().apply {
            numbers["video-out-params/dw"] = 1280.0
            numbers["video-out-params/dh"] = 720.0
        }
        val c = MpvCore(api2, minEvents)
        assertNull(c.start(emptyList(), startThread = false))
        c.load("http://v/1.mp4", null, emptyMap(), 0, emptyList())
        api2.event(MpvEvent.START_FILE)
        api2.event(MpvEvent.FILE_LOADED)
        c.pump(0.0)
        c.pump(0.0)
        assertEquals(1280 to 720, c.mediaInfo()?.let { it.width to it.height })
    }

    @Test
    fun probeVideoSizeWaitsForOutParamsReconfigAndReturnsDisplaySize() {
        var now = 0L
        val base = FakeMpvApi().apply {
            numbers["video-params/w"] = 720.0
            numbers["video-params/h"] = 720.0
            event(MpvEvent.START_FILE)
            event(MpvEvent.FILE_LOADED)
        }
        var reconfigured = false
        val probeApi = object : MpvApi by base {
            override fun waitEvent(handle: Long, timeoutSeconds: Double): IntArray {
                now += 10_000_000L
                val ev = base.waitEvent(handle, timeoutSeconds)
                if (ev[0] == MpvEvent.FILE_LOADED && !reconfigured) {
                    reconfigured = true
                    base.numbers["video-out-params/dw"] = 405.0
                    base.numbers["video-out-params/dh"] = 720.0
                    base.event(MpvEvent.VIDEO_RECONFIG)
                }
                return ev
            }
        }

        val size = MpvCore.probeVideoSize(
            probeApi,
            "http://v/LandscapeOrSar.m3u8",
            emptyMap(),
            timeoutMs = 2_000L,
            settleMs = 150L,
            nowNs = { now },
        )
        assertEquals(405 to 720, size)
        assertTrue(base.calls.contains("set:vo=null"))
        assertTrue(base.calls.contains("cmd:loadfile|http://v/LandscapeOrSar.m3u8|replace|-1|start=0.000"))
    }

    @Test
    fun probeVideoSizeSettlesWithoutOutParamsAndRespectsCancel() {
        var now = 0L
        var step = 0
        val api2 = FakeMpvApi().apply {
            numbers["video-params/w"] = 1280.0
            numbers["video-params/h"] = 720.0
            event(MpvEvent.START_FILE)
            event(MpvEvent.FILE_LOADED)
        }
        val settled = MpvCore.probeVideoSize(
            api2,
            "http://v/landscape.m3u8",
            emptyMap(),
            timeoutMs = 2_000L,
            settleMs = 150L,
            nowNs = { now.also { if (step++ > 2) now += 60_000_000L } },
        )
        assertEquals(1280 to 720, settled)

        val rejected = FakeMpvApi().apply { rejectedProperties += "vo" }
        assertNull(MpvCore.probeVideoSize(rejected, "http://v/1.m3u8", emptyMap(), nowNs = { 0L }))

        var cancelFn: (() -> Unit)? = null
        val cancelledApi = FakeMpvApi()
        var polls = 0
        val cancelledResult = MpvCore.probeVideoSize(
            cancelledApi,
            "http://v/slow.m3u8",
            emptyMap(),
            timeoutMs = 2_000L,
            nowNs = { if (polls++ == 2) cancelFn?.invoke(); polls * 1_000_000L },
            registerCancel = { cancelFn = it },
        )
        assertNull(cancelledResult)
        assertTrue(cancelledApi.calls.contains("wakeup"))
    }

    @Test
    fun requestStopWakesHandleWithoutDestroyingIt() {
        started()
        core.requestStop()
        assertEquals(listOf("wakeup"), api.calls)
        assertTrue(core.handle != 0L)
    }
}
