package com.example.uzv.native_player.ui

import com.example.uzv.native_player.PlaybackConfig
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PlayerSettingsTest {
    private val base = PlaybackConfig(
        hwDecode = true, fitMode = "fit", speed = 1.0, longPressSpeed = 3.0, fastForwardSeconds = 10,
        autoPictureInPicture = true, pauseOnBackground = false, isPriorityLandscape = true, isHiddenFastSeekBtn = false,
        isShowStatsBar = false, isShowAllDuration = false, isShowEpisodeSwitchNotice = true, showNetSpeed = true,
        hapticEnabled = true, skipNotice = true, kernel = "mpv",
    )

    @Before fun zh() { PlayerUiText.chinese = true }
    @After fun reset() { PlayerUiText.chinese = false }

    /**
     * OBSERVED (UZN 1.2.0 on the phone, 2026-11-11): the groups and rows of the player's 设置 panel, top to bottom. MDK is
     * this project's addition to 播放内核.
     */
    @Test
    fun theRowsAreTheOriginalPanels() {
        val titles = PlayerSettings.items().filter { it !is PlayerSettings.Item.Section }.map { it.title }
        assertEquals(
            listOf(
                "硬件加速", "适应（留黑边）", "裁剪填充", "拉伸填充", "MPV", "MDK", "EXO", "快进快退秒数",
                "进度条显示总时长", "隐藏中央快进快退", "进入后台暂停", "进入后台自动画中画", "跳过提示", "切集提示", "优先横屏",
                "长按滑动调节倍速", "显示帧率与编码", "始终显示网速",
            ),
            titles,
        )
        val sections = PlayerSettings.items().filterIsInstance<PlayerSettings.Item.Section>().map { it.title }
        assertEquals(listOf("解码", "画面比例", "播放内核", "快进快退秒数", "播放", "信息显示"), sections)
    }

    @Test
    fun optionsPickOneValue() {
        fun option(title: String) = PlayerSettings.items().filterIsInstance<PlayerSettings.Item.Option>().single { it.title == title }
        assertTrue(option("适应（留黑边）").selected(base))
        assertFalse(option("裁剪填充").selected(base))
        assertEquals("zoom", option("裁剪填充").select(base).fitMode)
        assertEquals("fill", option("拉伸填充").select(base).fitMode)
        assertTrue(option("适应（留黑边）").selected(base.copy(fitMode = "nonsense")))
        assertTrue(option("MPV").selected(base))
        assertTrue(option("MPV").selected(base.copy(kernel = "MPV")))
        assertEquals("exo", option("EXO").select(base).kernel)
        assertTrue(option("EXO").selected(base.copy(kernel = "whatever")))
        assertTrue(PlayerSettings.needsReload(base, option("MDK").select(base)))
        assertFalse(PlayerSettings.needsReload(base, option("裁剪填充").select(base)))
    }

    @Test
    fun togglesFlipTheirOwnField() {
        fun toggle(title: String) = PlayerSettings.items().filterIsInstance<PlayerSettings.Item.Toggle>().single { it.title == title }
        assertFalse(toggle("硬件加速").set(base, false).hwDecode)
        assertTrue(toggle("隐藏中央快进快退").set(base, true).isHiddenFastSeekBtn)
        assertTrue(toggle("进度条显示总时长").set(base, true).isShowAllDuration)
        assertFalse(toggle("优先横屏").set(base, false).isPriorityLandscape)
        // null = on (the original only turns it off for an explicit false)
        assertTrue(toggle("长按滑动调节倍速").get(base))
        assertEquals(false, toggle("长按滑动调节倍速").set(base, false).isLongPressSpeedAdjustEnabled)
        assertFalse(toggle("长按滑动调节倍速").get(base.copy(isLongPressSpeedAdjustEnabled = false)))
    }

    @Test
    fun theSeekStepStepper() {
        val seek = PlayerSettings.items().filterIsInstance<PlayerSettings.Item.Stepper>().single()
        assertEquals("10 秒", seek.value(base))
        assertEquals(15L, seek.plus(base)!!.fastForwardSeconds)
        assertNull(seek.minus(base.copy(fastForwardSeconds = 5)))
        assertNull(seek.plus(base.copy(fastForwardSeconds = 120)))
    }

    /** OBSERVED (UZN 1.2.0): 记片头 early in the video (00:13, 04:16), nothing at 05:31; the rest is inferred. */
    @Test
    fun markButtonWindow() {
        val dur = 84 * 60_000L + 18_000
        assertEquals(true, PlayerUiText.markButton(13_000, dur, true))
        assertEquals(true, PlayerUiText.markButton(256_000, dur, true))
        assertNull(PlayerUiText.markButton(331_000, dur, true))
        assertEquals(false, PlayerUiText.markButton(dur - 60_000, dur, true))
        assertNull(PlayerUiText.markButton(13_000, dur, false))
        assertNull(PlayerUiText.markButton(13_000, 0, true))
        // a short clip: a third each
        assertEquals(true, PlayerUiText.markButton(10_000, 60_000, true))
        assertNull(PlayerUiText.markButton(30_000, 60_000, true))
        assertEquals(false, PlayerUiText.markButton(50_000, 60_000, true))
    }

    /** OBSERVED (UZN 1.2.0): the speed menu's rows and the 样式调节 value labels. */
    @Test
    fun menuAndDanmakuLabels() {
        assertEquals(listOf("3x", "2x", "1.5x", "1.25x", "1.0x 常速", "0.75x", "0.5x"), PlayerUiText.speeds.reversed().map(PlayerUiText::speedMenuLabel))
        assertEquals("+0 秒", PlayerUiText.danmakuDelay(0.0))
        assertEquals("-1.5 秒", PlayerUiText.danmakuDelay(-1.5))
        assertEquals("+3 秒", PlayerUiText.danmakuDelay(3.0))
        assertEquals("自带颜色", PlayerUiText.danmakuColorMode("original"))
        assertEquals(listOf("适应（留黑边）", "裁剪填充", "拉伸填充"), listOf("fit", "zoom", "fill").map(PlayerUiText::fitModePanel))
        assertEquals(60_000L, PlayerUiText.swipeSeekMs(540f, 1080))
        assertEquals(-30_000L, PlayerUiText.swipeSeekMs(-270f, 1080))
    }

    /** OBSERVED (UZN 1.1.7, 2026-11-10): tapping 画面填充 in the player goes 原比例 → 裁剪铺满 → 拉伸铺满 → 原比例. */
    @Test
    fun fitCyclesLikeTheOriginal() {
        assertEquals("zoom", PlayerUiText.nextFit("fit"))
        assertEquals("fill", PlayerUiText.nextFit("zoom"))
        assertEquals("fit", PlayerUiText.nextFit("fill"))
        assertEquals("zoom", PlayerUiText.nextFit("unknown"))
        assertEquals(listOf("原比例", "裁剪铺满", "拉伸铺满"), listOf("fit", "zoom", "fill").map(PlayerUiText::fitMode))
    }

    /** OBSERVED in the original's picker: MPV (MPV) / MDK (MDK) / EXO (SYSTEM); the row shows the short name. */
    @Test
    fun kernelLabels() {
        assertEquals(listOf("MPV (MPV)", "MDK (MDK)", "EXO (SYSTEM)"), PlayerUiText.kernels.map(PlayerUiText::kernelOption))
        assertEquals(listOf("MPV", "MDK", "EXO"), listOf("mpv", "mdk", "exo").map(PlayerUiText::kernelName))
        assertEquals("EXO", PlayerUiText.kernelName("whatever"))
    }

    /**
     * OBSERVED (original i2.a0.onTouchEvent): while the finger is down after a long press, the speed is the long-press
     * speed plus one per 50 dp slid upwards, kept within 0.5x..8x; an explicit false leaves the fixed speed.
     */
    @Test
    fun longPressSlideAdjustsTheSpeed() {
        val step = 137.5f // 50 dp at 2.75 px/dp
        assertEquals(3.0, PlayerUiText.longPressSlideSpeed(3.0, 0f, step, null), 1e-9)
        assertEquals(4.0, PlayerUiText.longPressSlideSpeed(3.0, 137.5f, step, null), 1e-9)
        assertEquals(2.5, PlayerUiText.longPressSlideSpeed(3.0, -68.75f, step, true), 1e-9)
        assertEquals(8.0, PlayerUiText.longPressSlideSpeed(3.0, 5000f, step, true), 1e-9)
        assertEquals(0.5, PlayerUiText.longPressSlideSpeed(3.0, -5000f, step, true), 1e-9)
        assertEquals(3.0, PlayerUiText.longPressSlideSpeed(3.0, 500f, step, false), 1e-9)
    }
}
