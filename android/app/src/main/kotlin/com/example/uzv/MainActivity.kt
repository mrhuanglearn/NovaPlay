package com.example.uzv

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.example.uzv.native_player.NativePlayerHost
import com.example.uzv.native_player.media.PlaybackNotificationService
import com.example.uzv.node.NodeBridgePlugin

/**
 * OBSERVED behaviour of the shipped MainActivity.onCreate:
 *  - if this is not the task root and was launched from the launcher (MAIN + LAUNCHER) it finishes itself
 *    (prevents a second instance on top of a running one),
 *  - from API 27 on it draws behind the system bars (transparent status bar, layout-stable fullscreen flags).
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val launchedFromLauncher = intent?.hasCategory(Intent.CATEGORY_LAUNCHER) == true &&
            intent?.action == Intent.ACTION_MAIN
        if (!isTaskRoot && launchedFromLauncher) {
            finish()
            return
        }
        if (Build.VERSION.SDK_INT >= 27) {
            window.addFlags(android.view.WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS)
            window.statusBarColor = 0
            window.decorView.systemUiVisibility =
                View.SYSTEM_UI_FLAG_LAYOUT_STABLE or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        NodeBridgePlugin.register(flutterEngine, applicationContext)
        NativePlayerHost.register(flutterEngine, applicationContext)
        // 重置应用 ends with "所有数据已清空，应用将退出，请重新打开。": the task and the whole process go (the embedded Node
        // runtime cannot start twice in one process). The playback service is START_NOT_STICKY and is stopped first anyway.
        // 触感反馈: the Flutter pages ask for a short vibration by kind (see Haptics and lib/core/haptics.dart)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uzv/haptics").setMethodCallHandler { call, result ->
            Haptics.play(applicationContext, call.method)
            result.success(null)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "uzv/app").setMethodCallHandler { call, result ->
            if (call.method != "exit") return@setMethodCallHandler result.notImplemented()
            result.success(null)
            stopService(Intent(this, PlaybackNotificationService::class.java))
            finishAndRemoveTask()
            Handler(Looper.getMainLooper()).postDelayed({ Process.killProcess(Process.myPid()) }, 300)
        }
    }
}
