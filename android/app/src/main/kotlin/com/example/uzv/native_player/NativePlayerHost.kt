package com.example.uzv.native_player

import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine

/**
 * Implements the Pigeon `NativePlayerHostApi` (Dart -> Kotlin) and keeps the Flutter-side callback API.
 *
 * OBSERVED: the shipped NativePlayerActivity refuses to start ("Native player channel not registered") unless the
 * Flutter engine and a pending OpenPlayerRequest are present, which is the same hand-off done here.
 */
object NativePlayerHost : NativePlayerHostApi {
    lateinit var flutterApi: NativePlayerFlutterApi
        private set
    private lateinit var appContext: Context

    @Volatile private var pending: OpenPlayerRequest? = null
    @Volatile var controller: PlayerController? = null

    fun register(engine: FlutterEngine, context: Context) {
        appContext = context.applicationContext
        NativePlayerHostApi.setUp(engine.dartExecutor.binaryMessenger, this)
        flutterApi = NativePlayerFlutterApi(engine.dartExecutor.binaryMessenger)
    }

    fun takePending(): OpenPlayerRequest? = pending.also { pending = null }

    /** Look without consuming: `onNewIntent` must leave the request for the recreated activity's `onCreate`. */
    fun hasPending(): Boolean = pending != null

    /**
     * The page reloads itself (kernel or hardware decoding changed in its 设置 panel): the recreated activity takes
     * [request] and starts at [speed]. The Dart session stays open; no PageClosedEvent is sent.
     */
    fun restart(request: OpenPlayerRequest, speed: Double) {
        pending = request
        carriedSpeed = speed
    }

    @Volatile private var carriedSpeed: Double? = null
    fun takeCarriedSpeed(): Double? = carriedSpeed.also { carriedSpeed = null }

    override fun openPlayerPage(request: OpenPlayerRequest) {
        pending = request
        carriedSpeed = null
        appContext.startActivity(
            Intent(appContext, NativePlayerActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    override fun provideSource(payload: SourcePayload) { controller?.onSource(payload) }
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
