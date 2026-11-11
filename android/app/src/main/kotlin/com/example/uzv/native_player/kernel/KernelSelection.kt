package com.example.uzv.native_player.kernel

/**
 * Which back end to build for `PlaybackConfig.kernel` ('exo' | 'mpv' | 'mdk'). Pure, so it is unit-tested.
 *
 * OBSERVED: UZN 1.1.7 on the phone offers MPV (MPV) / MDK (MDK) / EXO (SYSTEM); 1.1.13 offers Exo / MPV. A kernel whose
 * native library cannot be loaded falls back to Exo and says why, once.
 */
object KernelSelection {
    enum class Kernel(val id: String, val label: String) { EXO("exo", "Exo"), MPV("mpv", "MPV"), MDK("mdk", "MDK") }

    class Choice(val kernel: Kernel, val notice: String?)

    fun parse(requested: String?): Kernel = Kernel.entries.firstOrNull { it.id.equals(requested?.trim(), ignoreCase = true) } ?: Kernel.EXO

    /** [available] and [unavailableReason] are only asked about the requested kernel, and never about Exo. */
    fun choose(requested: String?, available: (Kernel) -> Boolean, unavailableReason: (Kernel) -> String): Choice {
        val k = parse(requested)
        if (k == Kernel.EXO || available(k)) return Choice(k, null)
        return Choice(Kernel.EXO, fallbackNotice(k, unavailableReason(k)))
    }

    fun fallbackNotice(kernel: Kernel, reason: String?): String =
        "${kernel.label} kernel unavailable, using Exo" + if (reason.isNullOrBlank()) "" else " ($reason)"
}
