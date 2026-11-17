package com.example.uzv.native_player.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.util.TypedValue
import android.view.Choreographer
import android.view.View
import com.example.uzv.native_player.DanmakuConfig
import com.example.uzv.native_player.kernel.PlayerKernel
import kotlin.math.ceil

internal object DanmakuTimeline {
    /**
     * Returns the repositioned comment cursor after a backward (< -1.5s) or forward (> +2.5s) seek, or null during
     * continuous playback so normal frame-by-frame advancement proceeds without skipping or spraying comments.
     */
    fun seekTargetCursor(timesMs: LongArray, lastPosMs: Long, posMs: Long, nowMs: Long): Int? {
        if (posMs >= lastPosMs - 1_500L && posMs <= lastPosMs + 2_500L) return null
        var lo = 0
        var hi = timesMs.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            if (timesMs[mid] < nowMs) lo = mid + 1 else hi = mid
        }
        return lo
    }

    fun shouldScheduleVsync(
        attached: Boolean,
        paused: Boolean,
        enabled: Boolean,
        activeCount: Int,
        hasUpcoming: Boolean,
    ): Boolean = attached && !paused && enabled && (activeCount > 0 || hasUpcoming)

    fun idleWaitMs(activeCount: Int, nextCommentMs: Long, nowMs: Long): Long {
        if (activeCount > 0) return 0L
        val gap = nextCommentMs - nowMs
        return if (gap <= 200L) 0L else (gap - 120L).coerceAtMost(500L)
    }
}

/**
 * Danmaku renderer matching original UZN (d2.m / d2.b): scrolling comments in lanes + fixed top/bottom comments,
 * 5 color modes (random_Mix, white, original, gradient, random), 8 gradient styles, and font weight (0..8).
 *
 * Performance invariants:
 *  - Zero vsync callbacks / redraws when paused, disabled, or after the last comment has exited.
 *  - Sleeps up to 500ms between ticks when no comments are on screen and the next comment is still ahead.
 *  - Unit [LinearGradient] shaders are allocated once and scaled via [Matrix]; each active comment pre-renders its
 *    stroke + fill once into a cached [Bitmap] so 120Hz [onDraw] executes a single `drawBitmap` per active comment.
 */
class DanmakuView(context: Context) : View(context), Choreographer.FrameCallback {
    data class Comment(val time: Double, val mode: Int, val color: Int, val text: String)

    private var comments: List<Comment> = emptyList()
    private var commentTimesMs: LongArray = LongArray(0)
    val commentCount: Int get() = comments.size
    private var cfg: DanmakuConfig? = null
    private var kernel: PlayerKernel? = null

    var paused: Boolean = true
        set(v) {
            if (field == v) return
            field = v
            ensureTicking()
        }

    private class Active(
        val c: Comment,
        val lane: Int,
        var width: Float,
        val bornMs: Long,
        var bitmap: Bitmap? = null,
        var pad: Float = 0f,
        var baselineOffset: Float = 0f,
        var renderedStamp: Int = -1,
    ) {
        fun release() {
            bitmap?.recycle()
            bitmap = null
        }
    }

    private val active = ArrayList<Active>()
    private var cursor = 0
    private var lastPos = 0L
    private var lastFontWeight = -1
    private var styleStamp = 0
    private var callbackScheduled = false
    private val wakeRunnable = Runnable { ensureTicking() }

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
        color = Color.BLACK
    }
    private val bitmapPaint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val bitmapCanvas = Canvas()
    private val shaderMatrix = Matrix()
    private val unitGradients: Array<LinearGradient> = Array(PlayerUiText.danmakuGradientColors.size) { i ->
        val pair = PlayerUiText.danmakuGradientColors[i]
        LinearGradient(0f, 0f, 1f, 0f, pair[0], pair[1], Shader.TileMode.CLAMP)
    }

    private fun clearActive() {
        for (a in active) a.release()
        active.clear()
    }

    private fun spToPx(sp: Float): Float =
        TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sp, resources.displayMetrics)

    fun attach(kernel: PlayerKernel) {
        this.kernel = kernel
        paused = !kernel.isPlaying
        ensureTicking()
    }

    fun configure(c: DanmakuConfig) {
        val prev = cfg
        cfg = c
        if (prev == null ||
            prev.fontSize != c.fontSize ||
            prev.strokeWidth != c.strokeWidth ||
            prev.colorMode != c.colorMode ||
            prev.gradientStyle != c.gradientStyle
        ) {
            styleStamp++
        }
        if (!c.enabled && active.isNotEmpty()) clearActive()
        postInvalidate()
        ensureTicking()
    }

    fun setComments(list: List<Comment>) {
        val sorted = list.sortedBy { it.time }
        comments = sorted
        commentTimesMs = LongArray(sorted.size) { (sorted[it].time * 1000.0).toLong() }
        cursor = 0
        clearActive()
        postInvalidate()
        ensureTicking()
    }

    fun onSeek() {
        removeCallbacks(wakeRunnable)
        if (isAttachedToWindow && cfg?.enabled == true) {
            scheduleFrame()
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        ensureTicking()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(wakeRunnable)
        if (callbackScheduled) {
            Choreographer.getInstance().removeFrameCallback(this)
            callbackScheduled = false
        }
        for (a in active) a.release()
        super.onDetachedFromWindow()
    }

    private fun scheduleFrame() {
        if (!callbackScheduled && isAttachedToWindow) {
            callbackScheduled = true
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    private fun ensureTicking() {
        removeCallbacks(wakeRunnable)
        val enabled = cfg?.enabled == true
        val want = DanmakuTimeline.shouldScheduleVsync(
            attached = isAttachedToWindow && kernel != null,
            paused = paused,
            enabled = enabled,
            activeCount = active.size,
            hasUpcoming = cursor < comments.size,
        )
        if (want) {
            scheduleFrame()
        } else if (callbackScheduled) {
            Choreographer.getInstance().removeFrameCallback(this)
            callbackScheduled = false
        }
    }

    private fun applyTypeface(weight: Int) {
        if (weight == lastFontWeight) return
        lastFontWeight = weight
        val tf = if (Build.VERSION.SDK_INT >= 28) {
            Typeface.create(Typeface.DEFAULT, ((weight.coerceIn(0, 8) + 1) * 100).coerceIn(100, 900), false)
        } else {
            if (weight >= 5) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        }
        fill.typeface = tf
        stroke.typeface = tf
    }

    override fun doFrame(frameTimeNanos: Long) {
        callbackScheduled = false
        val k = kernel ?: return
        val config = cfg
        if (config == null || !config.enabled) return
        val pos = k.positionMs
        val now = pos - (config.delaySeconds * 1000).toLong()
        val hadActive = active.isNotEmpty()

        DanmakuTimeline.seekTargetCursor(commentTimesMs, lastPos, pos, now)?.let { target ->
            cursor = target
            clearActive()
        }
        lastPos = pos

        val travelMs = (8000 / config.scrollSpeed.coerceIn(0.3, 2.0)).toLong()
        val it = active.iterator()
        while (it.hasNext()) {
            val a = it.next()
            val life = if (a.c.mode == 1) travelMs else 4000L
            if (now - a.bornMs > life) {
                a.release()
                it.remove()
            }
        }

        applyTypeface(PlayerUiText.parseFontWeight(config.gradientStyle))
        val textPx = spToPx(config.fontSize.toFloat())
        fill.textSize = textPx

        while (cursor < comments.size && commentTimesMs[cursor] <= now) {
            val raw = comments[cursor++]
            if (raw.text.isEmpty()) continue
            if (config.blackList.any { it.isNotEmpty() && raw.text.contains(it) }) continue
            // OBSERVED (显示顶部弹幕 / 显示底部弹幕): "关闭后该位置弹幕改为滚动显示" - they scroll instead of disappearing
            val c = if ((raw.mode == 5 && !config.showTop) || (raw.mode == 4 && !config.showBottom)) raw.copy(mode = 1) else raw
            val lanes = ((height * config.area) / (textPx * config.lineHeight)).toInt().coerceAtLeast(1)
            val lane = (0 until lanes).firstOrNull { l ->
                active.none { it.lane == l && it.c.mode == c.mode && now - it.bornMs < 3000 }
            } ?: continue
            val measured = fill.measureText(c.text)
            active += Active(c, lane, measured, now)
        }

        if (active.isNotEmpty() || hadActive) {
            invalidate()
        }

        if (!DanmakuTimeline.shouldScheduleVsync(isAttachedToWindow, paused, config.enabled, active.size, cursor < comments.size)) {
            return
        }
        val nextMs = if (cursor < commentTimesMs.size) commentTimesMs[cursor] else Long.MAX_VALUE
        val waitMs = DanmakuTimeline.idleWaitMs(active.size, nextMs, now)
        if (waitMs <= 0L) {
            scheduleFrame()
        } else {
            postDelayed(wakeRunnable, waitMs)
        }
    }

    private fun hashFor(c: Comment): Int = (c.text.hashCode() xor c.time.hashCode()) and 0x7fffffff

    /** 颜色模式: "random_Mix" (80% random + 20% gradient), "white", "original", "gradient", "random". */
    private fun applyFillColorOrShader(c: Comment, pad: Float, width: Float, config: DanmakuConfig) {
        val h = hashFor(c)
        val mode = config.colorMode
        val useGradient = mode == "gradient" || mode == "3" || ((mode == "random_Mix" || mode == "0") && h % 5 == 0)
        if (useGradient) {
            val preset = PlayerUiText.parseGradientPreset(config.gradientStyle)
            val idx = if (preset in unitGradients.indices) preset else h % unitGradients.size
            val shader = unitGradients[idx]
            shaderMatrix.setScale(width.coerceAtLeast(1f), 1f)
            shaderMatrix.postTranslate(pad, 0f)
            shader.setLocalMatrix(shaderMatrix)
            fill.color = Color.WHITE
            fill.shader = shader
            return
        }
        fill.shader = null
        fill.color = when (mode) {
            "white", "1" -> Color.WHITE
            "random", "random_Color", "4", "random_Mix", "0" -> RANDOM_COLORS[h % RANDOM_COLORS.size]
            else -> c.color or 0xFF000000.toInt()
        }
    }

    private fun ensureBitmap(a: Active, config: DanmakuConfig, textPx: Float) {
        if (a.bitmap != null && a.renderedStamp == styleStamp) return
        a.release()
        applyTypeface(PlayerUiText.parseFontWeight(config.gradientStyle))
        fill.textSize = textPx
        stroke.textSize = textPx
        val strokeW = config.strokeWidth.toFloat().coerceAtLeast(0f)
        stroke.strokeWidth = strokeW.coerceAtLeast(0.5f)
        fill.alpha = 255
        stroke.alpha = 255

        val textW = fill.measureText(a.c.text).coerceAtLeast(1f)
        a.width = textW
        val pad = ceil(strokeW + 2f)
        val fm = fill.fontMetrics
        val baseline = pad - fm.top
        val bmpW = ceil(textW + pad * 2f).toInt().coerceAtLeast(1).coerceAtMost(4096)
        val bmpH = ceil(fm.bottom - fm.top + pad * 2f).toInt().coerceAtLeast(1).coerceAtMost(512)

        val bmp = Bitmap.createBitmap(bmpW, bmpH, Bitmap.Config.ARGB_8888)
        bitmapCanvas.setBitmap(bmp)
        applyFillColorOrShader(a.c, pad, textW, config)
        if (config.strokeWidth > 0) bitmapCanvas.drawText(a.c.text, pad, baseline, stroke)
        bitmapCanvas.drawText(a.c.text, pad, baseline, fill)
        fill.shader = null
        bitmapCanvas.setBitmap(null)

        a.bitmap = bmp
        a.pad = pad
        a.baselineOffset = baseline
        a.renderedStamp = styleStamp
    }

    override fun onDraw(canvas: Canvas) {
        val config = cfg ?: return
        if (!config.enabled || active.isEmpty()) return
        val pos = (kernel?.positionMs ?: 0L) - (config.delaySeconds * 1000).toLong()
        val textPx = spToPx(config.fontSize.toFloat())
        val alpha = (config.opacity * 255).toInt().coerceIn(0, 255)
        bitmapPaint.alpha = alpha
        val lineH = textPx * config.lineHeight.toFloat()
        val travelMs = (8000 / config.scrollSpeed.coerceIn(0.3, 2.0)).toLong()
        val it = active.iterator()
        while (it.hasNext()) {
            val a = it.next()
            val age = pos - a.bornMs
            val life = if (a.c.mode == 1) travelMs else 4000L
            if (age < 0) continue
            if (age > life) {
                a.release()
                it.remove()
                continue
            }
            ensureBitmap(a, config, textPx)
            val bmp = a.bitmap ?: continue
            val x = if (a.c.mode == 1) width - (width + a.width) * (age.toFloat() / travelMs) else (width - a.width) / 2f
            val y = when (a.c.mode) {
                4 -> height - lineH * (a.lane + 1)
                else -> lineH * (a.lane + 1)
            }
            canvas.drawBitmap(bmp, x - a.pad, y - a.baselineOffset, bitmapPaint)
        }
    }

    private companion object {
        // Original UZN d2.b.f4349b 15-color palette
        val RANDOM_COLORS = intArrayOf(
            0xFFFF6B9D.toInt(), 0xFF70A1FF.toInt(), 0xFF7BED9F.toInt(), 0xFFFFA502.toInt(), 0xFFA29BFE.toInt(),
            0xFFFF7675.toInt(), 0xFF55EFC4.toInt(), 0xFFFD79A8.toInt(), 0xFF74B9FF.toInt(), 0xFFFFEAA7.toInt(),
            0xFFDFE6E9.toInt(), 0xFF81ECEC.toInt(), 0xFFFAB1A0.toInt(), 0xFFE17055.toInt(), 0xFF00CEC9.toInt(),
        )
    }
}
