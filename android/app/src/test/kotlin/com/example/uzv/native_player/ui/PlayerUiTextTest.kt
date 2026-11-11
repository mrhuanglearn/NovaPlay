package com.example.uzv.native_player.ui

import com.example.uzv.native_player.kernel.MediaInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

class PlayerUiTextTest {
    @Before fun chinese() { PlayerUiText.chinese = true }

    @Test fun clockMatchesTheOriginal() {
        assertEquals("00:31", PlayerUiText.clock(31_400))
        assertEquals("04:29", PlayerUiText.clock(269_000))
        assertEquals("1:02:03", PlayerUiText.clock(3_723_000))
        assertEquals("00:00", PlayerUiText.clock(-5))
    }

    @Test fun rightTimeIsRemainingUnlessShowTotalIsOn() {
        // OBSERVED: 00:31 … -04:29 for a 5-minute video with 进度条显示总时长 off
        assertEquals("-04:29", PlayerUiText.rightTime(31_000, 300_000, showTotal = false))
        assertEquals("05:00", PlayerUiText.rightTime(31_000, 300_000, showTotal = true))
        assertEquals("00:00", PlayerUiText.rightTime(0, 0, showTotal = false)) // duration not known yet
    }

    @Test fun speedLabels() {
        assertEquals("1.0x", PlayerUiText.speed(1.0))
        assertEquals("1.25x", PlayerUiText.speed(1.25))
        assertEquals("2.0x", PlayerUiText.speed(2.0))
        assertEquals("0.75x", PlayerUiText.speed(0.75))
        assertEquals("1.0x 常速", PlayerUiText.speedOption(1.0))
        assertEquals("长按倍速 2.0x", PlayerUiText.longPressSpeed(2.0))
    }

    // OBSERVED in the original (i2.i1.g / i2.i1.f, B3.d case 4): KB/s without decimals below 1 MiB/s, MB/s with one;
    // the buffering label falls back to "0.0 KB/s"; the bitrate is "%.1f Mbps" of bits/1e6.
    @Test fun netSpeedAndBitrateFormats() {
        assertEquals("0 KB/s", PlayerUiText.netSpeed(0))
        assertEquals("512 KB/s", PlayerUiText.netSpeed(512 * 1024))
        assertEquals("1024 KB/s", PlayerUiText.netSpeed(1024 * 1024 - 1))
        assertEquals("1.5 MB/s", PlayerUiText.netSpeed(1536 * 1024))
        assertEquals("0.0 KB/s", PlayerUiText.bufferingSpeed(null))
        assertEquals("0.0 KB/s", PlayerUiText.bufferingSpeed(0))
        assertEquals("2 KB/s", PlayerUiText.bufferingSpeed(2048))
        assertEquals("1.5 Mbps", PlayerUiText.bitrate(1_500_000))
    }

    @Test fun fpsLabels() {
        assertEquals("15 FPS", PlayerUiText.fps(15.0))
        assertEquals("23.5 FPS", PlayerUiText.fps(23.5))
        assertNull(PlayerUiText.fps(0.0))
        assertNull(PlayerUiText.fps(null))
    }

    /** OBSERVED in the original (B3.d case 4): what the bottom bar's stats line and the always-on speed show. */
    @Test fun statsLineAndPersistentSpeed() {
        val info = MediaInfo(640, 360, 15.0, "h264")
        // 显示帧率与编码 on: codec · fps · speed (or the bitrate when the speed is unknown)
        assertEquals("H.264 · 15 FPS · 2 KB/s", PlayerUiText.statsLine(true, info, 2048, 1_500_000))
        assertEquals("H.264 · 15 FPS · 1.5 Mbps", PlayerUiText.statsLine(true, info, null, 1_500_000))
        assertEquals("H.264 · 15 FPS", PlayerUiText.statsLine(true, info, 0, null))
        // only 始终显示网速 on: "↓ speed · bitrate"
        assertEquals("↓ 2 KB/s · 1.5 Mbps", PlayerUiText.statsLine(false, info, 2048, 1_500_000))
        assertEquals("↓ 1.5 Mbps", PlayerUiText.statsLine(false, info, null, 1_500_000))
        assertNull(PlayerUiText.statsLine(false, info, null, null))
        assertEquals("2 KB/s", PlayerUiText.persistentSpeed(2048, 1_500_000))
        assertEquals("1.5 Mbps", PlayerUiText.persistentSpeed(0, 1_500_000))
        assertNull(PlayerUiText.persistentSpeed(null, null))
    }

    /** OBSERVED in the original (g2.g.g for mpv's video-format, f2.b.g for Exo's MIME type). */
    @Test fun codecNames() {
        assertEquals("H.264", PlayerUiText.codecName("h264"))
        assertEquals("H.264", PlayerUiText.codecName("video/avc"))
        assertEquals("HEVC", PlayerUiText.codecName("hevc"))
        assertEquals("HEVC", PlayerUiText.codecName("video/hevc"))
        assertEquals("AV1", PlayerUiText.codecName("av1"))
        assertEquals("VP9", PlayerUiText.codecName("video/x-vnd.on2.vp9"))
        assertEquals("MPEG2VIDEO", PlayerUiText.codecName("mpeg2video"))
        assertNull(PlayerUiText.codecName(" "))
        assertNull(PlayerUiText.codecName(null))
    }

    @Test fun resolution() {
        assertNull(PlayerUiText.resolution(null))
        assertEquals("640x360", PlayerUiText.resolution(MediaInfo(640, 360)))
    }

    @Test fun notices() {
        assertEquals("正在切换至 第2集", PlayerUiText.switchingTo("第2集"))
        assertEquals("快进 10 秒", PlayerUiText.seekStep(true, 10))
        assertEquals("原比例", PlayerUiText.fitMode("fit"))
        assertEquals("剧集选集（3 集）", PlayerUiText.episodesTitle(3))
        PlayerUiText.chinese = false
        assertEquals("Switching to Ep 2", PlayerUiText.switchingTo("Ep 2"))
    }

    /** OBSERVED in 1.1.13's i2.P0.A: the error layer's title follows the message, the link prefix is dropped. */
    @Test fun errorLayerTitleAndDetail() {
        val failed = PlayerUiText.sourceFailed("HTTP 401：夸克登录状态失效")
        assertEquals("获取播放链接失败：HTTP 401：夸克登录状态失效", failed)
        assertEquals("⚠️ 获取播放链接失败", PlayerUiText.errorTitle(failed))
        assertEquals("HTTP 401：夸克登录状态失效", PlayerUiText.errorDetail(failed))
        assertEquals("HTTP 403", PlayerUiText.errorDetail("获取播放链接失败: HTTP 403"))

        assertEquals("⚠️ 视频播放失败", PlayerUiText.errorTitle("MPV 播放失败"))
        assertEquals("MPV 播放失败", PlayerUiText.errorDetail("MPV 播放失败"))
        assertEquals("⚠️ 播放失败", PlayerUiText.errorTitle("MDK: the media could not be opened"))

        // the message Dart already prefixed is not prefixed twice
        assertEquals(failed, PlayerUiText.sourceFailed(failed))
        assertEquals("获取播放链接失败：解析失败", PlayerUiText.sourceFailed(" "))
        assertEquals("获取播放链接失败：解析失败", PlayerUiText.sourceFailed(null))

        val mpv = PlayerUiText.kernelFailed("MPV", "loading failed")
        assertEquals("MPV 播放失败 (loading failed)", mpv)
        assertEquals("⚠️ 视频播放失败", PlayerUiText.errorTitle(mpv))
        assertEquals("MDK 播放失败", PlayerUiText.kernelFailed("MDK", " "))
    }

    @Test fun danmakuColorGradientAndWeight() {
        assertEquals(listOf("random_Mix", "white", "original", "gradient", "random"), PlayerUiText.danmakuColorModes)
        assertEquals("随机（混渐变）", PlayerUiText.danmakuColorMode("random_Mix"))
        assertEquals("全部渐变", PlayerUiText.danmakuColorMode("gradient"))
        val encoded = PlayerUiText.encodeGradientAndWeight(3, 6)
        assertEquals(3, PlayerUiText.parseGradientPreset(encoded))
        assertEquals(6, PlayerUiText.parseFontWeight(encoded))
        assertEquals("适中", PlayerUiText.danmakuFontWeightLabel(4))
        assertEquals("随机风格", PlayerUiText.danmakuGradientLabel("-1"))
        assertEquals("粉→蓝", PlayerUiText.danmakuGradientLabel("0"))
    }
}
