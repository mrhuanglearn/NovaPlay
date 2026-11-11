package com.example.uzv.native_player.ui

import com.example.uzv.native_player.PlaybackConfig
import java.math.BigDecimal
import java.math.RoundingMode
import java.util.Locale

/**
 * Rows of the player page's 设置 panel (the gear in the top bar). Pure, so the order and the rules are unit-tested.
 *
 * OBSERVED (UZN 1.2.0 on the phone, 2026-11-11; the player page is native since 1.1.9): the gear opens a translucent
 * panel with these groups, top to bottom:
 *  - 解码: 硬件加速 (关闭后使用软解（更兼容但更耗电）);
 *  - 画面比例: 适应（留黑边） / 裁剪填充 / 拉伸填充, the current one in the accent colour with a ✓;
 *  - 播放内核: MPV / EXO, same style;
 *  - 快进快退秒数: `− 10 秒 +`;
 *  - 播放: 进度条显示总时长, 隐藏中央快进快退, 进入后台暂停, 进入后台自动画中画, 跳过提示, 切集提示, 优先横屏, 长按滑动调节倍速;
 *  - 信息显示: 显示帧率与编码, 始终显示网速.
 * Every row is one of the settings of 设置 → 播放器 (the same PlaybackConfig, saved at once); that page has more rows
 * (默认倍速, 长按倍速, the subtitle and audio preferences), which the original's panel does not show either.
 * DEVIATION: 播放内核 also lists MDK (UZN 1.1.13 has it; the 1.2.0 panel on the phone showed MPV and EXO).
 */
object PlayerSettings {
    sealed class Item(val key: String, val title: String) {
        class Section(title: String) : Item("section:$title", title)

        class Toggle(
            key: String,
            title: String,
            val subtitle: String?,
            val icon: Int,
            val get: (PlaybackConfig) -> Boolean,
            val set: (PlaybackConfig, Boolean) -> PlaybackConfig,
        ) : Item(key, title)

        /** `[−] value [+]`; a null result disables that button. */
        class Stepper(
            key: String,
            title: String,
            val icon: Int,
            val value: (PlaybackConfig) -> String,
            val minus: (PlaybackConfig) -> PlaybackConfig?,
            val plus: (PlaybackConfig) -> PlaybackConfig?,
        ) : Item(key, title)

        /** One row of a pick-one group (画面比例, 播放内核). */
        class Option(
            key: String,
            title: String,
            val icon: Int,
            val rotateIcon: Boolean,
            val selected: (PlaybackConfig) -> Boolean,
            val select: (PlaybackConfig) -> PlaybackConfig,
        ) : Item(key, title)
    }

    const val KERNEL = "kernel"
    const val FIT = "fitMode"

    private fun t(zh: String, en: String) = PlayerUiText.t(zh, en)

    /** `1.0`, `1.25`, `3.5` (the settings page's format). */
    fun num(v: Double): String =
        if (v == Math.floor(v)) String.format(Locale.ROOT, "%.1f", v)
        else BigDecimal(v).setScale(2, RoundingMode.HALF_UP).stripTrailingZeros().toPlainString()

    private fun fit(mode: String, icon: Int, rotate: Boolean = false) = Item.Option("$FIT:$mode", PlayerUiText.fitModePanel(mode), icon, rotate,
        { (it.fitMode.takeIf { m -> m in PlayerUiText.fitModes } ?: "fit") == mode }, { it.copy(fitMode = mode) })

    private fun kernel(id: String) = Item.Option("$KERNEL:$id", PlayerUiText.kernelName(id), Ic.MEMORY, false,
        { PlayerUiText.kernelName(it.kernel.lowercase(Locale.ROOT)) == PlayerUiText.kernelName(id) }, { it.copy(kernel = id) })

    fun items(): List<Item> = listOf(
        Item.Section(t("解码", "Decoding")),
        Item.Toggle("hwDecode", t("硬件加速", "Hardware acceleration"),
            t("关闭后使用软解（更兼容但更耗电）", "Off: software decoding (more compatible, uses more power)"), Ic.MEMORY,
            { it.hwDecode }, { c, v -> c.copy(hwDecode = v) }),

        Item.Section(t("画面比例", "Aspect")),
        fit("fit", Ic.ASPECT), fit("zoom", Ic.FIT), fit("fill", Ic.HEIGHT, rotate = true),

        Item.Section(t("播放内核", "Player kernel")),
        kernel("mpv"), kernel("mdk"), kernel("exo"),

        Item.Section(t("快进快退秒数", "Seek step")),
        Item.Stepper("fastForwardSeconds", t("快进快退秒数", "Seek step"), Ic.FORWARD,
            { t("${it.fastForwardSeconds} 秒", "${it.fastForwardSeconds} s") },
            { c -> if (c.fastForwardSeconds <= 5) null else c.copy(fastForwardSeconds = c.fastForwardSeconds - 5) },
            { c -> if (c.fastForwardSeconds >= 120) null else c.copy(fastForwardSeconds = c.fastForwardSeconds + 5) }),

        Item.Section(t("播放", "Playback")),
        Item.Toggle("showAllDuration", t("进度条显示总时长", "Show total duration on the progress bar"),
            t("关闭则显示剩余时长", "Off: show the remaining time"), Ic.CLOCK,
            { it.isShowAllDuration }, { c, v -> c.copy(isShowAllDuration = v) }),
        Item.Toggle("hiddenFastSeekBtn", t("隐藏中央快进快退", "Hide centre seek buttons"), null, Ic.SKIP_NEXT,
            { it.isHiddenFastSeekBtn }, { c, v -> c.copy(isHiddenFastSeekBtn = v) }),
        Item.Toggle("pauseOnBackground", t("进入后台暂停", "Pause in background"), null, Ic.PAUSE,
            { it.pauseOnBackground }, { c, v -> c.copy(pauseOnBackground = v) }),
        Item.Toggle("autoPictureInPicture", t("进入后台自动画中画", "Picture-in-picture in background"),
            t("切到后台时自动开启画中画继续播放", "Keep playing in picture-in-picture when you leave the app"), Ic.PIP,
            { it.autoPictureInPicture }, { c, v -> c.copy(autoPictureInPicture = v) }),
        Item.Toggle("skipNotice", t("跳过提示", "Skip notice"),
            t("跳过片头片尾时显示横幅与轻提示", "Show a banner and a short notice when intros/outros are skipped"), Ic.BOLT,
            { it.skipNotice }, { c, v -> c.copy(skipNotice = v) }),
        Item.Toggle("episodeSwitchNotice", t("切集提示", "Episode switch notice"),
            t("切集时显示「正在切换至 第X集」轻提示", "Show “Switching to episode X” when the episode changes"), Ic.DOUBLE_RIGHT,
            { it.isShowEpisodeSwitchNotice }, { c, v -> c.copy(isShowEpisodeSwitchNotice = v) }),
        Item.Toggle("priorityLandscape", t("优先横屏", "Prefer landscape"), null, Ic.ROTATE,
            { it.isPriorityLandscape }, { c, v -> c.copy(isPriorityLandscape = v) }),
        Item.Toggle("longPressSpeedAdjust", t("长按滑动调节倍速", "Slide to adjust the long-press speed"),
            t("关闭后长按仅使用固定倍速", "Off: a long press always uses the fixed speed"), Ic.TUNE,
            { it.isLongPressSpeedAdjustEnabled != false }, { c, v -> c.copy(isLongPressSpeedAdjustEnabled = v) }),

        Item.Section(t("信息显示", "On-screen info")),
        Item.Toggle("showStatsBar", t("显示帧率与编码", "Show frame rate and codec"), t("影响观影性能", "Costs some performance"), Ic.INFO,
            { it.isShowStatsBar }, { c, v -> c.copy(isShowStatsBar = v) }),
        Item.Toggle("showNetSpeed", t("始终显示网速", "Always show network speed"),
            t("无需开启上方信息栏即可看到下载速度", "See the download speed without opening the info bar"), Ic.BOLT,
            { it.showNetSpeed }, { c, v -> c.copy(showNetSpeed = v) }),
    )

    /** Changes the running kernel cannot take: the page reloads the video at the current position. */
    fun needsReload(old: PlaybackConfig, new: PlaybackConfig) =
        !old.kernel.equals(new.kernel, ignoreCase = true) || old.hwDecode != new.hwDecode
}
