package com.example.uzv.native_player

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Rational
import android.view.GestureDetector
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.example.uzv.native_player.kernel.ExoKernel
import com.example.uzv.native_player.kernel.KernelSelection
import com.example.uzv.native_player.kernel.PlayerKernel
import com.example.uzv.native_player.kernel.mpv.MpvKernel
import com.example.uzv.native_player.kernel.mdk.MdkKernel
import com.example.uzv.native_player.kernel.mdk.MdkNative
import com.example.uzv.native_player.kernel.mpv.MpvNative
import com.example.uzv.native_player.media.PlaybackNotificationService
import com.example.uzv.Haptics
import com.example.uzv.native_player.ui.DanmakuView
import com.example.uzv.native_player.ui.Ic
import com.example.uzv.native_player.ui.PlayerControlsView
import com.example.uzv.native_player.ui.PlayerSettings
import com.example.uzv.native_player.ui.PlayerUi
import com.example.uzv.native_player.ui.PlayerUiText
import com.example.uzv.native_player.ui.SliderView
import com.example.uzv.native_player.ui.SwitchView

/**
 * Full-screen native player page (run on Waydroid and on a Xiaomi phone, 2026-11-10).
 *
 * OBSERVED lifecycle overrides of the shipped class: onCreate, onNewIntent, onKeyDown, onBackPressed,
 * onUserLeaveHint (auto PiP), onPictureInPictureModeChanged, onWindowFocusChanged (immersive re-apply),
 * onStop, onDestroy, onActivityResult; it keeps the screen on (FLAG_KEEP_SCREEN_ON), finishes immediately when no
 * OpenPlayerRequest is pending, asks for POST_NOTIFICATIONS once (pref "notif_permission_asked") before starting
 * the media-playback service.
 */
class NativePlayerActivity : AppCompatActivity() {
    private var controller: PlayerController? = null
    private var inPip = false
    private var wasInPip = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val request = NativePlayerHost.takePending()
        if (request == null) { finish(); return }

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        applyOrientation(request.playbackConfig)

        val root = FrameLayout(this).apply { setBackgroundColor(0xFF000000.toInt()) }
        val kernel = createKernel(request.playbackConfig)
        val danmaku = DanmakuView(this).also { it.attach(kernel) }
        root.addView(kernel.view, FrameLayout.LayoutParams(-1, -1))
        root.addView(danmaku, FrameLayout.LayoutParams(-1, -1))
        val c = PlayerController(request, kernel, danmaku) { finish() }
        controller = c
        NativePlayerHost.controller = c
        c.applyHeadTail()

        val controls = PlayerControlsView(this, kernel, c, object : PlayerControlsView.Actions {
            override fun onQuality(anchor: View) = showQuality(c, anchor)
            override fun onSpeed(anchor: View) = showSpeed(c, anchor)
            override fun onEpisodes() = if (c.isLive) showChannels(c) else showEpisodes(c)
            override fun onDanmaku() { danmakuSubScreen = 0; showDanmaku(c) }
            override fun onEpg() = showEpg(c)
            override fun onAudio(anchor: View) = showAudio(c, anchor)
            override fun onSubtitles(anchor: View) = showSubtitles(c, anchor)
            override fun onMore(anchor: View) = showMore(c, anchor)
            override fun onSettings() = showSettings(c)
            override fun onPictureInPicture() = enterPip()
            override fun onScreenshot() = takeScreenshot(kernel)
            override fun onReload() = c.retry()
            override fun onRotate() = rotate()
            override fun onMarkIntro() = c.markIntro()
            override fun onMarkOutro() = c.markOutro()
            override fun onClose() = c.close()
            override fun onHaptic() = haptic(c, Haptics.SELECTION)
        }).also { it.setTitle(request.title) }
        this.controls = controls
        root.addView(controls, FrameLayout.LayoutParams(-1, -1))
        c.uiListener = object : PlayerController.UiListener {
            override fun onChanged() = controls.refresh()
            override fun onNotice(text: String) = controls.showNotice(text)
            override fun onToast(text: String, long: Boolean) =
                Toast.makeText(this@NativePlayerActivity, text, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()
        }
        c.danmakuSearchListener = { results -> onDanmakuResults(c, results) }
        c.danmakuEpisodesListener = { episodes -> onDanmakuEpisodes(c, episodes) }
        c.danmakuCountListener = { count ->
            danmakuCountBadge?.let {
                it.text = PlayerUiText.t("$count 条", "$count")
                it.visibility = if (count > 0) View.VISIBLE else View.GONE
            }
            danmakuStatusText?.text = if (count > 0) PlayerUiText.t("当前已加载 $count 条弹幕", "$count comments loaded")
            else PlayerUiText.t("当前未加载弹幕", "No comments loaded")
        }
        c.onSkipIntro = { fromMs -> controls.showSkipBanner(fromMs) }
        setContentView(root)
        hideSystemBars()
        installGestures(root, controls, c, kernel)

        PlaybackNotificationService.start(this, request.title)
        c.start()
    }

    /** 功能设置 → 触感反馈 (PlaybackConfig.hapticEnabled): the same short vibrations as in the Flutter pages. */
    private fun haptic(c: PlayerController, kind: String) { if (c.playbackConfig.hapticEnabled) Haptics.play(this, kind) }

    /**
     * Touches on the video (OBSERVED in UZN 1.2.0 on the phone, 2026-11-11):
     *  - a tap shows / hides the controls (the locks while locked);
     *  - a double tap pauses or resumes and flashes the glyph in the middle;
     *  - a long press plays at 长按倍速 (`▷▷ 3.0x` at the top) until released, sliding up / down changes it (长按滑动调节倍速);
     *  - a horizontal swipe previews a seek (`»» 09:03` and a thin progress line) and seeks on release, without showing
     *    the controls (changelog 1.1.12);
     *  - a vertical swipe on the right half changes the media volume (a bar and a percentage at the top).
     * INFERRED: the left half changes the screen brightness (iOS changelog: 滑动调节音量/亮度), the distances (two minutes
     * per screen width; the whole volume range per 300 dp, from one measurement: 146 dp moved it 48 %).
     */
    private fun installGestures(root: FrameLayout, controls: PlayerControlsView, c: PlayerController, kernel: PlayerKernel) {
        val density = resources.displayMetrics.density
        val slop = android.view.ViewConfiguration.get(this).scaledTouchSlop
        val slideStepPx = 50 * density // original: one speed step per 50 dp
        val levelRangePx = 300 * density
        val audio = getSystemService(AUDIO_SERVICE) as AudioManager
        var longPressing = false
        var longPressY = 0f
        var mode = 0 // 0 none, 1 seek, 2 volume, 3 brightness
        var downX = 0f
        var downY = 0f
        var startPos = 0L
        var startLevel = 0f
        var seekTarget = 0L
        val gestures = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                if (controls.menuOpen) controls.closeMenu() else if (controls.panelOpen) controls.closePanel() else controls.toggle()
                return true
            }
            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (controls.locked) return true
                val wasPlaying = kernel.isPlaying
                c.togglePause()
                controls.flashPlayState(paused = wasPlaying)
                controls.refresh()
                haptic(c, Haptics.LIGHT)
                return true
            }
            override fun onLongPress(e: MotionEvent) {
                if (controls.locked || mode != 0 || !kernel.isPlaying) return
                val speed = c.playbackConfig.longPressSpeed
                longPressing = true
                longPressY = e.y
                kernel.speed = speed.toFloat()
                controls.showSpeedHint(speed)
                haptic(c, Haptics.MEDIUM)
            }
        })
        root.setOnTouchListener { _, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> { downX = ev.x; downY = ev.y; mode = 0 }
                MotionEvent.ACTION_MOVE -> if (longPressing) {
                    // 长按滑动调节倍速: slide up / down while holding to change the long-press speed
                    val cfg = c.playbackConfig
                    val speed = PlayerUiText.longPressSlideSpeed(cfg.longPressSpeed, longPressY - ev.y, slideStepPx, cfg.isLongPressSpeedAdjustEnabled)
                    if (kernel.speed != speed.toFloat()) { kernel.speed = speed.toFloat(); controls.showSpeedHint(speed) }
                } else if (!controls.locked && !controls.panelOpen && !controls.menuOpen) {
                    val dx = ev.x - downX
                    val dy = ev.y - downY
                    if (mode == 0 && (Math.abs(dx) > slop * 2 || Math.abs(dy) > slop * 2)) {
                        // swipes that start at the very edge belong to the system's back / bars gestures
                        val edge = 24 * density
                        if (downX < edge || downX > root.width - edge || downY < edge || downY > root.height - edge) mode = -1
                        else if (Math.abs(dx) > Math.abs(dy)) {
                            if (kernel.durationMs > 0) { mode = 1; startPos = kernel.positionMs } else mode = -1
                        } else if (downX > root.width / 2f) {
                            mode = 2
                            startLevel = audio.getStreamVolume(AudioManager.STREAM_MUSIC).toFloat() / audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                        } else {
                            mode = 3
                            val b = window.attributes.screenBrightness
                            startLevel = if (b >= 0f) b else systemBrightness()
                        }
                    }
                    when (mode) {
                        1 -> {
                            seekTarget = (startPos + PlayerUiText.swipeSeekMs(dx, root.width)).coerceIn(0, kernel.durationMs)
                            controls.showSeekHint(seekTarget, dx >= 0)
                        }
                        2 -> {
                            val level = (startLevel - dy / levelRangePx).coerceIn(0f, 1f)
                            val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            audio.setStreamVolume(AudioManager.STREAM_MUSIC, Math.round(level * max), 0)
                            controls.showLevelHint(volume = true, fraction = level)
                        }
                        3 -> {
                            val level = (startLevel - dy / levelRangePx).coerceIn(0.01f, 1f)
                            window.attributes = window.attributes.apply { screenBrightness = level }
                            controls.showLevelHint(volume = false, fraction = level)
                        }
                    }
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (longPressing) {
                        longPressing = false
                        kernel.speed = c.currentSpeed.toFloat() // release ends long-press speed
                        controls.hideHint()
                    }
                    if (mode == 1) {
                        controls.hideSeekHint()
                        if (ev.actionMasked == MotionEvent.ACTION_UP) {
                            controls.beginSeekWait()
                            c.seekTo(seekTarget)
                        }
                    }
                    if (mode == 2 || mode == 3) controls.hideHint(600)
                }
            }
            if (mode > 0) {
                // a swipe is under way: the detector must not also read it as a tap or a long press
                if (ev.actionMasked == MotionEvent.ACTION_MOVE) {
                    val cancel = MotionEvent.obtain(ev).apply { action = MotionEvent.ACTION_CANCEL }
                    gestures.onTouchEvent(cancel)
                    cancel.recycle()
                }
                if (ev.actionMasked == MotionEvent.ACTION_UP || ev.actionMasked == MotionEvent.ACTION_CANCEL) mode = 0
                true
            } else gestures.onTouchEvent(ev)
        }
    }

    private fun systemBrightness(): Float = try {
        android.provider.Settings.System.getInt(contentResolver, android.provider.Settings.System.SCREEN_BRIGHTNESS) / 255f
    } catch (e: Exception) { 0.5f }

    private fun kernelAvailable(k: KernelSelection.Kernel) = when (k) {
        KernelSelection.Kernel.EXO -> true
        KernelSelection.Kernel.MPV -> MpvNative.isAvailable()
        KernelSelection.Kernel.MDK -> MdkNative.isAvailable()
    }

    private fun kernelUnavailableReason(k: KernelSelection.Kernel) = when (k) {
        KernelSelection.Kernel.MPV -> MpvNative.unavailableReason()
        KernelSelection.Kernel.MDK -> MdkNative.unavailableReason()
        else -> ""
    }

    /**
     * PlaybackConfig.kernel 'mpv' / 'mdk' builds that kernel; if its native library (or the glue) cannot be loaded, or the
     * player cannot be created, the page falls back to Exo and says so once. All three share the same controls
     * ([PlayerControlsView]) and panels, so the page looks and works the same whatever the kernel.
     */
    private fun createKernel(config: PlaybackConfig): PlayerKernel {
        val choice = KernelSelection.choose(config.kernel, ::kernelAvailable, ::kernelUnavailableReason)
        try {
            when (choice.kernel) {
                KernelSelection.Kernel.MPV -> return MpvKernel(this, config.hwDecode)
                KernelSelection.Kernel.MDK -> return MdkKernel(this, config.hwDecode)
                KernelSelection.Kernel.EXO -> choice.notice?.let { Toast.makeText(this, it, Toast.LENGTH_LONG).show() }
            }
        } catch (e: Throwable) {
            Toast.makeText(this, KernelSelection.fallbackNotice(choice.kernel, e.message), Toast.LENGTH_LONG).show()
        }
        return ExoKernel(this)
    }

    // -- menus and panels (OBSERVED in UZN 1.2.0 on the phone, 2026-11-11) ------------------------------------------------
    private var controls: PlayerControlsView? = null

    private fun notice(message: String) { controls?.showNotice(message) }

    /**
     * The quality pill's menu, above it: the source qualities (代理 / 原画 / 高清 / 标清 / 普画 for a cloud drive), the
     * current one bold with a ✓. Without source qualities the stream's own variants are offered.
     */
    private fun showQuality(c: PlayerController, anchor: View) {
        val v = controls ?: return
        if (c.qualityNames.isNotEmpty()) {
            v.showMenu(anchor, above = true, items = c.qualityNames.mapIndexed { i, name ->
                PlayerControlsView.MenuItem(name, selected = i == c.quality) { c.selectQuality(i) }
            })
            return
        }
        val tracks = c.videoOptions()
        if (tracks.size < 2) return
        v.showMenu(anchor, above = true, items = listOf(PlayerControlsView.MenuItem(PlayerUiText.t("自动", "Auto"), selected = c.videoAuto) { c.selectVideo(-1) }) +
            tracks.mapIndexed { i, t -> PlayerControlsView.MenuItem(t.label, selected = !c.videoAuto && t.selected) { c.selectVideo(i) } })
    }

    private fun showSpeed(c: PlayerController, anchor: View) {
        controls?.showSpeedMenu(anchor, c.currentSpeed) { c.setSpeed(it) }
    }

    /** 关闭字幕 ✓, the video's subtitle tracks, 加载字幕…. */
    private fun subtitleItems(c: PlayerController, divider: Boolean): List<PlayerControlsView.MenuItem> {
        val tracks = c.subtitleOptions()
        return listOf(PlayerControlsView.MenuItem(PlayerUiText.t("关闭字幕", "Subtitles off"), selected = !c.subtitlesEnabled, dividerBefore = divider) { c.selectSubtitle(-1) }) +
            tracks.mapIndexed { i, t -> PlayerControlsView.MenuItem(t.label, selected = c.subtitlesEnabled && t.selected) { c.selectSubtitle(i) } } +
            PlayerControlsView.MenuItem(PlayerUiText.t("加载字幕…", "Load subtitles…")) { loadSubtitle(c) }
    }

    private fun showSubtitles(c: PlayerController, anchor: View) {
        controls?.showMenu(anchor, above = false, items = subtitleItems(c, divider = false))
    }

    private fun showAudio(c: PlayerController, anchor: View) {
        val tracks = c.audioOptions()
        controls?.showMenu(anchor, above = false, items = listOf(PlayerControlsView.MenuItem(PlayerUiText.t("默认音轨", "Default audio"), selected = c.audioAuto) { c.selectAudio(-1) }) +
            tracks.mapIndexed { i, t -> PlayerControlsView.MenuItem(t.label, selected = !c.audioAuto && t.selected) { c.selectAudio(i) } })
    }

    /** Portrait's `•••`: 截图 / 重新加载 / 画中画, then the subtitle rows (and the audio tracks when there are several). */
    private fun showMore(c: PlayerController, anchor: View) {
        val audio = c.audioOptions()
        controls?.showMenu(anchor, above = false, items = listOf(
            PlayerControlsView.MenuItem(PlayerUiText.t("截图", "Screenshot")) { takeScreenshot(c.kernel) },
            PlayerControlsView.MenuItem(PlayerUiText.t("重新加载", "Reload")) { c.retry() },
            PlayerControlsView.MenuItem(PlayerUiText.t("画中画", "Picture-in-picture")) { enterPip() },
        ) + subtitleItems(c, divider = true) + (if (audio.size < 2) emptyList() else audio.mapIndexed { i, t ->
            PlayerControlsView.MenuItem(t.label, selected = !c.audioAuto && t.selected, dividerBefore = i == 0) { c.selectAudio(i) }
        }))
    }

    /** 加载字幕…: a local file or a link (the original's strings: 本地字幕, 请输入字幕链接, 已加载本地字幕：, 加载字幕失败：). */
    private fun loadSubtitle(c: PlayerController) {
        AlertDialog.Builder(this)
            .setTitle(PlayerUiText.t("加载字幕", "Load subtitles"))
            .setItems(arrayOf(PlayerUiText.t("本地字幕", "Local file"), PlayerUiText.t("字幕链接", "Subtitle link"))) { _, which ->
                if (which == 0) {
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { addCategory(Intent.CATEGORY_OPENABLE); type = "*/*" }, REQUEST_SUBTITLE)
                    } catch (e: android.content.ActivityNotFoundException) {
                        toast(PlayerUiText.t("加载字幕失败：没有可用的文件选择器", "Could not load subtitles: no file picker"))
                    }
                } else {
                    val input = EditText(this).apply { hint = PlayerUiText.t("请输入字幕链接", "Subtitle URL"); setSingleLine() }
                    AlertDialog.Builder(this).setTitle(PlayerUiText.t("字幕链接", "Subtitle link")).setView(input)
                        .setPositiveButton(PlayerUiText.t("确定", "OK")) { _, _ ->
                            val url = input.text.toString().trim()
                            if (url.startsWith("http://") || url.startsWith("https://")) addSubtitle(c, url, url.substringAfterLast('/').substringBefore('?').ifEmpty { "subtitle" })
                            else toast(PlayerUiText.t("加载字幕失败：链接无效", "Could not load subtitles: bad link"))
                        }
                        .setNegativeButton(PlayerUiText.t("取消", "Cancel"), null).show()
                }
            }.show()
    }

    private fun addSubtitle(c: PlayerController, url: String, name: String) {
        if (c.addSubtitle(url, name)) toast(PlayerUiText.t("已加载本地字幕：$name", "Subtitles loaded: $name"))
        else toast(PlayerUiText.t("加载字幕失败：视频尚未开始播放", "Could not load subtitles: nothing is playing yet"))
    }

    private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_SHORT).show()

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val c = controller ?: return
        val uri = data?.data
        if (requestCode != REQUEST_SUBTITLE || resultCode != RESULT_OK || uri == null) return
        try {
            var name = "subtitle.srt"
            contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { q ->
                if (q.moveToFirst()) q.getString(0)?.let { name = it }
            }
            val dir = java.io.File(cacheDir, "subtitles").apply { mkdirs() }
            val file = java.io.File(dir, name.replace('/', '_'))
            contentResolver.openInputStream(uri)!!.use { input -> file.outputStream().use { input.copyTo(it) } }
            addSubtitle(c, android.net.Uri.fromFile(file).toString(), name)
        } catch (e: Exception) {
            toast(PlayerUiText.t("加载字幕失败：${e.message}", "Could not load subtitles: ${e.message}"))
        }
    }

    // -- 选集 & 节目单 --------------------------------------------------------------------------------------------------

    private var episodesReversed = false
    private var episodesSearching = false
    private var episodesQuery = ""
    private var episodesTmdbMode = true

    /**
     * 选集 (matching original i2.V + i2.T): top-right action buttons (TMDB toggle, search toggle, locate current,
     * reverse order toggle), line chips, optional inline search input (搜索剧集名称...), and either standard episode rows
     * or TMDB episode cards (E{n} badge, title, 播放中 badge, 2-line overview).
     */
    private fun showEpisodes(c: PlayerController, shownLine: Int = c.line) {
        val v = controls ?: return
        val ui = v.ui
        val lines = c.lineNames()
        val names = c.episodeNames(shownLine)
        val tmdbList = c.tmdbMatches
        val useTmdb = episodesTmdbMode && tmdbList.isNotEmpty()
        var currentRow: View? = null
        var scroll: android.widget.ScrollView? = null
        var listContainer: LinearLayout? = null

        fun populateRows(container: LinearLayout) {
            container.removeAllViews()
            currentRow = null
            val q = episodesQuery.trim().lowercase(java.util.Locale.ROOT)
            val indices = names.indices.toList().let { if (episodesReversed) it.reversed() else it }
            for (i in indices) {
                val name = names[i]
                val tmdb = tmdbList.firstOrNull { it.episodeNumber.toInt() == i + 1 } ?: tmdbList.getOrNull(i)
                if (q.isNotEmpty()) {
                    val matchName = name.lowercase(java.util.Locale.ROOT).contains(q)
                    val matchTmdb = tmdb != null && (tmdb.episodeName.lowercase(java.util.Locale.ROOT).contains(q) ||
                        tmdb.overview.orEmpty().lowercase(java.util.Locale.ROOT).contains(q) ||
                        "e${tmdb.episodeNumber}".contains(q))
                    if (!matchName && !matchTmdb && !"${i + 1}".contains(q)) continue
                }
                val playing = shownLine == c.line && i == c.episode
                val row = if (useTmdb && tmdb != null) {
                    LinearLayout(this).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        setPadding(ui.dp(10), ui.dp(10), ui.dp(12), ui.dp(10))
                        background = if (playing) ui.rounded(PlayerUi.withAlpha(ui.accent, 0.14f), 12f, PlayerUi.withAlpha(ui.accent, 0.75f), 1f)
                        else ui.rounded(0x12FFFFFF, 12f)
                        addView(FrameLayout(this@NativePlayerActivity).apply {
                            background = ui.rounded(0x24FFFFFF, 8f)
                            clipToOutline = true
                            addView(ui.icon(Ic.MOVIE, 22f, 0x55FFFFFF), FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
                            addView(ui.text("E${tmdb.episodeNumber}", 10f, Color.WHITE, bold = true).apply {
                                background = ui.rounded(0xB3000000.toInt(), 5f)
                                setPadding(ui.dp(5), ui.dp(2), ui.dp(5), ui.dp(2))
                            }, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.START).apply { leftMargin = ui.dp(5); topMargin = ui.dp(5) })
                        }, LinearLayout.LayoutParams(ui.dp(96), ui.dp(56)).apply { rightMargin = ui.dp(12) })
                        addView(LinearLayout(this@NativePlayerActivity).apply {
                            orientation = LinearLayout.VERTICAL
                            addView(LinearLayout(this@NativePlayerActivity).apply {
                                orientation = LinearLayout.HORIZONTAL
                                gravity = Gravity.CENTER_VERTICAL
                                addView(ui.text(tmdb.episodeName.ifBlank { name }, 14f, if (playing) ui.accent else Color.WHITE, bold = true).apply {
                                    maxLines = 1; ellipsize = android.text.TextUtils.TruncateAt.END
                                }, LinearLayout.LayoutParams(0, -2, 1f))
                                if (playing) addView(ui.text(PlayerUiText.t("播放中", "Playing"), 10f, ui.accent).apply {
                                    background = ui.rounded(PlayerUi.withAlpha(ui.accent, 0.12f), 9f, PlayerUi.withAlpha(ui.accent, 0.6f), 0.6f)
                                    setPadding(ui.dp(7), ui.dp(2.5f), ui.dp(7), ui.dp(2.5f))
                                }, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(8) })
                            })
                            val desc = tmdb.overview?.takeIf { it.isNotBlank() } ?: name
                            addView(ui.text(desc, 11.5f, 0x99FFFFFF.toInt()).apply {
                                maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END
                                setPadding(0, ui.dp(4), 0, 0)
                            })
                        }, LinearLayout.LayoutParams(0, -2, 1f))
                        setOnClickListener {
                            haptic(c, Haptics.SELECTION)
                            v.closePanel()
                            if (shownLine != c.line) c.selectLineEpisode(shownLine, i) else if (!playing) c.selectEpisode(i)
                        }
                    }
                } else {
                    LinearLayout(this).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        minimumHeight = ui.dp(56)
                        setPadding(ui.dp(12), ui.dp(8), ui.dp(12), ui.dp(8))
                        background = if (playing) ui.rounded(PlayerUi.withAlpha(ui.accent, 0.14f), 12f, PlayerUi.withAlpha(ui.accent, 0.75f), 1f)
                        else ui.rounded(0x12FFFFFF, 12f)
                        addView(ui.text("${i + 1}", 13f).apply {
                            gravity = Gravity.CENTER
                            background = ui.rounded(if (playing) ui.accent else 0x24FFFFFF, 8f)
                        }, LinearLayout.LayoutParams(ui.dp(32), ui.dp(32)).apply { rightMargin = ui.dp(12) })
                        addView(ui.text(name, 14.5f, if (playing) ui.accent else Color.WHITE).apply { maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END },
                            LinearLayout.LayoutParams(0, -2, 1f))
                        if (playing) addView(ui.text(PlayerUiText.t("播放中", "Playing"), 10f, ui.accent).apply {
                            background = ui.rounded(PlayerUi.withAlpha(ui.accent, 0.12f), 9f, PlayerUi.withAlpha(ui.accent, 0.6f), 0.6f)
                            setPadding(ui.dp(7), ui.dp(2.5f), ui.dp(7), ui.dp(2.5f))
                        }, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(10) })
                        setOnClickListener {
                            haptic(c, Haptics.SELECTION)
                            v.closePanel()
                            if (shownLine != c.line) c.selectLineEpisode(shownLine, i) else if (!playing) c.selectEpisode(i)
                        }
                    }
                }
                if (playing) currentRow = row
                container.addView(row, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = ui.dp(8) })
            }
        }

        val header = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(16), ui.dp(12), ui.dp(16), ui.dp(8))
            addView(LinearLayout(this@NativePlayerActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.END or Gravity.CENTER_VERTICAL
                fun actionBtn(code: Int, active: Boolean = false, onClick: () -> Unit) = FrameLayout(this@NativePlayerActivity).apply {
                    background = ui.oval(if (active) PlayerUi.withAlpha(ui.accent, 0.24f) else 0x33FFFFFF)
                    addView(ui.icon(code, 17f, if (active) ui.accent else Color.WHITE), FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
                    setOnClickListener { haptic(c, Haptics.SELECTION); onClick() }
                }.also { addView(it, LinearLayout.LayoutParams(ui.dp(30), ui.dp(30)).apply { leftMargin = ui.dp(8) }) }

                if (tmdbList.isNotEmpty()) {
                    actionBtn(if (useTmdb) Ic.AUTO_AWESOME else Ic.MENU, active = useTmdb) {
                        episodesTmdbMode = !episodesTmdbMode
                        showEpisodes(c, shownLine)
                    }
                }
                if (names.size > 1) {
                    actionBtn(if (episodesSearching) Ic.CANCEL else Ic.SEARCH, active = episodesSearching) {
                        episodesSearching = !episodesSearching
                        if (!episodesSearching) episodesQuery = ""
                        showEpisodes(c, shownLine)
                    }
                }
                actionBtn(Ic.LOCATE) {
                    currentRow?.let { r -> scroll?.smoothScrollTo(0, (r.top - ui.dp(8)).coerceAtLeast(0)) }
                }
                if (names.size > 1) {
                    actionBtn(Ic.SWAP_VERT, active = episodesReversed) {
                        episodesReversed = !episodesReversed
                        showEpisodes(c, shownLine)
                    }
                }
            })
            if (lines.size > 1) addView(HorizontalScrollView(this@NativePlayerActivity).apply {
                isHorizontalScrollBarEnabled = false
                addView(LinearLayout(this@NativePlayerActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    lines.forEachIndexed { i, label ->
                        val sel = i == shownLine
                        addView(ui.text(label, 13.5f, if (sel) ui.accent else Color.WHITE).apply {
                            gravity = Gravity.CENTER
                            setPadding(ui.dp(13), 0, ui.dp(13), 0)
                            background = ui.rounded(if (sel) PlayerUi.withAlpha(ui.accent, 0.26f) else 0x24FFFFFF, 14f)
                            setOnClickListener { haptic(c, Haptics.SELECTION); showEpisodes(c, i) }
                        }, LinearLayout.LayoutParams(-2, ui.dp(28)).apply { if (i > 0) leftMargin = ui.dp(8) })
                    }
                })
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ui.dp(6) })
            if (episodesSearching) {
                val searchInput = field(ui, episodesQuery, PlayerUiText.t("搜索剧集名称...", "Search episodes...")).apply {
                    addTextChangedListener(object : android.text.TextWatcher {
                        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                            episodesQuery = s?.toString().orEmpty()
                            listContainer?.let { populateRows(it) }
                        }
                        override fun afterTextChanged(s: android.text.Editable?) {}
                    })
                }
                addView(searchInput, LinearLayout.LayoutParams(-1, ui.dp(36)).apply { topMargin = ui.dp(8) })
            }
        }
        val createdScroll = v.showPanel(header) { list ->
            listContainer = list
            populateRows(list)
        }
        scroll = createdScroll
        createdScroll.post { currentRow?.let { r -> createdScroll.scrollTo(0, (r.top - ui.dp(8)).coerceAtLeast(0)) } }
    }

    /**
     * 频道列表 (Live TV 2-column channel panel matching original i2.o0):
     * Left column (108dp wide) lists channel groups; 1dp vertical divider; right column lists channels in the group.
     */
    private fun showChannels(c: PlayerController, shownGroup: Int = c.line) {
        val v = controls ?: return
        val ui = v.ui
        val groups = c.lineNames()
        val groupIdx = shownGroup.coerceIn(0, (groups.size - 1).coerceAtLeast(0))
        val channels = c.episodeNames(groupIdx)
        val totalCount = groups.indices.sumOf { c.episodeNames(it).size }.takeIf { it > 0 } ?: channels.size
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(16), ui.dp(14), ui.dp(16), ui.dp(10))
            addView(ui.text(PlayerUiText.t("频道列表", "Channels"), 15f, bold = true), LinearLayout.LayoutParams(0, -2, 1f))
            addView(ui.text(PlayerUiText.t("共 $totalCount 个频道", "$totalCount channels"), 12f, PlayerUi.TEXT_DIM))
        }
        var activeGroupView: View? = null
        var activeChannelView: View? = null
        val groupList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(8), ui.dp(6), ui.dp(8), ui.dp(14))
            groups.forEachIndexed { idx, name ->
                val sel = idx == groupIdx
                val item = ui.text(name, 13f, if (sel) ui.accent else 0xB3FFFFFF.toInt(), bold = sel).apply {
                    maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.END
                    setPadding(ui.dp(10), ui.dp(9), ui.dp(10), ui.dp(9))
                    background = if (sel) ui.rounded(PlayerUi.withAlpha(ui.accent, 0.22f), 10f) else null
                    setOnClickListener {
                        if (idx != groupIdx) {
                            haptic(c, Haptics.SELECTION)
                            showChannels(c, idx)
                        }
                    }
                }
                if (sel) activeGroupView = item
                addView(item, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = ui.dp(4) })
            }
        }
        val channelList = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(ui.dp(10), ui.dp(6), ui.dp(12), ui.dp(14))
            channels.forEachIndexed { idx, name ->
                val playing = groupIdx == c.line && idx == c.episode
                val row = LinearLayout(this@NativePlayerActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(ui.dp(12), ui.dp(10), ui.dp(12), ui.dp(10))
                    background = if (playing) ui.rounded(PlayerUi.withAlpha(ui.accent, 0.16f), 10f, PlayerUi.withAlpha(ui.accent, 0.65f), 1f)
                    else ui.rounded(0x10FFFFFF, 10f)
                    addView(ui.text("${idx + 1}", 12f, if (playing) ui.accent else PlayerUi.TEXT_DIM, mono = true).apply {
                        minWidth = ui.dp(24)
                    })
                    addView(ui.text(name, 14f, if (playing) ui.accent else Color.WHITE, bold = playing).apply {
                        maxLines = 1
                        ellipsize = android.text.TextUtils.TruncateAt.END
                    }, LinearLayout.LayoutParams(0, -2, 1f).apply { leftMargin = ui.dp(6) })
                    if (playing) {
                        addView(ui.text(PlayerUiText.t("播放中", "LIVE"), 10f, ui.accent).apply {
                            background = ui.rounded(PlayerUi.withAlpha(ui.accent, 0.14f), 8f)
                            setPadding(ui.dp(6), ui.dp(2), ui.dp(6), ui.dp(2))
                        }, LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(6) })
                    }
                    setOnClickListener {
                        haptic(c, Haptics.SELECTION)
                        v.closePanel()
                        if (groupIdx != c.line) c.selectLineEpisode(groupIdx, idx) else if (!playing) c.selectEpisode(idx)
                    }
                }
                if (playing) activeChannelView = row
                addView(row, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = ui.dp(6) })
            }
        }
        val groupScroll = android.widget.ScrollView(this).apply { isVerticalScrollBarEnabled = false; addView(groupList) }
        val channelScroll = android.widget.ScrollView(this).apply { isVerticalScrollBarEnabled = true; addView(channelList) }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            if (groups.size > 1) {
                addView(groupScroll, LinearLayout.LayoutParams(ui.dp(108), -1))
                addView(View(this@NativePlayerActivity).apply { setBackgroundColor(0x14FFFFFF) }, LinearLayout.LayoutParams(1, -1))
            }
            addView(channelScroll, LinearLayout.LayoutParams(0, -1, 1f))
        }
        v.showCustomPanel(header, content)
        groupScroll.post { activeGroupView?.let { g -> groupScroll.scrollTo(0, (g.top - ui.dp(16)).coerceAtLeast(0)) } }
        channelScroll.post { activeChannelView?.let { ch -> channelScroll.scrollTo(0, (ch.top - ui.dp(16)).coerceAtLeast(0)) } }
    }

    /** 节目单 (EPG panel matching original i2.M): programme list with HH:mm - HH:mm, 直播中 badge, and live progress bar. */
    private fun showEpg(c: PlayerController) {
        val v = controls ?: return
        val ui = v.ui
        val programmes = c.epgProgrammes
        val fmt = java.text.SimpleDateFormat("HH:mm", java.util.Locale.ROOT)
        val nowMs = System.currentTimeMillis()
        var liveRow: View? = null
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(16), ui.dp(14), ui.dp(16), ui.dp(10))
            addView(ui.text(PlayerUiText.t("节目单", "EPG"), 15f, bold = true), LinearLayout.LayoutParams(0, -2, 1f))
            if (programmes.isNotEmpty()) {
                addView(ui.text(PlayerUiText.t("${programmes.size} 档", "${programmes.size}"), 11f, 0xCCFFFFFF.toInt()).apply {
                    background = ui.rounded(0x1FFFFFFF, 10f)
                    setPadding(ui.dp(8), ui.dp(3), ui.dp(8), ui.dp(3))
                })
            }
        }
        val scroll = v.showPanel(header) { list ->
            if (programmes.isEmpty()) {
                list.addView(ui.text(PlayerUiText.t("暂无节目单", "No EPG data"), 13f, PlayerUi.TEXT_DIM).apply {
                    gravity = Gravity.CENTER
                    setPadding(0, ui.dp(40), 0, ui.dp(40))
                })
                return@showPanel
            }
            for (p in programmes) {
                val live = nowMs in p.startEpochMs until p.endEpochMs
                val past = nowMs >= p.endEpochMs
                val row = LinearLayout(this).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(ui.dp(12), ui.dp(10), ui.dp(12), ui.dp(10))
                    background = if (live) ui.rounded(PlayerUi.withAlpha(ui.accent, 0.14f), 12f, PlayerUi.withAlpha(ui.accent, 0.7f), 1f)
                    else ui.rounded(0x12FFFFFF, 12f)
                    alpha = if (past) 0.5f else 1f
                    addView(LinearLayout(this@NativePlayerActivity).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        val timeText = "${fmt.format(java.util.Date(p.startEpochMs))} - ${fmt.format(java.util.Date(p.endEpochMs))}"
                        addView(ui.text(timeText, 11.5f, if (live) ui.accent else PlayerUi.TEXT_DIM, mono = true), LinearLayout.LayoutParams(0, -2, 1f))
                        if (live) addView(ui.text(PlayerUiText.t("直播中", "LIVE"), 10f, ui.accent, bold = true).apply {
                            background = ui.rounded(PlayerUi.withAlpha(ui.accent, 0.16f), 8f)
                            setPadding(ui.dp(6), ui.dp(2), ui.dp(6), ui.dp(2))
                        })
                    })
                    addView(ui.text(p.title, 13.5f, Color.WHITE, bold = live).apply {
                        setPadding(0, ui.dp(4), 0, 0)
                    })
                    if (live && p.endEpochMs > p.startEpochMs) {
                        val frac = ((nowMs - p.startEpochMs).toFloat() / (p.endEpochMs - p.startEpochMs)).coerceIn(0f, 1f)
                        addView(SliderView(this@NativePlayerActivity, ui.accent, 0x33FFFFFF, 0f, 2.5f) { _, _ -> }.apply {
                            isEnabled = false
                            fraction = frac
                        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ui.dp(6) })
                    }
                }
                if (live) liveRow = row
                list.addView(row, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = ui.dp(8) })
            }
        }
        scroll.post { liveRow?.let { r -> scroll.scrollTo(0, (r.top - ui.dp(8)).coerceAtLeast(0)) } }
    }

    // -- 设置 -----------------------------------------------------------------------------------------------------------

    /**
     * The gear: the groups of [PlayerSettings] as cards. Every row is a 设置 → 播放器 setting, applied and saved at once.
     * The panel is rebuilt after a pick-one change so the ✓ moves; its scroll position is kept.
     */
    private fun showSettings(c: PlayerController, scrollY: Int = 0) {
        val v = controls ?: return
        val ui = v.ui
        lateinit var scroll: android.widget.ScrollView
        scroll = v.showPanel { list ->
            var card: LinearLayout? = null
            for (item in PlayerSettings.items()) when (item) {
                is PlayerSettings.Item.Section -> {
                    list.addView(ui.sectionLabel(item.title))
                    card = ui.card().also { list.addView(it, LinearLayout.LayoutParams(-1, -2)) }
                }
                is PlayerSettings.Item.Toggle -> {
                    val sw = SwitchView(this, ui.accent, item.get(c.playbackConfig)) { on ->
                        haptic(c, Haptics.SELECTION)
                        if (item.get(c.playbackConfig) != on) applySetting(c, item.set(c.playbackConfig, on))
                    }
                    ui.addRow(card!!, ui.row(item.icon, item.title, item.subtitle, sw).also { r -> r.setOnClickListener { sw.toggle() } })
                }
                is PlayerSettings.Item.Option -> {
                    val sel = item.selected(c.playbackConfig)
                    val row = ui.row(item.icon, item.title, null, if (sel) ui.icon(Ic.CHECK, 16f, ui.accent) else null, item.rotateIcon)
                    row.findViewWithTag<TextView>("icon")?.setTextColor(if (sel) ui.accent else 0xD9FFFFFF.toInt())
                    row.findViewWithTag<TextView>("title")?.let { t -> if (!sel) t.setTextColor(0xD9FFFFFF.toInt()) else t.typeface = android.graphics.Typeface.DEFAULT_BOLD }
                    row.setOnClickListener {
                        if (item.selected(c.playbackConfig)) return@setOnClickListener
                        haptic(c, Haptics.SELECTION)
                        val next = item.select(c.playbackConfig)
                        if (item.key.startsWith(PlayerSettings.KERNEL)) {
                            val k = KernelSelection.parse(next.kernel)
                            if (!kernelAvailable(k)) {
                                toast(PlayerUiText.t("${k.label} 内核不可用：${kernelUnavailableReason(k)}", "${k.label} kernel unavailable: ${kernelUnavailableReason(k)}"))
                                return@setOnClickListener
                            }
                        }
                        val y = scroll.scrollY
                        applySetting(c, next)
                        if (controller === c && controls?.panelOpen == true) showSettings(c, y)
                    }
                    ui.addRow(card!!, row)
                }
                is PlayerSettings.Item.Stepper -> {
                    val value = ui.text(item.value(c.playbackConfig), 13f).apply { gravity = Gravity.CENTER; minWidth = ui.dp(46) }
                    fun button(code: Int, change: (PlaybackConfig) -> PlaybackConfig?) = ui.circleButton(code, 26f, 16f, 0x29FFFFFF).also { b ->
                        b.setOnClickListener {
                            val next = change(c.playbackConfig) ?: return@setOnClickListener
                            haptic(c, Haptics.SELECTION)
                            applySetting(c, next)
                            value.text = item.value(next)
                        }
                    }
                    val box = LinearLayout(this).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        background = ui.rounded(0x14FFFFFF, 17f)
                        setPadding(ui.dp(4), ui.dp(4), ui.dp(4), ui.dp(4))
                        addView(button(Ic.REMOVE, item.minus), LinearLayout.LayoutParams(ui.dp(26), ui.dp(26)))
                        addView(value)
                        addView(button(Ic.ADD, item.plus), LinearLayout.LayoutParams(ui.dp(26), ui.dp(26)))
                    }
                    ui.addRow(card!!, ui.row(item.icon, item.title, null, box))
                }
            }
        }
        if (scrollY > 0) scroll.post { scroll.scrollTo(0, scrollY) }
    }

    private fun applySetting(c: PlayerController, next: PlaybackConfig) {
        val old = c.playbackConfig
        if (PlayerSettings.needsReload(old, next)) { reloadWith(c, next); return }
        c.updatePlayback(next)
        if (old.isPriorityLandscape != next.isPriorityLandscape) applyOrientation(next)
    }

    private fun applyOrientation(config: PlaybackConfig) {
        requestedOrientation = if (config.isPriorityLandscape) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        else ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    }

    /** 旋转屏幕 (OBSERVED: three steps): landscape → the other landscape → portrait → landscape. */
    private fun rotate() {
        @Suppress("DEPRECATION")
        val rotation = windowManager.defaultDisplay.rotation
        requestedOrientation = when (rotation) {
            Surface.ROTATION_90 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
            Surface.ROTATION_270 -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            else -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        }
    }

    /**
     * Kernel or hardware decoding changed: save it, then rebuild the page with the new kernel at the same line, episode,
     * quality, position and speed. The Dart session stays open.
     */
    private fun reloadWith(c: PlayerController, next: PlaybackConfig) {
        c.updatePlayback(next)
        val request = c.reloadRequest(next)
        NativePlayerHost.restart(request, c.currentSpeed)
        c.detach()
        if (NativePlayerHost.controller === c) NativePlayerHost.controller = null
        controller = null
        recreate()
    }

    // -- 截图 -----------------------------------------------------------------------------------------------------------

    private fun findSurface(view: View): View? = when (view) {
        is SurfaceView, is TextureView -> view
        is ViewGroup -> (0 until view.childCount).firstNotNullOfOrNull { findSurface(view.getChildAt(it)) }
        else -> null
    }

    /** 截图: the video frame as it is shown, saved to Pictures/NovaPlay (the gallery). */
    private fun takeScreenshot(kernel: PlayerKernel) {
        val failed = PlayerUiText.t("截图失败", "Screenshot failed")
        val surface = findSurface(kernel.view)
        if (surface == null || surface.width <= 0 || surface.height <= 0) { toast(failed); return }
        when (surface) {
            is TextureView -> surface.bitmap?.let(::saveScreenshot) ?: toast(failed)
            is SurfaceView -> {
                val bitmap = Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888)
                try {
                    PixelCopy.request(surface, bitmap, { result -> if (result == PixelCopy.SUCCESS) saveScreenshot(bitmap) else toast(failed) }, Handler(Looper.getMainLooper()))
                } catch (e: IllegalArgumentException) {
                    toast(failed)
                }
            }
        }
    }

    private fun saveScreenshot(bitmap: Bitmap) {
        val name = "NovaPlay_" + java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.ROOT).format(java.util.Date()) + ".jpg"
        Thread {
            val ok = try {
                if (Build.VERSION.SDK_INT >= 29) {
                    val values = android.content.ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, name)
                        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                        put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/NovaPlay")
                    }
                    val uri = contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
                    contentResolver.openOutputStream(uri)!!.use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
                } else {
                    val dir = java.io.File(getExternalFilesDir(Environment.DIRECTORY_PICTURES), "NovaPlay").apply { mkdirs() }
                    java.io.File(dir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
                }
                true
            } catch (e: Exception) { false }
            runOnUiThread { toast(if (ok) PlayerUiText.t("截图已保存到相册", "Screenshot saved") else PlayerUiText.t("截图失败", "Screenshot failed")) }
        }.start()
    }

    // -- 弹幕 -----------------------------------------------------------------------------------------------------------

    private var danmakuTab = 0
    private var danmakuSubScreen = 0 // 0 = tabs, 1 = anime results, 2 = episode results, 3 = blocked words
    private var danmakuDirect: Int? = null
    private var lastAnimeResults: List<DanmakuSearchResultItem> = emptyList()
    private var lastEpisodeResults: List<EpisodeItem> = emptyList()
    private var danmakuCountBadge: TextView? = null
    private var danmakuStatusText: TextView? = null

    private fun field(ui: PlayerUi, value: String, hint: String, number: Boolean = false) = EditText(this).apply {
        setText(value)
        this.hint = hint
        setHintTextColor(0x66FFFFFF)
        setTextColor(Color.WHITE)
        textSize = 14f
        setSingleLine()
        if (number) inputType = android.text.InputType.TYPE_CLASS_NUMBER
        background = ui.rounded(0x14FFFFFF, 10f, 0x12FFFFFF, 0.6f)
        setPadding(ui.dp(12), 0, ui.dp(12), 0)
        imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE or android.view.inputmethod.EditorInfo.IME_FLAG_NO_EXTRACT_UI
    }

    /**
     * 弹 (matching original i2.J):
     * Header has either the 2-tab pill (弹幕设置 / 样式调节) or `<` back button + sub-page title, and `{n} 条` badge on the right.
     * Sub-screens: 1 = 搜索结果 — 选择剧集, 2 = 选择集数, 3 = 屏蔽词管理.
     */
    private fun showDanmaku(c: PlayerController, scrollY: Int = 0) {
        val v = controls ?: return
        val ui = v.ui
        val count = c.loadedDanmakuCount
        val badge = ui.text(PlayerUiText.t("$count 条", "$count"), 11f, ui.accent, bold = true).apply {
            background = ui.rounded(PlayerUi.withAlpha(ui.accent, 0.16f), 10f)
            setPadding(ui.dp(8), ui.dp(3), ui.dp(8), ui.dp(3))
            visibility = if (count > 0) View.VISIBLE else View.GONE
        }
        danmakuCountBadge = badge
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(14), ui.dp(12), ui.dp(14), ui.dp(10))
            if (danmakuSubScreen == 0) {
                addView(LinearLayout(this@NativePlayerActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    background = ui.rounded(0x14FFFFFF, 17f)
                    setPadding(ui.dp(3), ui.dp(3), ui.dp(3), ui.dp(3))
                    listOf(Ic.FORUM to PlayerUiText.t("弹幕设置", "Danmaku"), Ic.TUNE to PlayerUiText.t("样式调节", "Style")).forEachIndexed { i, (code, label) ->
                        val sel = i == danmakuTab
                        addView(LinearLayout(this@NativePlayerActivity).apply {
                            orientation = LinearLayout.HORIZONTAL
                            gravity = Gravity.CENTER
                            background = if (sel) ui.rounded(0x2EFFFFFF, 14f) else null
                            setPadding(ui.dp(12), 0, ui.dp(13), 0)
                            addView(ui.icon(code, 13f, if (sel) Color.WHITE else 0xB3FFFFFF.toInt()), LinearLayout.LayoutParams(-2, -2).apply { rightMargin = ui.dp(7) })
                            addView(ui.text(label, 12.5f, if (sel) Color.WHITE else 0xB3FFFFFF.toInt(), bold = sel))
                            setOnClickListener { if (danmakuTab != i) { haptic(c, Haptics.SELECTION); danmakuTab = i; showDanmaku(c) } }
                        }, LinearLayout.LayoutParams(-2, ui.dp(28)))
                    }
                }, LinearLayout.LayoutParams(-2, -2))
            } else {
                addView(ui.circleButton(Ic.BACK, 30f, 16f, 0x24FFFFFF).apply {
                    setOnClickListener {
                        haptic(c, Haptics.SELECTION)
                        danmakuSubScreen = if (danmakuSubScreen == 2) 1 else 0
                        showDanmaku(c)
                    }
                }, LinearLayout.LayoutParams(ui.dp(30), ui.dp(30)).apply { rightMargin = ui.dp(10) })
                val subTitle = when (danmakuSubScreen) {
                    1 -> PlayerUiText.t("搜索结果 — 选择剧集", "Choose a show")
                    2 -> PlayerUiText.t("选择集数", "Choose an episode")
                    else -> PlayerUiText.t("屏蔽词管理", "Blocked words")
                }
                addView(ui.text(subTitle, 14.5f, bold = true))
            }
            addView(View(this@NativePlayerActivity), LinearLayout.LayoutParams(0, 1, 1f))
            addView(badge)
        }
        val scroll = v.showPanel(header) { list ->
            when (danmakuSubScreen) {
                1 -> danmakuAnimeList(c, ui, list)
                2 -> danmakuEpisodeList(c, ui, list)
                3 -> danmakuBlockedWordsView(c, ui, list)
                else -> if (danmakuTab == 0) danmakuSettings(c, ui, list) else danmakuStyle(c, ui, list)
            }
        }
        if (scrollY > 0) scroll.post { scroll.scrollTo(0, scrollY) }
    }

    private fun danmakuSettings(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        list.addView(ui.sectionLabel(PlayerUiText.t("弹幕状态", "Status")))
        val search = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        fun dim() { search.alpha = if (c.danmakuEnabled) 1f else 0.38f }
        val sw = SwitchView(this, ui.accent, c.danmakuEnabled) { on -> haptic(c, Haptics.SELECTION); c.setDanmakuEnabled(on); dim() }
        val count = c.loadedDanmakuCount
        val statusLabel = ui.text(
            if (count > 0) PlayerUiText.t("当前已加载 $count 条弹幕", "$count comments loaded")
            else PlayerUiText.t("当前未加载弹幕", "No comments loaded"),
            12f,
            if (count > 0) ui.accent else PlayerUi.TEXT_DIM,
        )
        danmakuStatusText = statusLabel
        list.addView(ui.card().also { card ->
            ui.addRow(card, ui.row(Ic.FORUM, PlayerUiText.t("启用弹幕", "Show danmaku"), null, sw).also { r -> r.setOnClickListener { sw.toggle() } })
            ui.addRow(card, LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(ui.dp(16), ui.dp(9), ui.dp(14), ui.dp(9))
                addView(ui.icon(Ic.CHECK_CIRCLE, 15f, if (count > 0) ui.accent else PlayerUi.TEXT_DIM), LinearLayout.LayoutParams(-2, -2).apply { rightMargin = ui.dp(10) })
                addView(statusLabel)
            })
        })
        search.addView(ui.sectionLabel(PlayerUiText.t("弹幕搜索与匹配", "Search and match")))
        val name = field(ui, c.title, PlayerUiText.t("剧集名称", "Title"))
        val season = field(ui, "1", PlayerUiText.t("第 1 季", "Season 1"), number = true)
        val episode = field(ui, "${c.episode + 1}", "1", number = true)
        c.danmakuPrompt { info -> info?.let { if (!isFinishing) { name.setText(it.keyword); episode.setText("${it.episodeNumber}") } } }
        search.addView(ui.card().apply {
            setPadding(ui.dp(14), ui.dp(12), ui.dp(14), ui.dp(14))
            addView(ui.text(PlayerUiText.t("剧集名称", "Title"), 11f, PlayerUi.TEXT_DIM).apply { setPadding(0, 0, 0, ui.dp(6)) })
            addView(name, LinearLayout.LayoutParams(-1, ui.dp(40)))
            addView(LinearLayout(this@NativePlayerActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                fun column(label: String, f: EditText, left: Int) = addView(LinearLayout(this@NativePlayerActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(ui.text(label, 11f, PlayerUi.TEXT_DIM).apply { setPadding(0, ui.dp(10), 0, ui.dp(6)) })
                    addView(f, LinearLayout.LayoutParams(-1, ui.dp(40)))
                }, LinearLayout.LayoutParams(0, -2, 1f).apply { leftMargin = ui.dp(left) })
                column(PlayerUiText.t("季数 (S)", "Season (S)"), season, 0)
                column(PlayerUiText.t("集数 (E)", "Episode (E)"), episode, 10)
            })
            addView(LinearLayout(this@NativePlayerActivity).apply {
                orientation = LinearLayout.HORIZONTAL
                fun button(code: Int, label: String, fill: Int, left: Int, onClick: () -> Unit) = addView(LinearLayout(this@NativePlayerActivity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER
                    background = ui.rounded(fill, 10f, if (fill == ui.accent) 0 else 0x1FFFFFFF, 0.6f)
                    addView(ui.icon(code, 14f), LinearLayout.LayoutParams(-2, -2).apply { rightMargin = ui.dp(8) })
                    addView(ui.text(label, 13f, bold = fill == ui.accent))
                    setOnClickListener {
                        if (!c.danmakuEnabled) return@setOnClickListener
                        haptic(c, Haptics.SELECTION)
                        (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager).hideSoftInputFromWindow(windowToken, 0)
                        onClick()
                    }
                }, LinearLayout.LayoutParams(0, ui.dp(40), 1f).apply { leftMargin = ui.dp(left) })
                // 分步搜索: pick the show, then the episode. 直接搜索匹配: the first hit and episode E, without asking.
                button(Ic.MENU, PlayerUiText.t("分步搜索", "Step by step"), 0x14FFFFFF, 0) {
                    danmakuDirect = null
                    c.searchDanmaku(name.text.toString().trim())
                }
                button(Ic.BOLT, PlayerUiText.t("直接搜索匹配", "Search and match"), ui.accent, 10) {
                    danmakuDirect = (episode.text.toString().toIntOrNull() ?: 1).coerceAtLeast(1) - 1
                    c.searchDanmaku(name.text.toString().trim())
                }
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ui.dp(14) })
        })
        search.addView(ui.text(PlayerUiText.t(
            "提示：直接搜索匹配会自动关联剧名、季数与集数直接从弹幕库加载并保存记忆；若未命中，可尝试「分步搜索」手动选择剧集。",
            "Search and match loads the comments for this title and episode and remembers the match; if it misses, use “Step by step”.",
        ), 11f, PlayerUi.TEXT_DIM).apply { setPadding(ui.dp(2), ui.dp(12), ui.dp(2), 0); setLineSpacing(ui.dp(3).toFloat(), 1f) })
        dim()
        list.addView(search)
    }

    private fun danmakuStyle(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        fun cfg() = c.danmakuConfig
        list.addView(View(this), LinearLayout.LayoutParams(1, ui.dp(8)))
        list.addView(ui.card().also { card ->
            fun toggle(title: String, get: () -> Boolean, set: (Boolean) -> DanmakuConfig) {
                val sw = SwitchView(this, ui.accent, get()) { on -> haptic(c, Haptics.SELECTION); c.updateDanmaku(set(on)) }
                ui.addRow(card, ui.row(null, title, null, sw).also { r -> r.minimumHeight = ui.dp(51); r.setOnClickListener { sw.toggle() } })
            }
            toggle(PlayerUiText.t("显示顶部固定弹幕", "Show top comments"), { cfg().showTop }) { cfg().copy(showTop = it) }
            toggle(PlayerUiText.t("显示底部固定弹幕", "Show bottom comments"), { cfg().showBottom }) { cfg().copy(showBottom = it) }
        })
        list.addView(ui.sectionLabel(PlayerUiText.t("颜色模式", "Colour")))
        list.addView(ui.card().also { card ->
            val value = ui.text(PlayerUiText.danmakuColorMode(cfg().colorMode), 12f, PlayerUi.TEXT_DIM)
            val trailing = LinearLayout(this).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(value)
                addView(ui.icon(Ic.CHEVRON, 16f, PlayerUi.TEXT_DIM), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
            }
            ui.addRow(card, ui.row(Ic.BRUSH, PlayerUiText.t("颜色模式", "Colour"), null, trailing).also { r ->
                r.setOnClickListener {
                    controls?.showMenu(trailing, above = false, items = PlayerUiText.danmakuColorModes.map { m ->
                        PlayerControlsView.MenuItem(PlayerUiText.danmakuColorMode(m), selected = m == cfg().colorMode) {
                            c.updateDanmaku(cfg().copy(colorMode = m))
                            showDanmaku(c)
                        }
                    })
                }
            })
            val usesGradient = cfg().colorMode == "gradient" || cfg().colorMode == "3" || cfg().colorMode == "random_Mix" || cfg().colorMode == "0"
            if (usesGradient) {
                val gradValue = ui.text(PlayerUiText.danmakuGradientLabel(cfg().gradientStyle), 12f, PlayerUi.TEXT_DIM)
                val gradTrailing = LinearLayout(this).apply {
                    gravity = Gravity.CENTER_VERTICAL
                    addView(gradValue)
                    addView(ui.icon(Ic.CHEVRON, 16f, PlayerUi.TEXT_DIM), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
                }
                ui.addRow(card, ui.row(Ic.AUTO_AWESOME, PlayerUiText.t("渐变色风格", "Gradient style"), null, gradTrailing).also { r ->
                    r.setOnClickListener {
                        val curPreset = PlayerUiText.parseGradientPreset(cfg().gradientStyle)
                        val curWeight = PlayerUiText.parseFontWeight(cfg().gradientStyle)
                        controls?.showMenu(gradTrailing, above = false, items = PlayerUiText.danmakuGradientPresets.map { (id, label) ->
                            PlayerControlsView.MenuItem(label, selected = id == curPreset) {
                                val nextStyle = PlayerUiText.encodeGradientAndWeight(id, curWeight)
                                c.updateDanmaku(cfg().copy(gradientStyle = nextStyle))
                                gradValue.text = label
                            }
                        })
                    }
                })
            }
        })
        fun pct(v: Double) = "${Math.round(v * 100)}%"
        fun sliders(title: String, rows: List<SliderRow>) {
            list.addView(ui.sectionLabel(title))
            list.addView(ui.card().also { card ->
                for (r in rows) {
                    val badge = ui.valueBadge(r.label(r.get()))
                    val box = LinearLayout(this).apply {
                        orientation = LinearLayout.VERTICAL
                        setPadding(ui.dp(14), ui.dp(10), ui.dp(14), ui.dp(4))
                        addView(LinearLayout(this@NativePlayerActivity).apply {
                            orientation = LinearLayout.HORIZONTAL
                            gravity = Gravity.CENTER_VERTICAL
                            addView(ui.icon(r.icon, 14f, 0xB3FFFFFF.toInt()).apply { if (r.rotate) rotation = 90f }, LinearLayout.LayoutParams(ui.dp(16), ui.dp(16)).apply { rightMargin = ui.dp(10) })
                            addView(ui.text(r.title, 13.5f), LinearLayout.LayoutParams(0, -2, 1f))
                            addView(badge)
                        })
                        addView(SliderView(this@NativePlayerActivity, ui.accent, 0x33FFFFFF, 12f, 2.5f) { f, done ->
                            val value = Math.round((r.min + (r.max - r.min) * f) / r.step) * r.step
                            badge.text = r.label(value)
                            c.updateDanmaku(r.set(value), save = done)
                        }.apply { fraction = ((r.get() - r.min) / (r.max - r.min)).toFloat() })
                    }
                    ui.addRow(card, box)
                }
            })
        }
        sliders(PlayerUiText.t("外观与排版", "Appearance"), listOf(
            SliderRow(Ic.TEXT_FORMAT, PlayerUiText.t("字号大小", "Font size"), 12.0, 32.0, 1.0, { cfg().fontSize }, { cfg().copy(fontSize = it) }) { "${Math.round(it)} pt" },
            SliderRow(
                Ic.TEXT_FORMAT,
                PlayerUiText.t("字体粗细", "Font weight"),
                0.0,
                8.0,
                1.0,
                { PlayerUiText.parseFontWeight(cfg().gradientStyle).toDouble() },
                { w -> cfg().copy(gradientStyle = PlayerUiText.encodeGradientAndWeight(PlayerUiText.parseGradientPreset(cfg().gradientStyle), Math.round(w).toInt())) },
            ) { PlayerUiText.danmakuFontWeightLabel(Math.round(it).toInt()) },
            SliderRow(Ic.UNFOLD, PlayerUiText.t("行高", "Line height"), 1.0, 2.5, 0.1, { cfg().lineHeight }, { cfg().copy(lineHeight = it) }) { PlayerSettings.num(Math.round(it * 10) / 10.0) },
            SliderRow(Ic.CONTRAST, PlayerUiText.t("不透明度", "Opacity"), 0.1, 1.0, 0.05, { cfg().opacity }, { cfg().copy(opacity = it) }, label = ::pct),
            SliderRow(Ic.COLUMNS, PlayerUiText.t("显示区域", "Area"), 0.1, 1.0, 0.05, { cfg().area }, { cfg().copy(area = it) }, label = ::pct),
            SliderRow(Ic.DOUBLE_RIGHT, PlayerUiText.t("滚动速度", "Scroll speed"), 0.3, 2.0, 0.1, { cfg().scrollSpeed }, { cfg().copy(scrollSpeed = it) }) { PlayerSettings.num(Math.round(it * 10) / 10.0) },
            SliderRow(Ic.BRUSH, PlayerUiText.t("文字描边", "Outline"), 0.0, 3.0, 0.1, { cfg().strokeWidth }, { cfg().copy(strokeWidth = it) }) { PlayerSettings.num(Math.round(it * 10) / 10.0) },
        ))
        sliders(PlayerUiText.t("时间同步", "Timing"), listOf(
            SliderRow(Ic.CLOCK, PlayerUiText.t("弹幕延迟", "Delay"), -30.0, 30.0, 0.5, { cfg().delaySeconds }, { cfg().copy(delaySeconds = it) }, label = PlayerUiText::danmakuDelay),
        ))
        list.addView(View(this), LinearLayout.LayoutParams(1, ui.dp(12)))
        list.addView(ui.card().also { card ->
            val count = ui.text(PlayerUiText.t("${cfg().blackList.size} 个", "${cfg().blackList.size}"), 12f, PlayerUi.TEXT_DIM)
            val trailing = LinearLayout(this).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(count)
                addView(ui.icon(Ic.CHEVRON, 16f, PlayerUi.TEXT_DIM), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
            }
            ui.addRow(card, ui.row(Ic.CANCEL, PlayerUiText.t("屏蔽词管理", "Blocked words"), null, trailing).also { r ->
                r.setOnClickListener {
                    haptic(c, Haptics.SELECTION)
                    danmakuSubScreen = 3
                    showDanmaku(c)
                }
            })
        })
    }

    private class SliderRow(
        val icon: Int, val title: String, val min: Double, val max: Double, val step: Double,
        val get: () -> Double, val set: (Double) -> DanmakuConfig, val rotate: Boolean = false, val label: (Double) -> String,
    )

    /** Inline 屏蔽词管理 sub-view inside the danmaku panel (matching original i2.J). */
    private fun danmakuBlockedWordsView(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        val input = field(ui, "", PlayerUiText.t("输入屏蔽词后点击添加", "Enter blocked word"))
        fun addWord() {
            val w = input.text.toString().trim()
            if (w.isEmpty()) return
            val cur = c.danmakuConfig.blackList
            if (w !in cur) {
                haptic(c, Haptics.SELECTION)
                c.updateDanmaku(c.danmakuConfig.copy(blackList = cur + w))
            }
            input.setText("")
            showDanmaku(c)
        }
        list.addView(LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ui.dp(8), 0, ui.dp(12))
            addView(input, LinearLayout.LayoutParams(0, ui.dp(38), 1f))
            addView(ui.text(PlayerUiText.t("添加", "Add"), 13f, Color.WHITE, bold = true).apply {
                gravity = Gravity.CENTER
                background = ui.rounded(ui.accent, 10f)
                setPadding(ui.dp(14), 0, ui.dp(14), 0)
                setOnClickListener { addWord() }
            }, LinearLayout.LayoutParams(-2, ui.dp(38)).apply { leftMargin = ui.dp(8) })
        })
        val words = c.danmakuConfig.blackList
        if (words.isEmpty()) {
            list.addView(ui.text(PlayerUiText.t("暂无屏蔽词，命中屏蔽词的弹幕将被过滤", "No blocked words yet"), 12.5f, PlayerUi.TEXT_DIM).apply {
                gravity = Gravity.CENTER
                setPadding(0, ui.dp(32), 0, ui.dp(32))
            })
        } else {
            list.addView(ui.card().also { card ->
                for (w in words) {
                    val del = ui.icon(Ic.CLOSE, 16f, PlayerUi.TEXT_DIM).apply {
                        setPadding(ui.dp(8), ui.dp(6), ui.dp(4), ui.dp(6))
                        setOnClickListener {
                            haptic(c, Haptics.SELECTION)
                            c.updateDanmaku(c.danmakuConfig.copy(blackList = words.filterNot { it == w }))
                            showDanmaku(c)
                        }
                    }
                    ui.addRow(card, ui.row(null, w, null, del))
                }
            })
        }
    }

    private fun danmakuAnimeList(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        list.addView(View(this), LinearLayout.LayoutParams(1, ui.dp(6)))
        list.addView(ui.card().also { card ->
            for (r in lastAnimeResults) {
                val badge = ui.text(PlayerUiText.t("${r.episodeCount} 集", "${r.episodeCount} eps"), 12f, PlayerUi.TEXT_DIM)
                ui.addRow(card, ui.row(null, r.animeTitle, null, badge).also { row ->
                    row.setOnClickListener {
                        haptic(c, Haptics.SELECTION)
                        c.pickDanmakuAnime(r.animeId)
                    }
                })
            }
        })
    }

    private fun danmakuEpisodeList(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        list.addView(View(this), LinearLayout.LayoutParams(1, ui.dp(6)))
        list.addView(ui.card().also { card ->
            lastEpisodeResults.forEachIndexed { i, ep ->
                ui.addRow(card, ui.row(null, ep.episodeName, null, null).also { row ->
                    row.setOnClickListener {
                        haptic(c, Haptics.SELECTION)
                        danmakuSubScreen = 0
                        controls?.closePanel()
                        c.pickDanmakuEpisode(i)
                        toast(PlayerUiText.t("已匹配弹幕：${ep.episodeName}", "Danmaku matched"))
                    }
                })
            }
        })
    }

    private fun onDanmakuResults(c: PlayerController, results: List<DanmakuSearchResultItem>) {
        if (results.isEmpty()) { danmakuDirect = null; toast(PlayerUiText.t("未匹配到相关弹幕", "No matching danmaku")); return }
        if (danmakuDirect != null) { c.pickDanmakuAnime(results.first().animeId); return }
        lastAnimeResults = results
        danmakuSubScreen = 1
        showDanmaku(c)
    }

    private fun onDanmakuEpisodes(c: PlayerController, episodes: List<EpisodeItem>) {
        val direct = danmakuDirect
        if (direct != null) {
            danmakuDirect = null
            if (episodes.isEmpty()) { toast(PlayerUiText.t("未匹配到相关弹幕", "No matching danmaku")); return }
            c.pickDanmakuEpisode(direct.coerceIn(0, episodes.size - 1))
            danmakuSubScreen = 0
            controls?.closePanel()
            toast(PlayerUiText.t("已匹配弹幕：${episodes[direct.coerceIn(0, episodes.size - 1)].episodeName}", "Danmaku matched"))
            return
        }
        lastEpisodeResults = episodes
        danmakuSubScreen = 2
        showDanmaku(c)
    }

    private fun enterPip() {
        if (Build.VERSION.SDK_INT < 26) { notice(PlayerUiText.t("画中画需要 Android 8.0 及以上", "Picture-in-picture needs Android 8.0")); return }
        controls?.hide()
        try {
            val info = controller?.kernel?.mediaInfo()
            val ratio = if (info != null && info.width > 0 && info.height > 0) {
                val r = info.width.toDouble() / info.height.toDouble()
                when {
                    r < 100.0 / 239.0 -> Rational(100, 239)
                    r > 239.0 / 100.0 -> Rational(239, 100)
                    else -> Rational(info.width, info.height)
                }
            } else {
                Rational(16, 9)
            }
            val entered = enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(ratio).build())
            if (entered) {
                inPip = true
                wasInPip = true
                controls?.setPipMode(true)
            }
        } catch (e: IllegalStateException) {
            notice(PlayerUiText.t("画中画不可用", "Picture-in-picture is not available"))
        }
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            val attrs = window.attributes
            if (attrs.layoutInDisplayCutoutMode != WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS) {
                attrs.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                window.attributes = attrs
            }
        } else if (Build.VERSION.SDK_INT >= 28) {
            val attrs = window.attributes
            if (attrs.layoutInDisplayCutoutMode != WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES) {
                attrs.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                window.attributes = attrs
            }
        }
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(androidx.core.view.WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && !inPip) hideSystemBars()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        val c = controller ?: return super.onKeyDown(keyCode, event)
        return when (keyCode) {
            KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE, KeyEvent.KEYCODE_SPACE -> { c.togglePause(); true }
            KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> { controls?.beginSeekWait(); c.seekBy(c.playbackConfig.fastForwardSeconds.toInt()); true }
            KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_MEDIA_REWIND -> { controls?.beginSeekWait(); c.seekBy(-c.playbackConfig.fastForwardSeconds.toInt()); true }
            KeyEvent.KEYCODE_MEDIA_NEXT -> { c.nextEpisode(); true }
            else -> super.onKeyDown(keyCode, event)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        if (controls?.menuOpen == true) { controls?.closeMenu(); return }
        if (controls?.panelOpen == true) {
            val c = controller
            if (danmakuSubScreen != 0 && c != null) {
                danmakuSubScreen = if (danmakuSubScreen == 2) 1 else 0
                showDanmaku(c)
                return
            }
            controls?.closePanel()
            return
        }
        if (controls?.locked == true) { controls?.toggle(); return } // locked: 返回 only shows the locks
        controller?.close() ?: finish()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Only when the "auto picture-in-picture" preference is on (the original shipped a bug here, fixed in 1.1.10).
        if (Build.VERSION.SDK_INT >= 26 && controller?.autoPictureInPicture == true) {
            enterPip()
        }
    }

    override fun onResume() {
        super.onResume()
        if (Build.VERSION.SDK_INT < 26 || !isInPictureInPictureMode) {
            inPip = false
            wasInPip = false
            controls?.setPipMode(false)
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        inPip = isInPictureInPictureMode
        controls?.setPipMode(isInPictureInPictureMode)
        if (isInPictureInPictureMode) {
            wasInPip = true
        } else if (!lifecycle.currentState.isAtLeast(androidx.lifecycle.Lifecycle.State.STARTED)) {
            wasInPip = false
            controller?.close()
            PlaybackNotificationService.stop(this)
            finish()
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // a second openPlayerPage while the page is alive replaces the session
        if (NativePlayerHost.hasPending()) {
            inPip = false
            wasInPip = false
            controller?.close(finishActivity = false)
            recreate()
        }
    }

    override fun onStop() {
        val closingPip = (Build.VERSION.SDK_INT >= 26 && isInPictureInPictureMode) || inPip || wasInPip
        if (closingPip) {
            inPip = false
            wasInPip = false
            controller?.close()
            PlaybackNotificationService.stop(this)
            finish()
            super.onStop()
            return
        }
        super.onStop()
        controller?.reportPreferences()
        val c = controller ?: return
        // pauseOnBackground = pause when the page leaves the foreground; otherwise the media service keeps playing
        if (c.pauseOnBackground && !isInPictureInPictureMode && c.kernel.isPlaying) c.kernel.pause()
    }

    private companion object {
        const val REQUEST_SUBTITLE = 7301
    }

    override fun onDestroy() {
        controller?.close()
        if (NativePlayerHost.controller === controller) NativePlayerHost.controller = null
        PlaybackNotificationService.stop(this)
        super.onDestroy()
    }
}
