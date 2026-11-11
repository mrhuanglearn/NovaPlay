package com.example.uzv.native_player.kernel.mpv

import java.util.Locale

/** One entry of mpv's `track-list`. */
data class MpvTrack(
    val id: Int,
    val type: String, // "video" | "audio" | "sub"
    val lang: String?,
    val title: String?,
    val selected: Boolean,
    val isDefault: Boolean,
    val external: Boolean,
    val channels: Int,
    val height: Int,
)

/** Pure helpers that turn app data into mpv option strings and read mpv's track list. No Android imports. */
object MpvOptions {
    class HeaderOptions(val fields: List<String>, val userAgent: String?, val referrer: String?)

    /**
     * Splits request headers into the three mpv options that carry them. User-Agent and Referer have options of
     * their own (mpv would send both, with the built-in default, if they were only passed as raw fields).
     * CR/LF are stripped: a header value must never be able to smuggle in another header line.
     */
    fun headerOptions(headers: Map<String, String>): HeaderOptions {
        var ua: String? = null
        var referrer: String? = null
        val fields = ArrayList<String>()
        for ((rawName, rawValue) in headers) {
            val name = rawName.trim().replace(Regex("[\\r\\n:]"), "")
            val value = rawValue.replace(Regex("[\\r\\n]"), " ").trim()
            if (name.isEmpty()) continue
            when (name.lowercase(Locale.ROOT)) {
                "user-agent" -> ua = value
                "referer", "referrer" -> referrer = value
                else -> fields.add("$name: $value")
            }
        }
        return HeaderOptions(fields, ua, referrer)
    }

    /** `start` option: seconds with millisecond precision, never negative. */
    fun startValue(ms: Long): String = String.format(Locale.ROOT, "%.3f", ms.coerceAtLeast(0) / 1000.0)

    /** Options applied before mpv_initialize. `hwdec=mediacodec-copy` because the zero-copy path needs mpv to own the Surface. */
    fun initialOptions(hwDecode: Boolean): List<Pair<String, String>> = listOf(
        "vo" to "libmpv", // render API; the app draws into its own GL surface
        "ao" to "audiotrack,opensles",
        "hwdec" to if (hwDecode) "mediacodec-copy" else "no",
        "idle" to "yes", // keep the core alive between files (episode switch = loadfile replace)
        "osd-level" to "0", // no on-screen messages; the app has its own controls
        "sub-auto" to "no", // never go looking for sidecar files next to a URL
        "audio-file-auto" to "no",
        "ytdl" to "no",
        "network-timeout" to "20",
        "demuxer-max-bytes" to "64MiB",
        "demuxer-max-back-bytes" to "32MiB",
        "msg-level" to "all=warn",
    )

    /** (keepaspect, panscan) for PlaybackConfig.fitMode: fit = letterbox, fill = stretch, zoom = crop to fill. */
    fun fit(mode: String): Pair<Boolean, Double> = when (mode) {
        "fill" -> false to 0.0
        "zoom" -> true to 1.0
        else -> true to 0.0
    }

    fun isYes(value: String?): Boolean = value == "yes" || value == "true"

    /**
     * Reads `track-list/N/...` through [read] (one mpv property string per call). Tracks without a usable id or type are
     * skipped; empty `lang`/`title` become null.
     */
    fun parseTracks(read: (String) -> String?): List<MpvTrack> {
        val count = read("track-list/count")?.trim()?.toIntOrNull() ?: return emptyList()
        return (0 until count).mapNotNull { i ->
            val p = "track-list/$i/"
            val id = read(p + "id")?.trim()?.toIntOrNull() ?: return@mapNotNull null
            val type = read(p + "type")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            MpvTrack(
                id = id,
                type = type,
                lang = read(p + "lang")?.takeIf { it.isNotBlank() },
                title = read(p + "title")?.takeIf { it.isNotBlank() },
                selected = isYes(read(p + "selected")),
                isDefault = isYes(read(p + "default")),
                external = isYes(read(p + "external")),
                channels = read(p + "demux-channel-count")?.trim()?.toIntOrNull() ?: 0,
                height = read(p + "demux-h")?.trim()?.toIntOrNull() ?: 0,
            )
        }
    }
}
