package com.example.uzv.native_player.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DanmakuTimelineTest {
    @Test
    fun `forward seek skips past intermediate danmaku instead of spraying them`() {
        val times = LongArray(100) { (it * 1_000).toLong() } // 0s..99s
        // Normal playback tick (1000ms -> 1200ms): null = keep advancing normally
        assertNull(DanmakuTimeline.seekTargetCursor(times, lastPosMs = 1_000, posMs = 1_200, nowMs = 1_200))

        // Forward seek from 2s to 60s: jumps straight to >= 60s (index 60)
        val fwd = DanmakuTimeline.seekTargetCursor(times, lastPosMs = 2_000, posMs = 60_000, nowMs = 60_000)
        assertEquals(60, fwd)

        // Backward seek from 60s to 5s: rewinds to index 5
        val bwd = DanmakuTimeline.seekTargetCursor(times, lastPosMs = 60_000, posMs = 5_000, nowMs = 5_000)
        assertEquals(5, bwd)
    }

    @Test
    fun `shouldScheduleVsync stops completely when paused, disabled, or idle with no comments`() {
        assertFalse(DanmakuTimeline.shouldScheduleVsync(attached = true, paused = true, enabled = true, activeCount = 5, hasUpcoming = true))
        assertFalse(DanmakuTimeline.shouldScheduleVsync(attached = true, paused = false, enabled = false, activeCount = 5, hasUpcoming = true))
        assertFalse(DanmakuTimeline.shouldScheduleVsync(attached = true, paused = false, enabled = true, activeCount = 0, hasUpcoming = false))
        assertTrue(DanmakuTimeline.shouldScheduleVsync(attached = true, paused = false, enabled = true, activeCount = 1, hasUpcoming = false))
    }

    @Test
    fun `idleWaitMs sleeps instead of burning 120fps vsync when screen is empty and next comment is far away`() {
        // Active comment on screen -> 0ms (run on next vsync)
        assertEquals(0L, DanmakuTimeline.idleWaitMs(activeCount = 2, nextCommentMs = 10_000L, nowMs = 1_000L))
        // Empty screen, next comment in 10s -> sleep (capped at 500ms so seeks/speed changes react quickly)
        assertEquals(500L, DanmakuTimeline.idleWaitMs(activeCount = 0, nextCommentMs = 10_000L, nowMs = 1_000L))
        // Empty screen, next comment in 120ms -> 0ms (tick on vsync right before spawn)
        assertEquals(0L, DanmakuTimeline.idleWaitMs(activeCount = 0, nextCommentMs = 1_120L, nowMs = 1_000L))
    }
}
