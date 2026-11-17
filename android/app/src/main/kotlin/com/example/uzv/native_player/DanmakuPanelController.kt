package com.example.uzv.native_player

import android.app.Activity
import android.content.Context
import android.graphics.Color
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import com.example.uzv.Haptics
import com.example.uzv.native_player.ui.Ic
import com.example.uzv.native_player.ui.PlayerControlsView
import com.example.uzv.native_player.ui.PlayerSettings
import com.example.uzv.native_player.ui.PlayerUi
import com.example.uzv.native_player.ui.PlayerUiText
import com.example.uzv.native_player.ui.SliderView
import com.example.uzv.native_player.ui.SwitchView

/**
 * Manages the native player's danmaku side/bottom panel (弹幕设置, 样式调节, 屏蔽词管理, and Dandanplay anime/episode matching).
 */
internal class DanmakuPanelController(
    private val activity: Activity,
    private val controlsProvider: () -> PlayerControlsView?,
    private val onHaptic: (PlayerController, String) -> Unit,
    private val onToast: (String) -> Unit,
) {
    private var danmakuTab = 0
    var subScreen = 0 // 0 = tabs, 1 = anime results, 2 = episode results, 3 = blocked words
        private set
    private var danmakuDirect: Int? = null
    private var lastAnimeResults: List<DanmakuSearchResultItem> = emptyList()
    private var lastEpisodeResults: List<EpisodeItem> = emptyList()
    private var danmakuCountBadge: TextView? = null
    private var danmakuStatusText: TextView? = null

    fun openRoot(c: PlayerController) {
        subScreen = 0
        show(c)
    }

    /** Returns true if a sub-screen consumed the Back press by returning to its parent screen. */
    fun handleBack(c: PlayerController?): Boolean {
        if (subScreen == 0 || c == null) return false
        subScreen = if (subScreen == 2) 1 else 0
        show(c)
        return true
    }

    fun onCountChanged(count: Int) {
        danmakuCountBadge?.let {
            it.text = PlayerUiText.t("$count 条", "$count")
            it.visibility = if (count > 0) View.VISIBLE else View.GONE
        }
        danmakuStatusText?.text = if (count > 0) {
            PlayerUiText.t("当前已加载 $count 条弹幕", "$count comments loaded")
        } else {
            PlayerUiText.t("当前未加载弹幕", "No comments loaded")
        }
    }

    fun onSearchResults(c: PlayerController, results: List<DanmakuSearchResultItem>) {
        if (results.isEmpty()) {
            danmakuDirect = null
            onToast(PlayerUiText.t("未匹配到相关弹幕", "No matching danmaku"))
            return
        }
        if (danmakuDirect != null) {
            c.pickDanmakuAnime(results.first().animeId)
            return
        }
        lastAnimeResults = results
        subScreen = 1
        show(c)
    }

    fun onEpisodeResults(c: PlayerController, episodes: List<EpisodeItem>) {
        val direct = danmakuDirect
        if (direct != null) {
            danmakuDirect = null
            if (episodes.isEmpty()) {
                onToast(PlayerUiText.t("未匹配到相关弹幕", "No matching danmaku"))
                return
            }
            val chosen = direct.coerceIn(0, episodes.size - 1)
            c.pickDanmakuEpisode(chosen)
            subScreen = 0
            controlsProvider()?.closePanel()
            onToast(PlayerUiText.t("已匹配弹幕：${episodes[chosen].episodeName}", "Danmaku matched"))
            return
        }
        lastEpisodeResults = episodes
        subScreen = 2
        show(c)
    }

    internal fun field(ui: PlayerUi, value: String, hint: String, number: Boolean = false) = EditText(activity).apply {
        setText(value)
        this.hint = hint
        setHintTextColor(0x66FFFFFF)
        setTextColor(Color.WHITE)
        textSize = 14f
        setSingleLine()
        if (number) inputType = InputType.TYPE_CLASS_NUMBER
        background = ui.rounded(0x14FFFFFF, 10f, 0x12FFFFFF, 0.6f)
        setPadding(ui.dp(12), 0, ui.dp(12), 0)
        imeOptions = EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_EXTRACT_UI
    }

    fun show(c: PlayerController, scrollY: Int = 0) {
        val v = controlsProvider() ?: return
        val ui = v.ui
        val count = c.loadedDanmakuCount
        val badge = ui.text(PlayerUiText.t("$count 条", "$count"), 11f, ui.accent, bold = true).apply {
            background = ui.rounded(PlayerUi.withAlpha(ui.accent, 0.16f), 10f)
            setPadding(ui.dp(8), ui.dp(3), ui.dp(8), ui.dp(3))
            visibility = if (count > 0) View.VISIBLE else View.GONE
        }
        danmakuCountBadge = badge
        val header = LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(ui.dp(14), ui.dp(12), ui.dp(14), ui.dp(10))
            if (subScreen == 0) {
                addView(LinearLayout(activity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    background = ui.rounded(0x14FFFFFF, 17f)
                    setPadding(ui.dp(3), ui.dp(3), ui.dp(3), ui.dp(3))
                    listOf(
                        Ic.FORUM to PlayerUiText.t("弹幕设置", "Danmaku"),
                        Ic.TUNE to PlayerUiText.t("样式调节", "Style"),
                    ).forEachIndexed { i, (code, label) ->
                        val sel = i == danmakuTab
                        addView(LinearLayout(activity).apply {
                            orientation = LinearLayout.HORIZONTAL
                            gravity = Gravity.CENTER
                            background = if (sel) ui.rounded(0x2EFFFFFF, 14f) else null
                            setPadding(ui.dp(12), 0, ui.dp(13), 0)
                            addView(
                                ui.icon(code, 13f, if (sel) Color.WHITE else 0xB3FFFFFF.toInt()),
                                LinearLayout.LayoutParams(-2, -2).apply { rightMargin = ui.dp(7) },
                            )
                            addView(ui.text(label, 12.5f, if (sel) Color.WHITE else 0xB3FFFFFF.toInt(), bold = sel))
                            setOnClickListener {
                                if (danmakuTab != i) {
                                    onHaptic(c, Haptics.SELECTION)
                                    danmakuTab = i
                                    show(c)
                                }
                            }
                        }, LinearLayout.LayoutParams(-2, ui.dp(28)))
                    }
                }, LinearLayout.LayoutParams(-2, -2))
            } else {
                addView(ui.circleButton(Ic.BACK, 30f, 16f, 0x24FFFFFF).apply {
                    setOnClickListener {
                        onHaptic(c, Haptics.SELECTION)
                        subScreen = if (subScreen == 2) 1 else 0
                        show(c)
                    }
                }, LinearLayout.LayoutParams(ui.dp(30), ui.dp(30)).apply { rightMargin = ui.dp(10) })
                val subTitle = when (subScreen) {
                    1 -> PlayerUiText.t("搜索结果 — 选择剧集", "Choose a show")
                    2 -> PlayerUiText.t("选择集数", "Choose an episode")
                    else -> PlayerUiText.t("屏蔽词管理", "Blocked words")
                }
                addView(ui.text(subTitle, 14.5f, bold = true))
            }
            addView(View(activity), LinearLayout.LayoutParams(0, 1, 1f))
            addView(badge)
        }
        val scroll = v.showPanel(header) { list ->
            when (subScreen) {
                1 -> danmakuAnimeList(c, ui, list)
                2 -> danmakuEpisodeList(c, ui, list)
                3 -> danmakuBlockedWordsView(c, ui, list)
                else -> if (danmakuTab == 0) danmakuSettings(c, ui, list) else danmakuStyle(c, ui, list)
            }
        }
        if (scrollY > 0) scroll.post { scroll.scrollTo(0, scrollY) }
    }

    private fun danmakuSettings(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        list.addView(ui.sectionLabel(PlayerUiText.t("弹幕状态", "Status")))
        val search = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        fun dim() { search.alpha = if (c.danmakuEnabled) 1f else 0.38f }
        val sw = SwitchView(activity, ui.accent, c.danmakuEnabled) { on ->
            onHaptic(c, Haptics.SELECTION)
            c.setDanmakuEnabled(on)
            dim()
        }
        val count = c.loadedDanmakuCount
        val statusLabel = ui.text(
            if (count > 0) PlayerUiText.t("当前已加载 $count 条弹幕", "$count comments loaded")
            else PlayerUiText.t("当前未加载弹幕", "No comments loaded"),
            12f,
            if (count > 0) ui.accent else PlayerUi.TEXT_DIM,
        )
        danmakuStatusText = statusLabel
        list.addView(ui.card().also { card ->
            ui.addRow(card, ui.row(Ic.FORUM, PlayerUiText.t("启用弹幕", "Show danmaku"), null, sw).also { r -> r.setOnClickListener { sw.toggle() } })
            ui.addRow(card, LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(ui.dp(16), ui.dp(9), ui.dp(14), ui.dp(9))
                addView(
                    ui.icon(Ic.CHECK_CIRCLE, 15f, if (count > 0) ui.accent else PlayerUi.TEXT_DIM),
                    LinearLayout.LayoutParams(-2, -2).apply { rightMargin = ui.dp(10) },
                )
                addView(statusLabel)
            })
        })
        search.addView(ui.sectionLabel(PlayerUiText.t("弹幕搜索与匹配", "Search and match")))
        val name = field(ui, c.title, PlayerUiText.t("剧集名称", "Title"))
        val season = field(ui, "1", PlayerUiText.t("第 1 季", "Season 1"), number = true)
        val episode = field(ui, "${c.episode + 1}", "1", number = true)
        c.danmakuPrompt { info ->
            info?.let {
                if (!activity.isFinishing) {
                    name.setText(it.keyword)
                    episode.setText("${it.episodeNumber}")
                }
            }
        }
        search.addView(ui.card().apply {
            setPadding(ui.dp(14), ui.dp(12), ui.dp(14), ui.dp(14))
            addView(ui.text(PlayerUiText.t("剧集名称", "Title"), 11f, PlayerUi.TEXT_DIM).apply { setPadding(0, 0, 0, ui.dp(6)) })
            addView(name, LinearLayout.LayoutParams(-1, ui.dp(40)))
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                fun column(label: String, f: EditText, left: Int) = addView(LinearLayout(activity).apply {
                    orientation = LinearLayout.VERTICAL
                    addView(ui.text(label, 11f, PlayerUi.TEXT_DIM).apply { setPadding(0, ui.dp(10), 0, ui.dp(6)) })
                    addView(f, LinearLayout.LayoutParams(-1, ui.dp(40)))
                }, LinearLayout.LayoutParams(0, -2, 1f).apply { leftMargin = ui.dp(left) })
                column(PlayerUiText.t("季数 (S)", "Season (S)"), season, 0)
                column(PlayerUiText.t("集数 (E)", "Episode (E)"), episode, 10)
            })
            addView(LinearLayout(activity).apply {
                orientation = LinearLayout.HORIZONTAL
                fun button(code: Int, label: String, fill: Int, left: Int, onClick: () -> Unit) = addView(LinearLayout(activity).apply {
                    orientation = LinearLayout.HORIZONTAL
                    gravity = Gravity.CENTER
                    background = ui.rounded(fill, 10f, if (fill == ui.accent) 0 else 0x1FFFFFFF, 0.6f)
                    addView(ui.icon(code, 14f), LinearLayout.LayoutParams(-2, -2).apply { rightMargin = ui.dp(8) })
                    addView(ui.text(label, 13f, bold = fill == ui.accent))
                    setOnClickListener {
                        if (!c.danmakuEnabled) return@setOnClickListener
                        onHaptic(c, Haptics.SELECTION)
                        (activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
                            .hideSoftInputFromWindow(windowToken, 0)
                        onClick()
                    }
                }, LinearLayout.LayoutParams(0, ui.dp(40), 1f).apply { leftMargin = ui.dp(left) })
                button(Ic.MENU, PlayerUiText.t("分步搜索", "Step by step"), 0x14FFFFFF, 0) {
                    danmakuDirect = null
                    c.searchDanmaku(name.text.toString().trim())
                }
                button(Ic.BOLT, PlayerUiText.t("直接搜索匹配", "Search and match"), ui.accent, 10) {
                    danmakuDirect = (episode.text.toString().toIntOrNull() ?: 1).coerceAtLeast(1) - 1
                    c.searchDanmaku(name.text.toString().trim())
                }
            }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = ui.dp(14) })
        })
        search.addView(ui.text(
            PlayerUiText.t(
                "提示：直接搜索匹配会自动关联剧名、季数与集数直接从弹幕库加载并保存记忆；若未命中，可尝试「分步搜索」手动选择剧集。",
                "Search and match loads the comments for this title and episode and remembers the match; if it misses, use “Step by step”.",
            ),
            11f,
            PlayerUi.TEXT_DIM,
        ).apply { setPadding(ui.dp(2), ui.dp(12), ui.dp(2), 0); setLineSpacing(ui.dp(3).toFloat(), 1f) })
        dim()
        list.addView(search)
    }

    private fun danmakuStyle(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        fun cfg() = c.danmakuConfig
        list.addView(View(activity), LinearLayout.LayoutParams(1, ui.dp(8)))
        list.addView(ui.card().also { card ->
            fun toggle(title: String, get: () -> Boolean, set: (Boolean) -> DanmakuConfig) {
                val sw = SwitchView(activity, ui.accent, get()) { on -> onHaptic(c, Haptics.SELECTION); c.updateDanmaku(set(on)) }
                ui.addRow(card, ui.row(null, title, null, sw).also { r -> r.minimumHeight = ui.dp(51); r.setOnClickListener { sw.toggle() } })
            }
            toggle(PlayerUiText.t("显示顶部固定弹幕", "Show top comments"), { cfg().showTop }) { cfg().copy(showTop = it) }
            toggle(PlayerUiText.t("显示底部固定弹幕", "Show bottom comments"), { cfg().showBottom }) { cfg().copy(showBottom = it) }
        })
        list.addView(ui.sectionLabel(PlayerUiText.t("颜色模式", "Colour")))
        list.addView(ui.card().also { card ->
            val value = ui.text(PlayerUiText.danmakuColorMode(cfg().colorMode), 12f, PlayerUi.TEXT_DIM)
            val trailing = LinearLayout(activity).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(value)
                addView(ui.icon(Ic.CHEVRON, 16f, PlayerUi.TEXT_DIM), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
            }
            ui.addRow(card, ui.row(Ic.BRUSH, PlayerUiText.t("颜色模式", "Colour"), null, trailing).also { r ->
                r.setOnClickListener {
                    controlsProvider()?.showMenu(trailing, above = false, items = PlayerUiText.danmakuColorModes.map { m ->
                        PlayerControlsView.MenuItem(PlayerUiText.danmakuColorMode(m), selected = m == cfg().colorMode) {
                            c.updateDanmaku(cfg().copy(colorMode = m))
                            show(c)
                        }
                    })
                }
            })
            val usesGradient = cfg().colorMode == "gradient" || cfg().colorMode == "3" || cfg().colorMode == "random_Mix" || cfg().colorMode == "0"
            if (usesGradient) {
                val gradValue = ui.text(PlayerUiText.danmakuGradientLabel(cfg().gradientStyle), 12f, PlayerUi.TEXT_DIM)
                val gradTrailing = LinearLayout(activity).apply {
                    gravity = Gravity.CENTER_VERTICAL
                    addView(gradValue)
                    addView(ui.icon(Ic.CHEVRON, 16f, PlayerUi.TEXT_DIM), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
                }
                ui.addRow(card, ui.row(Ic.AUTO_AWESOME, PlayerUiText.t("渐变色风格", "Gradient style"), null, gradTrailing).also { r ->
                    r.setOnClickListener {
                        val curPreset = PlayerUiText.parseGradientPreset(cfg().gradientStyle)
                        val curWeight = PlayerUiText.parseFontWeight(cfg().gradientStyle)
                        controlsProvider()?.showMenu(gradTrailing, above = false, items = PlayerUiText.danmakuGradientPresets.map { (id, label) ->
                            PlayerControlsView.MenuItem(label, selected = id == curPreset) {
                                val nextStyle = PlayerUiText.encodeGradientAndWeight(id, curWeight)
                                c.updateDanmaku(cfg().copy(gradientStyle = nextStyle))
                                gradValue.text = label
                            }
                        })
                    }
                })
            }
        })
        fun pct(v: Double) = "${Math.round(v * 100)}%"
        fun sliders(title: String, rows: List<SliderRow>) {
            list.addView(ui.sectionLabel(title))
            list.addView(ui.card().also { card ->
                for (r in rows) {
                    val badge = ui.valueBadge(r.label(r.get()))
                    val box = LinearLayout(activity).apply {
                        orientation = LinearLayout.VERTICAL
                        setPadding(ui.dp(14), ui.dp(10), ui.dp(14), ui.dp(4))
                        addView(LinearLayout(activity).apply {
                            orientation = LinearLayout.HORIZONTAL
                            gravity = Gravity.CENTER_VERTICAL
                            addView(
                                ui.icon(r.icon, 14f, 0xB3FFFFFF.toInt()).apply { if (r.rotate) rotation = 90f },
                                LinearLayout.LayoutParams(ui.dp(16), ui.dp(16)).apply { rightMargin = ui.dp(10) },
                            )
                            addView(ui.text(r.title, 13.5f), LinearLayout.LayoutParams(0, -2, 1f))
                            addView(badge)
                        })
                        addView(SliderView(activity, ui.accent, 0x33FFFFFF, 12f, 2.5f) { f, done ->
                            val value = Math.round((r.min + (r.max - r.min) * f) / r.step) * r.step
                            badge.text = r.label(value)
                            c.updateDanmaku(r.set(value), save = done)
                        }.apply { fraction = ((r.get() - r.min) / (r.max - r.min)).toFloat() })
                    }
                    ui.addRow(card, box)
                }
            })
        }
        sliders(PlayerUiText.t("外观与排版", "Appearance"), listOf(
            SliderRow(Ic.TEXT_FORMAT, PlayerUiText.t("字号大小", "Font size"), 12.0, 32.0, 1.0, { cfg().fontSize }, { cfg().copy(fontSize = it) }) { "${Math.round(it)} pt" },
            SliderRow(
                Ic.TEXT_FORMAT,
                PlayerUiText.t("字体粗细", "Font weight"),
                0.0,
                8.0,
                1.0,
                { PlayerUiText.parseFontWeight(cfg().gradientStyle).toDouble() },
                { w -> cfg().copy(gradientStyle = PlayerUiText.encodeGradientAndWeight(PlayerUiText.parseGradientPreset(cfg().gradientStyle), Math.round(w).toInt())) },
            ) { PlayerUiText.danmakuFontWeightLabel(Math.round(it).toInt()) },
            SliderRow(Ic.UNFOLD, PlayerUiText.t("行高", "Line height"), 1.0, 2.5, 0.1, { cfg().lineHeight }, { cfg().copy(lineHeight = it) }) { PlayerSettings.num(Math.round(it * 10) / 10.0) },
            SliderRow(Ic.CONTRAST, PlayerUiText.t("不透明度", "Opacity"), 0.1, 1.0, 0.05, { cfg().opacity }, { cfg().copy(opacity = it) }, label = ::pct),
            SliderRow(Ic.COLUMNS, PlayerUiText.t("显示区域", "Area"), 0.1, 1.0, 0.05, { cfg().area }, { cfg().copy(area = it) }, label = ::pct),
            SliderRow(Ic.DOUBLE_RIGHT, PlayerUiText.t("滚动速度", "Scroll speed"), 0.3, 2.0, 0.1, { cfg().scrollSpeed }, { cfg().copy(scrollSpeed = it) }) { PlayerSettings.num(Math.round(it * 10) / 10.0) },
            SliderRow(Ic.BRUSH, PlayerUiText.t("文字描边", "Outline"), 0.0, 3.0, 0.1, { cfg().strokeWidth }, { cfg().copy(strokeWidth = it) }) { PlayerSettings.num(Math.round(it * 10) / 10.0) },
        ))
        sliders(PlayerUiText.t("时间同步", "Timing"), listOf(
            SliderRow(Ic.CLOCK, PlayerUiText.t("弹幕延迟", "Delay"), -30.0, 30.0, 0.5, { cfg().delaySeconds }, { cfg().copy(delaySeconds = it) }, label = PlayerUiText::danmakuDelay),
        ))
        list.addView(View(activity), LinearLayout.LayoutParams(1, ui.dp(12)))
        list.addView(ui.card().also { card ->
            val count = ui.text(PlayerUiText.t("${cfg().blackList.size} 个", "${cfg().blackList.size}"), 12f, PlayerUi.TEXT_DIM)
            val trailing = LinearLayout(activity).apply {
                gravity = Gravity.CENTER_VERTICAL
                addView(count)
                addView(ui.icon(Ic.CHEVRON, 16f, PlayerUi.TEXT_DIM), LinearLayout.LayoutParams(-2, -2).apply { leftMargin = ui.dp(4) })
            }
            ui.addRow(card, ui.row(Ic.CANCEL, PlayerUiText.t("屏蔽词管理", "Blocked words"), null, trailing).also { r ->
                r.setOnClickListener {
                    onHaptic(c, Haptics.SELECTION)
                    subScreen = 3
                    show(c)
                }
            })
        })
    }

    private class SliderRow(
        val icon: Int,
        val title: String,
        val min: Double,
        val max: Double,
        val step: Double,
        val get: () -> Double,
        val set: (Double) -> DanmakuConfig,
        val rotate: Boolean = false,
        val label: (Double) -> String,
    )

    private fun danmakuBlockedWordsView(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        val input = field(ui, "", PlayerUiText.t("输入屏蔽词后点击添加", "Enter blocked word"))
        fun addWord() {
            val w = input.text.toString().trim()
            if (w.isEmpty()) return
            val cur = c.danmakuConfig.blackList
            if (w !in cur) {
                onHaptic(c, Haptics.SELECTION)
                c.updateDanmaku(c.danmakuConfig.copy(blackList = cur + w))
            }
            input.setText("")
            show(c)
        }
        list.addView(LinearLayout(activity).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, ui.dp(8), 0, ui.dp(12))
            addView(input, LinearLayout.LayoutParams(0, ui.dp(38), 1f))
            addView(ui.text(PlayerUiText.t("添加", "Add"), 13f, Color.WHITE, bold = true).apply {
                gravity = Gravity.CENTER
                background = ui.rounded(ui.accent, 10f)
                setPadding(ui.dp(14), 0, ui.dp(14), 0)
                setOnClickListener { addWord() }
            }, LinearLayout.LayoutParams(-2, ui.dp(38)).apply { leftMargin = ui.dp(8) })
        })
        val words = c.danmakuConfig.blackList
        if (words.isEmpty()) {
            list.addView(ui.text(PlayerUiText.t("暂无屏蔽词，命中屏蔽词的弹幕将被过滤", "No blocked words yet"), 12.5f, PlayerUi.TEXT_DIM).apply {
                gravity = Gravity.CENTER
                setPadding(0, ui.dp(32), 0, ui.dp(32))
            })
        } else {
            list.addView(ui.card().also { card ->
                for (w in words) {
                    val del = ui.icon(Ic.CLOSE, 16f, PlayerUi.TEXT_DIM).apply {
                        setPadding(ui.dp(8), ui.dp(6), ui.dp(4), ui.dp(6))
                        setOnClickListener {
                            onHaptic(c, Haptics.SELECTION)
                            c.updateDanmaku(c.danmakuConfig.copy(blackList = words.filterNot { it == w }))
                            show(c)
                        }
                    }
                    ui.addRow(card, ui.row(null, w, null, del))
                }
            })
        }
    }

    private fun danmakuAnimeList(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        list.addView(View(activity), LinearLayout.LayoutParams(1, ui.dp(6)))
        list.addView(ui.card().also { card ->
            for (r in lastAnimeResults) {
                val badge = ui.text(PlayerUiText.t("${r.episodeCount} 集", "${r.episodeCount} eps"), 12f, PlayerUi.TEXT_DIM)
                ui.addRow(card, ui.row(null, r.animeTitle, null, badge).also { row ->
                    row.setOnClickListener {
                        onHaptic(c, Haptics.SELECTION)
                        c.pickDanmakuAnime(r.animeId)
                    }
                })
            }
        })
    }

    private fun danmakuEpisodeList(c: PlayerController, ui: PlayerUi, list: LinearLayout) {
        list.addView(View(activity), LinearLayout.LayoutParams(1, ui.dp(6)))
        list.addView(ui.card().also { card ->
            lastEpisodeResults.forEachIndexed { i, ep ->
                ui.addRow(card, ui.row(null, ep.episodeName, null, null).also { row ->
                    row.setOnClickListener {
                        onHaptic(c, Haptics.SELECTION)
                        subScreen = 0
                        controlsProvider()?.closePanel()
                        c.pickDanmakuEpisode(i)
                        onToast(PlayerUiText.t("已匹配弹幕：${ep.episodeName}", "Danmaku matched"))
                    }
                })
            }
        })
    }
}
