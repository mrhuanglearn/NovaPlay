package com.example.uzv.native_player.ui

import android.content.Context
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import kotlin.math.abs

/**
 * Hosts popup menus (`showMenu`, `showSpeedMenu`) and translucent right/bottom panels (`showPanel`, `showCustomPanel`)
 * over [PlayerControlsView].
 */
internal class PlayerOverlayHost(
    private val context: Context,
    private val root: FrameLayout,
    private val ui: PlayerUi,
    private val menuHost: FrameLayout,
    private val panelHost: FrameLayout,
    private val isLandscape: () -> Boolean,
    private val isControlsVisible: () -> Boolean,
    private val cancelAutoHide: () -> Unit,
    private val hideControls: () -> Unit,
    private val touchControls: () -> Unit,
    private val onHaptic: () -> Unit,
) {
    private fun dp(v: Int): Int = ui.dp(v)

    val menuOpen: Boolean get() = menuHost.visibility == View.VISIBLE
    val panelOpen: Boolean get() = panelHost.visibility == View.VISIBLE
    var onPanelClosed: (() -> Unit)? = null

    fun closeMenu() {
        menuHost.removeAllViews()
        menuHost.visibility = View.GONE
        if (isControlsVisible()) touchControls()
    }

    fun showMenuCard(anchor: View, above: Boolean, card: View) {
        cancelAutoHide()
        menuHost.removeAllViews()
        menuHost.addView(View(context).apply { setOnClickListener { closeMenu() } }, FrameLayout.LayoutParams(-1, -1))
        card.background = ui.rounded(PlayerUi.MENU_FILL, 16f, 0x14FFFFFF, 0.6f)
        card.elevation = dp(6).toFloat()
        card.isClickable = true
        menuHost.addView(card, FrameLayout.LayoutParams(-2, -2))
        menuHost.visibility = View.VISIBLE
        card.visibility = View.INVISIBLE
        card.post {
            val a = IntArray(2).also { anchor.getLocationInWindow(it) }
            val me = IntArray(2).also { root.getLocationInWindow(it) }
            val ax = a[0] - me[0]
            val ay = a[1] - me[1]
            val m = dp(8)
            val x = if (above) ax + anchor.width - card.width else ax - dp(2)
            val y = if (above) ay - card.height - dp(7) else ay + anchor.height + dp(7)
            card.translationX = x.coerceIn(m, (root.width - card.width - m).coerceAtLeast(m)).toFloat()
            card.translationY = y.coerceIn(m, (root.height - card.height - m).coerceAtLeast(m)).toFloat()
            card.alpha = 0f
            card.visibility = View.VISIBLE
            card.animate().alpha(1f).setDuration(120).start()
        }
    }

    fun showMenu(anchor: View, above: Boolean, items: List<PlayerControlsView.MenuItem>) {
        val list = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(4), 0, dp(4))
        }
        for (item in items) {
            if (item.dividerBefore) {
                list.addView(
                    View(context).apply { setBackgroundColor(0x1FFFFFFF) },
                    LinearLayout.LayoutParams(-1, 1).apply {
                        leftMargin = dp(14); rightMargin = dp(14); topMargin = dp(4); bottomMargin = dp(4)
                    },
                )
            }
            list.addView(LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                minimumHeight = dp(44)
                minimumWidth = dp(120)
                setPadding(dp(18), 0, dp(14), 0)
                addView(
                    ui.text(item.label, 14.5f, if (item.selected) Color.WHITE else 0xB8FFFFFF.toInt(), bold = item.selected).apply {
                        maxLines = 1; ellipsize = TextUtils.TruncateAt.END; maxWidth = dp(220)
                    },
                    LinearLayout.LayoutParams(0, -2, 1f),
                )
                if (item.selected) {
                    addView(ui.icon(Ic.CHECK, 15f, ui.accent), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = dp(18) })
                }
                setOnClickListener { closeMenu(); onHaptic(); item.onClick() }
            }, LinearLayout.LayoutParams(-1, -2))
        }
        val scroll = ScrollView(context).apply { addView(list); isVerticalScrollBarEnabled = false }
        showMenuCard(anchor, above, FrameLayout(context).apply {
            addView(scroll, FrameLayout.LayoutParams(-2, -2))
            clipToOutline = true
        })
    }

    fun showSpeedMenu(anchor: View, current: Double, onPick: (Double) -> Unit) {
        val footer = ui.text(PlayerUiText.speedOption(current), 12.5f, 0x99FFFFFF.toInt()).apply { gravity = Gravity.CENTER }
        val rows = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        lateinit var slider: VerticalFillSlider
        fun fractionOf(v: Double) = ((v - 0.5) / 2.5).toFloat()
        fun fillRows(value: Double) {
            rows.removeAllViews()
            for (s in PlayerUiText.speeds.reversed()) {
                val sel = abs(s - value) < 0.001
                rows.addView(LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER_VERTICAL
                    background = if (sel) ui.rounded(PlayerUi.withAlpha(ui.accent, 0.22f), 8f) else null
                    setPadding(dp(10), 0, dp(10), 0)
                    addView(
                        if (sel) ui.icon(Ic.CHECK, 12f, ui.accent) else View(context),
                        LinearLayout.LayoutParams(dp(12), dp(12)).apply { rightMargin = dp(8) },
                    )
                    addView(ui.text(PlayerUiText.speedMenuLabel(s), 13f, if (sel) ui.accent else Color.WHITE, mono = true))
                    setOnClickListener { onHaptic(); onPick(s); closeMenu() }
                }, LinearLayout.LayoutParams(-1, dp(32)))
            }
        }
        slider = VerticalFillSlider(context, ui.accent) { f, done ->
            val v = Math.round((0.5 + f * 2.5) * 10) / 10.0
            slider.topLabel = PlayerUiText.speed(v)
            footer.text = PlayerUiText.speedOption(v)
            fillRows(v)
            if (done) onPick(v)
        }.apply {
            fraction = fractionOf(current)
            topLabel = PlayerUiText.speed(current)
            bottomLabel = "0.5"
        }
        fillRows(current)
        showMenuCard(anchor, true, LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(8), dp(8), dp(8), dp(8))
            addView(slider, LinearLayout.LayoutParams(dp(34), dp(254)))
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                setPadding(dp(8), 0, 0, 0)
                addView(rows, LinearLayout.LayoutParams(dp(128), -2))
                addView(View(context).apply { setBackgroundColor(0x1FFFFFFF) }, LinearLayout.LayoutParams(-1, 1).apply { topMargin = dp(4) })
                addView(footer, LinearLayout.LayoutParams(-1, 0, 1f))
            }, LinearLayout.LayoutParams(-2, -1))
        })
    }

    fun showPanel(header: View? = null, fill: (LinearLayout) -> Unit): ScrollView {
        val body = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), 0, dp(16), dp(20))
        }
        fill(body)
        val scroll = ScrollView(context).apply { addView(body); isVerticalScrollBarEnabled = true }
        showCustomPanel(header, scroll)
        return scroll
    }

    fun showCustomPanel(header: View? = null, content: View) {
        cancelAutoHide()
        hideControls()
        closeMenu()
        val landscape = isLandscape()
        panelHost.removeAllViews()
        panelHost.addView(View(context).apply { setOnClickListener { closePanel() } }, FrameLayout.LayoutParams(-1, -1))
        val sheet = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            isClickable = true
            background = GradientDrawable().apply {
                setColor(PlayerUi.PANEL_FILL)
                val r = dp(16).toFloat()
                cornerRadii = if (landscape) floatArrayOf(r, r, 0f, 0f, 0f, 0f, r, r) else floatArrayOf(r, r, r, r, 0f, 0f, 0f, 0f)
            }
            clipToOutline = true
            if (header != null) addView(header) else setPadding(0, dp(6), 0, 0)
            addView(content, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        val lp = if (landscape) {
            FrameLayout.LayoutParams((root.width * 0.44f).toInt().coerceAtLeast(dp(300)).coerceAtMost(root.width), -1, Gravity.END)
        } else {
            FrameLayout.LayoutParams(-1, (root.height * 0.526f).toInt(), Gravity.BOTTOM)
        }
        panelHost.addView(sheet, lp)
        panelHost.visibility = View.VISIBLE
        if (landscape) {
            sheet.translationX = dp(40).toFloat()
            sheet.animate().translationX(0f)
        } else {
            sheet.translationY = dp(40).toFloat()
            sheet.animate().translationY(0f)
        }
        sheet.alpha = 0f
        sheet.animate().alpha(1f).setDuration(160).start()
    }

    fun closePanel() {
        panelHost.removeAllViews()
        panelHost.visibility = View.GONE
        onPanelClosed?.invoke()
        onPanelClosed = null
    }
}
