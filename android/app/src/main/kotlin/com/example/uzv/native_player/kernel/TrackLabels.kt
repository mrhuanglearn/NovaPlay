package com.example.uzv.native_player.kernel

import java.io.File
import java.util.Locale

/** One selectable audio/video/text track as shown in a picker. */
data class TrackOption(val label: String, val selected: Boolean, val language: String? = null)

/** What the player shows about the playing video: the 640x360 badge and the 显示帧率与编码 line. 0 / null = unknown. */
data class MediaInfo(val width: Int, val height: Int, val fps: Double = 0.0, val codec: String? = null)

/**
 * Pure helpers for subtitles and quality. They deliberately import neither Android nor media3 classes (mime types are
 * plain strings) so they run in host-side unit tests.
 */
object TrackLabels {
    const val SUBRIP = "application/x-subrip"
    const val VTT = "text/vtt"
    const val SSA = "text/x-ssa"
    const val TTML = "application/ttml+xml"

    /**
     * Exo cannot sniff the format of a sidecar subtitle, so a mime type is required. The file extension wins, the
     * declared type is the fallback; null means unknown and the entry has to be dropped.
     */
    fun subtitleMime(url: String, declared: String?): String? {
        val path = url.substringBefore('#').substringBefore('?').lowercase(Locale.ROOT)
        return when {
            path.endsWith(".srt") -> SUBRIP
            path.endsWith(".vtt") || path.endsWith(".webvtt") -> VTT
            path.endsWith(".ass") || path.endsWith(".ssa") -> SSA
            path.endsWith(".ttml") || path.endsWith(".dfxp") -> TTML
            else -> fromDeclared(declared)
        }
    }

    private fun fromDeclared(declared: String?): String? {
        val d = declared?.trim()?.lowercase(Locale.ROOT).orEmpty()
        return when {
            d.isEmpty() -> null
            d == "srt" || d.contains("subrip") -> SUBRIP
            d == "vtt" || d.contains("webvtt") || d == VTT -> VTT
            d == "ass" || d == "ssa" || d.contains("ssa") -> SSA
            d == "ttml" || d.contains("ttml") || d.contains("dfxp") -> TTML
            else -> null
        }
    }

    private val iso3 = mapOf("chi" to "zh", "zho" to "zh", "eng" to "en", "jpn" to "ja", "kor" to "ko", "fre" to "fr", "fra" to "fr", "ger" to "de", "deu" to "de", "spa" to "es", "rus" to "ru")

    /** `zh-CN` / `zh_TW` / `chi` all become `zh`; null for empty or `und`. */
    fun primaryLanguage(tag: String?): String? {
        val p = tag?.trim()?.lowercase(Locale.ROOT)?.substringBefore('-')?.substringBefore('_').orEmpty()
        if (p.isEmpty() || p == "und") return null
        return iso3[p] ?: p
    }

    fun languageName(tag: String?): String? {
        val primary = primaryLanguage(tag) ?: return null
        val name = Locale.forLanguageTag(primary).getDisplayLanguage(Locale.ENGLISH)
        return if (name.isNullOrEmpty() || name.equals(primary, ignoreCase = true)) primary else name
    }

    /** "Name · Language", whichever exist; "Subtitle N" when the track says nothing about itself. */
    fun textLabel(label: String?, language: String?, index: Int): String {
        val name = label?.trim().orEmpty()
        val lang = languageName(language)
        val parts = buildList {
            if (name.isNotEmpty()) add(name)
            if (lang != null && !name.contains(lang, ignoreCase = true)) add(lang)
        }
        return if (parts.isEmpty()) "Subtitle ${index + 1}" else parts.joinToString(" · ")
    }

    fun channelName(channels: Int): String? = when {
        channels <= 0 -> null
        channels == 1 -> "mono"
        channels == 2 -> "stereo"
        channels == 6 -> "5.1"
        channels == 8 -> "7.1"
        else -> "${channels}ch"
    }

    /** "Name \u00B7 Language \u00B7 5.1"; "Audio N" stands in when the track names neither itself nor a language. */
    fun audioLabel(label: String?, language: String?, channels: Int, index: Int): String {
        val name = label?.trim().orEmpty()
        val lang = languageName(language)
        val parts = buildList {
            if (name.isNotEmpty()) add(name)
            if (lang != null && !name.contains(lang, ignoreCase = true)) add(lang)
            if (isEmpty()) add("Audio ${index + 1}")
            channelName(channels)?.let { add(it) }
        }
        return parts.joinToString(" \u00B7 ")
    }

    /** "1080p · 4.5 Mbps"; just the bitrate when the height is unknown; "Track N" when nothing is known. */
    fun videoLabel(height: Int, bitrate: Int, index: Int): String {
        val parts = buildList {
            if (height > 0) add("${height}p")
            if (bitrate > 0) add(if (bitrate >= 1_000_000) String.format(Locale.ROOT, "%.1f Mbps", bitrate / 1_000_000.0) else "${bitrate / 1000} kbps")
        }
        return if (parts.isEmpty()) "Track ${index + 1}" else parts.joinToString(" · ")
    }

    /**
     * Which text track to switch on after a (re)load; -1 for none. Exo does not select sidecar subtitles on its own, so
     * the kernel applies this. Rules, in order: the track whose label equals the one the user picked last, the first
     * whose language matches [preferredLanguage], the first flagged default.
     */
    fun chooseDefaultText(
        labels: List<String?>,
        languages: List<String?>,
        defaults: List<Boolean>,
        preferredLabel: String?,
        preferredLanguage: String?,
    ): Int {
        val wantLabel = preferredLabel?.trim()?.takeIf { it.isNotEmpty() }
        if (wantLabel != null) {
            val i = labels.indexOfFirst { it?.trim().equals(wantLabel, ignoreCase = true) }
            if (i >= 0) return i
        }
        val wantLang = primaryLanguage(preferredLanguage)
        if (wantLang != null) {
            val i = languages.indexOfFirst { primaryLanguage(it) == wantLang }
            if (i >= 0) return i
        }
        return defaults.indexOfFirst { it }
    }

    /**
     * Which audio track to switch to after a (re)load, or -1 to leave Exo's own choice alone: the track whose label
     * equals the one the user picked last, else the first in the preferred language.
     */
    fun chooseAudio(labels: List<String?>, languages: List<String?>, preferredLabel: String?, preferredLanguage: String?): Int =
        chooseDefaultText(labels, languages, List(labels.size) { false }, preferredLabel, preferredLanguage)

    /** `<dir>/<family>.ttf|otf|ttc`, matched case-insensitively on the file name without extension. */
    fun findFont(dir: String?, family: String?): File? {
        if (dir.isNullOrBlank() || family.isNullOrBlank()) return null
        val files = File(dir).listFiles() ?: return null
        val wanted = family.trim()
        return files.firstOrNull {
            it.isFile && it.extension.lowercase(Locale.ROOT) in setOf("ttf", "otf", "ttc") && it.nameWithoutExtension.equals(wanted, ignoreCase = true)
        }
    }
}
