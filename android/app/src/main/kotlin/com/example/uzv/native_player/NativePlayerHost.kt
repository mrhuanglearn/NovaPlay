package com.example.uzv.native_player

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import com.example.uzv.native_player.kernel.KernelSelection
import com.example.uzv.native_player.kernel.PlayerKernel
import com.example.uzv.native_player.kernel.mdk.MdkNative
import com.example.uzv.native_player.kernel.mpv.MpvNative
import com.example.uzv.native_player.ui.PlayerUiText
import io.flutter.embedding.engine.FlutterEngine
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Carries a launch hand-off from [NativePlayerHost.openPlayerPage] into [NativePlayerActivity] so the player opens
 * immediately in its target orientation (from fast-probed stream dimensions when known, else landscape first).
 */
data class PrewarmedLaunch(
    val request: OpenPlayerRequest,
    val kernel: PlayerKernel?,
    val activeKernelId: String,
    val proxyToken: String?,
    val initialSource: SourcePayload?,
    val probedSize: Pair<Int, Int>?,
    val initialLandscape: Boolean,
    val manualOrientation: Boolean = false,
    val notice: String? = null,
    val earlyError: Pair<String, Int?>? = null,
    val lastLoadStartMs: Long = 0L,
    val autoSkippedIntro: Boolean = false,
)

internal fun extractSourceSize(src: SourcePayload?): Pair<Int, Int>? {
    val w = src?.videoWidth?.toInt() ?: return null
    val h = src.videoHeight?.toInt() ?: return null
    return if (w > 0 && h > 0) w to h else null
}

internal fun extractInitialRequestSize(request: OpenPlayerRequest): Pair<Int, Int>? {
    extractSourceSize(request.initialSource)?.let { return it }
    val w = request.initialVideoWidth?.toInt() ?: return null
    val h = request.initialVideoHeight?.toInt() ?: return null
    return if (w > 0 && h > 0) w to h else null
}

internal fun resolveInitialLandscape(
    mode: String,
    isPhone: Boolean,
    probedSize: Pair<Int, Int>?,
): Boolean =
    when (mode) {
        "landscape" -> true
        "portrait" -> false
        // Adaptive mode: adapt immediately when source dimensions are known; otherwise prioritize landscape first.
        else -> if (!isPhone) true else probedSize?.let { it.first >= it.second } ?: true
    }

/**
 * Implements the Pigeon `NativePlayerHostApi` (Dart -> Kotlin) and keeps the Flutter-side callback API.
 *
 * OBSERVED: the shipped NativePlayerActivity refuses to start ("Native player channel not registered") unless the
 * Flutter engine and a pending launch are present, which is the same hand-off done here.
 */
object NativePlayerHost : NativePlayerHostApi {
    lateinit var flutterApi: NativePlayerFlutterApi
        private set
    private lateinit var appContext: Context
    private val main by lazy { Handler(Looper.getMainLooper()) }

    @Volatile private var pendingLaunch: PrewarmedLaunch? = null
    @Volatile var controller: PlayerController? = null
    @Volatile private var carriedSpeed: Double? = null
    private var openSeq = 0L

    fun register(engine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        NativePlayerHostApi.setUp(engine.dartExecutor.binaryMessenger, this)
        flutterApi = NativePlayerFlutterApi(engine.dartExecutor.binaryMessenger)
    }

    fun takePendingLaunch(): PrewarmedLaunch? = pendingLaunch.also { pendingLaunch = null }

    /** Look without consuming: `onNewIntent` must leave the launch for the recreated activity's `onCreate`. */
    fun hasPending(): Boolean = pendingLaunch != null

    /**
     * The page reloads itself (kernel or hardware decoding changed in its 设置 panel): the recreated activity takes
     * [request] and starts at [speed]. The Dart session stays open; no PageClosedEvent is sent.
     */
    fun restart(
        request: OpenPlayerRequest,
        speed: Double,
        initialLandscape: Boolean = true,
        carriedVideoSize: Pair<Int, Int>? = null,
        manualOrientation: Boolean = false,
    ) {
        openSeq++
        pendingLaunch?.kernel?.let { k ->
            k.listener = null
            k.release()
        }
        pendingLaunch = PrewarmedLaunch(
            request = request,
            kernel = null,
            activeKernelId = KernelSelection.parse(request.playbackConfig.kernel).id,
            proxyToken = null,
            initialSource = request.initialSource,
            probedSize = carriedVideoSize ?: extractInitialRequestSize(request),
            initialLandscape = initialLandscape,
            manualOrientation = manualOrientation,
        )
        carriedSpeed = speed
    }

    fun takeCarriedSpeed(): Double? = carriedSpeed.also { carriedSpeed = null }

    internal fun kernelAvailable(k: KernelSelection.Kernel) = when (k) {
        KernelSelection.Kernel.EXO -> true
        KernelSelection.Kernel.MPV -> MpvNative.isAvailable()
        KernelSelection.Kernel.MDK -> MdkNative.isAvailable()
    }

    internal fun kernelUnavailableReason(k: KernelSelection.Kernel) = when (k) {
        KernelSelection.Kernel.MPV -> MpvNative.unavailableReason()
        KernelSelection.Kernel.MDK -> MdkNative.unavailableReason()
        else -> ""
    }

    override fun openPlayerPage(request: OpenPlayerRequest, callback: (Result<Unit>) -> Unit) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { openPlayerPage(request, callback) }
            return
        }
        val seq = ++openSeq
        pendingLaunch?.kernel?.let { k ->
            k.listener = null
            k.release()
        }

        val mode = PlayerUiText.effectiveOrientationMode(request.playbackConfig)
        val isPhone = appContext.resources.configuration.smallestScreenWidthDp < 600
        val src = request.initialSource
        val knownSize = extractInitialRequestSize(request)

        val choice = KernelSelection.choose(request.playbackConfig.kernel, ::kernelAvailable, ::kernelUnavailableReason)
        var selected = choice.kernel
        var notice = choice.notice
        if (src != null && src.success && !src.url.isNullOrBlank() &&
            selected == KernelSelection.Kernel.EXO && KernelSelection.requiresFfmpegKernel(src.url)
        ) {
            for (cand in KernelSelection.fallbackOrder(selected)) {
                if (kernelAvailable(cand)) {
                    selected = cand
                    notice = PlayerUiText.t(
                        "检测到蓝光原盘格式，已自动切换至 ${PlayerUiText.kernelName(cand.id)} 内核",
                        "Blu-ray format detected; switched to ${PlayerUiText.kernelName(cand.id)}",
                    )
                    break
                }
            }
        }

        val replied = AtomicBoolean(false)
        fun launchWith(size: Pair<Int, Int>?, aborted: Boolean = false) {
            if (!replied.compareAndSet(false, true)) return
            if (aborted || seq != openSeq) {
                callback(Result.success(Unit))
                return
            }
            val effectiveSrc = if (size != null && src != null && src.videoWidth == null) {
                src.copy(videoWidth = size.first.toLong(), videoHeight = size.second.toLong())
            } else {
                src
            }
            pendingLaunch = PrewarmedLaunch(
                request = request,
                kernel = null,
                activeKernelId = selected.id,
                proxyToken = null,
                initialSource = effectiveSrc,
                probedSize = size,
                initialLandscape = resolveInitialLandscape(mode, isPhone, size),
                notice = notice,
            )
            carriedSpeed = null
            appContext.startActivity(
                Intent(appContext, NativePlayerActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            callback(Result.success(Unit))
        }

        val budgetMs = (request.probeBudgetMs ?: 0L).coerceIn(0L, 260L)
        val canFastProbe = mode == "auto" &&
            isPhone &&
            budgetMs > 0L &&
            request.epgProgrammes == null &&
            knownSize == null &&
            src != null &&
            src.success &&
            !src.url.isNullOrBlank() &&
            !KernelSelection.requiresFfmpegKernel(src.url)

        if (!canFastProbe) {
            launchWith(knownSize)
            return
        }

        val fallbackTask = Runnable { launchWith(null) }
        main.postDelayed(fallbackTask, budgetMs + 30L)
        flutterApi.onProbeVideoSize(
            request.sessionId,
            request.startLineIndex,
            request.startEpisodeIndex,
            src.url,
            src.headers.orEmpty(),
            budgetMs,
        ) { res ->
            main.post {
                main.removeCallbacks(fallbackTask)
                val p = res.getOrNull()
                if (p != null && p.width < 0) {
                    launchWith(null, aborted = true)
                    return@post
                }
                val dims = if (p != null && p.width > 0 && p.height > 0) p.width.toInt() to p.height.toInt() else null
                launchWith(dims)
            }
        }
    }

    override fun provideSource(payload: SourcePayload) { controller?.onSource(payload) }
    override fun updateVideoSize(sessionId: String, lineIndex: Long, episodeIndex: Long, width: Long, height: Long) {
        val w = width.toInt()
        val h = height.toInt()
        if (w <= 0 || h <= 0) return
        val launch = pendingLaunch
        if (launch != null &&
            launch.request.sessionId == sessionId &&
            launch.request.startLineIndex == lineIndex &&
            launch.request.startEpisodeIndex == episodeIndex
        ) {
            val mode = PlayerUiText.effectiveOrientationMode(launch.request.playbackConfig)
            val isPhone = appContext.resources.configuration.smallestScreenWidthDp < 600
            val updatedSrc = launch.initialSource?.let { s ->
                if (s.videoWidth == null) s.copy(videoWidth = width, videoHeight = height) else s
            }
            pendingLaunch = launch.copy(
                initialSource = updatedSrc,
                probedSize = w to h,
                initialLandscape = resolveInitialLandscape(mode, isPhone, w to h),
            )
        }
        controller?.onProbedVideoSize(sessionId, lineIndex.toInt(), episodeIndex.toInt(), w, h)
    }
    override fun updateDanmaku(payload: DanmakuPayload) { controller?.onDanmaku(payload) }
    override fun updateLineTmdbMatches(sessionId: String, matches: List<TmdbEpisodeItem>) { controller?.onTmdbMatches(matches) }
    override fun updateRuntimeConfig(sessionId: String, patch: RuntimeConfigPatch) { controller?.onRuntimeConfig(patch) }
    override fun provideDanmakuSearchResults(sessionId: String, results: List<DanmakuSearchResultItem>) { controller?.onDanmakuSearchResults(results) }
    override fun provideDanmakuEpisodesResults(sessionId: String, episodes: List<EpisodeItem>) { controller?.onDanmakuEpisodes(episodes) }

    override fun showToast(message: String, long: Boolean): Boolean {
        val c = controller ?: return false
        c.toast(message, long)
        return true
    }
}
