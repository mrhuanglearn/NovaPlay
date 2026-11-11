package com.example.uzv.native_player.kernel.mdk

/** Pure mappings between MDK's values and what the page uses. Unit-tested. */
object MdkStates {
    // MDK_MediaStatus flags (MDK C API)
    private const val LOADING = 2
    private const val LOADED = 4
    internal const val BUFFERING = 16
    internal const val BUFFERED = 32
    private const val END = 64
    const val INVALID = Int.MIN_VALUE

    /** idle | buffering | playing | paused | ended, from MDK's state (0 stopped, 1 playing, 2 paused) and media status. */
    fun kernelState(state: Int, status: Int): String = when {
        status and INVALID != 0 -> "idle"
        status and END != 0 -> "ended"
        status and LOADING != 0 && status and LOADED == 0 -> "buffering"
        status and BUFFERING != 0 && status and BUFFERED == 0 -> "buffering"
        state == 1 -> "playing"
        state == 2 -> "paused"
        else -> "idle"
    }

    /**
     * MDK's setAspectRatio: KeepAspectRatio (FLT_EPSILON) for 原比例, KeepAspectRatioCrop (-FLT_EPSILON) for 裁剪, 0 to
     * stretch. OBSERVED in libmdk.so (0.38, from UZN 1.1.7): VideoRenderer::redraw stretches for 0, compares the value
     * with 0x34000000 / 0xB4000000 (±FLT_EPSILON) for keep / crop, and takes any other value as the ratio itself. FLT_MIN
     * and Float.MIN_VALUE, tried before, were such ratios: the 2D scale came out as (0, 1) and the picture was black while
     * the sound played (phone, 2026-11-10, MDK log "update transform 2d. scale: (0.000000, 1.000000)").
     */
    fun aspect(fitMode: String): Float = when (fitMode) {
        "fill" -> 0f
        "zoom" -> -FLT_EPSILON
        else -> FLT_EPSILON
    }

    private const val FLT_EPSILON = 1.1920929e-7f // Math.ulp(1f)

    fun metadata(text: String): Map<String, String> =
        text.split('\t').filter { '=' in it }.associate { it.substringBefore('=') to it.substringAfter('=') }

    fun trackLabel(meta: Map<String, String>, index: Int): String {
        val lang = meta["language"]?.takeIf { it.isNotBlank() && it != "und" }
        val title = meta["title"]?.takeIf { it.isNotBlank() }
        return when {
            title != null && lang != null -> "$title ($lang)"
            title != null -> title
            lang != null -> lang
            else -> "Track ${index + 1}"
        }
    }

    /** avio.headers (OBSERVED property name in UZN 1.1.7's Dart code): `Name: value\r\n` per header. */
    fun headers(headers: Map<String, String>): String? =
        if (headers.isEmpty()) null else headers.entries.joinToString("") { "${it.key}: ${it.value}\r\n" }
}
