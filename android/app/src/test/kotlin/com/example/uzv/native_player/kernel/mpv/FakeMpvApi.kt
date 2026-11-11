package com.example.uzv.native_player.kernel.mpv

/** A scripted libmpv: records every call in order and answers property reads from maps. */
class FakeMpvApi : MpvApi {
    val calls = mutableListOf<String>()
    val strings = mutableMapOf<String, String>()
    val numbers = mutableMapOf<String, Double>()
    val events = java.util.concurrent.ConcurrentLinkedDeque<IntArray>() // the event thread test reads it concurrently
    val rejectedProperties = mutableSetOf<String>()
    val rejectedCommands = mutableSetOf<String>() // by first argument
    val rejectedTargets = mutableSetOf<String>() // by second argument (a url)
    var createResult = 1L
    var initializeResult = 0
    var logText = ""
    var renderCreateResult = 77L

    override fun create(): Long = createResult.also { calls += "create" }
    override fun initialize(handle: Long): Int = initializeResult.also { calls += "initialize" }
    override fun destroy(handle: Long) { calls += "destroy" }
    override fun command(handle: Long, args: Array<String>): Int {
        calls += "cmd:" + args.joinToString("|")
        return if (args[0] in rejectedCommands || args.getOrNull(1) in rejectedTargets) -12 else 0
    }

    override fun setProperty(handle: Long, name: String, format: Int, value: Double): Int {
        calls += "setp:$name=$format:$value"
        numbers[name] = value
        return 0
    }

    override fun setPropertyString(handle: Long, name: String, value: String): Int {
        calls += "set:$name=$value"
        if (name in rejectedProperties) return -5
        strings[name] = value
        return 0
    }

    override fun getProperty(handle: Long, name: String, format: Int): Double = numbers[name] ?: Double.NaN
    override fun getPropertyString(handle: Long, name: String): String? = strings[name]
    override fun observeProperty(handle: Long, userData: Long, name: String, format: Int): Int {
        calls += "observe:$userData:$name:$format"
        return 0
    }

    override fun waitEvent(handle: Long, timeoutSeconds: Double): IntArray = events.pollFirst() ?: intArrayOf(0, 0, 0, 0)
    override fun wakeup(handle: Long) { calls += "wakeup" }
    override fun errorString(code: Int): String = "err$code"
    override fun requestLogMessages(handle: Long, minLevel: String): Int {
        calls += "log:$minLevel"
        return 0
    }

    override fun lastLogMessages(): String = logText
    override fun renderContextCreate(handle: Long): Long = renderCreateResult.also { calls += "rcreate" }
    override fun renderContextFree(renderContext: Long) { calls += "rfree:$renderContext" }
    override fun render(renderContext: Long, width: Int, height: Int) { calls += "render:$renderContext:${width}x$height" }

    /** Publishes [tracks] the way mpv's `track-list/N/...` properties do. */
    fun setTracks(vararg tracks: MpvTrack) {
        strings.keys.removeAll { it.startsWith("track-list/") }
        strings["track-list/count"] = tracks.size.toString()
        tracks.forEachIndexed { i, t ->
            val p = "track-list/$i/"
            strings[p + "id"] = t.id.toString()
            strings[p + "type"] = t.type
            t.lang?.let { strings[p + "lang"] = it }
            t.title?.let { strings[p + "title"] = it }
            strings[p + "selected"] = if (t.selected) "yes" else "no"
            strings[p + "default"] = if (t.isDefault) "yes" else "no"
            strings[p + "external"] = if (t.external) "yes" else "no"
            if (t.channels > 0) strings[p + "demux-channel-count"] = t.channels.toString()
        }
    }

    fun event(id: Int, error: Int = 0, userData: Int = 0, extra: Int = 0) { events.addLast(intArrayOf(id, error, userData, extra)) }
    fun property(userData: Int, format: Int = MpvFormat.DOUBLE) = event(MpvEvent.PROPERTY_CHANGE, userData = userData, extra = format)
}
