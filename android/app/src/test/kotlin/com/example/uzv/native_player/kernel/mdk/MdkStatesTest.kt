package com.example.uzv.native_player.kernel.mdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MdkStatesTest {
    private val loading = 2
    private val loaded = 4
    private val prepared = 256
    private val buffering = 16
    private val buffered = 32
    private val end = 64
    private val invalid = Int.MIN_VALUE

    @Test
    fun statesFollowTheMediaStatusFirst() {
        assertEquals("ended", MdkStates.kernelState(0, loaded or prepared or end))
        assertEquals("buffering", MdkStates.kernelState(1, loading))
        assertEquals("buffering", MdkStates.kernelState(1, loaded or prepared or buffering))
        assertEquals("playing", MdkStates.kernelState(1, loaded or prepared or buffering or buffered))
        assertEquals("paused", MdkStates.kernelState(2, loaded or prepared or buffered))
        assertEquals("idle", MdkStates.kernelState(0, loaded))
        assertEquals("idle", MdkStates.kernelState(1, invalid))
    }

    /** OBSERVED fit modes of the page ('fit' | 'fill' | 'zoom') map onto MDK's aspect values. */
    @Test
    fun aspectValues() {
        assertEquals(1.1920929e-7f, MdkStates.aspect("fit")) // C's FLT_EPSILON (0x34000000), MDK's KeepAspectRatio
        assertEquals(0f, MdkStates.aspect("fill"))
        assertEquals(-1.1920929e-7f, MdkStates.aspect("zoom"))
    }

    @Test
    fun trackMetadataGivesLanguageAndTitle() {
        assertEquals(mapOf("language" to "chi", "title" to "简体"), MdkStates.metadata("language=chi\ttitle=简体"))
        assertEquals(emptyMap<String, String>(), MdkStates.metadata(""))
        assertEquals("简体 (chi)", MdkStates.trackLabel(mapOf("language" to "chi", "title" to "简体"), 0))
        assertEquals("chi", MdkStates.trackLabel(mapOf("language" to "chi"), 0))
        assertEquals("Track 2", MdkStates.trackLabel(emptyMap(), 1))
    }

    /** `Name: value` lines for avio.headers, as ffmpeg's http protocol expects them. */
    @Test
    fun headersJoinWithCrLf() {
        assertEquals("Referer: https://a/\r\nUser-Agent: UA\r\n", MdkStates.headers(linkedMapOf("Referer" to "https://a/", "User-Agent" to "UA")))
        assertNull(MdkStates.headers(emptyMap()))
    }
}
