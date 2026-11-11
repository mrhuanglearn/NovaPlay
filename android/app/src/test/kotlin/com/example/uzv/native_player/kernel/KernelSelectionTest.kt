package com.example.uzv.native_player.kernel

import com.example.uzv.native_player.kernel.KernelSelection.Kernel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
