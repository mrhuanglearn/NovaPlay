package com.example.uzv.native_player

import android.app.Activity
import android.content.ContentValues
import android.graphics.Bitmap
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import com.example.uzv.native_player.kernel.PlayerKernel
import com.example.uzv.native_player.ui.PlayerUiText
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

internal object PlayerScreenshotSaver {
    private fun findSurface(view: View): View? = when (view) {
        is SurfaceView, is TextureView -> view
        is ViewGroup -> (0 until view.childCount).firstNotNullOfOrNull { findSurface(view.getChildAt(it)) }
        else -> null
    }

    fun captureAndSave(activity: Activity, kernel: PlayerKernel, onToast: (String) -> Unit) {
        val failed = PlayerUiText.t("截图失败", "Screenshot failed")
        val surface = findSurface(kernel.view)
        if (surface == null || surface.width <= 0 || surface.height <= 0) {
            onToast(failed)
            return
        }
        when (surface) {
            is TextureView -> surface.bitmap?.let { saveBitmap(activity, it, onToast) } ?: onToast(failed)
            is SurfaceView -> {
                val bitmap = Bitmap.createBitmap(surface.width, surface.height, Bitmap.Config.ARGB_8888)
                try {
                    PixelCopy.request(
                        surface,
                        bitmap,
                        { result -> if (result == PixelCopy.SUCCESS) saveBitmap(activity, bitmap, onToast) else onToast(failed) },
                        Handler(Looper.getMainLooper()),
                    )
                } catch (_: IllegalArgumentException) {
                    onToast(failed)
                }
            }
        }
    }

    private fun saveBitmap(activity: Activity, bitmap: Bitmap, onToast: (String) -> Unit) {
        val name = "NovaPlay_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.ROOT).format(Date()) + ".jpg"
        Thread {
            val ok = try {
                if (Build.VERSION.SDK_INT >= 29) {
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, name)
                        put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                        put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/NovaPlay")
                    }
                    val uri = activity.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
                    activity.contentResolver.openOutputStream(uri)!!.use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
                } else {
                    val dir = File(activity.getExternalFilesDir(Environment.DIRECTORY_PICTURES), "NovaPlay").apply { mkdirs() }
                    File(dir, name).outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
                }
                true
            } catch (_: Exception) {
                false
            }
            activity.runOnUiThread {
                onToast(if (ok) PlayerUiText.t("截图已保存到相册", "Screenshot saved") else PlayerUiText.t("截图失败", "Screenshot failed"))
            }
        }.start()
    }
}
