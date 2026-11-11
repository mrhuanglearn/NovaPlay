package com.example.uzv

import android.content.Context
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * 触感反馈 (功能设置). OBSERVED (UZN on the phone, 2026-11-11): the original vibrates through the `gaimon` plugin
 * (`HapticUtils gaimon error:` in its Dart code, com.dimitridessus.gaimon.GaimonPlugin in its dex), i.e. it drives the
 * Vibrator itself with a predefined effect under USAGE_TOUCH; `dumpsys vibrator_manager` showed
 * `Prebaked{effect=HEAVY_CLICK}` from com.example.uzn for each bottom-tab tap. UZV used View.performHapticFeedback in
 * the player only, so nothing vibrated in the Flutter pages. This is the same call path as gaimon's, for both the
 * Flutter pages (channel `uzv/haptics`, see MainActivity) and the native player.
 */
object Haptics {
    const val SELECTION = "selection"
    const val LIGHT = "light"
    const val MEDIUM = "medium"
    const val HEAVY = "heavy"

    private fun vibrator(context: Context): Vibrator? = when {
        Build.VERSION.SDK_INT >= 31 -> context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        else -> @Suppress("DEPRECATION") (context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator)
    }

    /** The effect of each kind, as gaimon maps them where the device has no composition primitives. */
    fun effectId(kind: String): Int = when (kind) {
        HEAVY -> 5 // VibrationEffect.EFFECT_HEAVY_CLICK
        MEDIUM -> 0 // EFFECT_CLICK
        else -> 2 // EFFECT_TICK
    }

    fun play(context: Context, kind: String) {
        val v = vibrator(context) ?: return
        if (Build.VERSION.SDK_INT < 26 || !v.hasVibrator()) return
        try {
            val effect = when {
                kind == SELECTION -> VibrationEffect.createOneShot(5, VibrationEffect.DEFAULT_AMPLITUDE)
                Build.VERSION.SDK_INT >= 29 -> VibrationEffect.createPredefined(effectId(kind))
                else -> VibrationEffect.createOneShot(if (kind == HEAVY) 40 else 20, VibrationEffect.DEFAULT_AMPLITUDE)
            }
            if (Build.VERSION.SDK_INT >= 33) v.vibrate(effect, VibrationAttributes.createForUsage(VibrationAttributes.USAGE_TOUCH))
            else v.vibrate(effect)
        } catch (e: RuntimeException) {
            // no vibration is not worth a crash
        }
    }
}
