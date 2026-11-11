package com.example.uzv.node

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * Dart <-> Node bridge (this transport is this project's own design, see node_host/src/bridge_tcp.js). First run against a real
 * Node on 2026-11-08 (Waydroid, arm32 build with the original's libnode.so).
 *
 * MethodChannel "uzv/node":  start() / send(channel, message)
 * EventChannel  "uzv/node/events": {channel, message} maps for everything Node sends.
 *
 * Node can be started only once per process (node::Start is not re-entrant; a second call aborts the whole process, seen on
 * 2026-11-09 after the double-back exit closed the activity but kept the process, and the app was opened again). So the
 * runtime and its socket live in [NodeHost], one per process, and each Flutter engine only attaches to it.
 */
class NodeBridgePlugin private constructor(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> try {
                NodeHost.attach(this)
                NodeHost.start(context)
                result.success(null)
            } catch (t: Throwable) {
                result.error("node_start_failed", t.message ?: t.javaClass.simpleName, null)
            }
            "send" -> {
                val channel = call.argument<String>("channel")!!
                val message = call.argument<String>("message")!!
                val line = JSONObject().put("c", channel).put("m", message).toString() + "\n"
                NodeHost.send(line) { failure ->
                    main.post { if (failure == null) result.success(null) else result.error(failure.first, failure.second, null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    /** Called by [NodeHost] on any thread. */
    internal fun deliver(event: Map<String, String>) {
        main.post { sink?.success(event) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        NodeHost.attach(this)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        NodeHost.detach(this)
    }

    companion object {
        fun register(engine: FlutterEngine, context: Context) {
            val plugin = NodeBridgePlugin(context.applicationContext)
            MethodChannel(engine.dartExecutor.binaryMessenger, "uzv/node").setMethodCallHandler(plugin)
            EventChannel(engine.dartExecutor.binaryMessenger, "uzv/node/events").setStreamHandler(plugin)
        }
    }
}

/** The process-wide Node runtime and its loopback connection. Events go to the engine that attached last. */
internal object NodeHost {
    private var listener: NodeBridgePlugin? = null
    private var writer: OutputStreamWriter? = null
    private var started = false
    private var firstFailure: String? = null

    /** The last "Node ready …" status line, replayed to an engine that attaches to an already running runtime. */
    private var readyLine: String? = null
    private val token = ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }

    /** Socket writes must not run on the main thread (NetworkOnMainThreadException); one thread keeps messages in order. */
    private val sender = Executors.newSingleThreadExecutor { r -> Thread(r, "uzv-node-send").apply { isDaemon = true } }

    @Synchronized
    fun attach(plugin: NodeBridgePlugin) {
        listener = plugin
    }

    @Synchronized
    fun detach(plugin: NodeBridgePlugin) {
        if (listener === plugin) listener = null
    }

    private fun emit(channel: String, message: String) {
        val target = synchronized(this) { listener }
        target?.deliver(mapOf("channel" to channel, "message" to message))
    }

    private fun emitStatus(line: String) = emit("status", line)

    @Synchronized
    fun start(context: Context) {
        if (started) {
            // Already running for an earlier engine of this process: tell the new one it is ready (if it is).
            readyLine?.let { line -> thread(name = "uzv-node-replay") { emitStatus(line) } }
            return
        }
        started = true
        readyLine = null
        val project = NodeAssets.install(context) // copies assets/nodejs -> filesDir/nodejs-project
        val srv = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        thread(name = "uzv-node-bridge") { acceptLoop(srv) }
        thread(name = "uzv-node-main") {
            val dataDir = File(context.filesDir, "node-data").apply { mkdirs() }.absolutePath
            // UnsatisfiedLinkError (libnode.so / libc++_shared.so missing from the APK) is an Error, not an Exception: left uncaught
            // on this thread it kills the whole app. Report it on the status channel instead; Dart turns it into a visible error.
            val code = try {
                NodeRuntime.start(
                    // The configuration goes in the arguments as well as the environment: on Waydroid (translated ARM code)
                    // the variables set from Java were not visible to Node.
                    arrayOf(
                        "node", File(project, "src/main.js").absolutePath,
                        "--bridge-port=${srv.localPort}", "--bridge-token=$token", "--data-dir=$dataDir",
                    ),
                    env = mapOf(
                        "UZV_BRIDGE_PORT" to srv.localPort.toString(),
                        "UZV_BRIDGE_TOKEN" to token,
                        "UZV_DATA_DIR" to dataDir,
                    ),
                )
            } catch (t: Throwable) {
                // Let a later "Retry" start over (it fails again at once if the library is really missing) instead of waiting for a runtime
                // that will never answer. Only a runtime that never ran may be started again.
                synchronized(this) { started = false }
                runCatching { srv.close() }
                // A failed class initialisation (the System.loadLibrary calls in NodeRuntime) makes every later attempt throw a bare
                // NoClassDefFoundError; keep saying why the first one failed.
                val reason = if (t is NoClassDefFoundError && firstFailure != null) firstFailure else t.message ?: t.javaClass.simpleName
                if (firstFailure == null) firstFailure = reason
                emitStatus("Node runtime failed: $reason")
                return@thread
            }
            // Node ran and ended; it cannot be started again in this process, so `started` stays true.
            synchronized(this) { readyLine = null }
            emitStatus("Node runtime exited with code $code")
        }
    }

    fun send(line: String, done: (Pair<String, String>?) -> Unit) {
        sender.execute {
            val failure: Pair<String, String>? = try {
                synchronized(this) {
                    val w = writer
                    if (w == null) {
                        "not_connected" to "Node runtime is not connected"
                    } else {
                        w.write(line)
                        w.flush()
                        null
                    }
                }
            } catch (e: Exception) {
                "send_failed" to (e.message ?: e.javaClass.simpleName)
            }
            done(failure)
        }
    }

    private fun acceptLoop(srv: ServerSocket) {
        // This thread must never let an exception escape: on Android that ends the whole app. Closing the server socket
        // (a failed Node start) makes accept() throw, and a garbled line from the other side makes the JSON parser throw.
        var socket: Socket? = null
        try {
            socket = srv.accept()
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
            val hello = JSONObject(reader.readLine() ?: return)
            if (hello.optString("hello") != token) { socket.close(); return } // reject foreign local processes
            synchronized(this) { writer = OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8) }
            while (true) {
                val line = reader.readLine() ?: break
                val frame = JSONObject(line)
                val channel = frame.getString("c")
                val message = frame.getString("m")
                if (channel == "status" && message.startsWith("Node ready")) synchronized(this) { readyLine = message }
                emit(channel, message)
            }
        } catch (e: Exception) {
            if (!srv.isClosed) emitStatus("Node bridge failed: ${e.message ?: e.javaClass.simpleName}")
        } finally {
            synchronized(this) { writer = null; readyLine = null }
            runCatching { socket?.close() }
        }
    }
}
