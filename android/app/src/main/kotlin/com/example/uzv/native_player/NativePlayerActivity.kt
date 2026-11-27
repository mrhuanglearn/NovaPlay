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
    private var rootView: FrameLayout? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var inPip = false
    private var wasInPip = false
    private var manualOrientationThisEpisode = false
    private var lastVideoSize: Pair<Int, Int>? = null
    private var deferredAutoOrientSize: Pair<Int, Int>? = null
    private val danmakuPanel by lazy {
        DanmakuPanelController(
            activity = this,
            controlsProvider = { controls },
            onHaptic = ::haptic,
            onToast = ::toast,
        )
    }

    private fun ensureKeepScreenOn() {
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.decorView.keepScreenOn = true
        rootView?.keepScreenOn = true
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val launch = NativePlayerHost.takePendingLaunch()
        if (launch == null) { finish(); return }
        val request = launch.request

        ensureKeepScreenOn()
        val initialMode = PlayerUiText.effectiveOrientationMode(request.playbackConfig)
        requestedOrientation = when (initialMode) {
            "landscape" -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            "portrait" -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            else -> if (isHandheldPhone()) {
                if (launch.initialLandscape) ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                else ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            } else {
                ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            }
        }
        lastVideoSize = launch.probedSize
        manualOrientationThisEpisode = launch.manualOrientation

        val root = FrameLayout(this).apply {
            setBackgroundColor(0xFF000000.toInt())
            keepScreenOn = true
        }
        rootView = root
        val (kernel, activeKernelId) = if (launch.kernel != null) {
            launch.kernel to launch.activeKernelId
        } else {
            val requestedEnum = KernelSelection.parse(launch.activeKernelId)
            val built = buildSpecificKernel(requestedEnum, request.playbackConfig.hwDecode)
            if (built != null) {
                built to requestedEnum.id
            } else {
                val (fallbackKernel, fallbackEnum) = createKernel(request.playbackConfig)
                fallbackKernel to fallbackEnum.id
            }
        }
        val kernelView = kernel.attachActivity(this)
        val danmaku = DanmakuView(this).also { it.attach(kernel) }
        root.addView(kernelView, FrameLayout.LayoutParams(-1, -1))
        root.addView(danmaku, FrameLayout.LayoutParams(-1, -1))
        val c = PlayerController(request, kernel, danmaku, activeKernelId, prewarmed = launch) { finish() }
        controller = c
        NativePlayerHost.controller = c
        c.applyHeadTail()
        c.onAutoSwitchKernel = { target ->
            buildSpecificKernel(target, c.playbackConfig.hwDecode)?.also { nextKernel ->
                val oldView = c.kernel.view
                val idx = root.indexOfChild(oldView).coerceAtLeast(0)
                root.removeView(oldView)
                root.addView(nextKernel.attachActivity(this), idx, FrameLayout.LayoutParams(-1, -1))
            }
        }

        val controls = PlayerControlsView(this, c, object : PlayerControlsView.Actions {
            override fun onQuality(anchor: View) = showQuality(c, anchor)
            override fun onSpeed(anchor: View) = showSpeed(c, anchor)
            override fun onEpisodes() = if (c.isLive) showChannels(c) else showEpisodes(c)
            override fun onDanmaku() = danmakuPanel.openRoot(c)
            override fun onEpg() = showEpg(c)
            override fun onAudio(anchor: View) = showAudio(c, anchor)
            override fun onSubtitles(anchor: View) = showSubtitles(c, anchor)
            override fun onMore(anchor: View) = showMore(c, anchor)
            override fun onSettings() = showSettings(c)
            override fun onPictureInPicture() = enterPip()
            override fun onScreenshot() = PlayerScreenshotSaver.captureAndSave(this@NativePlayerActivity, c.kernel, ::toast)
            override fun onReload() = c.retry()
            override fun onRotate() = rotate()
            override fun onMarkIntro() = c.markIntro()
            override fun onMarkOutro() = c.markOutro()
            override fun onClose() = c.close()
            override fun onHaptic() = haptic(c, Haptics.SELECTION)
        }).also { it.setTitle(request.title) }
        this.controls = controls
        controls.onOverlayClosed = {
            if (deferredAutoOrientSize != null) {
                mainHandler.post {
                    if (isFinishing || isDestroyed || controls.menuOpen || controls.panelOpen) return@post
                    val pending = deferredAutoOrientSize ?: return@post
                    deferredAutoOrientSize = null
                    val ctrl = controller ?: return@post
                    if (PlayerUiText.effectiveOrientationMode(ctrl.playbackConfig) == "auto" &&
                        !manualOrientationThisEpisode
                    ) {
                        applyAutoOrientationForSize(pending.first, pending.second)
                    }
                }
            }
        }
        root.addView(controls, FrameLayout.LayoutParams(-1, -1))
        c.uiListener = object : PlayerController.UiListener {
            override fun onChanged() {
                controls.refresh()
                if (settingsPanelOpen && controls.panelOpen && lastSettingsKernel != c.activeKernelId) {
                    showSettings(c, settingsScrollRef?.scrollY ?: 0)
                }
            }
            override fun onNotice(text: String) = controls.showNotice(text)
            override fun onToast(text: String, long: Boolean) =
                Toast.makeText(this@NativePlayerActivity, text, if (long) Toast.LENGTH_LONG else Toast.LENGTH_SHORT).show()
            override fun onVideoSizeChanged(width: Int, height: Int) {
                if (width <= 0 || height <= 0) return
                lastVideoSize = width to height
                controls.refresh()
                if (inPip && Build.VERSION.SDK_INT >= 26) {
                    syncPipAspectRatio()
                }
                val mode = PlayerUiText.effectiveOrientationMode(c.playbackConfig)
                if (mode != "auto" || manualOrientationThisEpisode) return
                if (controls.menuOpen || controls.panelOpen) {
                    deferredAutoOrientSize = width to height
                    return
                }
                applyAutoOrientationForSize(width, height)
            }
            override fun onEpisodeStarted() {
                val wasManual = manualOrientationThisEpisode
                val prevSize = lastVideoSize
                lastVideoSize = null
                deferredAutoOrientSize = null
                if (PlayerUiText.effectiveOrientationMode(c.playbackConfig) == "auto") {
                    manualOrientationThisEpisode = false
                    if (wasManual && isHandheldPhone()) {
                        val targetLandscape = resolveEpisodeResetLandscape(prevSize)
                        val desired = if (targetLandscape) {
                            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                        } else {
                            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                        }
                        if (isCurrentlyLandscape() != targetLandscape || requestedOrientation != desired) {
                            requestedOrientation = desired
                        }
                    }
                }
            }
            override fun onOrientationConfigChanged() {
                onOrientationModeChanged(PlayerUiText.effectiveOrientationMode(c.playbackConfig))
            }
        }
        c.danmakuSearchListener = { results -> danmakuPanel.onSearchResults(c, results) }
        c.danmakuEpisodesListener = { episodes -> danmakuPanel.onEpisodeResults(c, episodes) }
        c.danmakuCountListener = { count -> danmakuPanel.onCountChanged(count) }
        c.onSkipIntro = { fromMs -> controls.showSkipBanner(fromMs) }
        setContentView(root)
        hideSystemBars()
        installGestures(root, controls, c)

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
    private fun installGestures(root: FrameLayout, controls: PlayerControlsView, c: PlayerController) {
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
                val wasPlaying = c.kernel.isPlaying
                c.togglePause()
                controls.flashPlayState(paused = wasPlaying)
                controls.refresh()
                haptic(c, Haptics.LIGHT)
                return true
            }
            override fun onLongPress(e: MotionEvent) {
                if (controls.locked || mode != 0 || !c.kernel.isPlaying) return
                val speed = c.playbackConfig.longPressSpeed
                longPressing = true
                longPressY = e.y
                c.kernel.speed = speed.toFloat()
                controls.showSpeedHint(speed)
                haptic(c, Haptics.MEDIUM)
            }
        })
        root.setOnTouchListener { _, ev ->
            val kernel = c.kernel
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

    private fun instantiateKernel(k: KernelSelection.Kernel, hwDecode: Boolean): PlayerKernel = when (k) {
        KernelSelection.Kernel.MPV -> MpvKernel(this, hwDecode)
        KernelSelection.Kernel.MDK -> MdkKernel(this, hwDecode)
        KernelSelection.Kernel.EXO -> ExoKernel(this)
    }

    private fun buildSpecificKernel(k: KernelSelection.Kernel, hwDecode: Boolean): PlayerKernel? {
        if (!NativePlayerHost.kernelAvailable(k)) return null
        return try {
            instantiateKernel(k, hwDecode)
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * PlaybackConfig.kernel 'mpv' / 'mdk' builds that kernel; if its native library (or the glue) cannot be loaded, or the
     * player cannot be created, the page falls back to Exo and says so once. All three share the same controls
     * ([PlayerControlsView]) and panels, so the page looks and works the same whatever the kernel.
     */
    private fun createKernel(config: PlaybackConfig): Pair<PlayerKernel, KernelSelection.Kernel> {
        val choice = KernelSelection.choose(
            config.kernel,
            NativePlayerHost::kernelAvailable,
            NativePlayerHost::kernelUnavailableReason,
        )
        if (choice.kernel == KernelSelection.Kernel.EXO) {
            choice.notice?.let { Toast.makeText(this, it, Toast.LENGTH_LONG).show() }
        } else {
            try {
                return instantiateKernel(choice.kernel, config.hwDecode) to choice.kernel
            } catch (e: Throwable) {
                Toast.makeText(this, KernelSelection.fallbackNotice(choice.kernel, e.message), Toast.LENGTH_LONG).show()
            }
        }
        return ExoKernel(this) to KernelSelection.Kernel.EXO
    }

    // -- menus and panels (OBSERVED in UZN 1.2.0 on the phone, 2026-11-11) ------------------------------------------------
    private var controls: PlayerControlsView? = null
    private var settingsPanelOpen = false
    private var lastSettingsKernel = ""
    private var settingsScrollRef: android.widget.ScrollView? = null

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
            PlayerControlsView.MenuItem(PlayerUiText.t("截图", "Screenshot")) {
                PlayerScreenshotSaver.captureAndSave(this, c.kernel, ::toast)
            },
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
                val searchInput = danmakuPanel.field(ui, episodesQuery, PlayerUiText.t("搜索剧集名称...", "Search episodes...")).apply {
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
        lastSettingsKernel = c.activeKernelId
        lateinit var scroll: android.widget.ScrollView
        scroll = v.showPanel { list ->
            var card: LinearLayout? = null
            for (item in PlayerSettings.items()) when (item) {
                is PlayerSettings.Item.Section -> {
                    list.addView(ui.sectionLabel(item.title))
                    card = ui.card().also { list.addView(it, LinearLayout.LayoutParams(-1, -2)) }
                }
                is PlayerSettings.Item.Toggle -> {
                    val sw = SwitchView(this, ui.accent, item.get(c.effectivePlaybackConfig)) { on ->
                        haptic(c, Haptics.SELECTION)
                        if (item.get(c.effectivePlaybackConfig) != on) applySetting(c, item.set(c.effectivePlaybackConfig, on))
                    }
                    ui.addRow(card!!, ui.row(item.icon, item.title, item.subtitle, sw).also { r -> r.setOnClickListener { sw.toggle() } })
                }
                is PlayerSettings.Item.Option -> {
                    val sel = item.selected(c.effectivePlaybackConfig)
                    val row = ui.row(item.icon, item.title, null, if (sel) ui.icon(Ic.CHECK, 16f, ui.accent) else null, item.rotateIcon)
                    row.findViewWithTag<TextView>("icon")?.setTextColor(if (sel) ui.accent else 0xD9FFFFFF.toInt())
                    row.findViewWithTag<TextView>("title")?.let { t -> if (!sel) t.setTextColor(0xD9FFFFFF.toInt()) else t.typeface = android.graphics.Typeface.DEFAULT_BOLD }
                    row.setOnClickListener {
                        if (item.selected(c.effectivePlaybackConfig)) return@setOnClickListener
                        haptic(c, Haptics.SELECTION)
                        val next = item.select(c.effectivePlaybackConfig)
                        if (item.key.startsWith(PlayerSettings.KERNEL)) {
                            val k = KernelSelection.parse(next.kernel)
                            if (!NativePlayerHost.kernelAvailable(k)) {
                                toast(PlayerUiText.t("${k.label} 内核不可用：${NativePlayerHost.kernelUnavailableReason(k)}", "${k.label} kernel unavailable: ${NativePlayerHost.kernelUnavailableReason(k)}"))
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
                    val value = ui.text(item.value(c.effectivePlaybackConfig), 13f).apply { gravity = Gravity.CENTER; minWidth = ui.dp(46) }
                    fun button(code: Int, change: (PlaybackConfig) -> PlaybackConfig?) = ui.circleButton(code, 26f, 16f, 0x29FFFFFF).also { b ->
                        b.setOnClickListener {
                            val next = change(c.effectivePlaybackConfig) ?: return@setOnClickListener
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
        settingsPanelOpen = true
        settingsScrollRef = scroll
        v.onPanelClosed = {
            settingsPanelOpen = false
            settingsScrollRef = null
        }
        if (scrollY > 0) scroll.post { scroll.scrollTo(0, scrollY) }
    }

    private fun applySetting(c: PlayerController, next: PlaybackConfig) {
        val old = c.effectivePlaybackConfig
        if (PlayerSettings.needsReload(old, next)) { reloadWith(c, next); return }
        c.updatePlayback(next)
        val oldMode = PlayerUiText.effectiveOrientationMode(old)
        val newMode = PlayerUiText.effectiveOrientationMode(next)
        if (oldMode != newMode || old.isPriorityLandscape != next.isPriorityLandscape) {
            onOrientationModeChanged(newMode)
        }
    }

    private fun isHandheldPhone(): Boolean =
        resources.configuration.smallestScreenWidthDp < 600 &&
            !inPip &&
            !(Build.VERSION.SDK_INT >= 24 && isInMultiWindowMode)

    private fun onOrientationModeChanged(mode: String) {
        manualOrientationThisEpisode = false
        deferredAutoOrientSize = null
        when (mode) {
            "landscape" -> requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            "portrait" -> requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            else -> {
                val size = lastVideoSize
                    ?: controller?.kernel?.mediaInfo()?.takeIf { it.width > 0 && it.height > 0 }?.let { it.width to it.height }
                if (size != null) {
                    applyAutoOrientationForSize(size.first, size.second)
                } else if (isHandheldPhone()) {
                    requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                }
            }
        }
    }

    private fun isCurrentlyLandscape(): Boolean {
        val root = rootView
        return if (root != null && root.width > 0 && root.height > 0) {
            root.width > root.height
        } else {
            resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        }
    }

    private fun applyAutoOrientationForSize(w: Int, h: Int) {
        if (!isHandheldPhone()) return
        val targetLandscape = w >= h
        val desired = if (targetLandscape) {
            ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        } else {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        }
        if (isCurrentlyLandscape() != targetLandscape || requestedOrientation != desired) {
            requestedOrientation = desired
        }
    }

    /** 旋转屏幕 (OBSERVED: three steps): landscape → the other landscape → portrait → landscape. */
    private fun rotate() {
        manualOrientationThisEpisode = true
        deferredAutoOrientSize = null
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
        val carriedSize = lastVideoSize
            ?: c.kernel.mediaInfo()?.takeIf { it.width > 0 && it.height > 0 }?.let { it.width to it.height }
        NativePlayerHost.restart(request, c.currentSpeed, isCurrentlyLandscape(), carriedSize, manualOrientationThisEpisode)
        c.detach()
        if (NativePlayerHost.controller === c) NativePlayerHost.controller = null
        controller = null
        recreate()
    }

    private fun currentPipRatio(): Rational {
        val info = controller?.kernel?.mediaInfo()
        val decoded = if (info != null && info.width > 0 && info.height > 0) info.width to info.height else null
        val (num, den) = computePipAspectRatio(decoded, lastVideoSize)
        return Rational(num, den)
    }

    private fun syncPipAspectRatio() {
        if (Build.VERSION.SDK_INT < 26) return
        try {
            setPictureInPictureParams(PictureInPictureParams.Builder().setAspectRatio(currentPipRatio()).build())
        } catch (_: Throwable) {}
    }

    private fun enterPip() {
        if (Build.VERSION.SDK_INT < 26) { notice(PlayerUiText.t("画中画需要 Android 8.0 及以上", "Picture-in-picture needs Android 8.0")); return }
        controls?.hide()
        try {
            val entered = enterPictureInPictureMode(PictureInPictureParams.Builder().setAspectRatio(currentPipRatio()).build())
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
        if (hasFocus) {
            ensureKeepScreenOn()
            if (!inPip) hideSystemBars()
        }
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
            if (danmakuPanel.handleBack(controller)) return
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

    private fun syncOrientationForCurrentWindowMode() {
        if (isFinishing || isDestroyed) return
        val c = controller ?: return
        val mode = PlayerUiText.effectiveOrientationMode(c.playbackConfig)
        val inNonPipMultiWindow = Build.VERSION.SDK_INT >= 24 &&
            isInMultiWindowMode &&
            !inPip &&
            !(Build.VERSION.SDK_INT >= 26 && isInPictureInPictureMode)
        if (inNonPipMultiWindow) {
            if (mode == "auto" && requestedOrientation != ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED) {
                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
            }
            return
        }
        if (!isHandheldPhone()) return
        when (mode) {
            "landscape" -> if (requestedOrientation != ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE) {
                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            }
            "portrait" -> if (requestedOrientation != ActivityInfo.SCREEN_ORIENTATION_PORTRAIT) {
                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
            else -> {
                if (manualOrientationThisEpisode) return
                val size = lastVideoSize
                    ?: c.kernel.mediaInfo()?.takeIf { it.width > 0 && it.height > 0 }?.let { it.width to it.height }
                if (controls?.menuOpen == true || controls?.panelOpen == true) {
                    if (size != null) deferredAutoOrientSize = size
                    return
                }
                if (size != null) {
                    applyAutoOrientationForSize(size.first, size.second)
                } else if (requestedOrientation != ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE) {
                    requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        ensureKeepScreenOn()
        if (Build.VERSION.SDK_INT < 26 || !isInPictureInPictureMode) {
            val exitingPip = inPip || wasInPip
            inPip = false
            wasInPip = false
            controls?.setPipMode(false)
            if (exitingPip) {
                syncOrientationForCurrentWindowMode()
                mainHandler.post { syncOrientationForCurrentWindowMode() }
            }
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
        } else {
            wasInPip = false
            ensureKeepScreenOn()
            syncOrientationForCurrentWindowMode()
            mainHandler.post { syncOrientationForCurrentWindowMode() }
        }
    }

    override fun onMultiWindowModeChanged(isInMultiWindowMode: Boolean, newConfig: Configuration) {
        super.onMultiWindowModeChanged(isInMultiWindowMode, newConfig)
        syncOrientationForCurrentWindowMode()
        if (!isInMultiWindowMode) {
            mainHandler.post { syncOrientationForCurrentWindowMode() }
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
        mainHandler.removeCallbacksAndMessages(null)
        rootView = null
        controller?.close()
        if (NativePlayerHost.controller === controller) NativePlayerHost.controller = null
        controller = null
        PlaybackNotificationService.stop(this)
        super.onDestroy()
    }
}

internal fun resolveEpisodeResetLandscape(prevVideoSize: Pair<Int, Int>?): Boolean =
    prevVideoSize?.takeIf { it.first > 0 && it.second > 0 }?.let { it.first >= it.second } ?: true

internal fun computePipAspectRatio(
    decodedSize: Pair<Int, Int>?,
    fallbackSize: Pair<Int, Int>?,
): Pair<Int, Int> {
    val size = decodedSize?.takeIf { it.first > 0 && it.second > 0 }
        ?: fallbackSize?.takeIf { it.first > 0 && it.second > 0 }
        ?: return 16 to 9
    val r = size.first.toDouble() / size.second.toDouble()
    return when {
        r < 100.0 / 239.0 -> 100 to 239
        r > 239.0 / 100.0 -> 239 to 100
        else -> size
    }
}
