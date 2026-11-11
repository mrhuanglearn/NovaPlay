package com.example.uzv.native_player.kernel.mpv

/** mpv_format values used by the glue (verified against mpv's client.h, see native_tests/mpv_glue). */
object MpvFormat {
    const val NONE = 0
    const val FLAG = 3
    const val INT64 = 4
    const val DOUBLE = 5
}

/** mpv_event_id values this player reacts to. */
object MpvEvent {
    const val NONE = 0
    const val SHUTDOWN = 1
    const val START_FILE = 6
    const val END_FILE = 7
    const val FILE_LOADED = 8
    const val SEEK = 20
    const val PLAYBACK_RESTART = 21
    const val PROPERTY_CHANGE = 22
}

/** mpv_end_file_reason, delivered as `extra` of an END_FILE event. */
object MpvEndReason {
    const val EOF = 0
    const val STOP = 2
    const val QUIT = 3
    const val ERROR = 4
    const val REDIRECT = 5
}

/**
 * Everything [MpvCore] needs from libmpv. [NativeMpvApi] forwards to the JNI object; the unit tests use a scripted fake,
 * which is how the state machine is tested without a device or libmpv.
 */
interface MpvApi {
    fun create(): Long
    fun initialize(handle: Long): Int
    fun destroy(handle: Long)
    fun command(handle: Long, args: Array<String>): Int
    fun setProperty(handle: Long, name: String, format: Int, value: Double): Int
    fun setPropertyString(handle: Long, name: String, value: String): Int
    fun getProperty(handle: Long, name: String, format: Int): Double
    fun getPropertyString(handle: Long, name: String): String?
    fun observeProperty(handle: Long, userData: Long, name: String, format: Int): Int

    /** `[eventId, error, userData, extra]`, see MpvNative. Blocks up to [timeoutSeconds]. */
    fun waitEvent(handle: Long, timeoutSeconds: Double): IntArray
    fun wakeup(handle: Long)
    fun errorString(code: Int): String
    fun requestLogMessages(handle: Long, minLevel: String): Int
    fun lastLogMessages(): String
    fun renderContextCreate(handle: Long): Long
    fun renderContextFree(renderContext: Long)
    fun render(renderContext: Long, width: Int, height: Int)
}

object NativeMpvApi : MpvApi {
    override fun create() = MpvNative.create()
    override fun initialize(handle: Long) = MpvNative.initialize(handle)
    override fun destroy(handle: Long) = MpvNative.destroy(handle)
    override fun command(handle: Long, args: Array<String>) = MpvNative.command(handle, args)
    override fun setProperty(handle: Long, name: String, format: Int, value: Double) = MpvNative.setProperty(handle, name, format, value)
    override fun setPropertyString(handle: Long, name: String, value: String) = MpvNative.setPropertyString(handle, name, value)
    override fun getProperty(handle: Long, name: String, format: Int) = MpvNative.getProperty(handle, name, format)
    override fun getPropertyString(handle: Long, name: String) = MpvNative.getPropertyString(handle, name)
    override fun observeProperty(handle: Long, userData: Long, name: String, format: Int) = MpvNative.observeProperty(handle, userData, name, format)
    override fun waitEvent(handle: Long, timeoutSeconds: Double) = MpvNative.waitEvent(handle, timeoutSeconds)
    override fun wakeup(handle: Long) = MpvNative.wakeup(handle)
    override fun errorString(code: Int) = MpvNative.errorString(code)
    override fun requestLogMessages(handle: Long, minLevel: String) = MpvNative.requestLogMessages(handle, minLevel)
    override fun lastLogMessages() = MpvNative.getLastLogMessages()
    override fun renderContextCreate(handle: Long) = MpvNative.renderContextCreate(handle)
    override fun renderContextFree(renderContext: Long) = MpvNative.renderContextFree(renderContext)
    override fun render(renderContext: Long, width: Int, height: Int) = MpvNative.render(renderContext, width, height)
}
