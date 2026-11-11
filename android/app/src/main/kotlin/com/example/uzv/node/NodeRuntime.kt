package com.example.uzv.node

import android.content.Context
import java.io.File

/**
 * JNI entry into the embedded Node.js runtime (src/main/cpp/uzv_node.c).
 *
 * OBSERVED: the APK ships libnode.so (46 MB, exports node::Start) and libflutter_nodejs_mobile.so (17 KB) and the Node project
 * under assets/flutter_assets/nodejs/. The latter has NO JNI exports: it is a Dart-FFI library (flutter_node_start,
 * flutter_register_bridge_cb, ...). This project's bridge is a loopback socket instead, so only libnode.so (+ libc++_shared.so)
 * is needed at run time; libuzv_node.so, built from uzv_node.c, calls node::Start and forwards Node's output to logcat (tag NODEJS).
 */
object NodeRuntime {
    init {
        System.loadLibrary("c++_shared")
        System.loadLibrary("node")
        System.loadLibrary("uzv_node")
    }

    @JvmStatic
    private external fun startNodeWithArguments(args: Array<String>, nodePath: String?, redirectOutputToLogcat: Boolean): Int

    /** Blocks the calling thread until Node exits. Environment variables are applied before start. */
    fun start(args: Array<String>, env: Map<String, String>): Int {
        env.forEach { (k, v) -> android.system.Os.setenv(k, v, true) }
        return startNodeWithArguments(args, null, true)
    }
}

/** Copies the bundled Node project out of the APK (Node cannot read from compressed assets). */
object NodeAssets {
    fun install(context: Context): File {
        val target = File(context.filesDir, "nodejs-project")
        val stamp = File(target, ".version")
        // lastUpdateTime is part of the stamp: versionName+versionCode stay the same between development builds, and a stale copy of the
        // Node project (observed: an old main.js kept running after a reinstall) is worse than copying a few small files again.
        val version = context.packageManager.getPackageInfo(context.packageName, 0).let {
            @Suppress("DEPRECATION") "${it.versionName}+${it.versionCode}+${it.lastUpdateTime}"
        }
        if (stamp.exists() && stamp.readText() == version) return target
        target.deleteRecursively()
        copyDir(context, "flutter_assets/assets/nodejs", target)
        stamp.writeText(version)
        return target
    }

    private fun copyDir(context: Context, assetDir: String, to: File) {
        to.mkdirs()
        for (name in context.assets.list(assetDir).orEmpty()) {
            val child = "$assetDir/$name"
            if (context.assets.list(child).isNullOrEmpty()) {
                context.assets.open(child).use { input -> File(to, name).outputStream().use { input.copyTo(it) } }
            } else {
                copyDir(context, child, File(to, name))
            }
        }
    }
}
