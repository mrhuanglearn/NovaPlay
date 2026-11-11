package com.example.uzv.native_player.ui

import com.example.uzv.native_player.kernel.MediaInfo
import java.util.Locale

/**
 * Texts of the player page. Pure (no Android classes) so they run in host-side unit tests.
 *
 * OBSERVED on the original (2026-11-10, portrait, mock video): `00:31` left of the progress bar and `-04:29` right of
 * it (the remaining time; 播放器设置 → 进度条显示总时长 switches it to the total), a `原画` quality pill and a `1.0x`
 * speed pill, `640x360` and `第1集` badges under the title, `0.0KB/s` under the loading spinner. The other wording is
 * from the original's dex strings (正在切换至 {episode}, 已跳过片段, 长按倍速 {speed}x, 1.0x 常速, 适应（留黑边）…).
 */
object PlayerUiText {
    /** The player follows the system language like the rest of the app: Chinese, or English otherwise. */
    var chinese: Boolean = Locale.getDefault().language == "zh"

    fun t(zh: String, en: String) = if (chinese) zh else en

    /** `00:31`, `04:29`, `1:02:03`. */
    fun clock(ms: Long): String {
        val s = (ms / 1000).coerceAtLeast(0)
        val h = s / 3600
        return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, (s % 3600) / 60, s % 60)
        else String.format(Locale.ROOT, "%02d:%02d", s / 60, s % 60)
    }

    /** Right of the progress bar: the total with 进度条显示总时长 on, else the remaining time with a minus sign. */
    fun rightTime(positionMs: Long, durationMs: Long, showTotal: Boolean): String =
        if (showTotal || durationMs <= 0) clock(durationMs) else "-" + clock((durationMs - positionMs).coerceAtLeast(0))

    /** `1.0x`, `1.25x`, `2.0x`. */
    fun speed(v: Double): String {
        val r = Math.round(v * 100) / 100.0
        return if (Math.round(r * 10) * 10 == Math.round(r * 100)) String.format(Locale.ROOT, "%.1fx", r)
        else String.format(Locale.ROOT, "%.2fx", r)
    }

    val speeds = listOf(0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0)

    fun speedOption(v: Double) = if (v == 1.0) t("1.0x 常速", "1.0x Normal") else speed(v)

    /** Rows of the speed menu (OBSERVED in UZN 1.2.0): `3x`, `2x`, `1.5x`, `1.25x`, `1.0x 常速`, `0.75x`, `0.5x`. */
    fun speedMenuLabel(v: Double): String = when {
        v == 1.0 -> t("1.0x 常速", "1.0x Normal")
        v % 1.0 == 0.0 -> "${v.toInt()}x"
        else -> java.math.BigDecimal(v.toString()).stripTrailingZeros().toPlainString() + "x"
    }

    /**
     * Which of 记片头 / 记片尾 the bottom bar offers: true = 记片头, false = 记片尾, null = neither.
     * OBSERVED (UZN 1.2.0, a film of 1:24:18): 记片头 at 00:13 and 04:16, nothing at 05:31 and later. INFERRED: the window
     * is the first five minutes (a third of a shorter video), and 记片尾 mirrors it at the end.
     */
    fun markButton(positionMs: Long, durationMs: Long, allowed: Boolean): Boolean? {
        if (!allowed || durationMs <= 0) return null
        val window = minOf(300_000L, durationMs / 3)
        return when {
            positionMs < window -> true
            durationMs - positionMs < window -> false
            else -> null
        }
    }

    fun introMarked(ms: Long) = t("已记录片头 ${clock(ms)}", "Intro ends at ${clock(ms)}")
    fun outroMarked(beforeEndMs: Long) = t("已记录片尾（结束前 ${clock(beforeEndMs)}）", "Outro starts ${clock(beforeEndMs)} before the end")

    /** Horizontal swipe: how far a swipe of [dx] px over a view [width] px wide seeks. INFERRED: two minutes a width. */
    fun swipeSeekMs(dx: Float, width: Int): Long = if (width <= 0) 0 else (dx / width * 120_000f).toLong()

    /** 弹幕 → 样式调节 value labels (OBSERVED: `16 pt`, `1.6`, `100%`, `1.0`, `1.5`, `+0 秒`). */
    fun danmakuDelay(seconds: Double): String {
        val v = Math.round(seconds * 10) / 10.0
        val n = if (v % 1.0 == 0.0) "${v.toLong()}" else "$v"
        return (if (v >= 0) "+" else "") + n + t(" 秒", " s")
    }

    val danmakuColorModes = listOf("random_Mix", "white", "original", "gradient", "random")
    fun danmakuColorMode(mode: String) = when (mode) {
        "random_Mix", "0" -> t("随机（混渐变）", "Random (Mix Gradient)")
        "white", "1" -> t("白色", "White")
        "original", "2" -> t("自带颜色", "Original")
        "gradient", "3" -> t("全部渐变", "All Gradient")
        "random", "random_Color", "4" -> t("随机彩色", "Random Color")
        else -> t("自带颜色", "Original")
    }

    val danmakuGradientPresets: List<Pair<Int, String>>
        get() = listOf(
            -1 to t("随机风格", "Random Style"),
            0 to t("粉→蓝", "Pink → Purple"),
            1 to t("金→橙红", "Gold → Orange"),
            2 to t("青→薄荷绿", "Cyan → Mint"),
            3 to t("紫→粉", "Violet → Pink"),
            4 to t("天蓝→青", "Sky → Emerald"),
            5 to t("玫红→深紫", "Rose → Purple"),
            6 to t("橙→柠檬黄", "Orange → Yellow"),
            7 to t("薄荷→蓝绿", "Teal → Blue"),
        )

    val danmakuGradientColors: List<IntArray> = listOf(
        intArrayOf(0xFFFF6B9D.toInt(), 0xFFC44DFF.toInt()),
        intArrayOf(0xFFFFD700.toInt(), 0xFFFF6B35.toInt()),
        intArrayOf(0xFF00D2FF.toInt(), 0xFF3AFFA3.toInt()),
        intArrayOf(0xFFA78BFA.toInt(), 0xFFF472B6.toInt()),
        intArrayOf(0xFF38BDF8.toInt(), 0xFF34D399.toInt()),
        intArrayOf(0xFFFB7185.toInt(), 0xFFA855F7.toInt()),
        intArrayOf(0xFFFB923C.toInt(), 0xFFFACC15.toInt()),
        intArrayOf(0xFF2DD4BF.toInt(), 0xFF60A5FA.toInt()),
    )

    fun parseGradientPreset(gradientStyle: String): Int =
        gradientStyle.substringBefore(":").toIntOrNull()?.takeIf { it in 0..7 } ?: -1

    fun parseFontWeight(gradientStyle: String): Int =
        gradientStyle.substringAfter(":w=", "").toIntOrNull()?.coerceIn(0, 8) ?: 4

    fun encodeGradientAndWeight(preset: Int, weight: Int): String {
        val g = if (preset in 0..7) preset.toString() else "none"
        val w = weight.coerceIn(0, 8)
        return if (w == 4) g else "$g:w=$w"
    }

    fun danmakuGradientLabel(gradientStyle: String): String {
        val p = parseGradientPreset(gradientStyle)
        return danmakuGradientPresets.firstOrNull { it.first == p }?.second ?: t("随机风格", "Random Style")
    }

    fun danmakuFontWeightLabel(weight: Int): String {
        val w = weight.coerceIn(0, 8)
        val zh = listOf("最细", "特细", "细", "偏细", "适中", "半粗", "粗", "特粗", "最粗")
        val en = listOf("Thin", "Extra Light", "Light", "Normal-", "Medium", "Semi Bold", "Bold", "Extra Bold", "Black")
        return if (chinese) zh[w] else en[w]
    }

    /** OBSERVED (original i2.i1.g): `512 KB/s` below 1 MiB/s, `1.5 MB/s` from there. */
    fun netSpeed(bytesPerSecond: Long): String =
        if (bytesPerSecond >= 1_048_576) String.format(Locale.ROOT, "%.1f MB/s", bytesPerSecond / 1_048_576.0)
        else String.format(Locale.ROOT, "%.0f KB/s", bytesPerSecond.coerceAtLeast(0) / 1024.0)

    /** Under the buffering spinner: the speed, or `0.0 KB/s` while it is unknown (original B3.d case 4). */
    fun bufferingSpeed(bytesPerSecond: Long?): String =
        if (bytesPerSecond != null && bytesPerSecond > 0) netSpeed(bytesPerSecond) else "0.0 KB/s"

    /** OBSERVED (original i2.i1.f): bits per second as `1.5 Mbps`. */
    fun bitrate(bitsPerSecond: Long): String = String.format(Locale.ROOT, "%.1f Mbps", bitsPerSecond / 1_000_000.0)

    /** `15 FPS`, `23.5 FPS`; null when unknown. */
    fun fps(v: Double?): String? = when {
        v == null || v <= 0 -> null
        v % 1.0 == 0.0 -> "${v.toInt()} FPS"
        else -> String.format(Locale.ROOT, "%.1f FPS", v)
    }

    fun resolution(info: MediaInfo?): String? = info?.let { "${it.width}x${it.height}" }

    /** OBSERVED in the original (g2.g.g / f2.b.g): common codecs get their usual names, anything else is upper-cased. */
    fun codecName(raw: String?): String? {
        val v = raw?.trim()?.lowercase(Locale.ROOT)?.takeIf { it.isNotEmpty() } ?: return null
        return when {
            "hevc" in v || "h265" in v -> "HEVC"
            "avc" in v || "h264" in v -> "H.264"
            "av01" in v || "av1" in v -> "AV1"
            "vp9" in v -> "VP9"
            "vp8" in v -> "VP8"
            else -> v.removePrefix("video/").uppercase(Locale.ROOT)
        }
    }

    private fun speedOrBitrate(speed: Long?, bitrate: Long?): String? = when {
        speed != null && speed > 0 -> netSpeed(speed)
        bitrate != null && bitrate > 0 -> bitrate(bitrate)
        else -> null
    }

    /**
     * The bottom bar's stats line (original B3.d case 4, every second). With 显示帧率与编码 on: codec · FPS · speed (or the
     * bitrate while the speed is unknown); with only 始终显示网速 on: `↓ speed · bitrate`. Null hides the line.
     */
    fun statsLine(showStats: Boolean, info: MediaInfo?, speed: Long?, bitrate: Long?): String? {
        val parts = if (showStats) {
            listOfNotNull(codecName(info?.codec), fps(info?.fps), speedOrBitrate(speed, bitrate))
        } else {
            listOfNotNull(speed?.takeIf { it > 0 }?.let(::netSpeed), bitrate?.takeIf { it > 0 }?.let(::bitrate))
        }
        if (parts.isEmpty()) return null
        return (if (showStats) "" else "↓ ") + parts.joinToString(" · ")
    }

    /** 始终显示网速: the speed, or the bitrate while the speed is unknown (original setPersistentNetSpeed). */
    fun persistentSpeed(speed: Long?, bitrate: Long?): String? = speedOrBitrate(speed, bitrate)

    fun switchingTo(episode: String) = t("正在切换至 $episode", "Switching to $episode")
    fun longPressSpeed(v: Double) = t("长按倍速 ${speed(v)}", "Hold for ${speed(v)}")
    fun seekStep(forward: Boolean, seconds: Int) =
        if (forward) t("快进 $seconds 秒", "Forward $seconds s") else t("快退 $seconds 秒", "Back $seconds s")

    /**
     * OBSERVED (UZN 1.1.7 on the phone, 2026-11-10): the in-player 画面填充 row shows 原比例 / 裁剪铺满 / 拉伸铺满 and each
     * tap moves to the next one in this order. (1.1.13's dex also has 适应（留黑边）/拉伸填充/裁剪填充; the labels the user
     * sees on the phone are used, the same ones as 设置 → 播放器.)
     */
    val fitModes = listOf("fit", "zoom", "fill")
    fun fitMode(mode: String) = when (mode) {
        "fill" -> t("拉伸铺满", "Stretch")
        "zoom" -> t("裁剪铺满", "Crop")
        else -> t("原比例", "Original")
    }

    fun nextFit(mode: String) = fitModes[(fitModes.indexOf(mode).coerceAtLeast(0) + 1) % fitModes.size]

    /** The player's own 画面比例 rows (OBSERVED in UZN 1.2.0's panel): 适应（留黑边） / 裁剪填充 / 拉伸填充. */
    fun fitModePanel(mode: String) = when (mode) {
        "fill" -> t("拉伸填充", "Stretch")
        "zoom" -> t("裁剪填充", "Crop")
        else -> t("适应（留黑边）", "Fit (letterbox)")
    }

    /** OBSERVED picker order and labels in the original: MPV (MPV) / MDK (MDK) / EXO (SYSTEM). */
    val kernels = listOf("mpv", "mdk", "exo")
    fun kernelOption(kernel: String) = when (kernel) {
        "mpv" -> "MPV (MPV)"
        "mdk" -> "MDK (MDK)"
        else -> "EXO (SYSTEM)"
    }

    fun kernelName(kernel: String) = when (kernel) {
        "mpv" -> "MPV"
        "mdk" -> "MDK"
        else -> "EXO"
    }

    /**
     * 长按滑动调节倍速 (OBSERVED in the original's i2.a0.onTouchEvent): while a long press holds, the speed is the long-press
     * speed plus one for every [pxPerStep] (50 dp) slid upwards, kept within 0.5x..8x. Only an explicit false turns it off.
     */
    fun longPressSlideSpeed(base: Double, upPx: Float, pxPerStep: Float, enabled: Boolean?): Double {
        if (enabled == false || pxPerStep <= 0f) return base
        val v = (base + upPx / pxPerStep).coerceIn(0.5, 8.0)
        return Math.round(v * 100) / 100.0
    }

    fun episodesTitle(count: Int) = t("剧集选集（$count 集）", "Episodes ($count)")

    // -- the error layer (OBSERVED in 1.1.13: i2.P0.A picks the title, its constructor builds 取消 / 复制错误信息 / 重试) --
    private const val LINK_FAILED = "获取播放链接失败"

    /**
     * A failed episode request as the error layer reads it. The prefix is the one 1.1.13's i2.P0.A looks for; an empty
     * message falls back to 解析失败 (INFERRED text for the original's `toastParseFailed` key, W0.c.n).
     */
    fun sourceFailed(message: String?): String {
        val m = message?.trim().orEmpty().ifEmpty { t("解析失败", "Parse failed") }
        return if (m.startsWith(LINK_FAILED)) m else "$LINK_FAILED：$m"
    }

    fun errorTitle(message: String): String = when {
        message.startsWith(LINK_FAILED) -> "⚠️ $LINK_FAILED"
        message.contains("播放失败") -> "⚠️ 视频播放失败"
        else -> "⚠️ 播放失败"
    }

    fun errorDetail(message: String): String = message.removePrefix("$LINK_FAILED: ").removePrefix("$LINK_FAILED：")

    /**
     * A kernel's playback error: `MPV 播放失败 (detail)` (OBSERVED shape in 1.1.13's mpv kernel; its Exo one starts
     * `ExoPlayer 播放失败 [`). The error layer titles these ⚠️ 视频播放失败.
     */
    fun kernelFailed(kernel: String, detail: String?): String {
        val d = detail?.trim().orEmpty()
        return if (d.isEmpty()) "$kernel 播放失败" else "$kernel 播放失败 ($d)"
    }
}
