package com.example.uzv.native_player.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.view.Choreographer
import android.view.View
import com.example.uzv.native_player.DanmakuConfig
import com.example.uzv.native_player.kernel.PlayerKernel

/**
 * Danmaku renderer matching original UZN (d2.m / d2.b): scrolling comments in lanes + fixed top/bottom comments,
 * 5 color modes (random_Mix, white, original, gradient, random), 8 gradient styles, and font weight (0..8).
 */
class DanmakuView(context: Context) : View(context), Choreographer.FrameCallback {
    data class Comment(val time: Double, val mode: Int, val color: Int, val text: String)

    private var comments: List<Comment> = emptyList()
    val commentCount: Int get() = comments.size
    private var cfg: DanmakuConfig? = null
    private var kernel: PlayerKernel? = null
    var paused = false

    private class Active(val c: Comment, val lane: Int, val width: Float, val bornMs: Long)

    private val active = ArrayList<Active>()
    private var cursor = 0
    private var lastPos = 0L
    private var lastFontWeight = -1
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeJoin = Paint.Join.ROUND
        strokeCap = Paint.Cap.ROUND
        color = Color.BLACK
    }

    fun attach(kernel: PlayerKernel) { this.kernel = kernel; Choreographer.getInstance().postFrameCallback(this) }
    fun configure(c: DanmakuConfig) { cfg = c; postInvalidate() }
    fun setComments(list: List<Comment>) { comments = list.sortedBy { it.time }; cursor = 0; active.clear(); postInvalidate() }

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
        if (isAttachedToWindow) Choreographer.getInstance().postFrameCallback(this)
        val k = kernel ?: return
        val pos = k.positionMs
        if (pos < lastPos - 1500) { cursor = comments.indexOfFirst { it.time * 1000 >= pos }.let { if (it < 0) comments.size else it }; active.clear() }
        lastPos = pos
        val config = cfg ?: return
        if (!config.enabled) return
        applyTypeface(PlayerUiText.parseFontWeight(config.gradientStyle))
        val now = pos - (config.delaySeconds * 1000).toLong()
        while (cursor < comments.size && comments[cursor].time * 1000 <= now) {
            val raw = comments[cursor++]
            if (config.blackList.any { it.isNotEmpty() && raw.text.contains(it) }) continue
            // OBSERVED (显示顶部弹幕 / 显示底部弹幕): "关闭后该位置弹幕改为滚动显示" - they scroll instead of disappearing
            val c = if ((raw.mode == 5 && !config.showTop) || (raw.mode == 4 && !config.showBottom)) raw.copy(mode = 1) else raw
            fill.textSize = config.fontSize.toFloat() * resources.displayMetrics.scaledDensity
            val lanes = ((height * config.area) / (fill.textSize * config.lineHeight)).toInt().coerceAtLeast(1)
            val lane = (0 until lanes).firstOrNull { l -> active.none { it.lane == l && it.c.mode == c.mode && now - it.bornMs < 3000 } } ?: continue
            active += Active(c, lane, fill.measureText(c.text), now)
        }
        invalidate()
    }

    private fun hashFor(c: Comment): Int = (c.text.hashCode() xor c.time.hashCode()) and 0x7fffffff

    /** 颜色模式: "random_Mix" (80% random + 20% gradient), "white", "original", "gradient", "random". */
    private fun applyFillColorOrShader(c: Comment, x: Float, width: Float, config: DanmakuConfig) {
        val h = hashFor(c)
        val mode = config.colorMode
        val useGradient = mode == "gradient" || mode == "3" || ((mode == "random_Mix" || mode == "0") && h % 5 == 0)
        if (useGradient) {
            val preset = PlayerUiText.parseGradientPreset(config.gradientStyle)
            val pair = PlayerUiText.danmakuGradientColors[if (preset in 0..7) preset else h % PlayerUiText.danmakuGradientColors.size]
            fill.color = Color.WHITE
            fill.shader = LinearGradient(x, 0f, x + width.coerceAtLeast(1f), 0f, pair[0], pair[1], Shader.TileMode.CLAMP)
            return
        }
        fill.shader = null
        fill.color = when (mode) {
            "white", "1" -> Color.WHITE
            "random", "random_Color", "4", "random_Mix", "0" -> RANDOM_COLORS[h % RANDOM_COLORS.size]
            else -> c.color or 0xFF000000.toInt()
        }
    }

    override fun onDraw(canvas: Canvas) {
        val config = cfg ?: return
        if (!config.enabled) return
        applyTypeface(PlayerUiText.parseFontWeight(config.gradientStyle))
        val pos = (kernel?.positionMs ?: 0) - (config.delaySeconds * 1000).toLong()
        fill.textSize = config.fontSize.toFloat() * resources.displayMetrics.scaledDensity
        stroke.textSize = fill.textSize
        stroke.strokeWidth = config.strokeWidth.toFloat().coerceAtLeast(0.5f)
        val alpha = (config.opacity * 255).toInt().coerceIn(0, 255)
        val lineH = fill.textSize * config.lineHeight.toFloat()
        val travelMs = (8000 / config.scrollSpeed.coerceIn(0.3, 2.0)).toLong()
        val it = active.iterator()
        while (it.hasNext()) {
            val a = it.next()
            val age = pos - a.bornMs
            val life = if (a.c.mode == 1) travelMs else 4000
            if (age < 0 || age > life) { if (age > life) it.remove(); continue }
            val x = if (a.c.mode == 1) width - (width + a.width) * (age.toFloat() / travelMs) else (width - a.width) / 2
            val y = when (a.c.mode) {
                4 -> height - lineH * (a.lane + 1)
                else -> lineH * (a.lane + 1)
            }
            applyFillColorOrShader(a.c, x, a.width, config)
            fill.alpha = alpha
            stroke.alpha = alpha
            if (config.strokeWidth > 0) canvas.drawText(a.c.text, x, y, stroke)
            canvas.drawText(a.c.text, x, y, fill)
        }
        fill.shader = null
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
