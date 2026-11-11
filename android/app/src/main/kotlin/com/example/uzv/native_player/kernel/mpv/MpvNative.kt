package com.example.uzv.native_player.kernel.mpv

/**
 * JNI surface of the libmpv wrapper (libuzv_mpv.so, src/main/cpp/uzv_mpv.c).
 *
 * OBSERVED (class com.example.uzn.native_player.kernel.mpv.MpvNative in the original APK): these methods with exactly
 * these descriptors, plus a static onMpvRenderUpdate()V that the native code calls from mpv's render thread. The C side
 * here is this project's own implementation of that surface; the original wrapper library was only studied for its
 * design (dlopen of libmpv.so, "opengl" render API, "[prefix] text" log format).
 *
 * Project-defined contract (not observable in the original):
 *  - [waitEvent] returns `[eventId, error, userData, extra]`, see uzv_mpv.c. Property values are not carried in the
 *    event; read them back with [getProperty] / [getPropertyString].
 *  - [getProperty] returns NaN for an unavailable property or an unsupported format.
 *  - Strings cross the boundary as real UTF-8, so supplementary characters (emoji) survive.
 *
 * native_tests/mpv_glue/run.sh loads this exact JNI surface (through a Java twin whose descriptors are compared with
 * the compiled class of this file) against a stub libmpv.
 */
object MpvNative {
    /** False when libuzv_mpv.so itself could not be loaded (wrong ABI, stripped build); every external call would throw then. */
    @JvmField
    val libraryLoaded: Boolean = try {
        System.loadLibrary("uzv_mpv")
        true
    } catch (_: UnsatisfiedLinkError) {
        false
    }

    external fun create(): Long
    external fun initialize(handle: Long): Int
    external fun destroy(handle: Long)
    external fun command(handle: Long, args: Array<String>): Int
    external fun setProperty(handle: Long, name: String, format: Int, value: Double): Int
    external fun setPropertyString(handle: Long, name: String, value: String): Int
    external fun getProperty(handle: Long, name: String, format: Int): Double
    external fun getPropertyString(handle: Long, name: String): String?
    external fun observeProperty(handle: Long, userData: Long, name: String, format: Int): Int
    external fun waitEvent(handle: Long, timeoutSeconds: Double): IntArray
    external fun wakeup(handle: Long)
    external fun errorString(code: Int): String
    external fun requestLogMessages(handle: Long, minLevel: String): Int
    external fun getLastLogMessages(): String
    external fun clearLogMessages()
    external fun renderContextCreate(handle: Long): Long
    external fun renderContextFree(renderContext: Long)
    external fun render(renderContext: Long, width: Int, height: Int)
    external fun probe(): Boolean
    external fun probeDetail(): String

    @Volatile
    private var renderUpdateListener: (() -> Unit)? = null

    /**
     * Called by the native code from an mpv thread whenever a new frame is ready (OBSERVED: a static Kotlin method that
     * the C++ glue invokes by name). It must stay cheap and must not call into mpv.
     */
    @JvmStatic
    fun onMpvRenderUpdate() {
        renderUpdateListener?.invoke()
    }

    fun setRenderUpdateListener(listener: (() -> Unit)?) {
        renderUpdateListener = listener
    }

    /** True when libuzv_mpv.so loaded and libmpv.so (with every symbol the glue needs) could be dlopen()ed. */
    fun isAvailable(): Boolean = libraryLoaded && runCatching { probe() }.getOrDefault(false)

    /** Why [isAvailable] is false, for the notice shown when the player falls back to Exo. */
    fun unavailableReason(): String =
        if (!libraryLoaded) "libuzv_mpv.so could not be loaded" else runCatching { probeDetail() }.getOrElse { it.message ?: "probe failed" }
}
