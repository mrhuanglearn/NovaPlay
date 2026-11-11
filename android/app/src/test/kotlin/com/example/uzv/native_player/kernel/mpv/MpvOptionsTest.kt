package com.example.uzv.native_player.kernel.mpv

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MpvOptionsTest {
    @Test
    fun headersSplitIntoThreeOptions() {
        val o = MpvOptions.headerOptions(
            linkedMapOf("User-Agent" to "UA/1", "referer" to "https://r/", "Cookie" to "a=b", "X-Token" to "t"),
        )
        assertEquals("UA/1", o.userAgent)
        assertEquals("https://r/", o.referrer)
        assertEquals(listOf("Cookie: a=b", "X-Token: t"), o.fields)
    }

    @Test
    fun headerValuesCannotInjectLines() {
        val o = MpvOptions.headerOptions(linkedMapOf("X-A" to "v\r\nEvil: 1", "Bad:Name" to "z", "" to "skipped", "  " to "skipped too"))
        assertEquals(listOf("X-A: v  Evil: 1", "BadName: z"), o.fields)
        assertNull(o.userAgent)
        assertNull(o.referrer)
    }

    @Test
    fun startValueIsSecondsWithMilliseconds() {
        assertEquals("0.000", MpvOptions.startValue(0))
        assertEquals("12.500", MpvOptions.startValue(12_500))
        assertEquals("0.000", MpvOptions.startValue(-5))
        assertEquals("3661.001", MpvOptions.startValue(3_661_001))
    }

    @Test
    fun fitModes() {
        assertEquals(true to 0.0, MpvOptions.fit("fit"))
        assertEquals(false to 0.0, MpvOptions.fit("fill"))
        assertEquals(true to 1.0, MpvOptions.fit("zoom"))
        assertEquals(true to 0.0, MpvOptions.fit("anything else"))
    }

    @Test
    fun initialOptionsPutRenderApiFirstAndFollowHwDecode() {
        val on = MpvOptions.initialOptions(true)
        assertEquals("vo" to "libmpv", on.first())
        assertEquals("mediacodec-copy", on.toMap()["hwdec"])
        assertEquals("no", MpvOptions.initialOptions(false).toMap()["hwdec"])
    }

    @Test
    fun parseTracksReadsEveryField() {
        val p = mapOf(
            "track-list/count" to "3",
            "track-list/0/id" to "1", "track-list/0/type" to "video", "track-list/0/selected" to "yes", "track-list/0/demux-h" to "1080",
            "track-list/1/id" to "2", "track-list/1/type" to "audio", "track-list/1/lang" to "jpn", "track-list/1/title" to "Main",
            "track-list/1/selected" to "yes", "track-list/1/default" to "yes", "track-list/1/demux-channel-count" to "6",
            "track-list/2/id" to "1", "track-list/2/type" to "sub", "track-list/2/lang" to "", "track-list/2/external" to "yes",
        )
        val t = MpvOptions.parseTracks { p[it] }
        assertEquals(3, t.size)
        assertEquals(MpvTrack(1, "video", null, null, true, false, false, 0, 1080), t[0])
        assertEquals(MpvTrack(2, "audio", "jpn", "Main", true, true, false, 6, 0), t[1])
        assertEquals(MpvTrack(1, "sub", null, null, false, false, true, 0, 0), t[2])
    }

    @Test
    fun parseTracksSurvivesMissingData() {
        assertTrue(MpvOptions.parseTracks { null }.isEmpty())
        assertTrue(MpvOptions.parseTracks { if (it == "track-list/count") "x" else null }.isEmpty())
        // entry 0 has no id, entry 1 no type: both skipped, no exception
        val p = mapOf("track-list/count" to "2", "track-list/0/type" to "audio", "track-list/1/id" to "5")
        assertTrue(MpvOptions.parseTracks { p[it] }.isEmpty())
    }
}
