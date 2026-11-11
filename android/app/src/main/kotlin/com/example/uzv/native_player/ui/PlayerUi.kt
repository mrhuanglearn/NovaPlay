package com.example.uzv.native_player.ui

import android.animation.ValueAnimator
import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Codepoints of the Material icon font shipped as `assets/player_icons.otf` (Flutter's MaterialIcons-Regular.otf, the
 * same glyph set the rest of the app draws its icons from). OBSERVED (UZN 1.1.7 on the phone, 2026-11-11): the player
 * page uses outlined / rounded Material icons; the hollow pause bars and the battery are drawn here ([PauseBars],
 * [BatteryView]) because that font has no matching glyph.
 */
object Ic {
    const val BACK = 0xf572
    const val CAMERA = 0xf29b
    const val REFRESH = 0xf00e9
    const val ROTATE = 0xf342
    const val PIP = 0xf2a5
    const val SUBTITLES = 0xf3fd
    const val SETTINGS = 0xf36e
    const val LOCK_OPEN = 0xf196
    const val LOCK = 0xf197
    const val REWIND = 0xf048
    const val FORWARD = 0xf047
    const val PLAY = 0xf00a0
    const val PAUSE = 0xe47c
    const val PREV = 0xf3a1
    const val NEXT = 0xf3a0
    const val SKIP_NEXT = 0xe5bd
    const val FORUM = 0xf0b0
    const val MENU = 0xe3dc
    const val UNFOLD = 0xe68e
    const val MORE = 0xe402
    const val LOCATE = 0xe2dc
    const val MEMORY = 0xe3db
    const val ASPECT = 0xe0a3
    const val FIT = 0xf079
    const val HEIGHT = 0xe308
    const val VOLUME_UP = 0xf4a8
    const val VOLUME_DOWN = 0xf4a5
    const val VOLUME_MUTE = 0xf4a6
    const val BRIGHTNESS = 0xeef9
    const val CHECK = 0xe156
    const val TUNE = 0xe683
    const val CLOCK = 0xe556
    const val BOLT = 0xe0ee
    const val DOUBLE_RIGHT = 0xf0531
    const val DOUBLE_LEFT = 0xf0530
    const val INFO = 0xe33d
    const val TEXT_FORMAT = 0xe64a
    const val CONTRAST = 0xf04d8
    const val COLUMNS = 0xf492
    const val BRUSH = 0xef02
    const val CANCEL = 0xef28
    const val CHEVRON = 0xe15f
    const val ADD = 0xe047
    const val REMOVE = 0xe516
    const val MUSIC = 0xf1fb
    const val CLOSE = 0xe16a
    const val MOVIE = 0xf1f5
    const val SEARCH = 0xe567
    const val SWAP_VERT = 0xe627
    const val AUTO_AWESOME = 0xe0b7
    const val CHECK_CIRCLE = 0xe159
    const val GRID_VIEW = 0xe2ea
    const val FILTER_LIST = 0xe280
}

/** View factory shared by the player's controls, menus and panels. Sizes are dp / sp as measured on the original. */
class PlayerUi(val context: Context) {
    val density: Float = context.resources.displayMetrics.density
    fun dp(v: Float) = (v * density + 0.5f).toInt()
    fun dp(v: Int) = dp(v.toFloat())

    val iconFont: Typeface = try {
        Typeface.createFromAsset(context.assets, "player_icons.otf")
    } catch (e: RuntimeException) {
        Typeface.DEFAULT
    }

    /** The app's accent (主题色彩), passed with the playback config; #007AFF when absent. */
    var accent: Int = ACCENT_DEFAULT

    fun icon(code: Int, sizeDp: Float, color: Int = Color.WHITE): TextView = TextView(context).apply {
        typeface = iconFont
        text = String(Character.toChars(code))
        setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, sizeDp * density)
        setTextColor(color)
        includeFontPadding = false
        gravity = Gravity.CENTER
    }

    fun text(s: String, sp: Float, color: Int = Color.WHITE, bold: Boolean = false, mono: Boolean = false): TextView =
        TextView(context).apply {
            text = s
            textSize = sp
            setTextColor(color)
            includeFontPadding = false
            typeface = when {
                mono -> Typeface.MONOSPACE
                bold -> Typeface.DEFAULT_BOLD
                else -> Typeface.DEFAULT
            }
        }

    fun rounded(color: Int, radiusDp: Float, stroke: Int = 0, strokeDp: Float = 1f) = GradientDrawable().apply {
        setColor(color)
        cornerRadius = radiusDp * density
        if (stroke != 0) setStroke(dp(strokeDp).coerceAtLeast(1), stroke)
    }

    fun oval(color: Int, stroke: Int = 0) = GradientDrawable().apply {
        shape = GradientDrawable.OVAL
        setColor(color)
        if (stroke != 0) setStroke(dp(0.6f).coerceAtLeast(1), stroke)
    }

    /** A round translucent button with one icon (top bar: 34 dp, back: 38 dp). */
    fun circleButton(code: Int, sizeDp: Float, iconDp: Float, fill: Int = BTN_FILL): FrameLayout = FrameLayout(context).apply {
        background = oval(fill, BTN_STROKE)
        addView(icon(code, iconDp), FrameLayout.LayoutParams(-2, -2, Gravity.CENTER))
        layoutParams = LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp))
    }

    /** A 32 dp pill of the bottom bar: optional icon, label, optional trailing icon. */
    fun pill(label: String, leading: Int? = null, trailing: Int? = null, mono: Boolean = false): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            background = rounded(BTN_FILL, 16f, BTN_STROKE, 0.6f)
            setPadding(dp(13), 0, dp(13), 0)
            minimumHeight = dp(32)
            leading?.let { addView(icon(it, 17f), LinearLayout.LayoutParams(-2, -2).apply { rightMargin = dp(8) }) }
            addView(text(label, 13.5f, mono = mono).apply { tag = "label"; maxLines = 1 })
            trailing?.let { addView(icon(it, 13f, 0xCCFFFFFF.toInt()), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = dp(6) }) }
        }

    fun pillLabel(pill: LinearLayout): TextView = pill.findViewWithTag("label")

    /** The small grey chips under the title (`1920x800`, the episode name). */
    fun chip(): TextView = text("", 11.5f, 0xE6FFFFFF.toInt()).apply {
        background = rounded(0x24FFFFFF, 9f)
        setPadding(dp(7), dp(2.5f), dp(7), dp(2.5f))
        maxLines = 1
        ellipsize = TextUtils.TruncateAt.MIDDLE
        visibility = View.GONE
    }

    // -- panel pieces ---------------------------------------------------------------------------------------------------

    fun sectionLabel(title: String): TextView = text(title, 12.5f, TEXT_DIM).apply { setPadding(dp(2), dp(18), 0, dp(8)) }

    /** A rounded card that stacks rows with hairlines between them. */
    fun card(): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        background = rounded(CARD_FILL, 16f, CARD_STROKE, 0.5f)
        clipToOutline = true
    }

    fun addRow(card: LinearLayout, row: View) {
        if (card.childCount > 0) card.addView(View(context).apply { setBackgroundColor(CARD_STROKE) }, LinearLayout.LayoutParams(-1, 1))
        card.addView(row, LinearLayout.LayoutParams(-1, -2))
    }

    /** icon · title (+ grey subtitle) · trailing. */
    fun row(iconCode: Int?, title: String, subtitle: String? = null, trailing: View? = null, rotateIcon: Boolean = false): LinearLayout =
        LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(if (subtitle == null) 44 else 49)
            setPadding(dp(16), dp(6), dp(14), dp(6))
            if (iconCode != null) addView(icon(iconCode, 18f, 0xD9FFFFFF.toInt()).apply {
                tag = "icon"
                if (rotateIcon) rotation = 90f
            }, LinearLayout.LayoutParams(dp(20), dp(20)).apply { rightMargin = dp(14) })
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(text(title, 14.5f).apply { tag = "title" })
                if (subtitle != null) addView(text(subtitle, 10.5f, TEXT_DIM).apply { setPadding(0, dp(3), 0, 0) })
            }, LinearLayout.LayoutParams(0, -2, 1f))
            trailing?.let { addView(it) }
        }

    fun valueBadge(textValue: String): TextView = text(textValue, 11f, 0xD9FFFFFF.toInt()).apply {
        background = rounded(0x1FFFFFFF, 10f)
        setPadding(dp(8), dp(3), dp(8), dp(3))
    }

    companion object {
        const val ACCENT_DEFAULT = 0xFF007AFF.toInt()
        const val BTN_FILL = 0x73111114
        const val BTN_STROKE = 0x1FFFFFFF
        const val TEXT_DIM = 0x99FFFFFF.toInt()
        const val CARD_FILL = 0x14FFFFFF
        const val CARD_STROKE = 0x12FFFFFF

        /** Panel background measured on the original: about rgb(21,21,21) at 67 % over the video. */
        const val PANEL_FILL = 0xAC151515.toInt()

        /** Menus are opaque (M3 dark surface container, rgb(25,25,30)). */
        const val MENU_FILL = 0xFF19191E.toInt()

        fun withAlpha(color: Int, alpha: Float) = (color and 0x00FFFFFF) or ((alpha * 255).toInt().coerceIn(0, 255) shl 24)
    }
}

/** Two hollow rounded bars: the original's pause glyph (the font's pause is solid). */
class PauseBars(context: Context, private val color: Int) : View(context) {
    private val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = this@PauseBars.color }
    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        p.strokeWidth = w * 0.115f
        val bw = w * 0.2f; val top = h * 0.2f; val bottom = h * 0.8f; val r = bw * 0.38f
        canvas.drawRoundRect(RectF(w * 0.22f, top, w * 0.22f + bw, bottom), r, r, p)
        canvas.drawRoundRect(RectF(w * 0.78f - bw, top, w * 0.78f, bottom), r, r, p)
    }
}

/** Outlined battery with its fill level, as next to the clock in the landscape top bar. */
class BatteryView(context: Context) : View(context) {
    var level = 1f
        set(v) { field = v.coerceIn(0f, 1f); invalidate() }
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = Color.WHITE }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        val sw = h * 0.12f
        stroke.strokeWidth = sw
        val body = RectF(sw / 2, sw / 2, w - sw * 1.6f, h - sw / 2)
        canvas.drawRoundRect(body, h * 0.22f, h * 0.22f, stroke)
        canvas.drawRoundRect(RectF(w - sw * 1.2f, h * 0.3f, w, h * 0.7f), sw / 2, sw / 2, fill)
        val inset = sw * 1.6f
        val full = body.width() - inset * 2 + sw
        canvas.drawRoundRect(RectF(body.left + inset - sw / 2, body.top + inset - sw / 2, body.left + inset - sw / 2 + full * level, body.bottom - inset + sw / 2), sw / 2, sw / 2, fill)
    }
}

/** A white arc turning on a grey ring (the loading box). */
class RingSpinner(context: Context) : View(context) {
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = 0x40FFFFFF }
    private val arc = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; color = Color.WHITE; strokeCap = Paint.Cap.ROUND }
    private var angle = 0f
    private val animator = ValueAnimator.ofFloat(0f, 360f).apply {
        duration = 900; repeatCount = ValueAnimator.INFINITE; interpolator = android.view.animation.LinearInterpolator()
        addUpdateListener { angle = it.animatedValue as Float; invalidate() }
    }
    override fun onAttachedToWindow() { super.onAttachedToWindow(); animator.start() }
    override fun onDetachedFromWindow() { animator.cancel(); super.onDetachedFromWindow() }
    override fun onDraw(canvas: Canvas) {
        val sw = width * 0.14f
        ring.strokeWidth = sw; arc.strokeWidth = sw
        val r = RectF(sw / 2, sw / 2, width - sw / 2, height - sw / 2)
        canvas.drawOval(r, ring)
        canvas.drawArc(r, angle - 90f, 80f, false, arc)
    }
}

/** The original's switch: a 39 × 22 dp track (accent when on) with a white thumb. */
@SuppressLint("ViewConstructor")
class SwitchView(context: Context, private val accent: Int, checked: Boolean, private val onChange: (Boolean) -> Unit) : View(context) {
    var checked = checked
        private set
    private var pos = if (checked) 1f else 0f
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val d = resources.displayMetrics.density

    init { setOnClickListener { toggle() } }

    fun toggle() { set(!checked, notify = true) }

    fun set(value: Boolean, notify: Boolean = false) {
        if (value == checked) return
        checked = value
        ValueAnimator.ofFloat(pos, if (value) 1f else 0f).apply {
            duration = 140
            addUpdateListener { pos = it.animatedValue as Float; invalidate() }
        }.start()
        if (notify) onChange(value)
    }

    override fun onMeasure(w: Int, h: Int) = setMeasuredDimension((39 * d).toInt(), (22 * d).toInt())

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat()
        paint.color = blend(0xFF5B5B5F.toInt(), accent, pos)
        canvas.drawRoundRect(RectF(0f, 0f, w, h), h / 2, h / 2, paint)
        val r = h / 2 - 3 * d
        paint.color = Color.WHITE
        canvas.drawCircle(h / 2 + (w - h) * pos, h / 2, r, paint)
    }

    private fun blend(a: Int, b: Int, t: Float): Int {
        fun ch(shift: Int) = ((a shr shift and 0xFF) + ((b shr shift and 0xFF) - (a shr shift and 0xFF)) * t).toInt() and 0xFF
        return (0xFF shl 24) or (ch(16) shl 16) or (ch(8) shl 8) or ch(0)
    }
}

/**
 * A thin horizontal slider (accent fill, white thumb) used by 样式调节 and the progress bar. [fraction] is 0..1;
 * [onChange] is called while dragging with `done = false` and once on release with `done = true`.
 */
@SuppressLint("ViewConstructor")
class SliderView(
    context: Context,
    private val fillColor: Int,
    private val trackColor: Int = 0x40FFFFFF,
    private val thumbDp: Float = 11f,
    private val trackDp: Float = 3f,
    private val onChange: (Float, Boolean) -> Unit,
) : View(context) {
    var fraction = 0f
        set(v) { field = v.coerceIn(0f, 1f); invalidate() }

    /** A second, paler fill (the buffered part of the progress bar). */
    var secondary = 0f
        set(v) { field = v.coerceIn(0f, 1f); invalidate() }
    var dragging = false
        private set
    private val d = resources.displayMetrics.density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)

    override fun onMeasure(w: Int, h: Int) =
        setMeasuredDimension(MeasureSpec.getSize(w), ((thumbDp + 14f) * d).toInt())

    private fun fractionAt(x: Float): Float {
        val pad = thumbDp * d / 2
        return ((x - pad) / (width - pad * 2)).coerceIn(0f, 1f)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        if (!isEnabled) return false
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { dragging = true; parent?.requestDisallowInterceptTouchEvent(true); fraction = fractionAt(e.x); onChange(fraction, false) }
            MotionEvent.ACTION_MOVE -> { fraction = fractionAt(e.x); onChange(fraction, false) }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { dragging = false; fraction = fractionAt(e.x); onChange(fraction, true) }
        }
        return true
    }

    override fun onDraw(canvas: Canvas) {
        val pad = thumbDp * d / 2
        val cy = height / 2f
        val th = trackDp * d
        val left = pad; val right = width - pad
        paint.color = trackColor
        canvas.drawRoundRect(RectF(left, cy - th / 2, right, cy + th / 2), th / 2, th / 2, paint)
        if (secondary > 0f) {
            paint.color = 0x66FFFFFF
            canvas.drawRoundRect(RectF(left, cy - th / 2, left + (right - left) * secondary, cy + th / 2), th / 2, th / 2, paint)
        }
        val x = left + (right - left) * fraction
        paint.color = fillColor
        canvas.drawRoundRect(RectF(left, cy - th / 2, x, cy + th / 2), th / 2, th / 2, paint)
        paint.color = Color.WHITE
        canvas.drawCircle(x, cy, thumbDp * d / 2, paint)
    }
}

/**
 * The tall slider of the speed menu (OBSERVED: a 34 dp wide rounded track, accent fill rising from the bottom, the value
 * at the top and `0.5` at the bottom). [fraction] 0 = bottom.
 */
@SuppressLint("ViewConstructor")
class VerticalFillSlider(context: Context, private val accent: Int, private val onChange: (Float, Boolean) -> Unit) : View(context) {
    var fraction = 0f
        set(v) { field = v.coerceIn(0f, 1f); invalidate() }
    var topLabel = ""
        set(v) { field = v; invalidate() }
    var bottomLabel = ""
    private val d = resources.displayMetrics.density
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE; textAlign = Paint.Align.CENTER; typeface = Typeface.MONOSPACE
        textSize = 11.5f * resources.displayMetrics.scaledDensity
    }

    private fun fractionAt(y: Float) = (1f - (y - width / 2f) / (height - width).toFloat()).coerceIn(0f, 1f)

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> { parent?.requestDisallowInterceptTouchEvent(true); fraction = fractionAt(e.y); onChange(fraction, false) }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> { fraction = fractionAt(e.y); onChange(fraction, true) }
        }
        return true
    }

    override fun onDraw(canvas: Canvas) {
        val w = width.toFloat(); val h = height.toFloat(); val r = w / 2
        paint.color = 0x1FFFFFFF
        canvas.drawRoundRect(RectF(0f, 0f, w, h), r, r, paint)
        val fillTop = h - w - (h - w * 2) * fraction
        paint.color = accent
        canvas.drawRoundRect(RectF(0f, fillTop, w, h), r, r, paint)
        label.color = Color.WHITE
        canvas.drawText(topLabel, r, 22 * d, label)
        label.color = 0x99FFFFFF.toInt()
        canvas.drawText(bottomLabel, r, h - 10 * d, label)
    }
}
