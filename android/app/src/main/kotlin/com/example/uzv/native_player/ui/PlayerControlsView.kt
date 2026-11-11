package com.example.uzv.native_player.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.BatteryManager
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.example.uzv.native_player.PlayerController
import com.example.uzv.native_player.kernel.PlayerKernel
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * On-screen controls of the player page, laid out like UZN 1.1.7's (OBSERVED on the phone, 2026-11-11, playing a film;
 * screenshots in docs/ui-ref/original/orig_player_*.png).
 *
 * Landscape:
 *  - top left: a 38 dp round 返回, the title, chips under it (`1920x800`, the episode name);
 *  - top right: 34 dp round buttons 截图, 重新加载, 旋转屏幕, 画中画, (音轨, when there is more than one), 字幕, 设置, then
 *    the clock over a battery with its percentage;
 *  - 锁定 at both edges, 快退 / 快进 in the centre (hidden by 隐藏中央快进快退);
 *  - bottom: `00:13` ─ progress ─ `1:24:18` (the remaining time unless 进度条显示总时长), then a white round play / pause,
 *    上一集 / 下一集, 记片头 / 记片尾 and, on the right, 弹, 选集, the quality (`代理 ⁝`) and the speed (`1.0x`) pills.
 * Portrait: the buttons 截图 / 重新加载 / 画中画 / 字幕 fold into a `•••` menu, there is one 锁定 (right), the clock is not
 * shown and 弹 / 选集 move to a third row.
 *
 * Over the video, outside the controls: the loading box with the download speed, the long-press speed (`▷▷ 3.0x`),
 * volume / brightness bars, the seek preview (`»» 09:03` and a thin progress line), a pause glyph after a double tap,
 * the locked layer (two closed locks and `12:04 | 03:31 / 1:24:18` over a thin line), notices, menus and panels.
 * Menus drop from their button; panels cover the right 44 % in landscape and the lower 53 % in portrait.
 *
 * INFERRED: when 记片头 / 记片尾 are offered (seen: 记片头 until about 5 minutes in, not after), the brightness bar (only
 * the volume one was seen), and the play glyph shown when a double tap resumes.
 */
@SuppressLint("ViewConstructor")
class PlayerControlsView(
    context: Context,
    private val kernel: PlayerKernel,
    private val controller: PlayerController,
    private val actions: Actions,
) : FrameLayout(context) {
    interface Actions {
        fun onQuality(anchor: View)
        fun onSpeed(anchor: View)
        fun onEpisodes()
        fun onDanmaku()
        fun onEpg() {}
        fun onAudio(anchor: View)
        fun onSubtitles(anchor: View)
        fun onMore(anchor: View)
        fun onSettings()
        fun onPictureInPicture()
        fun onScreenshot()
        fun onReload()
        fun onRotate()
        fun onMarkIntro()
        fun onMarkOutro()
        fun onClose()
        fun onHaptic()
    }

    val ui = PlayerUi(context).also { u ->
        controller.playbackConfig.accentColorHex?.let { hex ->
            try { u.accent = Color.parseColor(if (hex.startsWith("#")) hex else "#$hex") } catch (_: IllegalArgumentException) {}
        }
    }
    private fun dp(v: Float) = ui.dp(v)
    private fun dp(v: Int) = ui.dp(v)

    private var title = ""
    private var landscape = true
    private var built = false
    private var cutoutInset = 0
    private var inPip = false
    private var seekWaitUntilMs = 0L
    private var lastRxBytes = -1L
    private var lastRxTimeMs = 0L
    private var liveRxSpeed = 0L

    private val controls = FrameLayout(context).apply { visibility = GONE }
    private var topBar: View? = null
    private var bottomBar: View? = null

    // views of the current build
    private var titleView: TextView? = null
    private var resolutionChip: TextView? = null
    private var episodeChip: TextView? = null
    private var playButton: FrameLayout? = null
    private var prev: View? = null
    private var next: View? = null
    private var rewind: View? = null
    private var forward: View? = null
    private var audioButton: View? = null
    private var subtitleButton: View? = null
    private var markButton: LinearLayout? = null
    private var danmakuPill: View? = null
    private var qualityPill: LinearLayout? = null
    private var speedPill: LinearLayout? = null
    private var episodesPill: LinearLayout? = null
    private var epgPill: View? = null
    private var positionView: TextView? = null
    private var rightTimeView: TextView? = null
    private var seek: SliderView? = null
    private var statsLine: TextView? = null
    private var clockView: TextView? = null
    private var batteryText: TextView? = null
    private var batteryView: BatteryView? = null
    private var playingShown: Boolean? = null

    private val loading = LinearLayout(context)
    private val loadingSpeed = ui.text("", 12f, 0xE6FFFFFF.toInt()).apply {
        typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
        gravity = Gravity.CENTER
        setSingleLine(true)
        includeFontPadding = false
    }
    private val notice = ui.text("", 13f).apply {
        background = ui.rounded(0xB3000000.toInt(), 18f)
        setPadding(dp(14), dp(7), dp(14), dp(7))
        visibility = GONE
    }
    private val cornerSpeed = ui.text("", 12f, 0x8DFFFFFF.toInt()).apply {
        gravity = Gravity.CENTER
        setSingleLine(true)
        setShadowLayer(2.5f, 0f, 1f, 0x66000000)
        visibility = GONE
    }
    private val hint = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; visibility = GONE }
    private val seekHint = FrameLayout(context).apply { visibility = GONE }
    private val seekHintIcon = ui.icon(Ic.DOUBLE_RIGHT, 20f)
    private val seekHintText = ui.text("", 15f)
    private val seekHintBar = SliderView(context, Color.WHITE, 0x40FFFFFF, 0f, 2f) { _, _ -> }.apply { isEnabled = false }
    private val centreFlash = FrameLayout(context).apply { visibility = GONE }
    private val lockLayer = FrameLayout(context).apply { visibility = GONE }
    private var lockInfo: TextView? = null
    private var lockBar: SliderView? = null
    private val skipBanner = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = ui.rounded(0xEB1C1C22.toInt(), 14f, 0x29FFFFFF, 0.8f)
        setPadding(dp(14), dp(12), dp(14), dp(12))
        visibility = GONE
    }
    private var skipCountdown = 0
    private var skipFromMs = 0L
    private var skipSubView: TextView? = null
    private val skipTick = object : Runnable {
        override fun run() {
            skipCountdown--
            if (skipCountdown <= 0) {
                skipBanner.visibility = GONE
            } else {
                skipSubView?.text = PlayerUiText.t("${skipCountdown} 秒后自动关闭", "Closes in ${skipCountdown}s")
                postDelayed(this, 1000)
            }
        }
    }
    private val menuHost = FrameLayout(context).apply { visibility = GONE }
    private val panelHost = FrameLayout(context).apply { visibility = GONE }

    /** The error layer (OBSERVED in 1.1.13, i2.P0): ⚠️ title, the message in a scroll box, 取消 / 复制错误信息 / 重试. */
    private val errorTitle = ui.text("", 17f, bold = true).apply { gravity = Gravity.CENTER }
    private val errorDetail = ui.text("", 13f, 0xFFE0E0E0.toInt()).apply { setTextIsSelectable(true) }
    private val errorScroll = ScrollView(context).apply { addView(errorDetail) }
    private val errorLayer = FrameLayout(context).apply {
        setBackgroundColor(0xCC000000.toInt())
        visibility = GONE
        isClickable = true
    }
    private var shownError: String? = null

    var locked = false
        private set

    private val hideTask = Runnable { hide() }
    private val hideNotice = Runnable { notice.visibility = GONE }
    private val hideHint = Runnable { hint.visibility = GONE }
    private val hideLock = Runnable { lockLayer.visibility = GONE }
    private val hideFlash = Runnable { centreFlash.animate().alpha(0f).setDuration(180).withEndAction { centreFlash.visibility = GONE }.start() }
    private val tick = object : Runnable {
        override fun run() {
            refreshInfo()
            if (visibleNow || lockLayer.visibility == VISIBLE) refresh()
            postDelayed(this, if (loading.visibility == VISIBLE) 250L else 500L)
        }
    }

    init {
        addView(controls, LayoutParams(-1, -1))
        loading.apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(20), dp(14), dp(20), dp(14))
            minimumWidth = dp(88)
            background = ui.rounded(0x80000000.toInt(), 14f, 0x1BFFFFFF, 1f)
            addView(
                RingSpinner(context),
                LinearLayout.LayoutParams(dp(30), dp(30)).apply { gravity = Gravity.CENTER_HORIZONTAL },
            )
            addView(
                loadingSpeed,
                LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                    topMargin = dp(8)
                    gravity = Gravity.CENTER_HORIZONTAL
                },
            )
            visibility = GONE
        }
        addView(loading, LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        addView(notice, LayoutParams(-2, -2, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = dp(64) })
        addView(cornerSpeed, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT, Gravity.TOP).apply { topMargin = dp(8) })
        addView(hint, LayoutParams(-2, -2, Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = dp(36) })
        seekHint.addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(seekHintIcon, LinearLayout.LayoutParams(-2, -2).apply { rightMargin = dp(8) })
            addView(seekHintText)
        }, LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL).apply { bottomMargin = dp(56) })
        seekHint.addView(seekHintBar, LayoutParams(-1, -2, Gravity.BOTTOM).apply { leftMargin = dp(16); rightMargin = dp(16); bottomMargin = dp(2) })
        addView(seekHint, LayoutParams(-1, -1))
        addView(centreFlash, LayoutParams(dp(56), dp(56), Gravity.CENTER))
        addView(skipBanner, LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.END).apply { rightMargin = dp(20); bottomMargin = dp(86) })
        addView(lockLayer, LayoutParams(-1, -1))
        addView(errorLayer.apply { addView(errorBox(), LayoutParams(-2, -2, Gravity.CENTER)) }, LayoutParams(-1, -1))
        addView(panelHost, LayoutParams(-1, -1))
        addView(menuHost, LayoutParams(-1, -1))
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            setOnApplyWindowInsetsListener { _, insets ->
                val dc = insets.displayCutout
                val nextInset = if (dc != null) maxOf(dc.safeInsetLeft, dc.safeInsetRight) else 0
                if (nextInset != cutoutInset) {
                    cutoutInset = nextInset
                    if (built) post { rebuild() }
                }
                insets
            }
        }
        post(tick)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val nowLandscape = w > h
        if (!built || nowLandscape != landscape) {
            landscape = nowLandscape
            post { rebuild() }
        }
    }

    // -- layout ---------------------------------------------------------------------------------------------------------

    /** Builds the controls for the current orientation; state comes back from the controller in [refresh]. */
    private fun rebuild() {
        built = true
        closeMenu()
        if (panelOpen) closePanel()
        controls.removeAllViews()
        playingShown = null
        val edgeLockMargin = (if (landscape) dp(20) else dp(16)) + cutoutInset
        topBar = buildTopBar().also { controls.addView(it, LayoutParams(-1, -2, Gravity.TOP)) }
        // 锁定: both edges in landscape, the right edge in portrait (matching P0.b cutout inset)
        if (landscape) controls.addView(lockButton(false), LayoutParams(dp(44), dp(44), Gravity.CENTER_VERTICAL or Gravity.LEFT).apply { leftMargin = edgeLockMargin })
        controls.addView(lockButton(false), LayoutParams(dp(44), dp(44), Gravity.CENTER_VERTICAL or Gravity.RIGHT).apply { rightMargin = edgeLockMargin })
        controls.addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            rewind = ui.icon(Ic.REWIND, 31f).also { v -> v.setOnClickListener { tap(); step(false) } }
            forward = ui.icon(Ic.FORWARD, 31f).also { v -> v.setOnClickListener { tap(); step(true) } }
            addView(rewind, LinearLayout.LayoutParams(dp(44), dp(44)))
            addView(View(context), LinearLayout.LayoutParams(dp(50), 1))
            addView(forward, LinearLayout.LayoutParams(dp(44), dp(44)))
        }, LayoutParams(-2, -2, Gravity.CENTER))
        bottomBar = buildBottomBar().also { controls.addView(it, LayoutParams(-1, -2, Gravity.BOTTOM)) }
        (seekHintBar.layoutParams as? LayoutParams)?.let { lp ->
            lp.leftMargin = dp(16) + cutoutInset
            lp.rightMargin = dp(16) + cutoutInset
            seekHintBar.layoutParams = lp
        }
        buildLockLayer()
        refresh()
    }

    private fun buildTopBar() = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(16) + cutoutInset, dp(10), dp(16) + cutoutInset, dp(14))
        background = GradientDrawable(GradientDrawable.Orientation.TOP_BOTTOM, intArrayOf(0x59000000, 0x00000000))
        addView(ui.circleButton(Ic.BACK, 38f, 20f).also { it.setOnClickListener { actions.onClose() } })
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(13), 0, dp(10), 0)
            titleView = ui.text(title, 16f).apply { maxLines = 1; ellipsize = TextUtils.TruncateAt.END; typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL) }
            addView(titleView)
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(0, dp(4), 0, 0)
                resolutionChip = ui.chip()
                episodeChip = ui.chip().apply { maxWidth = dp(if (landscape) 240 else 100) }
                addView(resolutionChip)
                addView(episodeChip, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = dp(6) })
            })
        }, LinearLayout.LayoutParams(0, -2, 1f))
        fun button(code: Int, onClick: (View) -> Unit) = ui.circleButton(code, 34f, 21f).also { b ->
            b.setOnClickListener { tap(); onClick(b) }
            addView(b, LinearLayout.LayoutParams(dp(34), dp(34)).apply { leftMargin = dp(8) })
        }
        audioButton = null
        subtitleButton = null
        if (landscape) {
            button(Ic.CAMERA) { actions.onScreenshot() }
            button(Ic.REFRESH) { actions.onReload() }
            button(Ic.ROTATE) { actions.onRotate() }
            button(Ic.PIP) { actions.onPictureInPicture() }
            audioButton = button(Ic.MUSIC) { actions.onAudio(it) }
            subtitleButton = button(Ic.SUBTITLES) { actions.onSubtitles(it) }
            button(Ic.SETTINGS) { actions.onSettings() }
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                clockView = ui.text("", 12.5f, mono = true).apply { letterSpacing = 0.04f }
                addView(clockView)
                addView(LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(0, dp(3), 0, 0)
                    batteryView = BatteryView(context)
                    batteryText = ui.text("", 10.5f, mono = true)
                    addView(batteryView, LinearLayout.LayoutParams(dp(19), dp(10)).apply { rightMargin = dp(5) })
                    addView(batteryText)
                })
            }, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = dp(16) })
        } else {
            clockView = null; batteryText = null; batteryView = null
            button(Ic.MORE) { actions.onMore(it) }
            button(Ic.ROTATE) { actions.onRotate() }
            button(Ic.SETTINGS) { actions.onSettings() }
        }
    }

    private fun lockButton(closed: Boolean) = ui.icon(if (closed) Ic.LOCK else Ic.LOCK_OPEN, 27f).apply {
        setOnClickListener { tap(); setLocked(!closed) }
    }

    private fun buildBottomBar() = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = GradientDrawable(GradientDrawable.Orientation.BOTTOM_TOP, intArrayOf(0x73000000, 0x00000000))
        setPadding(dp(16) + cutoutInset, dp(26), dp(16) + cutoutInset, dp(12))
        statsLine = ui.chip().apply { visibility = GONE }
        addView(statsLine, LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
            gravity = Gravity.END
            bottomMargin = dp(6)
        })
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            positionView = ui.text("00:00", 12f, 0xE6FFFFFF.toInt(), mono = true).apply {
                letterSpacing = 0.04f
                minWidth = dp(52)
            }
            rightTimeView = ui.text("00:00", 12f, 0x99FFFFFF.toInt(), mono = true).apply {
                letterSpacing = 0.04f
                minWidth = dp(52)
                gravity = Gravity.END
            }
            seek = SliderView(context, Color.WHITE, 0x38FFFFFF) { f, done ->
                val dur = kernel.durationMs
                val targetMs = (dur * f).toLong()
                positionView?.text = PlayerUiText.clock(targetMs)
                rightTimeView?.text = PlayerUiText.rightTime(targetMs, dur, controller.playbackConfig.isShowAllDuration)
                if (done) {
                    hideSeekHint()
                    beginSeekWait()
                    controller.seekTo(targetMs)
                    touch()
                } else {
                    removeCallbacks(hideTask)
                    showSeekHint(targetMs, targetMs >= kernel.positionMs, showBar = false)
                }
            }
            addView(positionView)
            addView(seek, LinearLayout.LayoutParams(0, -2, 1f).apply { leftMargin = dp(10); rightMargin = dp(10) })
            addView(rightTimeView)
        })
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(8), 0, 0)
        }
        playButton = FrameLayout(context).apply {
            background = ui.oval(Color.WHITE)
            setOnClickListener { tap(); controller.togglePause(); refresh() }
        }
        row.addView(playButton, LinearLayout.LayoutParams(dp(40), dp(40)))
        fun small(code: Int, onClick: () -> Unit) = ui.circleButton(code, 32f, 19f, 0x4D111114).also { b ->
            b.setOnClickListener { tap(); onClick() }
            row.addView(b, LinearLayout.LayoutParams(dp(32), dp(32)).apply { leftMargin = dp(8) })
        }
        prev = small(Ic.PREV) { controller.previousEpisode() }
        next = small(Ic.NEXT) { controller.nextEpisode() }
        markButton = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            background = ui.rounded(PlayerUi.BTN_FILL, 10f, PlayerUi.BTN_STROKE, 0.6f)
            setPadding(dp(14), 0, dp(13), 0)
            addView(ui.icon(Ic.SKIP_NEXT, 11f), LinearLayout.LayoutParams(-2, -2).apply { rightMargin = dp(8) })
            addView(ui.text("", 13.5f).apply { tag = "label" })
            setOnClickListener { tap(); if (markIsOutro) actions.onMarkOutro() else actions.onMarkIntro() }
        }
        val danmaku = ui.pill(PlayerUiText.t("弹", "Danmaku"), leading = Ic.FORUM).also { it.setOnClickListener { tap(); actions.onDanmaku() } }
        danmakuPill = danmaku
        episodesPill = ui.pill(if (controller.isLive) PlayerUiText.t("频道", "Channels") else PlayerUiText.t("选集", "Episodes"), leading = Ic.MENU).also { it.setOnClickListener { tap(); actions.onEpisodes() } }
        epgPill = ui.pill(PlayerUiText.t("节目单", "EPG"), leading = Ic.CLOCK).also {
            it.visibility = if (controller.epgProgrammes.isNotEmpty()) VISIBLE else GONE
            it.setOnClickListener { tap(); actions.onEpg() }
        }
        qualityPill = ui.pill("", trailing = Ic.UNFOLD).also { p -> p.setOnClickListener { tap(); actions.onQuality(p) } }
        speedPill = ui.pill("", mono = true).also { p -> p.setOnClickListener { tap(); actions.onSpeed(p) } }
        fun gap(l: Int) = LinearLayout.LayoutParams(-2, dp(32)).apply { leftMargin = dp(l) }
        if (landscape) {
            row.addView(markButton, LinearLayout.LayoutParams(-2, dp(38)).apply { leftMargin = dp(8) })
            row.addView(View(context), LinearLayout.LayoutParams(0, 1, 1f))
            row.addView(danmaku, gap(0))
            row.addView(episodesPill, gap(8))
            row.addView(epgPill, gap(8))
            row.addView(qualityPill, gap(8))
            row.addView(speedPill, gap(8))
            addView(row)
        } else {
            row.addView(View(context), LinearLayout.LayoutParams(0, 1, 1f))
            row.addView(qualityPill, gap(0))
            row.addView(speedPill, gap(8))
            addView(row)
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(8), dp(12), 0, 0)
                addView(danmaku, gap(0))
                addView(episodesPill, gap(8))
                addView(epgPill, gap(8))
                addView(markButton, LinearLayout.LayoutParams(-2, dp(32)).apply { leftMargin = dp(8) })
            })
        }
    }

    /** Locked: closed locks where the open ones were, and `clock | position / duration` over a thin progress line. */
    private fun buildLockLayer() {
        lockLayer.removeAllViews()
        val edgeLockMargin = (if (landscape) dp(20) else dp(16)) + cutoutInset
        if (landscape) lockLayer.addView(lockButton(true), LayoutParams(dp(44), dp(44), Gravity.CENTER_VERTICAL or Gravity.LEFT).apply { leftMargin = edgeLockMargin })
        lockLayer.addView(lockButton(true), LayoutParams(dp(44), dp(44), Gravity.CENTER_VERTICAL or Gravity.RIGHT).apply { rightMargin = edgeLockMargin })
        lockInfo = ui.text("", 10.5f, 0xE6FFFFFF.toInt())
        lockBar = SliderView(context, ui.accent, 0x33FFFFFF, 0f, 2f) { _, _ -> }.apply { isEnabled = false }
        lockLayer.addView(lockInfo, LayoutParams(-2, -2, Gravity.BOTTOM or Gravity.LEFT).apply { leftMargin = dp(27) + cutoutInset; bottomMargin = dp(22) })
        lockLayer.addView(lockBar, LayoutParams(-1, -2, Gravity.BOTTOM).apply { leftMargin = dp(19) + cutoutInset; rightMargin = dp(19) + cutoutInset; bottomMargin = dp(4) })
    }

    private fun errorBox() = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        gravity = Gravity.CENTER_HORIZONTAL
        setPadding(dp(28), dp(16), dp(28), dp(16))
        addView(errorTitle, LinearLayout.LayoutParams(-2, -2).apply { bottomMargin = dp(10) })
        addView(errorScroll, LinearLayout.LayoutParams(-2, -2).apply { bottomMargin = dp(18) })
        addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            val buttons = listOf<Pair<String, () -> Unit>>(
                PlayerUiText.t("取消", "Cancel") to { controller.dismissError() },
                PlayerUiText.t("复制错误信息", "Copy error") to { copyError() },
                PlayerUiText.t("重试", "Retry") to { controller.retry() },
            )
            buttons.forEachIndexed { i, (label, action) ->
                addView(ui.text(label, 14f).apply {
                    maxLines = 1
                    background = ui.rounded(if (i == buttons.lastIndex) 0x44FFFFFF else 0x22FFFFFF, 18f, 0x44FFFFFF)
                    setPadding(dp(18), dp(8), dp(18), dp(8))
                    setOnClickListener { action() }
                }, LinearLayout.LayoutParams(-2, -2).apply { if (i > 0) leftMargin = dp(12) })
            }
        }, LinearLayout.LayoutParams(-2, -2))
    }

    private fun copyError() {
        val message = shownError ?: return
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as android.content.ClipboardManager
        clipboard.setPrimaryClip(android.content.ClipData.newPlainText("player_error", message))
        android.widget.Toast.makeText(context, PlayerUiText.t("已复制错误信息", "Error copied"), android.widget.Toast.LENGTH_SHORT).show()
    }

    private fun refreshError() {
        val message = controller.error
        if (message == shownError) return
        shownError = message
        if (message == null) { errorLayer.visibility = GONE; return }
        hide()
        errorTitle.text = PlayerUiText.errorTitle(message)
        errorDetail.text = PlayerUiText.errorDetail(message)
        errorScroll.layoutParams = errorScroll.layoutParams.apply { height = LayoutParams.WRAP_CONTENT }
        errorScroll.post {
            val max = (height * 0.4f).toInt()
            if (max > 0 && errorScroll.height > max) errorScroll.layoutParams = errorScroll.layoutParams.apply { height = max }
        }
        errorLayer.alpha = 0f
        errorLayer.visibility = VISIBLE
        errorLayer.animate().alpha(1f).setDuration(200).start()
    }

    // -- state ----------------------------------------------------------------------------------------------------------

    fun setTitle(text: String) { title = text; titleView?.text = text }

    val visibleNow get() = controls.visibility == VISIBLE

    /** A tap on the video: the controls, or the locks while locked. */
    fun toggle() {
        if (locked) {
            if (lockLayer.visibility == VISIBLE) { removeCallbacks(hideLock); lockLayer.visibility = GONE } else showLockLayer()
            return
        }
        if (visibleNow) hide() else show()
    }

    /** OBSERVED: the top bar slides down and the bottom bar slides up while the controls fade in. */
    fun show() {
        if (locked || !built) return
        if (!visibleNow) {
            controls.visibility = VISIBLE
            controls.alpha = 0f
            controls.animate().alpha(1f).setDuration(180).start()
            topBar?.let { it.translationY = -dp(18).toFloat(); it.animate().translationY(0f).setDuration(180).start() }
            bottomBar?.let { it.translationY = dp(18).toFloat(); it.animate().translationY(0f).setDuration(180).start() }
        }
        refresh()
        refreshInfo()
        touch()
    }

    fun hide() {
        removeCallbacks(hideTask)
        if (!visibleNow) return
        controls.animate().cancel()
        controls.visibility = GONE
        refreshInfo()
    }

    /** Restarts the auto-hide timer; called after any interaction with the controls. */
    fun touch() {
        removeCallbacks(hideTask)
        postDelayed(hideTask, 4000)
    }

    private fun tap() { touch(); actions.onHaptic() }

    fun setLocked(value: Boolean) {
        locked = value
        if (value) { hide(); closeMenu(); showLockLayer() } else { removeCallbacks(hideLock); lockLayer.visibility = GONE; show() }
    }

    private fun showLockLayer() {
        lockLayer.visibility = VISIBLE
        refresh()
        removeCallbacks(hideLock)
        postDelayed(hideLock, 3000)
    }

    fun showNotice(text: String) {
        notice.text = text
        notice.visibility = VISIBLE
        removeCallbacks(hideNotice)
        postDelayed(hideNotice, 2000)
    }

    /** Bottom-right skip prompt matching original i2.c1 (已跳过片段，是否返回原播放进度？). */
    fun showSkipBanner(fromMs: Long) {
        removeCallbacks(skipTick)
        skipFromMs = fromMs
        skipCountdown = 5
        skipBanner.removeAllViews()
        skipBanner.addView(ui.text(PlayerUiText.t("已跳过片段，是否返回原播放进度？", "Skipped intro, return to previous position?"), 13f, bold = true))
        val sub = ui.text(PlayerUiText.t("5 秒后自动关闭", "Closes in 5s"), 11.5f, 0x99FFFFFF.toInt())
        skipSubView = sub
        skipBanner.addView(sub, LinearLayout.LayoutParams(-2, -2).apply { topMargin = dp(3); bottomMargin = dp(10) })
        skipBanner.addView(LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END
            addView(ui.text(PlayerUiText.t("返回", "Return"), 12f, ui.accent, bold = true).apply {
                background = ui.rounded(PlayerUi.withAlpha(ui.accent, 0.18f), 8f)
                setPadding(dp(12), dp(5), dp(12), dp(5))
                setOnClickListener {
                    removeCallbacks(skipTick)
                    skipBanner.visibility = GONE
                    actions.onHaptic()
                    kernel.seekTo(skipFromMs)
                    refresh()
                }
            })
            addView(ui.text(PlayerUiText.t("继续观看", "Continue"), 12f, 0xCCFFFFFF.toInt()).apply {
                background = ui.rounded(0x1FFFFFFF, 8f)
                setPadding(dp(12), dp(5), dp(12), dp(5))
                setOnClickListener {
                    removeCallbacks(skipTick)
                    skipBanner.visibility = GONE
                    actions.onHaptic()
                }
            }, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = dp(8) })
        })
        skipBanner.visibility = VISIBLE
        postDelayed(skipTick, 1000)
    }

    // -- gesture feedback -----------------------------------------------------------------------------------------------

    private fun setHint(code: Int, label: String, fraction: Float?) {
        hint.removeAllViews()
        hint.addView(ui.icon(code, 17f, 0xD9FFFFFF.toInt()), LinearLayout.LayoutParams(-2, -2).apply { rightMargin = dp(8) })
        if (fraction != null) {
            hint.addView(SliderView(context, Color.WHITE, 0x40FFFFFF, 0f, 3f) { _, _ -> }.apply { isEnabled = false; this.fraction = fraction },
                LinearLayout.LayoutParams(dp(78), -2).apply { rightMargin = dp(8) })
        }
        hint.addView(ui.text(label, 13.5f, 0xD9FFFFFF.toInt(), mono = fraction == null))
        hint.visibility = VISIBLE
        removeCallbacks(hideHint)
    }

    /** `▷▷ 3.0x` while a long press holds. */
    fun showSpeedHint(speed: Double) = setHint(Ic.FORWARD, PlayerUiText.speed(speed), null)

    /** 🔈 ▬▬ 36 % / ☀ ▬▬ 50 % while a vertical swipe changes the volume or the brightness. */
    fun showLevelHint(volume: Boolean, fraction: Float) {
        val code = if (!volume) Ic.BRIGHTNESS else if (fraction <= 0f) Ic.VOLUME_MUTE else if (fraction < 0.5f) Ic.VOLUME_DOWN else Ic.VOLUME_UP
        setHint(code, "${Math.round(fraction * 100)}%", fraction)
    }

    fun hideHint(delayMs: Long = 0) { removeCallbacks(hideHint); if (delayMs <= 0) hint.visibility = GONE else postDelayed(hideHint, delayMs) }

    /** `»» 09:03` and a thin line of where the swipe would seek to. */
    fun showSeekHint(targetMs: Long, forward: Boolean, showBar: Boolean = true) {
        val dur = kernel.durationMs
        seekHintIcon.text = String(Character.toChars(if (forward) Ic.DOUBLE_RIGHT else Ic.DOUBLE_LEFT))
        seekHintText.text = PlayerUiText.clock(targetMs)
        seekHintBar.fraction = if (dur > 0) targetMs.toFloat() / dur else 0f
        seekHintBar.visibility = if (showBar && !visibleNow) VISIBLE else GONE
        seekHint.visibility = VISIBLE
    }

    fun hideSeekHint() { seekHint.visibility = GONE }

    fun beginSeekWait() {
        seekWaitUntilMs = android.os.SystemClock.elapsedRealtime() + 450L
        refreshInfo()
        removeCallbacks(tick)
        postDelayed(tick, 200L)
    }

    fun setPipMode(pip: Boolean) {
        if (inPip == pip) return
        inPip = pip
        if (pip) {
            hide()
            closeMenu()
            if (panelOpen) closePanel()
            lockLayer.visibility = GONE
            skipBanner.visibility = GONE
            cornerSpeed.visibility = GONE
        } else {
            refresh()
            refreshInfo()
        }
    }

    /** The glyph in the middle after a double tap paused or resumed. */
    fun flashPlayState(paused: Boolean) {
        centreFlash.removeAllViews()
        centreFlash.addView(ui.icon(if (paused) Ic.PAUSE else Ic.PLAY, 56f), LayoutParams(-1, -1))
        centreFlash.animate().cancel()
        centreFlash.alpha = 1f
        centreFlash.visibility = VISIBLE
        removeCallbacks(hideFlash)
        postDelayed(hideFlash, 700)
    }

    // -- refresh --------------------------------------------------------------------------------------------------------

    private var markIsOutro = false

    /** Labels and visibility that follow the episode, the quality list and 播放器设置. */
    fun refresh() {
        refreshInfo()
        if (!built) return
        val cfg = controller.playbackConfig
        val playing = kernel.isPlaying
        if (playingShown != playing) {
            playingShown = playing
            playButton?.let { b ->
                b.removeAllViews()
                if (playing) b.addView(PauseBars(context, Color.BLACK), LayoutParams(dp(26), dp(26), Gravity.CENTER))
                else b.addView(ui.icon(Ic.PLAY, 26f, Color.BLACK), LayoutParams(-2, -2, Gravity.CENTER))
            }
        }
        prev?.let { it.isEnabled = controller.hasPrevious; it.alpha = if (controller.hasPrevious) 1f else 0.45f }
        next?.let { it.isEnabled = controller.hasNext; it.alpha = if (controller.hasNext) 1f else 0.45f }
        val hideSeek = cfg.isHiddenFastSeekBtn || loading.visibility == VISIBLE
        rewind?.visibility = if (hideSeek) GONE else VISIBLE
        forward?.visibility = if (hideSeek) GONE else VISIBLE
        val live = controller.isLive
        danmakuPill?.visibility = if (live) GONE else VISIBLE
        episodesPill?.let { ui.pillLabel(it).text = if (live) PlayerUiText.t("频道", "Channels") else PlayerUiText.t("选集", "Episodes") }
        qualityPill?.let { p ->
            val q = controller.qualityName
            p.visibility = if (q == null) GONE else VISIBLE
            ui.pillLabel(p).text = q.orEmpty()
        }
        speedPill?.let {
            it.visibility = if (live) GONE else VISIBLE
            ui.pillLabel(it).text = PlayerUiText.speed(controller.currentSpeed)
        }
        epgPill?.visibility = if (controller.epgProgrammes.isNotEmpty()) VISIBLE else GONE
        audioButton?.visibility = if (kernel.audioTracks().size > 1) VISIBLE else GONE
        subtitleButton?.visibility = if (!live || kernel.subtitleTracks().size > 1) VISIBLE else GONE
        titleView?.text = title
        episodeChip?.let { c ->
            val name = controller.episodeName
            c.text = name.orEmpty()
            c.visibility = if (name.isNullOrBlank()) GONE else VISIBLE
        }
        resolutionChip?.let { c ->
            val res = PlayerUiText.resolution(kernel.mediaInfo())
            c.text = res.orEmpty()
            c.visibility = if (res == null) GONE else VISIBLE
        }
        val pos = kernel.positionMs
        val dur = kernel.durationMs
        // INFERRED window: 记片头 in the first five minutes, 记片尾 in the last five (only 记片头 was seen, up to 04:16)
        val mark = PlayerUiText.markButton(pos, dur, controller.canMarkHeadTail)
        markButton?.let { b ->
            b.visibility = if (mark == null) GONE else VISIBLE
            markIsOutro = mark == false
            b.findViewWithTag<TextView>("label").text = if (mark == false) PlayerUiText.t("记片尾", "Mark outro") else PlayerUiText.t("记片头", "Mark intro")
        }
        seek?.let { s ->
            if (!s.dragging) {
                s.fraction = if (dur > 0) pos.toFloat() / dur else 0f
                positionView?.text = PlayerUiText.clock(pos)
                rightTimeView?.text = PlayerUiText.rightTime(pos, dur, cfg.isShowAllDuration)
            }
        }
        val now = SimpleDateFormat("HH:mm", Locale.ROOT).format(Date())
        clockView?.text = now
        if (batteryText != null) batteryLevel()?.let { level ->
            batteryText?.text = "${Math.round(level * 100)}%"
            batteryView?.level = level
        }
        lockInfo?.text = "$now  |  ${PlayerUiText.clock(pos)} / ${PlayerUiText.clock(dur)}"
        lockBar?.fraction = if (dur > 0) pos.toFloat() / dur else 0f
    }

    private fun batteryLevel(): Float? {
        val i: Intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return null
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        return if (level < 0 || scale <= 0) null else level.toFloat() / scale
    }

    private fun currentDownloadSpeed(): Long? {
        val nowMs = android.os.SystemClock.elapsedRealtime()
        val rx = android.net.TrafficStats.getUidRxBytes(android.os.Process.myUid())
        if (rx >= 0) {
            if (lastRxBytes >= 0 && nowMs > lastRxTimeMs) {
                val dt = nowMs - lastRxTimeMs
                if (dt >= 180) {
                    val delta = (rx - lastRxBytes).coerceAtLeast(0L)
                    liveRxSpeed = (delta * 1000L) / dt
                    lastRxBytes = rx
                    lastRxTimeMs = nowMs
                }
            } else {
                lastRxBytes = rx
                lastRxTimeMs = nowMs
            }
        }
        val kSpeed = kernel.downloadSpeed() ?: 0L
        val best = maxOf(kSpeed, liveRxSpeed)
        return if (best > 0L) best else kernel.downloadSpeed()
    }

    /** Buffering speed, 始终显示网速 and 显示帧率与编码, from the kernel (OBSERVED in the original, B3.d case 4). */
    private fun refreshInfo() {
        val cfg = controller.playbackConfig
        val speed = currentDownloadSpeed()
        val bitrate = kernel.videoBitrate()
        refreshError()
        val nowMs = android.os.SystemClock.elapsedRealtime()
        val buffering = ((controller.state == "buffering" || controller.state == "idle" || nowMs < seekWaitUntilMs) && !controller.failed && !inPip)
        val wasVisible = loading.visibility == VISIBLE
        loading.visibility = if (buffering) VISIBLE else GONE
        loadingSpeed.text = PlayerUiText.bufferingSpeed(speed)
        if (wasVisible != buffering && built) {
            val hideSeek = cfg.isHiddenFastSeekBtn || buffering
            rewind?.visibility = if (hideSeek) GONE else VISIBLE
            forward?.visibility = if (hideSeek) GONE else VISIBLE
        }
        val line = if (cfg.isShowStatsBar || cfg.showNetSpeed)
            PlayerUiText.statsLine(cfg.isShowStatsBar, kernel.mediaInfo(), speed, bitrate) else null
        statsLine?.let { it.text = line.orEmpty(); it.visibility = if (line != null) VISIBLE else GONE }
        val persistent = if (cfg.showNetSpeed) PlayerUiText.persistentSpeed(speed, bitrate) else null
        cornerSpeed.text = persistent.orEmpty()
        cornerSpeed.visibility = if (persistent != null && !visibleNow && !buffering && !inPip) VISIBLE else GONE
    }

    private fun step(forward: Boolean) {
        val seconds = controller.playbackConfig.fastForwardSeconds.toInt()
        beginSeekWait()
        controller.seekBy(if (forward) seconds else -seconds)
        refresh()
    }

    // -- menus ----------------------------------------------------------------------------------------------------------

    class MenuItem(val label: String, val selected: Boolean = false, val dividerBefore: Boolean = false, val onClick: () -> Unit)

    val menuOpen get() = menuHost.visibility == VISIBLE

    fun closeMenu() {
        menuHost.removeAllViews()
        menuHost.visibility = GONE
        if (visibleNow) touch()
    }

    /**
     * A menu card dropped from [anchor]: below it for the top bar's buttons ([above] false, left edges aligned), above it
     * for the bottom bar's pills (right edges aligned). Kept inside the page with an 8 dp margin.
     */
    fun showMenuCard(anchor: View, above: Boolean, card: View) {
        removeCallbacks(hideTask)
        menuHost.removeAllViews()
        menuHost.addView(View(context).apply { setOnClickListener { closeMenu() } }, LayoutParams(-1, -1))
        card.background = ui.rounded(PlayerUi.MENU_FILL, 16f, 0x14FFFFFF, 0.6f)
        card.elevation = dp(6).toFloat()
        card.isClickable = true
        menuHost.addView(card, LayoutParams(-2, -2))
        menuHost.visibility = VISIBLE
        card.visibility = INVISIBLE
        card.post {
            val a = IntArray(2).also { anchor.getLocationInWindow(it) }
            val me = IntArray(2).also { getLocationInWindow(it) }
            val ax = a[0] - me[0]; val ay = a[1] - me[1]
            val m = dp(8)
            val x = if (above) ax + anchor.width - card.width else ax - dp(2)
            val y = if (above) ay - card.height - dp(7) else ay + anchor.height + dp(7)
            card.translationX = x.coerceIn(m, (width - card.width - m).coerceAtLeast(m)).toFloat()
            card.translationY = y.coerceIn(m, (height - card.height - m).coerceAtLeast(m)).toFloat()
            card.alpha = 0f
            card.visibility = VISIBLE
            card.animate().alpha(1f).setDuration(120).start()
        }
    }

    /** A plain list menu: 44 dp rows, the current one bold with an accent ✓ at the right. */
    fun showMenu(anchor: View, above: Boolean, items: List<MenuItem>) {
        val list = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(0, dp(4), 0, dp(4)) }
        for (item in items) {
            if (item.dividerBefore) list.addView(View(context).apply { setBackgroundColor(0x1FFFFFFF) },
                LinearLayout.LayoutParams(-1, 1).apply { leftMargin = dp(14); rightMargin = dp(14); topMargin = dp(4); bottomMargin = dp(4) })
            list.addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = dp(44)
                minimumWidth = dp(120)
                setPadding(dp(18), 0, dp(14), 0)
                addView(ui.text(item.label, 14.5f, if (item.selected) Color.WHITE else 0xB8FFFFFF.toInt(), bold = item.selected).apply {
                    maxLines = 1; ellipsize = TextUtils.TruncateAt.END; maxWidth = dp(220)
                }, LinearLayout.LayoutParams(0, -2, 1f))
                if (item.selected) addView(ui.icon(Ic.CHECK, 15f, ui.accent), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = dp(18) })
                setOnClickListener { closeMenu(); actions.onHaptic(); item.onClick() }
            }, LinearLayout.LayoutParams(-1, -2))
        }
        val scroll = ScrollView(context).apply { addView(list); isVerticalScrollBarEnabled = false }
        showMenuCard(anchor, above, FrameLayout(context).apply {
            addView(scroll, LayoutParams(-2, -2))
            clipToOutline = true
        })
    }

    /**
     * The speed menu (OBSERVED): a tall slider on the left (0.5x at the bottom to 3.0x at the top, the value shown at its
     * top), the presets 3x … 0.5x on the right with the current one tinted and ticked, and the current speed under a
     * hairline. INFERRED: the slider moves in steps of 0.1 (the original's string 倍速调节 (+/- 0.1)).
     */
    fun showSpeedMenu(anchor: View, current: Double, onPick: (Double) -> Unit) {
        val footer = ui.text(PlayerUiText.speedOption(current), 12.5f, 0x99FFFFFF.toInt()).apply { gravity = Gravity.CENTER }
        val rows = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        lateinit var slider: VerticalFillSlider
        fun fractionOf(v: Double) = ((v - 0.5) / 2.5).toFloat()
        fun fillRows(value: Double) {
            rows.removeAllViews()
            for (s in PlayerUiText.speeds.reversed()) {
                val sel = Math.abs(s - value) < 0.001
                rows.addView(LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    background = if (sel) ui.rounded(PlayerUi.withAlpha(ui.accent, 0.22f), 8f) else null
                    setPadding(dp(10), 0, dp(10), 0)
                    addView(if (sel) ui.icon(Ic.CHECK, 12f, ui.accent) else View(context), LinearLayout.LayoutParams(dp(12), dp(12)).apply { rightMargin = dp(8) })
                    addView(ui.text(PlayerUiText.speedMenuLabel(s), 13f, if (sel) ui.accent else Color.WHITE, mono = true))
                    setOnClickListener { actions.onHaptic(); onPick(s); closeMenu() }
                }, LinearLayout.LayoutParams(-1, dp(32)))
            }
        }
        slider = VerticalFillSlider(context, ui.accent) { f, done ->
            val v = Math.round((0.5 + f * 2.5) * 10) / 10.0
            slider.topLabel = PlayerUiText.speed(v)
            footer.text = PlayerUiText.speedOption(v)
            fillRows(v)
            if (done) onPick(v)
        }.apply { fraction = fractionOf(current); topLabel = PlayerUiText.speed(current); bottomLabel = "0.5" }
        fillRows(current)
        showMenuCard(anchor, true, LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(8), dp(8), dp(8), dp(8))
            addView(slider, LinearLayout.LayoutParams(dp(34), dp(254)))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(8), 0, 0, 0)
                addView(rows, LinearLayout.LayoutParams(dp(128), -2))
                addView(View(context).apply { setBackgroundColor(0x1FFFFFFF) }, LinearLayout.LayoutParams(-1, 1).apply { topMargin = dp(4) })
                addView(footer, LinearLayout.LayoutParams(-1, 0, 1f))
            }, LinearLayout.LayoutParams(-2, -1))
        })
    }

    // -- panels ---------------------------------------------------------------------------------------------------------

    val panelOpen get() = panelHost.visibility == VISIBLE

    /**
     * A translucent sheet over the video: the right 44 % in landscape, the lower 53 % in portrait (OBSERVED). [header]
     * stays fixed above the scrolling [fill]ed body. Tapping the video beside it closes it. Returns the scroll view.
     */
    fun showPanel(header: View? = null, fill: (LinearLayout) -> Unit): ScrollView {
        val body = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16), 0, dp(16), dp(20)) }
        fill(body)
        val scroll = ScrollView(context).apply { addView(body); isVerticalScrollBarEnabled = true }
        showCustomPanel(header, scroll)
        return scroll
    }

    /** Hosts a custom view (such as the 2-column Live TV Channel panel i2.o0) inside the right/bottom panel sheet. */
    fun showCustomPanel(header: View? = null, content: View) {
        removeCallbacks(hideTask)
        hide()
        closeMenu()
        panelHost.removeAllViews()
        panelHost.addView(View(context).apply { setOnClickListener { closePanel() } }, LayoutParams(-1, -1))
        val sheet = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            isClickable = true
            background = GradientDrawable().apply {
                setColor(PlayerUi.PANEL_FILL)
                val r = dp(16).toFloat()
                cornerRadii = if (landscape) floatArrayOf(r, r, 0f, 0f, 0f, 0f, r, r) else floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
            }
            clipToOutline = true
            if (header != null) addView(header) else setPadding(0, dp(6), 0, 0)
            addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        val lp = if (landscape) LayoutParams((width * 0.44f).toInt().coerceAtLeast(dp(300)).coerceAtMost(width), -1, Gravity.END)
        else LayoutParams(-1, (height * 0.526f).toInt(), Gravity.BOTTOM)
        panelHost.addView(sheet, lp)
        panelHost.visibility = VISIBLE
        if (landscape) { sheet.translationX = dp(40).toFloat(); sheet.animate().translationX(0f) } else { sheet.translationY = dp(40).toFloat(); sheet.animate().translationY(0f) }
        sheet.alpha = 0f
        sheet.animate().alpha(1f).setDuration(160).start()
    }

    fun closePanel() {
        panelHost.removeAllViews()
        panelHost.visibility = GONE
        onPanelClosed?.invoke()
        onPanelClosed = null
    }

    /** Runs once when the open panel closes (the 弹幕 panel saves its settings then). */
    var onPanelClosed: (() -> Unit)? = null
}
