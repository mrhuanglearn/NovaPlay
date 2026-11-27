package com.example.uzv.native_player

import com.example.uzv.native_player.kernel.resolveVideoDisplaySize
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NativePlayerLaunchTest {
    @Test
    fun resolveInitialLandscapeRespectsModeProbedSizeAndLandscapeFallback() {
        assertTrue(resolveInitialLandscape("landscape", isPhone = true, probedSize = 720 to 1280))
        assertFalse(resolveInitialLandscape("portrait", isPhone = true, probedSize = 1920 to 1080))
        assertFalse(resolveInitialLandscape("portrait", isPhone = false, probedSize = 1920 to 1080))

        // auto on handheld phone adapts immediately when format is known; when unknown, prioritizes landscape.
        assertTrue(resolveInitialLandscape("auto", isPhone = true, probedSize = 1920 to 1080))
        assertTrue(resolveInitialLandscape("auto", isPhone = true, probedSize = 1080 to 1080))
        assertFalse(resolveInitialLandscape("auto", isPhone = true, probedSize = 1080 to 1920))
        assertTrue(resolveInitialLandscape("auto", isPhone = true, probedSize = null))

        // auto on non-handheld (tablet) always starts landscape
        assertTrue(resolveInitialLandscape("auto", isPhone = false, probedSize = 720 to 1280))
        assertTrue(resolveInitialLandscape("auto", isPhone = false, probedSize = null))
    }

    @Test
    fun extractSourceSizeValidatesPositiveDimensions() {
        assertNull(extractSourceSize(null))
        assertNull(extractSourceSize(SourcePayload(requestId = 1, success = true)))
        assertNull(extractSourceSize(SourcePayload(requestId = 1, success = true, videoWidth = 0, videoHeight = 1080)))
        assertNull(extractSourceSize(SourcePayload(requestId = 1, success = true, videoWidth = 1080, videoHeight = -1)))
        assertEquals(
            1080 to 1920,
            extractSourceSize(SourcePayload(requestId = 1, success = true, videoWidth = 1080, videoHeight = 1920)),
        )
    }

    @Test
    fun extractInitialRequestSizePrefersEpisodeSourceAndFallsBackToVodHint() {
        val pb = PlaybackConfig(
            hwDecode = true,
            fitMode = "fit",
            speed = 1.0,
            longPressSpeed = 2.0,
            fastForwardSeconds = 10,
            autoPictureInPicture = true,
            pauseOnBackground = false,
            isPriorityLandscape = true,
            isHiddenFastSeekBtn = false,
            isShowStatsBar = false,
            isShowAllDuration = false,
            isShowEpisodeSwitchNotice = true,
            showNetSpeed = true,
            hapticEnabled = true,
            skipNotice = true,
            kernel = "exo",
            orientationMode = "auto",
        )
        val dm = DanmakuConfig(
            enabled = true,
            opacity = 1.0,
            fontSize = 18.0,
            scrollSpeed = 1.0,
            area = 0.5,
            colorMode = "original",
            gradientStyle = "none",
            showTop = true,
            showBottom = true,
            delaySeconds = 0.0,
            lineHeight = 1.2,
            strokeWidth = 1.0,
            blackList = emptyList(),
        )
        fun req(src: SourcePayload? = null, vw: Long? = null, vh: Long? = null) = OpenPlayerRequest(
            sessionId = "s1",
            title = "t",
            isMovie = false,
            lines = emptyList(),
            episodes = emptyList(),
            playbackConfig = pb,
            danmakuConfig = dm,
            startPositionSeconds = 0,
            startLineIndex = 0,
            startEpisodeIndex = 0,
            initialSource = src,
            initialVideoWidth = vw,
            initialVideoHeight = vh,
        )

        assertNull(extractInitialRequestSize(req()))
        assertNull(extractInitialRequestSize(req(vw = 0, vh = 1920)))
        assertEquals(720 to 1280, extractInitialRequestSize(req(vw = 720, vh = 1280)))
        assertEquals(
            1920 to 1080,
            extractInitialRequestSize(
                req(
                    src = SourcePayload(requestId = 1, success = true, videoWidth = 1920, videoHeight = 1080),
                    vw = 720,
                    vh = 1280,
                ),
            ),
        )
    }

    @Test
    fun resolveVideoDisplaySizeHandlesRotationSarAndInvalidDimensions() {
        assertNull(resolveVideoDisplaySize(0, 1080))
        assertNull(resolveVideoDisplaySize(1920, -1))
        assertEquals(1920 to 1080, resolveVideoDisplaySize(1920, 1080, 1f, 0))
        assertEquals(1080 to 1920, resolveVideoDisplaySize(1920, 1080, 1f, 90))
        assertEquals(1080 to 1920, resolveVideoDisplaySize(1920, 1080, 1f, -90))
        assertEquals(1080 to 1920, resolveVideoDisplaySize(1920, 1080, 1f, 270))
        assertEquals(1080 to 1080, resolveVideoDisplaySize(720, 1080, 1.5f, 90))
        assertEquals(1440 to 1080, resolveVideoDisplaySize(1080, 1080, 4f / 3f, 360))
        assertEquals(1080 to 1920, resolveVideoDisplaySize(1080, 1920, Float.NaN, 0))
        assertEquals(1080 to 1920, resolveVideoDisplaySize(1080, 1920, 0f, -180))
    }

    @Test
    fun parseHeadTailHandlesNullSafely() {
        val empty = PlayerController.parseHeadTail(null)
        assertEquals(0L, empty.introEndMs)
        assertEquals(0L, empty.outroBeforeEndMs)
        assertTrue(empty.ranges.isEmpty())
    }

    @Test
    fun computePipAspectRatioPrefersDecodedSizeThenFallbackLastVideoSizeAndClampsBounds() {
        // Unknown both -> 16:9 landscape fallback
        assertEquals(16 to 9, computePipAspectRatio(decodedSize = null, fallbackSize = null))
        assertEquals(16 to 9, computePipAspectRatio(decodedSize = 0 to 0, fallbackSize = -1 to 1080))

        // Before first frame decode (decodedSize == null), vertical probed/remembered size is used instead of 16:9!
        assertEquals(1080 to 1920, computePipAspectRatio(decodedSize = null, fallbackSize = 1080 to 1920))
        assertEquals(720 to 1280, computePipAspectRatio(decodedSize = 0 to 0, fallbackSize = 720 to 1280))

        // Once decoded frame is available, decodedSize wins over stale fallback
        assertEquals(1920 to 1080, computePipAspectRatio(decodedSize = 1920 to 1080, fallbackSize = 1080 to 1920))

        // Extreme ratios clamped to Android PiP [100/239, 239/100] bounds
        assertEquals(100 to 239, computePipAspectRatio(decodedSize = null, fallbackSize = 100 to 400))
        assertEquals(239 to 100, computePipAspectRatio(decodedSize = 400 to 100, fallbackSize = null))
    }

    @Test
    fun resolveEpisodeResetLandscapePreservesPortraitSeriesInsteadOfFlashingLandscape() {
        // Portrait series after manual rotation cycle must stay/restore portrait (false), NOT flash landscape!
        assertFalse(resolveEpisodeResetLandscape(1080 to 1920))
        assertFalse(resolveEpisodeResetLandscape(720 to 1280))

        // Landscape or square series restores sensor landscape (true)
        assertTrue(resolveEpisodeResetLandscape(1920 to 1080))
        assertTrue(resolveEpisodeResetLandscape(1080 to 1080))

        // Unknown / invalid previous size falls back to landscape first
        assertTrue(resolveEpisodeResetLandscape(null))
        assertTrue(resolveEpisodeResetLandscape(0 to 1920))
    }
}
