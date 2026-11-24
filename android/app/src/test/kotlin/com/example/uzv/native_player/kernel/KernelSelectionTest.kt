package com.example.uzv.native_player.kernel

import com.example.uzv.native_player.kernel.KernelSelection.Kernel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class KernelSelectionTest {
    private fun never(k: Kernel): String = error("must not be asked about $k")

    @Test
    fun exoIsDefaultAndNeverAsksAboutTheOthers() {
        for (requested in listOf("exo", "", null, "something")) {
            val c = KernelSelection.choose(requested, { error("must not be asked") }, ::never)
            assertEquals(Kernel.EXO, c.kernel)
            assertNull(c.notice)
        }
    }

    @Test
    fun mpvAndMdkWhenRequestedAndAvailable() {
        assertEquals(Kernel.MPV, KernelSelection.choose("MPV", { it == Kernel.MPV }, ::never).kernel)
        val mdk = KernelSelection.choose("mdk", { it == Kernel.MDK }, ::never)
        assertEquals(Kernel.MDK, mdk.kernel)
        assertNull(mdk.notice)
    }

    @Test
    fun anUnavailableKernelFallsBackToExoWithTheReason() {
        val c = KernelSelection.choose("mpv", { false }) { "dlopen(libmpv.so) failed: not found" }
        assertEquals(Kernel.EXO, c.kernel)
        assertEquals("MPV kernel unavailable, using Exo (dlopen(libmpv.so) failed: not found)", c.notice)
        val m = KernelSelection.choose("mdk", { false }) { "libmdk.so is only shipped for arm64-v8a" }
        assertEquals(Kernel.EXO, m.kernel)
        assertEquals("MDK kernel unavailable, using Exo (libmdk.so is only shipped for arm64-v8a)", m.notice)
        assertEquals("MPV kernel unavailable, using Exo", KernelSelection.fallbackNotice(Kernel.MPV, " "))
    }

    @Test
    fun runtimeFallbackOrderTriesEveryOtherKernelOnce() {
        assertEquals(listOf(Kernel.MPV, Kernel.MDK), KernelSelection.fallbackOrder(Kernel.EXO))
        assertEquals(listOf(Kernel.EXO, Kernel.MDK), KernelSelection.fallbackOrder(Kernel.MPV))
        assertEquals(listOf(Kernel.MPV, Kernel.EXO), KernelSelection.fallbackOrder(Kernel.MDK))
    }

    @Test
    fun blurayAndLegacyExtensionsRequireFfmpegKernel() {
        assertTrue(KernelSelection.requiresFfmpegKernel("http://127.0.0.1:2333/uzv-iso/0123456789abcdef/main.m2ts"))
        assertTrue(KernelSelection.requiresFfmpegKernel("https://cdn.example/disc/movie.ISO?sig=1"))
        assertTrue(KernelSelection.requiresFfmpegKernel("http://127.0.0.1:2333/uzv-iso/0123456789abcdef/main.vob|User-Agent=x"))
        assertFalse(KernelSelection.requiresFfmpegKernel("https://cdn.example/live/index.m3u8"))
        assertFalse(KernelSelection.requiresFfmpegKernel("https://cdn.example/vod/movie.mp4"))
        assertFalse(KernelSelection.requiresFfmpegKernel("http://127.0.0.1:2333/proxy/4kzn/3/stream?r=abc"))
    }
}
