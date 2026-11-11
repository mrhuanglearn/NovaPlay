package com.example.uzv.native_player.kernel.mdk

import android.view.Surface
import java.util.concurrent.ConcurrentHashMap

/**
 * JNI surface of libuzv_mdk.so (src/main/cpp/uzv_mdk.c), this project's glue over MDK's C API.
 *
 * libmdk.so (and the libffmpeg.so / libass.so it opens) is only shipped in the arm64-v8a build, taken from UZN 1.1.7
 * on the user's phone (the only build of the original that has MDK); on other ABIs [isAvailable] is false and the
 * page falls back to Exo with the reason.
 */
object MdkNative {
    /** libmdk.so is loaded first so its own JNI_OnLoad receives the VM (MediaCodec needs it); the glue then dlopen()s it. */
    private val loadError: String? = try {
        System.loadLibrary("mdk")
        System.loadLibrary("uzv_mdk")
        null
    } catch (e: UnsatisfiedLinkError) {
        e.message ?: "libmdk.so / libuzv_mdk.so could not be loaded"
    }

    @JvmStatic external fun probeError(): String?
    @JvmStatic external fun version(): Int
    @JvmStatic external fun create(id: Long, hwDecode: Boolean): Long
    @JvmStatic external fun destroy(handle: Long)

    /** [type] -1 = the main media, 1 = an external audio track, 3 = an external subtitle file. */
    @JvmStatic external fun setMedia(handle: Long, url: String, type: Int)
    @JvmStatic external fun setProperty(handle: Long, key: String, value: String)
    @JvmStatic external fun getProperty(handle: Long, key: String): String?
    @JvmStatic external fun prepare(handle: Long, startMs: Long)

    /** 0 stopped, 1 playing, 2 paused. */
    @JvmStatic external fun setState(handle: Long, state: Int)
    @JvmStatic external fun state(handle: Long): Int
    @JvmStatic external fun mediaStatus(handle: Long): Int
    @JvmStatic external fun position(handle: Long): Long
    @JvmStatic external fun duration(handle: Long): Long
    @JvmStatic external fun buffered(handle: Long): Long
    @JvmStatic external fun seek(handle: Long, ms: Long): Boolean
    @JvmStatic external fun setPlaybackRate(handle: Long, rate: Float)
    @JvmStatic external fun setAspectRatio(handle: Long, value: Float)
    @JvmStatic external fun setSurface(handle: Long, surface: Surface?, width: Int, height: Int)
    @JvmStatic external fun setActiveTracks(handle: Long, type: Int, tracks: IntArray)
    @JvmStatic external fun videoInfo(handle: Long): DoubleArray?
    @JvmStatic external fun videoCodec(handle: Long): String?
    @JvmStatic external fun tracks(handle: Long, type: Int): Array<String>

    fun interface Listener {
        /** From an MDK thread. kind 1 = state (a), 2 = media status (a new, b old), 3 = event (a error, text category\tdetail). */
        fun onEvent(kind: Int, a: Int, b: Int, text: String?)
    }

    private val listeners = ConcurrentHashMap<Long, Listener>()

    fun register(id: Long, listener: Listener) { listeners[id] = listener }
    fun unregister(id: Long) { listeners.remove(id) }

    @JvmStatic
    fun onMdkEvent(id: Long, kind: Int, a: Int, b: Int, text: String?) {
        listeners[id]?.onEvent(kind, a, b, text)
    }

    fun isAvailable(): Boolean = loadError == null && runCatching { probeError() == null }.getOrDefault(false)

    fun unavailableReason(): String = loadError?.let { "libmdk.so / libuzv_mdk.so could not be loaded (${it.substringBefore('\n')})" }
        ?: runCatching { probeError() }.getOrElse { it.message } ?: ""
}
