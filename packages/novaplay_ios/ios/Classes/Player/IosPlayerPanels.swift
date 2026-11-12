import UIKit

struct IosPlayerMenuItem {
  let label: String
  var selected: Bool = false
  var dividerBefore: Bool = false
  let onTap: () -> Void
}

/// Hosts anchored `#19191E` dropdown/popup menus (`menuHost`) and translucent `0xAC151515` right/bottom slide-in sheets (`panelHost`).
final class IosPlayerOverlayHost {
  let panelHost = UIView()
  let menuHost = UIView()

  private weak var containerView: UIView?
  private let ui: IosPlayerUi
  private let onHaptic: () -> Void
  private let onWillOpenOverlay: () -> Void
  private let onDidCloseMenu: () -> Void

  var onPanelClosed: (() -> Void)?

  init(
    containerView: UIView,
    ui: IosPlayerUi,
    onHaptic: @escaping () -> Void,
    onWillOpenOverlay: @escaping () -> Void,
    onDidCloseMenu: @escaping () -> Void
  ) {
    self.containerView = containerView
    self.ui = ui
    self.onHaptic = onHaptic
    self.onWillOpenOverlay = onWillOpenOverlay
    self.onDidCloseMenu = onDidCloseMenu

    panelHost.translatesAutoresizingMaskIntoConstraints = false
    panelHost.backgroundColor = .clear
    panelHost.isHidden = true

    menuHost.translatesAutoresizingMaskIntoConstraints = false
    menuHost.backgroundColor = .clear
    menuHost.isHidden = true
  }

  var isMenuOpen: Bool { !menuHost.isHidden }
  var isPanelOpen: Bool { !panelHost.isHidden }

  private var isLandscape: Bool {
    guard let c = containerView else { return true }
    return c.bounds.width > c.bounds.height
  }

  // MARK: - Menus

  func closeMenu() {
    guard !menuHost.isHidden else { return }
    menuHost.subviews.forEach { $0.removeFromSuperview() }
    menuHost.isHidden = true
    onDidCloseMenu()
  }

  func showMenuCard(anchor: UIView, above: Bool, card: UIView) {
    guard let root = containerView else { return }
    onWillOpenOverlay()
    menuHost.subviews.forEach { $0.removeFromSuperview() }

    let backdrop = PlayerTappableView()
    backdrop.backgroundColor = .clear
    backdrop.onTap = { [weak self] in self?.closeMenu() }
    menuHost.addSubview(backdrop)
    NSLayoutConstraint.activate([
      backdrop.leadingAnchor.constraint(equalTo: menuHost.leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: menuHost.trailingAnchor),
      backdrop.topAnchor.constraint(equalTo: menuHost.topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: menuHost.bottomAnchor)
    ])

    card.translatesAutoresizingMaskIntoConstraints = false
    ui.applyRounded(card, fill: IosPlayerUi.menuFill, radius: 16, stroke: IosPlayerUi.argb(0x14FF_FFFF), strokeWidth: 0.6)
    card.layer.shadowColor = UIColor.black.cgColor
    card.layer.shadowOpacity = 0.42
    card.layer.shadowRadius = 12
    card.layer.shadowOffset = CGSize(width: 0, height: 6)
    menuHost.addSubview(card)

    let maxH = max(180, root.bounds.height - 24)
    card.heightAnchor.constraint(lessThanOrEqualToConstant: maxH).isActive = true
    let leftConstraint = card.leadingAnchor.constraint(equalTo: menuHost.leadingAnchor, constant: 8)
    let topConstraint = card.topAnchor.constraint(equalTo: menuHost.topAnchor, constant: 8)
    NSLayoutConstraint.activate([leftConstraint, topConstraint])

    menuHost.isHidden = false
    card.alpha = 0
    menuHost.layoutIfNeeded()

    let anchorRect = anchor.convert(anchor.bounds, to: menuHost)
    let cardSize = card.bounds.size
    let safe = root.safeAreaInsets
    let minX = max(8, safe.left + 6)
    let maxX = max(minX, menuHost.bounds.width - safe.right - cardSize.width - 8)
    let minY = max(8, safe.top + 4)
    let maxY = max(minY, menuHost.bounds.height - safe.bottom - cardSize.height - 8)

    let rawX = above ? (anchorRect.maxX - cardSize.width) : (anchorRect.minX - 2)
    let rawY = above ? (anchorRect.minY - cardSize.height - 7) : (anchorRect.maxY + 7)
    leftConstraint.constant = max(minX, min(maxX, rawX))
    topConstraint.constant = max(minY, min(maxY, rawY))
    menuHost.layoutIfNeeded()

    UIView.animate(withDuration: 0.12) {
      card.alpha = 1
    }
  }

  func showMenu(anchor: UIView, above: Bool, items: [IosPlayerMenuItem]) {
    guard !items.isEmpty else { return }
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsVerticalScrollIndicator = false

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 0
    scroll.addSubview(stack)

    for item in items {
      if item.dividerBefore {
        let sepWrap = UIView()
        sepWrap.translatesAutoresizingMaskIntoConstraints = false
        let sep = UIView()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.backgroundColor = IosPlayerUi.argb(0x1FFF_FFFF)
        sepWrap.addSubview(sep)
        NSLayoutConstraint.activate([
          sep.leadingAnchor.constraint(equalTo: sepWrap.leadingAnchor, constant: 14),
          sep.trailingAnchor.constraint(equalTo: sepWrap.trailingAnchor, constant: -14),
          sep.topAnchor.constraint(equalTo: sepWrap.topAnchor, constant: 4),
          sep.bottomAnchor.constraint(equalTo: sepWrap.bottomAnchor, constant: -4),
          sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale)
        ])
        stack.addArrangedSubview(sepWrap)
      }

      let row = PlayerTappableView()
      let lbl = ui.text(
        item.label,
        size: 14.5,
        color: item.selected ? .white : IosPlayerUi.argb(0xB8FF_FFFF),
        bold: item.selected
      )
      lbl.numberOfLines = 1
      lbl.lineBreakMode = .byTruncatingTail
      lbl.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true

      let hStack = UIStackView()
      hStack.translatesAutoresizingMaskIntoConstraints = false
      hStack.axis = .horizontal
      hStack.alignment = .center
      hStack.spacing = 18
      hStack.isUserInteractionEnabled = false
      hStack.addArrangedSubview(lbl)
      if item.selected {
        hStack.addArrangedSubview(ui.icon(IosPlayerIcon.CHECK, size: 15, color: ui.accent))
      }
      row.addSubview(hStack)
      NSLayoutConstraint.activate([
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        row.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
        hStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18),
        hStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
        hStack.centerYAnchor.constraint(equalTo: row.centerYAnchor)
      ])
      row.onTap = { [weak self] in
        guard let self = self else { return }
        self.closeMenu()
        self.onHaptic()
        item.onTap()
      }
      stack.addArrangedSubview(row)
    }

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
    ])
    let hMatch = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 8)
    hMatch.priority = .defaultHigh
    hMatch.isActive = true

    let card = UIView()
    card.clipsToBounds = true
    card.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: card.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor)
    ])
    showMenuCard(anchor: anchor, above: above, card: card)
  }

  private func fillSpeedRows(_ rowsStack: UIStackView, value: Double, onPick: @escaping (Double) -> Void) {
    rowsStack.arrangedSubviews.forEach {
      rowsStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    for s in IosPlayerUiText.speeds.reversed() {
      let sel = abs(s - value) < 0.001
      let row = PlayerTappableView()
      if sel {
        ui.applyRounded(row, fill: IosPlayerUi.withAlpha(ui.accent, 0.22), radius: 8)
      }
      let checkSlot = UIView()
      checkSlot.translatesAutoresizingMaskIntoConstraints = false
      checkSlot.isUserInteractionEnabled = false
      NSLayoutConstraint.activate([
        checkSlot.widthAnchor.constraint(equalToConstant: 12),
        checkSlot.heightAnchor.constraint(equalToConstant: 12)
      ])
      if sel {
        let ck = ui.icon(IosPlayerIcon.CHECK, size: 12, color: ui.accent)
        checkSlot.addSubview(ck)
        NSLayoutConstraint.activate([
          ck.centerXAnchor.constraint(equalTo: checkSlot.centerXAnchor),
          ck.centerYAnchor.constraint(equalTo: checkSlot.centerYAnchor)
        ])
      }
      let lbl = ui.text(IosPlayerUiText.speedMenuLabel(s), size: 13, color: sel ? ui.accent : .white, mono: true)
      let h = UIStackView(arrangedSubviews: [checkSlot, lbl])
      h.translatesAutoresizingMaskIntoConstraints = false
      h.axis = .horizontal
      h.alignment = .center
      h.spacing = 8
      h.isUserInteractionEnabled = false
      row.addSubview(h)
      NSLayoutConstraint.activate([
        row.heightAnchor.constraint(equalToConstant: 32),
        h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
        h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
        h.centerYAnchor.constraint(equalTo: row.centerYAnchor)
      ])
      row.onTap = { [weak self] in
        guard let self = self else { return }
        self.onHaptic()
        onPick(s)
        self.closeMenu()
      }
      rowsStack.addArrangedSubview(row)
    }
  }

  /// 2-column Speed Menu (`VerticalFillSliderView` on left + `3.0x..0.5x` presets + hairline + `1.0x 常速` footer on right).
  func showSpeedMenu(anchor: UIView, current: Double, onPick: @escaping (Double) -> Void) {
    let footer = ui.text(IosPlayerUiText.speedOption(current), size: 12.5, color: IosPlayerUi.textDim)
    footer.textAlignment = .center

    let rowsStack = UIStackView()
    rowsStack.translatesAutoresizingMaskIntoConstraints = false
    rowsStack.axis = .vertical
    rowsStack.alignment = .fill
    rowsStack.spacing = 0

    let initialFraction = CGFloat(max(0, min(1, (current - 0.5) / 2.5)))

    weak var sliderRef: VerticalFillSliderView?
    let slider = VerticalFillSliderView(accent: ui.accent) { [weak self, weak rowsStack, weak footer] f, done in
      let v = ((0.5 + Double(f) * 2.5) * 10.0).rounded() / 10.0
      sliderRef?.topLabel = IosPlayerUiText.speed(v)
      footer?.text = IosPlayerUiText.speedOption(v)
      if let self = self, let rs = rowsStack {
        self.fillSpeedRows(rs, value: v, onPick: onPick)
      }
      if done {
        onPick(v)
      }
    }
    sliderRef = slider
    slider.fraction = initialFraction
    slider.topLabel = IosPlayerUiText.speed(current)
    slider.bottomLabel = "0.5"
    fillSpeedRows(rowsStack, value: current, onPick: onPick)

    let sep = UIView()
    sep.translatesAutoresizingMaskIntoConstraints = false
    sep.backgroundColor = IosPlayerUi.argb(0x1FFF_FFFF)
    sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true

    let footerWrap = UIView()
    footerWrap.translatesAutoresizingMaskIntoConstraints = false
    footerWrap.addSubview(footer)
    NSLayoutConstraint.activate([
      footer.leadingAnchor.constraint(equalTo: footerWrap.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: footerWrap.trailingAnchor),
      footer.centerYAnchor.constraint(equalTo: footerWrap.centerYAnchor)
    ])

    let rightCol = UIStackView(arrangedSubviews: [rowsStack, sep, footerWrap])
    rightCol.translatesAutoresizingMaskIntoConstraints = false
    rightCol.axis = .vertical
    rightCol.alignment = .fill
    rightCol.spacing = 4
    rowsStack.widthAnchor.constraint(equalToConstant: 128).isActive = true

    let card = UIView()
    card.addSubview(slider)
    card.addSubview(rightCol)
    NSLayoutConstraint.activate([
      slider.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
      slider.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
      slider.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
      slider.widthAnchor.constraint(equalToConstant: 34),
      slider.heightAnchor.constraint(equalToConstant: 254),
      rightCol.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
      rightCol.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
      rightCol.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
      rightCol.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
    ])

    showMenuCard(anchor: anchor, above: true, card: card)
  }

  // MARK: - Slide-in Panels

  func closePanel() {
    guard !panelHost.isHidden else { return }
    closeMenu()
    panelHost.subviews.forEach { $0.removeFromSuperview() }
    panelHost.isHidden = true
    let cb = onPanelClosed
    onPanelClosed = nil
    cb?()
  }

  @discardableResult
  func showPanel(header: UIView? = nil, buildBody: (UIStackView) -> Void) -> UIScrollView {
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.showsVerticalScrollIndicator = true
    scroll.indicatorStyle = .white
    scroll.keyboardDismissMode = .onDrag

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 0
    buildBody(stack)
    scroll.addSubview(stack)

    let safeRight = isLandscape ? (containerView?.safeAreaInsets.right ?? 0) : 0
    let safeBottom = containerView?.safeAreaInsets.bottom ?? 0
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -(16 + safeRight * 0.5)),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -(20 + safeBottom)),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -(32 + safeRight * 0.5))
    ])

    showCustomPanel(header: header, content: scroll)
    return scroll
  }

  func showCustomPanel(header: UIView? = nil, content: UIView) {
    guard let root = containerView else { return }
    onWillOpenOverlay()
    closeMenu()
    panelHost.subviews.forEach { $0.removeFromSuperview() }

    let backdrop = PlayerTappableView()
    backdrop.backgroundColor = .clear
    backdrop.onTap = { [weak self] in self?.closePanel() }
    panelHost.addSubview(backdrop)
    NSLayoutConstraint.activate([
      backdrop.leadingAnchor.constraint(equalTo: panelHost.leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: panelHost.trailingAnchor),
      backdrop.topAnchor.constraint(equalTo: panelHost.topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: panelHost.bottomAnchor)
    ])

    let land = isLandscape
    let sheet = UIView()
    sheet.translatesAutoresizingMaskIntoConstraints = false
    sheet.backgroundColor = IosPlayerUi.panelFill
    sheet.clipsToBounds = true
    sheet.layer.cornerRadius = 16
    sheet.layer.cornerCurve = .continuous
    if land {
      sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
    } else {
      sheet.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    content.translatesAutoresizingMaskIntoConstraints = false
    if let header = header {
      header.translatesAutoresizingMaskIntoConstraints = false
      sheet.addSubview(header)
      sheet.addSubview(content)
      NSLayoutConstraint.activate([
        header.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
        header.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
        header.topAnchor.constraint(equalTo: sheet.topAnchor),
        content.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
        content.topAnchor.constraint(equalTo: header.bottomAnchor),
        content.bottomAnchor.constraint(equalTo: sheet.bottomAnchor)
      ])
    } else {
      sheet.addSubview(content)
      NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
        content.topAnchor.constraint(equalTo: sheet.topAnchor, constant: 6),
        content.bottomAnchor.constraint(equalTo: sheet.bottomAnchor)
      ])
    }

    panelHost.addSubview(sheet)
    if land {
      let w = min(root.bounds.width, max(300, floor(root.bounds.width * 0.44)))
      NSLayoutConstraint.activate([
        sheet.trailingAnchor.constraint(equalTo: panelHost.trailingAnchor),
        sheet.topAnchor.constraint(equalTo: panelHost.topAnchor),
        sheet.bottomAnchor.constraint(equalTo: panelHost.bottomAnchor),
        sheet.widthAnchor.constraint(equalToConstant: w)
      ])
    } else {
      let h = max(280, floor(root.bounds.height * 0.526))
      NSLayoutConstraint.activate([
        sheet.leadingAnchor.constraint(equalTo: panelHost.leadingAnchor),
        sheet.trailingAnchor.constraint(equalTo: panelHost.trailingAnchor),
        sheet.bottomAnchor.constraint(equalTo: panelHost.bottomAnchor),
        sheet.heightAnchor.constraint(equalToConstant: h)
      ])
    }

    panelHost.isHidden = false
    panelHost.layoutIfNeeded()
    sheet.alpha = 0
    sheet.transform = land ? CGAffineTransform(translationX: 40, y: 0) : CGAffineTransform(translationX: 0, y: 40)
    UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut]) {
      sheet.alpha = 1
      sheet.transform = .identity
    }
  }
}

// MARK: - Panel Builders (选集 / 频道列表 / 节目单 / 弹幕 / 播放设置)

final class IosPlayerPanels {
  private unowned let controller: IosPlayerController
  private let ui: IosPlayerUi
  private let host: IosPlayerOverlayHost
  private let onHaptic: () -> Void
  private let onShowToast: (String, Bool) -> Void
  private let onOrientationPreferenceChanged: (Bool) -> Void

  // Episode panel state
  private var episodesReversed = false
  private var episodesSearching = false
  private var episodesQuery = ""
  private var episodesTmdbMode = true

  // Danmaku panel state
  private var danmakuTab = 0 // 0 = 弹幕设置, 1 = 样式调节
  private var danmakuSubScreen = 0 // 0 = tabs, 1 = anime results, 2 = episode results, 3 = blocked words
  private var danmakuDirectEpisodeIdx: Int?
  private var lastAnimeResults: [DanmakuSearchResultItem] = []
  private var lastEpisodeResults: [EpisodeItem] = []
  private weak var danmakuCountBadge: PlayerInsetLabel?
  private weak var danmakuStatusLabel: UILabel?

  private static let tmdbImageCache = NSCache<NSString, UIImage>()

  init(
    controller: IosPlayerController,
    ui: IosPlayerUi,
    host: IosPlayerOverlayHost,
    onHaptic: @escaping () -> Void,
    onShowToast: @escaping (String, Bool) -> Void,
    onOrientationPreferenceChanged: @escaping (Bool) -> Void
  ) {
    self.controller = controller
    self.ui = ui
    self.host = host
    self.onHaptic = onHaptic
    self.onShowToast = onShowToast
    self.onOrientationPreferenceChanged = onOrientationPreferenceChanged

    controller.danmakuSearchListener = { [weak self] results in
      self?.handleDanmakuSearchResults(results)
    }
    controller.danmakuEpisodesListener = { [weak self] episodes in
      self?.handleDanmakuEpisodes(episodes)
    }
    controller.danmakuCountListener = { [weak self] count in
      self?.refreshDanmakuLiveCount(count)
    }
  }

  // MARK: - 1. 选集 & 直播频道列表

  func showEpisodesOrChannels() {
    if controller.isLive {
      showLiveChannels(shownGroup: controller.line)
    } else {
      showEpisodes(shownLine: controller.line)
    }
  }

  @discardableResult
  private func populateEpisodeRows(
    into container: UIStackView,
    names: [String],
    tmdbList: [TmdbEpisodeItem],
    useTmdb: Bool,
    shownLine: Int
  ) -> UIView? {
    container.arrangedSubviews.forEach {
      container.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    var currentRow: UIView?
    let q = episodesQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let baseIndices = Array(names.indices)
    let indices = episodesReversed ? Array(baseIndices.reversed()) : baseIndices

    for i in indices {
      let name = names[i]
      let tmdb = tmdbList.first(where: { Int($0.episodeNumber) == i + 1 }) ?? (i < tmdbList.count ? tmdbList[i] : nil)
      if !q.isEmpty {
        let matchName = name.lowercased().contains(q)
        let matchTmdb = tmdb.map {
          $0.episodeName.lowercased().contains(q)
            || ($0.overview ?? "").lowercased().contains(q)
            || "e\($0.episodeNumber)".contains(q)
        } ?? false
        if !matchName && !matchTmdb && !"\(i + 1)".contains(q) {
          continue
        }
      }
      let playing = (shownLine == controller.line && i == controller.episode)
      let row: PlayerTappableView
      if useTmdb, let tmdb = tmdb {
        row = buildTmdbEpisodeRow(index: i, fallbackName: name, tmdb: tmdb, playing: playing, shownLine: shownLine)
      } else {
        row = buildStandardEpisodeRow(index: i, name: name, playing: playing, shownLine: shownLine)
      }
      if playing {
        currentRow = row
      }
      container.addArrangedSubview(row)
    }
    return currentRow
  }

  private func showEpisodes(shownLine: Int) {
    let lines = controller.lineNames()
    let names = controller.episodeNames(forLine: shownLine)
    let tmdbList = controller.tmdbMatches
    let useTmdb = episodesTmdbMode && !tmdbList.isEmpty

    weak var currentRowRef: UIView?
    weak var scrollRef: UIScrollView?
    weak var listStackRef: UIStackView?

    let header = UIView()
    let headerStack = UIStackView()
    headerStack.translatesAutoresizingMaskIntoConstraints = false
    headerStack.axis = .vertical
    headerStack.alignment = .fill
    headerStack.spacing = 8
    header.addSubview(headerStack)
    NSLayoutConstraint.activate([
      headerStack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      headerStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
      headerStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
      headerStack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -8)
    ])

    let actionsRow = UIStackView()
    actionsRow.axis = .horizontal
    actionsRow.alignment = .center
    actionsRow.spacing = 8
    let leadingTitle = ui.text(
      IosPlayerUiText.t("剧集选集（\(names.count)）", "Episodes (\(names.count))"),
      size: 14.5,
      bold: true
    )
    actionsRow.addArrangedSubview(leadingTitle)
    let spacer = UIView()
    actionsRow.addArrangedSubview(spacer)

    func addActionCircle(_ code: Int, active: Bool = false, action: @escaping () -> Void) {
      let btn = ui.circleButton(
        code,
        size: 30,
        iconSize: 17,
        fill: active ? IosPlayerUi.withAlpha(ui.accent, 0.24) : IosPlayerUi.argb(0x33FF_FFFF),
        stroke: nil,
        iconColor: active ? ui.accent : .white
      ) { [weak self] in
        self?.onHaptic()
        action()
      }
      actionsRow.addArrangedSubview(btn)
    }

    if !tmdbList.isEmpty {
      addActionCircle(useTmdb ? IosPlayerIcon.AUTO_AWESOME : IosPlayerIcon.MENU, active: useTmdb) { [weak self] in
        guard let self = self else { return }
        self.episodesTmdbMode.toggle()
        self.showEpisodes(shownLine: shownLine)
      }
    }
    if names.count > 1 {
      addActionCircle(episodesSearching ? IosPlayerIcon.CANCEL : IosPlayerIcon.SEARCH, active: episodesSearching) { [weak self] in
        guard let self = self else { return }
        self.episodesSearching.toggle()
        if !self.episodesSearching { self.episodesQuery = "" }
        self.showEpisodes(shownLine: shownLine)
      }
    }
    addActionCircle(IosPlayerIcon.LOCATE) {
      guard let row = currentRowRef, let sc = scrollRef else { return }
      let targetY = max(0, min(sc.contentSize.height - sc.bounds.height, row.frame.minY - 8))
      sc.setContentOffset(CGPoint(x: 0, y: max(0, targetY)), animated: true)
    }
    if names.count > 1 {
      addActionCircle(IosPlayerIcon.SWAP_VERT, active: episodesReversed) { [weak self] in
        guard let self = self else { return }
        self.episodesReversed.toggle()
        self.showEpisodes(shownLine: shownLine)
      }
    }
    headerStack.addArrangedSubview(actionsRow)

    if lines.count > 1 {
      let lineScroll = UIScrollView()
      lineScroll.translatesAutoresizingMaskIntoConstraints = false
      lineScroll.showsHorizontalScrollIndicator = false
      lineScroll.heightAnchor.constraint(equalToConstant: 30).isActive = true

      let lineRow = UIStackView()
      lineRow.translatesAutoresizingMaskIntoConstraints = false
      lineRow.axis = .horizontal
      lineRow.alignment = .center
      lineRow.spacing = 8
      lineScroll.addSubview(lineRow)
      NSLayoutConstraint.activate([
        lineRow.leadingAnchor.constraint(equalTo: lineScroll.contentLayoutGuide.leadingAnchor),
        lineRow.trailingAnchor.constraint(equalTo: lineScroll.contentLayoutGuide.trailingAnchor),
        lineRow.topAnchor.constraint(equalTo: lineScroll.contentLayoutGuide.topAnchor),
        lineRow.bottomAnchor.constraint(equalTo: lineScroll.contentLayoutGuide.bottomAnchor),
        lineRow.heightAnchor.constraint(equalTo: lineScroll.frameLayoutGuide.heightAnchor)
      ])
      for (idx, lineLabel) in lines.enumerated() {
        let sel = (idx == shownLine)
        let chip = PlayerTappableView()
        ui.applyRounded(
          chip,
          fill: sel ? IosPlayerUi.withAlpha(ui.accent, 0.26) : IosPlayerUi.argb(0x24FF_FFFF),
          radius: 14
        )
        let lbl = ui.text(lineLabel, size: 13.5, color: sel ? ui.accent : .white, bold: sel)
        lbl.isUserInteractionEnabled = false
        chip.addSubview(lbl)
        NSLayoutConstraint.activate([
          chip.heightAnchor.constraint(equalToConstant: 28),
          lbl.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 13),
          lbl.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -13),
          lbl.centerYAnchor.constraint(equalTo: chip.centerYAnchor)
        ])
        chip.onTap = { [weak self] in
          guard let self = self else { return }
          self.onHaptic()
          self.showEpisodes(shownLine: idx)
        }
        lineRow.addArrangedSubview(chip)
      }
      headerStack.addArrangedSubview(lineScroll)
    }

    if episodesSearching {
      let tf = ui.textField(
        text: episodesQuery,
        placeholder: IosPlayerUiText.t("搜索剧集名称...", "Search episodes...")
      )
      tf.heightAnchor.constraint(equalToConstant: 36).isActive = true
      tf.onTextChanged = { [weak self] nextText in
        guard let self = self else { return }
        self.episodesQuery = nextText
        if let st = listStackRef {
          currentRowRef = self.populateEpisodeRows(
            into: st,
            names: names,
            tmdbList: tmdbList,
            useTmdb: useTmdb,
            shownLine: shownLine
          )
        }
      }
      headerStack.addArrangedSubview(tf)
    }

    let scroll = host.showPanel(header: header) { [weak self] body in
      body.spacing = 8
      listStackRef = body
      currentRowRef = self?.populateEpisodeRows(
        into: body,
        names: names,
        tmdbList: tmdbList,
        useTmdb: useTmdb,
        shownLine: shownLine
      )
    }
    scrollRef = scroll
    DispatchQueue.main.async {
      scroll.layoutIfNeeded()
      if let row = currentRowRef {
        let maxOff = max(0, scroll.contentSize.height - scroll.bounds.height)
        let targetY = max(0, min(maxOff, row.frame.minY - 8))
        scroll.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
      }
    }
  }

  private func buildTmdbEpisodeRow(
    index: Int,
    fallbackName: String,
    tmdb: TmdbEpisodeItem,
    playing: Bool,
    shownLine: Int
  ) -> PlayerTappableView {
    let row = PlayerTappableView()
    if playing {
      ui.applyRounded(
        row,
        fill: IosPlayerUi.withAlpha(ui.accent, 0.14),
        radius: 12,
        stroke: IosPlayerUi.withAlpha(ui.accent, 0.75),
        strokeWidth: 1
      )
    } else {
      ui.applyRounded(row, fill: IosPlayerUi.argb(0x12FF_FFFF), radius: 12)
    }

    let thumbBox = UIView()
    thumbBox.translatesAutoresizingMaskIntoConstraints = false
    thumbBox.clipsToBounds = true
    thumbBox.isUserInteractionEnabled = false
    ui.applyRounded(thumbBox, fill: IosPlayerUi.argb(0x24FF_FFFF), radius: 8)
    let movieIcon = ui.icon(IosPlayerIcon.MOVIE, size: 22, color: IosPlayerUi.argb(0x55FF_FFFF))
    thumbBox.addSubview(movieIcon)

    let stillImage = UIImageView()
    stillImage.translatesAutoresizingMaskIntoConstraints = false
    stillImage.contentMode = .scaleAspectFill
    stillImage.clipsToBounds = true
    thumbBox.addSubview(stillImage)
    if let rawStill = tmdb.stillPath, !rawStill.isEmpty {
      let fullUrl = rawStill.hasPrefix("http") ? rawStill : "https://image.tmdb.org/t/p/w300\(rawStill)"
      loadTmdbStill(urlString: fullUrl, into: stillImage)
    }

    let epBadge = PlayerInsetLabel(insets: UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5))
    epBadge.translatesAutoresizingMaskIntoConstraints = false
    epBadge.text = "E\(tmdb.episodeNumber)"
    epBadge.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
    epBadge.textColor = .white
    epBadge.clipsToBounds = true
    ui.applyRounded(epBadge, fill: IosPlayerUi.argb(0xB300_0000), radius: 5)
    thumbBox.addSubview(epBadge)

    NSLayoutConstraint.activate([
      thumbBox.widthAnchor.constraint(equalToConstant: 96),
      thumbBox.heightAnchor.constraint(equalToConstant: 56),
      movieIcon.centerXAnchor.constraint(equalTo: thumbBox.centerXAnchor),
      movieIcon.centerYAnchor.constraint(equalTo: thumbBox.centerYAnchor),
      stillImage.leadingAnchor.constraint(equalTo: thumbBox.leadingAnchor),
      stillImage.trailingAnchor.constraint(equalTo: thumbBox.trailingAnchor),
      stillImage.topAnchor.constraint(equalTo: thumbBox.topAnchor),
      stillImage.bottomAnchor.constraint(equalTo: thumbBox.bottomAnchor),
      epBadge.leadingAnchor.constraint(equalTo: thumbBox.leadingAnchor, constant: 5),
      epBadge.topAnchor.constraint(equalTo: thumbBox.topAnchor, constant: 5)
    ])

    let displayTitle = tmdb.episodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : tmdb.episodeName
    let titleLbl = ui.text(displayTitle, size: 14, color: playing ? ui.accent : .white, bold: true)
    titleLbl.numberOfLines = 1
    titleLbl.lineBreakMode = .byTruncatingTail

    let topRow = UIStackView(arrangedSubviews: [titleLbl])
    topRow.axis = .horizontal
    topRow.alignment = .center
    topRow.spacing = 8
    if playing {
      topRow.addArrangedSubview(playingBadge())
    }

    let descText = (tmdb.overview?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
    let descLbl = ui.text(descText, size: 11.5, color: IosPlayerUi.textDim)
    descLbl.numberOfLines = 2
    descLbl.lineBreakMode = .byTruncatingTail

    let textCol = UIStackView(arrangedSubviews: [topRow, descLbl])
    textCol.axis = .vertical
    textCol.alignment = .fill
    textCol.spacing = 4
    textCol.isUserInteractionEnabled = false

    let mainRow = UIStackView(arrangedSubviews: [thumbBox, textCol])
    mainRow.translatesAutoresizingMaskIntoConstraints = false
    mainRow.axis = .horizontal
    mainRow.alignment = .center
    mainRow.spacing = 12
    mainRow.isUserInteractionEnabled = false
    row.addSubview(mainRow)
    NSLayoutConstraint.activate([
      mainRow.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
      mainRow.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
      mainRow.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
      mainRow.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10)
    ])

    row.onTap = { [weak self] in
      guard let self = self else { return }
      self.onHaptic()
      self.host.closePanel()
      if shownLine != self.controller.line || !playing {
        self.controller.selectLineEpisode(lineIndex: shownLine, episodeIndex: index)
      }
    }
    return row
  }

  private func buildStandardEpisodeRow(
    index: Int,
    name: String,
    playing: Bool,
    shownLine: Int
  ) -> PlayerTappableView {
    let row = PlayerTappableView()
    if playing {
      ui.applyRounded(
        row,
        fill: IosPlayerUi.withAlpha(ui.accent, 0.14),
        radius: 12,
        stroke: IosPlayerUi.withAlpha(ui.accent, 0.75),
        strokeWidth: 1
      )
    } else {
      ui.applyRounded(row, fill: IosPlayerUi.argb(0x12FF_FFFF), radius: 12)
    }

    let numBox = UILabel()
    numBox.translatesAutoresizingMaskIntoConstraints = false
    numBox.text = "\(index + 1)"
    numBox.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    numBox.textColor = .white
    numBox.textAlignment = .center
    numBox.clipsToBounds = true
    ui.applyRounded(numBox, fill: playing ? ui.accent : IosPlayerUi.argb(0x24FF_FFFF), radius: 8)
    NSLayoutConstraint.activate([
      numBox.widthAnchor.constraint(equalToConstant: 32),
      numBox.heightAnchor.constraint(equalToConstant: 32)
    ])

    let nameLbl = ui.text(name, size: 14.5, color: playing ? ui.accent : .white, bold: playing)
    nameLbl.numberOfLines = 2
    nameLbl.lineBreakMode = .byTruncatingTail

    let h = UIStackView(arrangedSubviews: [numBox, nameLbl])
    h.translatesAutoresizingMaskIntoConstraints = false
    h.axis = .horizontal
    h.alignment = .center
    h.spacing = 12
    h.isUserInteractionEnabled = false
    if playing {
      h.addArrangedSubview(playingBadge())
    }
    row.addSubview(h)
    NSLayoutConstraint.activate([
      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
      h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
      h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
      h.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
      h.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -8)
    ])

    row.onTap = { [weak self] in
      guard let self = self else { return }
      self.onHaptic()
      self.host.closePanel()
      if shownLine != self.controller.line || !playing {
        self.controller.selectLineEpisode(lineIndex: shownLine, episodeIndex: index)
      }
    }
    return row
  }

  private func playingBadge(text: String? = nil) -> PlayerInsetLabel {
    let b = PlayerInsetLabel(insets: UIEdgeInsets(top: 2.5, left: 7, bottom: 2.5, right: 7))
    b.translatesAutoresizingMaskIntoConstraints = false
    b.text = text ?? IosPlayerUiText.t("播放中", "Playing")
    b.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
    b.textColor = ui.accent
    b.clipsToBounds = true
    ui.applyRounded(
      b,
      fill: IosPlayerUi.withAlpha(ui.accent, 0.12),
      radius: 9,
      stroke: IosPlayerUi.withAlpha(ui.accent, 0.6),
      strokeWidth: 0.6
    )
    b.setContentHuggingPriority(.required, for: .horizontal)
    b.setContentCompressionResistancePriority(.required, for: .horizontal)
    return b
  }

  private func loadTmdbStill(urlString: String, into imageView: UIImageView) {
    let key = urlString as NSString
    if let cached = Self.tmdbImageCache.object(forKey: key) {
      imageView.image = cached
      return
    }
    guard let url = URL(string: urlString) else { return }
    URLSession.shared.dataTask(with: url) { [weak imageView] data, _, _ in
      guard let data = data, let img = UIImage(data: data) else { return }
      Self.tmdbImageCache.setObject(img, forKey: key)
      DispatchQueue.main.async {
        imageView?.image = img
      }
    }.resume()
  }

  /// 2-column Live TV `频道列表` (`108pt` groups column + `1pt` divider + channels column).
  private func showLiveChannels(shownGroup: Int) {
    let groups = controller.lineNames()
    let groupIdx = max(0, min(max(0, groups.count - 1), shownGroup))
    let channels = controller.episodeNames(forLine: groupIdx)
    let totalCount = groups.indices.reduce(0) { $0 + controller.episodeNames(forLine: $1).count }

    let header = UIView()
    let titleLbl = ui.text(IosPlayerUiText.t("频道列表", "Channels"), size: 15, bold: true)
    let countLbl = ui.text(
      IosPlayerUiText.t("共 \(max(totalCount, channels.count)) 个频道", "\(max(totalCount, channels.count)) channels"),
      size: 12,
      color: IosPlayerUi.textDim
    )
    header.addSubview(titleLbl)
    header.addSubview(countLbl)
    NSLayoutConstraint.activate([
      titleLbl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      titleLbl.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
      titleLbl.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),
      countLbl.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
      countLbl.centerYAnchor.constraint(equalTo: titleLbl.centerYAnchor)
    ])

    var activeGroupView: UIView?
    var activeChannelView: UIView?

    let groupScroll = UIScrollView()
    groupScroll.translatesAutoresizingMaskIntoConstraints = false
    groupScroll.showsVerticalScrollIndicator = false
    let groupStack = UIStackView()
    groupStack.translatesAutoresizingMaskIntoConstraints = false
    groupStack.axis = .vertical
    groupStack.alignment = .fill
    groupStack.spacing = 4
    groupScroll.addSubview(groupStack)
    NSLayoutConstraint.activate([
      groupStack.leadingAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.leadingAnchor, constant: 8),
      groupStack.trailingAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.trailingAnchor, constant: -8),
      groupStack.topAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.topAnchor, constant: 6),
      groupStack.bottomAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.bottomAnchor, constant: -14),
      groupStack.widthAnchor.constraint(equalTo: groupScroll.frameLayoutGuide.widthAnchor, constant: -16)
    ])
    for (idx, gName) in groups.enumerated() {
      let sel = (idx == groupIdx)
      let row = PlayerTappableView()
      if sel {
        ui.applyRounded(row, fill: IosPlayerUi.withAlpha(ui.accent, 0.22), radius: 10)
      }
      let lbl = ui.text(gName, size: 13, color: sel ? ui.accent : IosPlayerUi.argb(0xB3FF_FFFF), bold: sel)
      lbl.numberOfLines = 1
      lbl.lineBreakMode = .byTruncatingTail
      lbl.isUserInteractionEnabled = false
      row.addSubview(lbl)
      NSLayoutConstraint.activate([
        lbl.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
        lbl.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
        lbl.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
        lbl.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9)
      ])
      row.onTap = { [weak self] in
        guard let self = self, idx != groupIdx else { return }
        self.onHaptic()
        self.showLiveChannels(shownGroup: idx)
      }
      if sel { activeGroupView = row }
      groupStack.addArrangedSubview(row)
    }

    let channelScroll = UIScrollView()
    channelScroll.translatesAutoresizingMaskIntoConstraints = false
    channelScroll.showsVerticalScrollIndicator = true
    channelScroll.indicatorStyle = .white
    let channelStack = UIStackView()
    channelStack.translatesAutoresizingMaskIntoConstraints = false
    channelStack.axis = .vertical
    channelStack.alignment = .fill
    channelStack.spacing = 6
    channelScroll.addSubview(channelStack)
    NSLayoutConstraint.activate([
      channelStack.leadingAnchor.constraint(equalTo: channelScroll.contentLayoutGuide.leadingAnchor, constant: 10),
      channelStack.trailingAnchor.constraint(equalTo: channelScroll.contentLayoutGuide.trailingAnchor, constant: -12),
      channelStack.topAnchor.constraint(equalTo: channelScroll.contentLayoutGuide.topAnchor, constant: 6),
      channelStack.bottomAnchor.constraint(equalTo: channelScroll.contentLayoutGuide.bottomAnchor, constant: -14),
      channelStack.widthAnchor.constraint(equalTo: channelScroll.frameLayoutGuide.widthAnchor, constant: -22)
    ])

    for (idx, cName) in channels.enumerated() {
      let playing = (groupIdx == controller.line && idx == controller.episode)
      let row = PlayerTappableView()
      if playing {
        ui.applyRounded(
          row,
          fill: IosPlayerUi.withAlpha(ui.accent, 0.16),
          radius: 10,
          stroke: IosPlayerUi.withAlpha(ui.accent, 0.65),
          strokeWidth: 1
        )
      } else {
        ui.applyRounded(row, fill: IosPlayerUi.argb(0x10FF_FFFF), radius: 10)
      }
      let idxLbl = ui.text("\(idx + 1)", size: 12, color: playing ? ui.accent : IosPlayerUi.textDim, mono: true)
      idxLbl.widthAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
      let nameLbl = ui.text(cName, size: 14, color: playing ? ui.accent : .white, bold: playing)
      nameLbl.numberOfLines = 1
      nameLbl.lineBreakMode = .byTruncatingTail

      let h = UIStackView(arrangedSubviews: [idxLbl, nameLbl])
      h.translatesAutoresizingMaskIntoConstraints = false
      h.axis = .horizontal
      h.alignment = .center
      h.spacing = 6
      h.isUserInteractionEnabled = false
      if playing {
        h.addArrangedSubview(playingBadge(text: IosPlayerUiText.t("播放中", "LIVE")))
      }
      row.addSubview(h)
      NSLayoutConstraint.activate([
        h.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
        h.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
        h.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
        h.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10)
      ])
      row.onTap = { [weak self] in
        guard let self = self else { return }
        self.onHaptic()
        self.host.closePanel()
        if groupIdx != self.controller.line || !playing {
          self.controller.selectLineEpisode(lineIndex: groupIdx, episodeIndex: idx)
        }
      }
      if playing { activeChannelView = row }
      channelStack.addArrangedSubview(row)
    }

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    if groups.count > 1 {
      let divider = UIView()
      divider.translatesAutoresizingMaskIntoConstraints = false
      divider.backgroundColor = IosPlayerUi.argb(0x14FF_FFFF)
      container.addSubview(groupScroll)
      container.addSubview(divider)
      container.addSubview(channelScroll)
      NSLayoutConstraint.activate([
        groupScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        groupScroll.topAnchor.constraint(equalTo: container.topAnchor),
        groupScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        groupScroll.widthAnchor.constraint(equalToConstant: 108),
        divider.leadingAnchor.constraint(equalTo: groupScroll.trailingAnchor),
        divider.topAnchor.constraint(equalTo: container.topAnchor),
        divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        divider.widthAnchor.constraint(equalToConstant: 1),
        channelScroll.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
        channelScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        channelScroll.topAnchor.constraint(equalTo: container.topAnchor),
        channelScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
      ])
    } else {
      container.addSubview(channelScroll)
      NSLayoutConstraint.activate([
        channelScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        channelScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        channelScroll.topAnchor.constraint(equalTo: container.topAnchor),
        channelScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
      ])
    }

    host.showCustomPanel(header: header, content: container)
    DispatchQueue.main.async {
      container.layoutIfNeeded()
      if let gv = activeGroupView {
        let maxOff = max(0, groupScroll.contentSize.height - groupScroll.bounds.height)
        groupScroll.setContentOffset(CGPoint(x: 0, y: max(0, min(maxOff, gv.frame.minY - 16))), animated: false)
      }
      if let cv = activeChannelView {
        let maxOff = max(0, channelScroll.contentSize.height - channelScroll.bounds.height)
        channelScroll.setContentOffset(CGPoint(x: 0, y: max(0, min(maxOff, cv.frame.minY - 16))), animated: false)
      }
    }
  }

  // MARK: - 2. 节目单 (EPG)

  func showEpg() {
    let programmes = controller.epgProgrammes
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.dateFormat = "HH:mm"
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000.0)

    let header = UIView()
    let titleLbl = ui.text(IosPlayerUiText.t("节目单", "EPG"), size: 15, bold: true)
    header.addSubview(titleLbl)
    NSLayoutConstraint.activate([
      titleLbl.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
      titleLbl.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
      titleLbl.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10)
    ])
    if !programmes.isEmpty {
      let badge = ui.valueBadge(IosPlayerUiText.t("\(programmes.count) 档", "\(programmes.count)"))
      header.addSubview(badge)
      NSLayoutConstraint.activate([
        badge.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
        badge.centerYAnchor.constraint(equalTo: titleLbl.centerYAnchor)
      ])
    }

    var liveRow: UIView?
    let scroll = host.showPanel(header: header) { list in
      list.spacing = 8
      if programmes.isEmpty {
        let empty = ui.text(IosPlayerUiText.t("暂无节目单", "No EPG data"), size: 13, color: IosPlayerUi.textDim)
        empty.textAlignment = .center
        empty.heightAnchor.constraint(equalToConstant: 100).isActive = true
        list.addArrangedSubview(empty)
        return
      }
      for p in programmes {
        let live = (nowMs >= p.startEpochMs && nowMs < p.endEpochMs)
        let past = (nowMs >= p.endEpochMs)
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        if live {
          ui.applyRounded(
            card,
            fill: IosPlayerUi.withAlpha(ui.accent, 0.14),
            radius: 12,
            stroke: IosPlayerUi.withAlpha(ui.accent, 0.7),
            strokeWidth: 1
          )
        } else {
          ui.applyRounded(card, fill: IosPlayerUi.argb(0x12FF_FFFF), radius: 12)
        }
        card.alpha = past ? 0.5 : 1.0

        let startStr = fmt.string(from: Date(timeIntervalSince1970: Double(p.startEpochMs) / 1000.0))
        let endStr = fmt.string(from: Date(timeIntervalSince1970: Double(p.endEpochMs) / 1000.0))
        let timeLbl = ui.text("\(startStr) - \(endStr)", size: 11.5, color: live ? ui.accent : IosPlayerUi.textDim, mono: true)
        let topH = UIStackView(arrangedSubviews: [timeLbl])
        topH.axis = .horizontal
        topH.alignment = .center
        if live {
          topH.addArrangedSubview(playingBadge(text: IosPlayerUiText.t("直播中", "LIVE")))
        }

        let pTitle = ui.text(p.title, size: 13.5, color: .white, bold: live)
        pTitle.numberOfLines = 2
        let vStack = UIStackView(arrangedSubviews: [topH, pTitle])
        vStack.translatesAutoresizingMaskIntoConstraints = false
        vStack.axis = .vertical
        vStack.alignment = .fill
        vStack.spacing = 4

        if live && p.endEpochMs > p.startEpochMs {
          let frac = CGFloat(Double(nowMs - p.startEpochMs) / Double(p.endEpochMs - p.startEpochMs))
          let bar = ThinSliderView(fillColor: ui.accent, trackColor: IosPlayerUi.argb(0x33FF_FFFF), thumbSize: 0, trackHeight: 2.5)
          bar.isUserInteractionEnabled = false
          bar.fraction = frac
          vStack.setCustomSpacing(6, after: pTitle)
          vStack.addArrangedSubview(bar)
        }

        card.addSubview(vStack)
        NSLayoutConstraint.activate([
          vStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
          vStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
          vStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
          vStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
        ])
        if live { liveRow = card }
        list.addArrangedSubview(card)
      }
    }
    DispatchQueue.main.async {
      scroll.layoutIfNeeded()
      if let lr = liveRow {
        let maxOff = max(0, scroll.contentSize.height - scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 0, y: max(0, min(maxOff, lr.frame.minY - 8))), animated: false)
      }
    }
  }

  // MARK: - 3. 弹幕设置 / 样式调节 (+ 搜索结果 / 选集 / 屏蔽词子页面)

  func showDanmaku(scrollY: CGFloat = 0) {
    let count = controller.danmakuView.commentCount
    let badge = PlayerInsetLabel(insets: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8))
    badge.translatesAutoresizingMaskIntoConstraints = false
    badge.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    badge.textColor = ui.accent
    badge.clipsToBounds = true
    ui.applyRounded(badge, fill: IosPlayerUi.withAlpha(ui.accent, 0.16), radius: 10)
    badge.text = IosPlayerUiText.t("\(count) 条", "\(count)")
    badge.isHidden = (count <= 0)
    danmakuCountBadge = badge

    let header = UIView()
    let hRow = UIStackView()
    hRow.translatesAutoresizingMaskIntoConstraints = false
    hRow.axis = .horizontal
    hRow.alignment = .center
    hRow.spacing = 10
    header.addSubview(hRow)
    NSLayoutConstraint.activate([
      hRow.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
      hRow.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
      hRow.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
      hRow.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10)
    ])

    if danmakuSubScreen == 0 {
      let seg = UIView()
      seg.translatesAutoresizingMaskIntoConstraints = false
      ui.applyRounded(seg, fill: IosPlayerUi.cardFill, radius: 17)
      let segRow = UIStackView()
      segRow.translatesAutoresizingMaskIntoConstraints = false
      segRow.axis = .horizontal
      segRow.alignment = .center
      segRow.spacing = 2
      seg.addSubview(segRow)
      NSLayoutConstraint.activate([
        segRow.leadingAnchor.constraint(equalTo: seg.leadingAnchor, constant: 3),
        segRow.trailingAnchor.constraint(equalTo: seg.trailingAnchor, constant: -3),
        segRow.topAnchor.constraint(equalTo: seg.topAnchor, constant: 3),
        segRow.bottomAnchor.constraint(equalTo: seg.bottomAnchor, constant: -3)
      ])
      let tabs: [(Int, String)] = [
        (IosPlayerIcon.FORUM, IosPlayerUiText.t("弹幕设置", "Danmaku")),
        (IosPlayerIcon.TUNE, IosPlayerUiText.t("样式调节", "Style"))
      ]
      for (i, tab) in tabs.enumerated() {
        let sel = (i == danmakuTab)
        let tabBtn = PlayerTappableView()
        if sel {
          ui.applyRounded(tabBtn, fill: IosPlayerUi.argb(0x2EFF_FFFF), radius: 14)
        }
        let ic = ui.icon(tab.0, size: 13, color: sel ? .white : IosPlayerUi.argb(0xB3FF_FFFF))
        let lb = ui.text(tab.1, size: 12.5, color: sel ? .white : IosPlayerUi.argb(0xB3FF_FFFF), bold: sel)
        let inner = UIStackView(arrangedSubviews: [ic, lb])
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.axis = .horizontal
        inner.alignment = .center
        inner.spacing = 7
        inner.isUserInteractionEnabled = false
        tabBtn.addSubview(inner)
        NSLayoutConstraint.activate([
          tabBtn.heightAnchor.constraint(equalToConstant: 28),
          inner.leadingAnchor.constraint(equalTo: tabBtn.leadingAnchor, constant: 12),
          inner.trailingAnchor.constraint(equalTo: tabBtn.trailingAnchor, constant: -13),
          inner.centerYAnchor.constraint(equalTo: tabBtn.centerYAnchor)
        ])
        tabBtn.onTap = { [weak self] in
          guard let self = self, self.danmakuTab != i else { return }
          self.onHaptic()
          self.danmakuTab = i
          self.showDanmaku()
        }
        segRow.addArrangedSubview(tabBtn)
      }
      hRow.addArrangedSubview(seg)
    } else {
      let backBtn = ui.circleButton(
        IosPlayerIcon.BACK,
        size: 30,
        iconSize: 16,
        fill: IosPlayerUi.argb(0x24FF_FFFF),
        stroke: nil
      ) { [weak self] in
        guard let self = self else { return }
        self.onHaptic()
        self.danmakuSubScreen = (self.danmakuSubScreen == 2) ? 1 : 0
        self.showDanmaku()
      }
      let subTitle: String
      switch danmakuSubScreen {
      case 1: subTitle = IosPlayerUiText.t("搜索结果 — 选择剧集", "Choose a show")
      case 2: subTitle = IosPlayerUiText.t("选择集数", "Choose an episode")
      default: subTitle = IosPlayerUiText.t("屏蔽词管理", "Blocked words")
      }
      hRow.addArrangedSubview(backBtn)
      hRow.addArrangedSubview(ui.text(subTitle, size: 14.5, bold: true))
    }

    hRow.addArrangedSubview(UIView())
    hRow.addArrangedSubview(badge)

    host.onPanelClosed = { [weak self] in
      self?.controller.reportPreferences()
    }

    let scroll = host.showPanel(header: header) { [weak self] list in
      guard let self = self else { return }
      switch self.danmakuSubScreen {
      case 1: self.buildDanmakuAnimeResults(into: list)
      case 2: self.buildDanmakuEpisodeResults(into: list)
      case 3: self.buildDanmakuBlockedWords(into: list)
      default:
        if self.danmakuTab == 0 {
          self.buildDanmakuSettingsTab(into: list)
        } else {
          self.buildDanmakuStyleTab(into: list)
        }
      }
    }
    if scrollY > 0 {
      DispatchQueue.main.async {
        scroll.layoutIfNeeded()
        scroll.setContentOffset(CGPoint(x: 0, y: scrollY), animated: false)
      }
    }
  }

  private func buildDanmakuSettingsTab(into list: UIStackView) {
    list.addArrangedSubview(ui.sectionLabel(IosPlayerUiText.t("弹幕状态", "Status")))

    let searchWrap = UIStackView()
    searchWrap.axis = .vertical
    searchWrap.alignment = .fill
    searchWrap.spacing = 0
    let applyDim = { [weak self] in
      guard let self = self else { return }
      searchWrap.alpha = self.controller.danmakuConfig.enabled ? 1.0 : 0.38
      searchWrap.isUserInteractionEnabled = self.controller.danmakuConfig.enabled
    }

    let sw = SwitchControlView(accent: ui.accent, isOn: controller.danmakuConfig.enabled) { [weak self] on in
      guard let self = self else { return }
      self.onHaptic()
      self.controller.setDanmakuEnabled(on)
      applyDim()
    }
    let statusCard = ui.card()
    ui.addRow(statusCard, ui.row(iconCode: IosPlayerIcon.FORUM, title: IosPlayerUiText.t("启用弹幕", "Show danmaku"), trailing: sw) {
      sw.toggle()
    })

    let count = controller.danmakuView.commentCount
    let statusStr = formatDanmakuStatusText(count: count)
    let statusLbl = ui.text(statusStr, size: 12, color: count > 0 ? ui.accent : IosPlayerUi.textDim)
    statusLbl.numberOfLines = 2
    danmakuStatusLabel = statusLbl
    let statusRow = UIView()
    statusRow.translatesAutoresizingMaskIntoConstraints = false
    let checkIc = ui.icon(IosPlayerIcon.CHECK_CIRCLE, size: 15, color: count > 0 ? ui.accent : IosPlayerUi.textDim)
    let sStack = UIStackView(arrangedSubviews: [checkIc, statusLbl])
    sStack.translatesAutoresizingMaskIntoConstraints = false
    sStack.axis = .horizontal
    sStack.alignment = .center
    sStack.spacing = 10
    statusRow.addSubview(sStack)
    NSLayoutConstraint.activate([
      sStack.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor, constant: 16),
      sStack.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor, constant: -14),
      sStack.topAnchor.constraint(equalTo: statusRow.topAnchor, constant: 9),
      sStack.bottomAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: -9)
    ])
    ui.addRow(statusCard, statusRow)
    list.addArrangedSubview(statusCard)

    searchWrap.addArrangedSubview(ui.sectionLabel(IosPlayerUiText.t("弹幕搜索与匹配", "Search and match")))
    let nameField = ui.textField(text: controller.title, placeholder: IosPlayerUiText.t("剧集名称", "Title"))
    let seasonField = ui.textField(text: "1", placeholder: IosPlayerUiText.t("第 1 季", "Season 1"), numeric: true)
    let episodeField = ui.textField(text: "\(controller.episode + 1)", placeholder: "1", numeric: true)
    nameField.heightAnchor.constraint(equalToConstant: 40).isActive = true
    seasonField.heightAnchor.constraint(equalToConstant: 40).isActive = true
    episodeField.heightAnchor.constraint(equalToConstant: 40).isActive = true

    controller.danmakuPrompt { [weak nameField, weak episodeField] info in
      guard let info = info else { return }
      if !info.keyword.isEmpty { nameField?.text = info.keyword }
      if let epNum = info.episodeNumber { episodeField?.text = "\(epNum)" }
    }

    let searchCard = ui.card()
    let formStack = UIStackView()
    formStack.translatesAutoresizingMaskIntoConstraints = false
    formStack.axis = .vertical
    formStack.alignment = .fill
    formStack.spacing = 6
    searchCard.addSubview(formStack)
    NSLayoutConstraint.activate([
      formStack.leadingAnchor.constraint(equalTo: searchCard.leadingAnchor, constant: 14),
      formStack.trailingAnchor.constraint(equalTo: searchCard.trailingAnchor, constant: -14),
      formStack.topAnchor.constraint(equalTo: searchCard.topAnchor, constant: 12),
      formStack.bottomAnchor.constraint(equalTo: searchCard.bottomAnchor, constant: -14)
    ])

    formStack.addArrangedSubview(ui.text(IosPlayerUiText.t("剧集名称", "Title"), size: 11, color: IosPlayerUi.textDim))
    formStack.addArrangedSubview(nameField)

    func labeledCol(_ label: String, _ tf: UIView) -> UIStackView {
      let col = UIStackView(arrangedSubviews: [ui.text(label, size: 11, color: IosPlayerUi.textDim), tf])
      col.axis = .vertical
      col.alignment = .fill
      col.spacing = 6
      return col
    }
    let seRow = UIStackView(arrangedSubviews: [
      labeledCol(IosPlayerUiText.t("季数 (S)", "Season (S)"), seasonField),
      labeledCol(IosPlayerUiText.t("集数 (E)", "Episode (E)"), episodeField)
    ])
    seRow.axis = .horizontal
    seRow.distribution = .fillEqually
    seRow.spacing = 10
    formStack.setCustomSpacing(10, after: nameField)
    formStack.addArrangedSubview(seRow)

    func searchBtn(code: Int, title: String, primary: Bool, action: @escaping () -> Void) -> PlayerTappableView {
      let b = PlayerTappableView()
      ui.applyRounded(
        b,
        fill: primary ? ui.accent : IosPlayerUi.cardFill,
        radius: 10,
        stroke: primary ? nil : IosPlayerUi.btnStroke,
        strokeWidth: 0.6
      )
      let ic = ui.icon(code, size: 14)
      let lb = ui.text(title, size: 13, bold: primary)
      let inner = UIStackView(arrangedSubviews: [ic, lb])
      inner.translatesAutoresizingMaskIntoConstraints = false
      inner.axis = .horizontal
      inner.alignment = .center
      inner.spacing = 8
      inner.isUserInteractionEnabled = false
      b.addSubview(inner)
      NSLayoutConstraint.activate([
        b.heightAnchor.constraint(equalToConstant: 40),
        inner.centerXAnchor.constraint(equalTo: b.centerXAnchor),
        inner.centerYAnchor.constraint(equalTo: b.centerYAnchor)
      ])
      b.onTap = { [weak self] in
        guard let self = self, self.controller.danmakuConfig.enabled else { return }
        self.onHaptic()
        nameField.resignFirstResponder()
        seasonField.resignFirstResponder()
        episodeField.resignFirstResponder()
        action()
      }
      return b
    }

    let stepBtn = searchBtn(code: IosPlayerIcon.MENU, title: IosPlayerUiText.t("分步搜索", "Step by step"), primary: false) { [weak self] in
      guard let self = self else { return }
      let kw = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !kw.isEmpty else { return }
      self.danmakuDirectEpisodeIdx = nil
      self.controller.searchDanmaku(keyword: kw)
    }
    let directBtn = searchBtn(code: IosPlayerIcon.BOLT, title: IosPlayerUiText.t("直接搜索匹配", "Search & match"), primary: true) { [weak self] in
      guard let self = self else { return }
      let kw = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !kw.isEmpty else { return }
      let epNum = max(1, Int((episodeField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1)
      self.danmakuDirectEpisodeIdx = epNum - 1
      self.controller.searchDanmaku(keyword: kw)
    }
    let btnRow = UIStackView(arrangedSubviews: [stepBtn, directBtn])
    btnRow.axis = .horizontal
    btnRow.distribution = .fillEqually
    btnRow.spacing = 10
    formStack.setCustomSpacing(14, after: seRow)
    formStack.addArrangedSubview(btnRow)
    searchWrap.addArrangedSubview(searchCard)

    let tipWrap = UIView()
    tipWrap.translatesAutoresizingMaskIntoConstraints = false
    let tipLbl = ui.text(
      IosPlayerUiText.t(
        "提示：直接搜索匹配会自动关联剧名、季数与集数直接从弹幕库加载并保存记忆；若未命中，可尝试「分步搜索」手动选择剧集。",
        "Search & match loads comments for this title and episode automatically; if it misses, try “Step by step”."
      ),
      size: 11,
      color: IosPlayerUi.textDim
    )
    tipLbl.numberOfLines = 0
    tipWrap.addSubview(tipLbl)
    NSLayoutConstraint.activate([
      tipLbl.leadingAnchor.constraint(equalTo: tipWrap.leadingAnchor, constant: 2),
      tipLbl.trailingAnchor.constraint(equalTo: tipWrap.trailingAnchor, constant: -2),
      tipLbl.topAnchor.constraint(equalTo: tipWrap.topAnchor, constant: 12),
      tipLbl.bottomAnchor.constraint(equalTo: tipWrap.bottomAnchor)
    ])
    searchWrap.addArrangedSubview(tipWrap)
    applyDim()
    list.addArrangedSubview(searchWrap)
  }

  private func buildDanmakuStyleTab(into list: UIStackView) {
    let topPad = UIView()
    topPad.translatesAutoresizingMaskIntoConstraints = false
    topPad.heightAnchor.constraint(equalToConstant: 8).isActive = true
    list.addArrangedSubview(topPad)

    let fixedCard = ui.card()
    func addToggleRow(_ title: String, get: @escaping () -> Bool, mutate: @escaping (inout DanmakuConfig, Bool) -> Void) {
      let sw = SwitchControlView(accent: ui.accent, isOn: get()) { [weak self] on in
        guard let self = self else { return }
        self.onHaptic()
        var next = self.controller.danmakuConfig
        mutate(&next, on)
        self.controller.updateDanmaku(next)
      }
      ui.addRow(fixedCard, ui.row(iconCode: nil, title: title, trailing: sw, minHeight: 51) { sw.toggle() })
    }
    addToggleRow(IosPlayerUiText.t("显示顶部固定弹幕", "Show top comments"), get: { [unowned self] in self.controller.danmakuConfig.showTop }) { $0.showTop = $1 }
    addToggleRow(IosPlayerUiText.t("显示底部固定弹幕", "Show bottom comments"), get: { [unowned self] in self.controller.danmakuConfig.showBottom }) { $0.showBottom = $1 }
    list.addArrangedSubview(fixedCard)

    list.addArrangedSubview(ui.sectionLabel(IosPlayerUiText.t("颜色模式", "Colour")))
    let colorCard = ui.card()
    let curMode = controller.danmakuConfig.colorMode
    let modeVal = ui.text(IosPlayerUiText.danmakuColorModeLabel(curMode), size: 12, color: IosPlayerUi.textDim)
    let modeTrailing = UIStackView(arrangedSubviews: [modeVal, ui.icon(IosPlayerIcon.CHEVRON, size: 16, color: IosPlayerUi.textDim)])
    modeTrailing.axis = .horizontal
    modeTrailing.alignment = .center
    modeTrailing.spacing = 4
    modeTrailing.isUserInteractionEnabled = false
    ui.addRow(colorCard, ui.row(iconCode: IosPlayerIcon.BRUSH, title: IosPlayerUiText.t("颜色模式", "Colour"), trailing: modeTrailing) { [weak self] in
      guard let self = self else { return }
      let items = IosPlayerUiText.danmakuColorModes.map { m in
        IosPlayerMenuItem(
          label: IosPlayerUiText.danmakuColorModeLabel(m),
          selected: m == self.controller.danmakuConfig.colorMode
        ) { [weak self] in
          guard let self = self else { return }
          var next = self.controller.danmakuConfig
          next.colorMode = m
          self.controller.updateDanmaku(next)
          self.showDanmaku()
        }
      }
      self.host.showMenu(anchor: modeTrailing, above: false, items: items)
    })

    let usesGradient = (curMode == "gradient" || curMode == "3" || curMode == "random_Mix" || curMode == "0")
    if usesGradient {
      let gradVal = ui.text(IosPlayerUiText.danmakuGradientLabel(controller.danmakuConfig.gradientStyle), size: 12, color: IosPlayerUi.textDim)
      let gradTrailing = UIStackView(arrangedSubviews: [gradVal, ui.icon(IosPlayerIcon.CHEVRON, size: 16, color: IosPlayerUi.textDim)])
      gradTrailing.axis = .horizontal
      gradTrailing.alignment = .center
      gradTrailing.spacing = 4
      gradTrailing.isUserInteractionEnabled = false
      ui.addRow(colorCard, ui.row(iconCode: IosPlayerIcon.AUTO_AWESOME, title: IosPlayerUiText.t("渐变色风格", "Gradient style"), trailing: gradTrailing) { [weak self] in
        guard let self = self else { return }
        let curPreset = IosPlayerUiText.parseGradientPreset(self.controller.danmakuConfig.gradientStyle)
        let curWeight = IosPlayerUiText.parseFontWeight(self.controller.danmakuConfig.gradientStyle)
        let items = IosPlayerUiText.danmakuGradientPresets.map { id, label in
          IosPlayerMenuItem(label: label, selected: id == curPreset) { [weak self] in
            guard let self = self else { return }
            var next = self.controller.danmakuConfig
            next.gradientStyle = IosPlayerUiText.encodeGradientAndWeight(preset: id, weight: curWeight)
            self.controller.updateDanmaku(next)
            gradVal.text = label
          }
        }
        self.host.showMenu(anchor: gradTrailing, above: false, items: items)
      })
    }
    list.addArrangedSubview(colorCard)

    struct DanmakuSliderSpec {
      let icon: Int
      let title: String
      let min: Double
      let max: Double
      let step: Double
      let get: (DanmakuConfig) -> Double
      let apply: (inout DanmakuConfig, Double) -> Void
      let format: (Double) -> String
    }

    func addSliderSection(_ sectionTitle: String, specs: [DanmakuSliderSpec]) {
      list.addArrangedSubview(ui.sectionLabel(sectionTitle))
      let card = ui.card()
      for spec in specs {
        let initial = spec.get(controller.danmakuConfig)
        let badge = ui.valueBadge(spec.format(initial))
        let topH = UIStackView(arrangedSubviews: [
          ui.icon(spec.icon, size: 14, color: IosPlayerUi.argb(0xB3FF_FFFF)),
          ui.text(spec.title, size: 13.5),
          badge
        ])
        topH.axis = .horizontal
        topH.alignment = .center
        topH.spacing = 10

        let slider = ThinSliderView(fillColor: ui.accent, trackColor: IosPlayerUi.argb(0x33FF_FFFF), thumbSize: 12, trackHeight: 2.5) { [weak self] f, done in
          guard let self = self else { return }
          let raw = spec.min + (spec.max - spec.min) * Double(f)
          let stepped = (raw / spec.step).rounded() * spec.step
          let clamped = Swift.max(spec.min, Swift.min(spec.max, stepped))
          badge.text = spec.format(clamped)
          var next = self.controller.danmakuConfig
          spec.apply(&next, clamped)
          self.controller.updateDanmaku(next, save: done)
        }
        slider.fraction = CGFloat((initial - spec.min) / (spec.max - spec.min))

        let box = UIView()
        box.translatesAutoresizingMaskIntoConstraints = false
        let v = UIStackView(arrangedSubviews: [topH, slider])
        v.translatesAutoresizingMaskIntoConstraints = false
        v.axis = .vertical
        v.alignment = .fill
        v.spacing = 2
        box.addSubview(v)
        NSLayoutConstraint.activate([
          v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
          v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
          v.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
          v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4)
        ])
        ui.addRow(card, box)
      }
      list.addArrangedSubview(card)
    }

    addSliderSection(IosPlayerUiText.t("外观与排版", "Appearance"), specs: [
      DanmakuSliderSpec(
        icon: IosPlayerIcon.TEXT_FORMAT, title: IosPlayerUiText.t("字号大小", "Font size"),
        min: 12, max: 32, step: 1, get: { $0.fontSize }, apply: { $0.fontSize = $1 }, format: { "\(Int($0.rounded())) pt" }
      ),
      DanmakuSliderSpec(
        icon: IosPlayerIcon.TEXT_FORMAT, title: IosPlayerUiText.t("字体粗细", "Font weight"),
        min: 0, max: 8, step: 1,
        get: { Double(IosPlayerUiText.parseFontWeight($0.gradientStyle)) },
        apply: { cfg, w in
          let preset = IosPlayerUiText.parseGradientPreset(cfg.gradientStyle)
          cfg.gradientStyle = IosPlayerUiText.encodeGradientAndWeight(preset: preset, weight: Int(w.rounded()))
        },
        format: { IosPlayerUiText.danmakuFontWeightLabel(Int($0.rounded())) }
      ),
      DanmakuSliderSpec(
        icon: IosPlayerIcon.UNFOLD, title: IosPlayerUiText.t("行高", "Line height"),
        min: 1.0, max: 2.5, step: 0.1, get: { $0.lineHeight }, apply: { $0.lineHeight = $1 }, format: { IosPlayerUiText.num($0) }
      ),
      DanmakuSliderSpec(
        icon: IosPlayerIcon.CONTRAST, title: IosPlayerUiText.t("不透明度", "Opacity"),
        min: 0.1, max: 1.0, step: 0.05, get: { $0.opacity }, apply: { $0.opacity = $1 }, format: { "\(Int(($0 * 100).rounded()))%" }
      ),
      DanmakuSliderSpec(
        icon: IosPlayerIcon.COLUMNS, title: IosPlayerUiText.t("显示区域", "Area"),
        min: 0.1, max: 1.0, step: 0.05, get: { $0.area }, apply: { $0.area = $1 }, format: { "\(Int(($0 * 100).rounded()))%" }
      ),
      DanmakuSliderSpec(
        icon: IosPlayerIcon.DOUBLE_RIGHT, title: IosPlayerUiText.t("滚动速度", "Scroll speed"),
        min: 0.3, max: 2.0, step: 0.1, get: { $0.scrollSpeed }, apply: { $0.scrollSpeed = $1 }, format: { IosPlayerUiText.num($0) }
      ),
      DanmakuSliderSpec(
        icon: IosPlayerIcon.BRUSH, title: IosPlayerUiText.t("文字描边", "Outline"),
        min: 0.0, max: 3.0, step: 0.1, get: { $0.strokeWidth }, apply: { $0.strokeWidth = $1 }, format: { IosPlayerUiText.num($0) }
      )
    ])

    addSliderSection(IosPlayerUiText.t("时间同步", "Timing"), specs: [
      DanmakuSliderSpec(
        icon: IosPlayerIcon.CLOCK, title: IosPlayerUiText.t("弹幕延迟", "Delay"),
        min: -30.0, max: 30.0, step: 0.5, get: { $0.delaySeconds }, apply: { $0.delaySeconds = $1 }, format: { IosPlayerUiText.danmakuDelay($0) }
      )
    ])

    let gap = UIView()
    gap.translatesAutoresizingMaskIntoConstraints = false
    gap.heightAnchor.constraint(equalToConstant: 12).isActive = true
    list.addArrangedSubview(gap)

    let blockCard = ui.card()
    let bCount = controller.danmakuConfig.blackList.count
    let bTrailing = UIStackView(arrangedSubviews: [
      ui.text(IosPlayerUiText.t("\(bCount) 个", "\(bCount)"), size: 12, color: IosPlayerUi.textDim),
      ui.icon(IosPlayerIcon.CHEVRON, size: 16, color: IosPlayerUi.textDim)
    ])
    bTrailing.axis = .horizontal
    bTrailing.alignment = .center
    bTrailing.spacing = 4
    bTrailing.isUserInteractionEnabled = false
    ui.addRow(blockCard, ui.row(iconCode: IosPlayerIcon.CANCEL, title: IosPlayerUiText.t("屏蔽词管理", "Blocked words"), trailing: bTrailing) { [weak self] in
      guard let self = self else { return }
      self.onHaptic()
      self.danmakuSubScreen = 3
      self.showDanmaku()
    })
    list.addArrangedSubview(blockCard)
  }

  private func buildDanmakuBlockedWords(into list: UIStackView) {
    let tf = ui.textField(text: "", placeholder: IosPlayerUiText.t("输入屏蔽词后点击添加", "Enter blocked word"))
    tf.heightAnchor.constraint(equalToConstant: 38).isActive = true

    let addWord = { [weak self] in
      guard let self = self else { return }
      let w = (tf.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !w.isEmpty else { return }
      var next = self.controller.danmakuConfig
      if !next.blackList.contains(w) {
        self.onHaptic()
        next.blackList.append(w)
        self.controller.updateDanmaku(next)
      }
      tf.text = ""
      self.showDanmaku()
    }
    tf.onSubmit = addWord

    let addBtn = PlayerTappableView()
    ui.applyRounded(addBtn, fill: ui.accent, radius: 10)
    let addLbl = ui.text(IosPlayerUiText.t("添加", "Add"), size: 13, bold: true)
    addLbl.isUserInteractionEnabled = false
    addBtn.addSubview(addLbl)
    NSLayoutConstraint.activate([
      addBtn.heightAnchor.constraint(equalToConstant: 38),
      addLbl.leadingAnchor.constraint(equalTo: addBtn.leadingAnchor, constant: 14),
      addLbl.trailingAnchor.constraint(equalTo: addBtn.trailingAnchor, constant: -14),
      addLbl.centerYAnchor.constraint(equalTo: addBtn.centerYAnchor)
    ])
    addBtn.onTap = addWord

    let inputRowWrap = UIView()
    inputRowWrap.translatesAutoresizingMaskIntoConstraints = false
    let inputRow = UIStackView(arrangedSubviews: [tf, addBtn])
    inputRow.translatesAutoresizingMaskIntoConstraints = false
    inputRow.axis = .horizontal
    inputRow.alignment = .center
    inputRow.spacing = 8
    inputRowWrap.addSubview(inputRow)
    NSLayoutConstraint.activate([
      inputRow.leadingAnchor.constraint(equalTo: inputRowWrap.leadingAnchor),
      inputRow.trailingAnchor.constraint(equalTo: inputRowWrap.trailingAnchor),
      inputRow.topAnchor.constraint(equalTo: inputRowWrap.topAnchor, constant: 8),
      inputRow.bottomAnchor.constraint(equalTo: inputRowWrap.bottomAnchor, constant: -12)
    ])
    list.addArrangedSubview(inputRowWrap)

    let words = controller.danmakuConfig.blackList
    if words.isEmpty {
      let empty = ui.text(IosPlayerUiText.t("暂无屏蔽词，命中屏蔽词的弹幕将被过滤", "No blocked words yet"), size: 12.5, color: IosPlayerUi.textDim)
      empty.textAlignment = .center
      empty.numberOfLines = 0
      empty.heightAnchor.constraint(equalToConstant: 80).isActive = true
      list.addArrangedSubview(empty)
    } else {
      let card = ui.card()
      for w in words {
        let delBtn = ui.circleButton(
          IosPlayerIcon.CLOSE,
          size: 28,
          iconSize: 15,
          fill: .clear,
          stroke: nil,
          iconColor: IosPlayerUi.textDim
        ) { [weak self] in
          guard let self = self else { return }
          self.onHaptic()
          var next = self.controller.danmakuConfig
          next.blackList.removeAll { $0 == w }
          self.controller.updateDanmaku(next)
          self.showDanmaku()
        }
        ui.addRow(card, ui.row(iconCode: nil, title: w, trailing: delBtn))
      }
      list.addArrangedSubview(card)
    }
  }

  private func buildDanmakuAnimeResults(into list: UIStackView) {
    let card = ui.card()
    for item in lastAnimeResults {
      let badge = ui.text(IosPlayerUiText.t("\(item.episodeCount) 集", "\(item.episodeCount) eps"), size: 12, color: IosPlayerUi.textDim)
      ui.addRow(card, ui.row(iconCode: nil, title: item.animeTitle, trailing: badge) { [weak self] in
        guard let self = self else { return }
        self.onHaptic()
        self.controller.pickDanmakuAnime(animeId: item.animeId)
      })
    }
    list.addArrangedSubview(card)
  }

  private func buildDanmakuEpisodeResults(into list: UIStackView) {
    let card = ui.card()
    for (idx, ep) in lastEpisodeResults.enumerated() {
      ui.addRow(card, ui.row(iconCode: nil, title: ep.episodeName) { [weak self] in
        guard let self = self else { return }
        self.onHaptic()
        self.danmakuSubScreen = 0
        self.host.closePanel()
        self.controller.pickDanmakuEpisode(index: idx)
        self.onShowToast(IosPlayerUiText.t("已匹配弹幕：\(ep.episodeName)", "Danmaku matched: \(ep.episodeName)"), false)
      })
    }
    list.addArrangedSubview(card)
  }

  private func handleDanmakuSearchResults(_ results: [DanmakuSearchResultItem]) {
    guard !results.isEmpty else {
      danmakuDirectEpisodeIdx = nil
      onShowToast(IosPlayerUiText.t("未匹配到相关弹幕", "No matching danmaku"), false)
      return
    }
    if danmakuDirectEpisodeIdx != nil {
      controller.pickDanmakuAnime(animeId: results[0].animeId)
      return
    }
    lastAnimeResults = results
    danmakuSubScreen = 1
    showDanmaku()
  }

  private func handleDanmakuEpisodes(_ episodes: [EpisodeItem]) {
    if let direct = danmakuDirectEpisodeIdx {
      danmakuDirectEpisodeIdx = nil
      guard !episodes.isEmpty else {
        onShowToast(IosPlayerUiText.t("未匹配到相关弹幕", "No matching danmaku"), false)
        return
      }
      let clamped = max(0, min(episodes.count - 1, direct))
      controller.pickDanmakuEpisode(index: clamped)
      danmakuSubScreen = 0
      host.closePanel()
      onShowToast(IosPlayerUiText.t("已匹配弹幕：\(episodes[clamped].episodeName)", "Danmaku matched"), false)
      return
    }
    lastEpisodeResults = episodes
    danmakuSubScreen = 2
    showDanmaku()
  }

  private func refreshDanmakuLiveCount(_ count: Int) {
    if let badge = danmakuCountBadge {
      badge.text = IosPlayerUiText.t("\(count) 条", "\(count)")
      badge.isHidden = (count <= 0)
    }
    if let lbl = danmakuStatusLabel {
      lbl.text = formatDanmakuStatusText(count: count)
      lbl.textColor = count > 0 ? ui.accent : IosPlayerUi.textDim
    }
  }

  private func formatDanmakuStatusText(count: Int) -> String {
    guard count > 0 else {
      return IosPlayerUiText.t("当前未加载弹幕", "No comments loaded")
    }
    if let anime = controller.danmakuAnimeTitle, !anime.isEmpty {
      let epPart = (controller.danmakuEpisodeTitle?.isEmpty == false) ? " · \(controller.danmakuEpisodeTitle!)" : ""
      return IosPlayerUiText.t("当前已加载 \(count) 条弹幕（\(anime)\(epPart)）", "\(count) comments (\(anime)\(epPart))")
    }
    return IosPlayerUiText.t("当前已加载 \(count) 条弹幕", "\(count) comments loaded")
  }

  // MARK: - 4. 播放设置 (1:1 Android `PlayerSettings.kt` + iOS Triple Kernels)

  func showSettings(scrollY: CGFloat = 0) {
    var scrollRef: UIScrollView?
    let scroll = host.showPanel { [weak self] list in
      guard let self = self else { return }

      func addToggle(
        card: PlayerCardView,
        icon: Int,
        title: String,
        subtitle: String? = nil,
        get: @escaping (PlaybackConfig) -> Bool,
        mutate: @escaping (inout PlaybackConfig, Bool) -> Void,
        extra: ((Bool) -> Void)? = nil
      ) {
        let sw = SwitchControlView(accent: self.ui.accent, isOn: get(self.controller.playbackConfig)) { [weak self] on in
          guard let self = self else { return }
          self.onHaptic()
          var next = self.controller.playbackConfig
          mutate(&next, on)
          self.controller.updatePlayback(next)
          extra?(on)
        }
        self.ui.addRow(card, self.ui.row(iconCode: icon, title: title, subtitle: subtitle, trailing: sw) {
          sw.toggle()
        })
      }

      func addOption(
        card: PlayerCardView,
        icon: Int,
        rotateIcon: Bool = false,
        title: String,
        selected: Bool,
        onPick: @escaping () -> Void
      ) {
        let check = selected ? self.ui.icon(IosPlayerIcon.CHECK, size: 16, color: self.ui.accent) : nil
        let row = self.ui.row(iconCode: icon, title: title, trailing: check, rotateIcon: rotateIcon) { [weak self] in
          guard let self = self, !selected else { return }
          self.onHaptic()
          onPick()
        }
        row.iconView?.iconColor = selected ? self.ui.accent : IosPlayerUi.argb(0xD9FF_FFFF)
        row.titleLabel.textColor = selected ? .white : IosPlayerUi.argb(0xD9FF_FFFF)
        if selected {
          row.titleLabel.font = UIFont.systemFont(ofSize: 14.5, weight: .semibold)
        }
        self.ui.addRow(card, row)
      }

      // Group 1: 解码
      list.addArrangedSubview(self.ui.sectionLabel(IosPlayerUiText.t("解码", "Decoding")))
      let decodeCard = self.ui.card()
      addToggle(
        card: decodeCard,
        icon: IosPlayerIcon.MEMORY,
        title: IosPlayerUiText.t("硬件加速", "Hardware acceleration"),
        subtitle: IosPlayerUiText.t("关闭后使用软解（更兼容但更耗电）", "Off: software decoding (more compatible, uses more power)"),
        get: { $0.hwDecode },
        mutate: { $0.hwDecode = $1 }
      )
      list.addArrangedSubview(decodeCard)

      // Group 2: 画面比例
      list.addArrangedSubview(self.ui.sectionLabel(IosPlayerUiText.t("画面比例", "Aspect")))
      let fitCard = self.ui.card()
      let curFit = IosPlayerUiText.fitModes.contains(where: { $0.0 == self.controller.playbackConfig.fitMode })
        ? self.controller.playbackConfig.fitMode
        : "fit"
      let fitRows: [(String, Int, Bool)] = [
        ("fit", IosPlayerIcon.ASPECT, false),
        ("zoom", IosPlayerIcon.FIT, false),
        ("fill", IosPlayerIcon.HEIGHT, true)
      ]
      for (mode, ic, rot) in fitRows {
        addOption(
          card: fitCard,
          icon: ic,
          rotateIcon: rot,
          title: IosPlayerUiText.fitModePanelLabel(mode),
          selected: curFit == mode
        ) { [weak self] in
          guard let self = self else { return }
          let y = scrollRef?.contentOffset.y ?? 0
          self.controller.setFitMode(mode)
          if self.host.isPanelOpen {
            self.showSettings(scrollY: y)
          }
        }
      }
      list.addArrangedSubview(fitCard)

      // Group 3: 播放内核 (`AVPlayer (SYSTEM)`, `MPV (MPV)`, `VLC (FFmpeg)`)
      list.addArrangedSubview(self.ui.sectionLabel(IosPlayerUiText.t("播放内核", "Player kernel")))
      let kernelCard = self.ui.card()
      let curKernel = IosPlayerUiText.normalizeIosKernel(self.controller.playbackConfig.kernel)
      for kId in IosPlayerUiText.iosKernels {
        addOption(
          card: kernelCard,
          icon: IosPlayerIcon.MEMORY,
          title: IosPlayerUiText.kernelOptionName(kId),
          selected: curKernel == kId
        ) { [weak self] in
          guard let self = self else { return }
          if kId == "mpv" && !IosPlayerKernel.isMpvAvailable {
            self.onShowToast(
              IosPlayerUiText.t("MPV 内核不可用：当前安装包未内嵌 NovaMpv", "MPV kernel unavailable in this build"),
              false
            )
            return
          }
          if kId == "vlc" && !IosPlayerKernel.isVlcAvailable {
            self.onShowToast(
              IosPlayerUiText.t("VLC 内核不可用：当前安装包未内嵌 MobileVLCKit", "VLC kernel unavailable in this build"),
              false
            )
            return
          }
          let y = scrollRef?.contentOffset.y ?? 0
          self.controller.selectPlayerKernel(kId)
          if self.host.isPanelOpen {
            self.showSettings(scrollY: y)
          }
        }
      }
      list.addArrangedSubview(kernelCard)

      // Group 4: 快进快退秒数
      list.addArrangedSubview(self.ui.sectionLabel(IosPlayerUiText.t("快进快退秒数", "Seek step")))
      let stepCard = self.ui.card()
      let curSec = self.controller.playbackConfig.fastForwardSeconds
      let valLbl = self.ui.text(IosPlayerUiText.t("\(curSec) 秒", "\(curSec) s"), size: 13, mono: true)
      valLbl.textAlignment = .center
      valLbl.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true

      let minusBtn = self.ui.circleButton(
        IosPlayerIcon.REMOVE,
        size: 26,
        iconSize: 16,
        fill: IosPlayerUi.argb(0x29FF_FFFF),
        stroke: nil
      ) { [weak self] in
        guard let self = self else { return }
        let cur = self.controller.playbackConfig.fastForwardSeconds
        guard cur > 5 else { return }
        self.onHaptic()
        var next = self.controller.playbackConfig
        next.fastForwardSeconds = max(5, cur - 5)
        self.controller.updatePlayback(next)
        valLbl.text = IosPlayerUiText.t("\(next.fastForwardSeconds) 秒", "\(next.fastForwardSeconds) s")
      }
      let plusBtn = self.ui.circleButton(
        IosPlayerIcon.ADD,
        size: 26,
        iconSize: 16,
        fill: IosPlayerUi.argb(0x29FF_FFFF),
        stroke: nil
      ) { [weak self] in
        guard let self = self else { return }
        let cur = self.controller.playbackConfig.fastForwardSeconds
        guard cur < 120 else { return }
        self.onHaptic()
        var next = self.controller.playbackConfig
        next.fastForwardSeconds = min(120, cur + 5)
        self.controller.updatePlayback(next)
        valLbl.text = IosPlayerUiText.t("\(next.fastForwardSeconds) 秒", "\(next.fastForwardSeconds) s")
      }
      let stepperBox = UIView()
      stepperBox.translatesAutoresizingMaskIntoConstraints = false
      self.ui.applyRounded(stepperBox, fill: IosPlayerUi.cardFill, radius: 17)
      let stepH = UIStackView(arrangedSubviews: [minusBtn, valLbl, plusBtn])
      stepH.translatesAutoresizingMaskIntoConstraints = false
      stepH.axis = .horizontal
      stepH.alignment = .center
      stepH.spacing = 2
      stepperBox.addSubview(stepH)
      NSLayoutConstraint.activate([
        stepH.leadingAnchor.constraint(equalTo: stepperBox.leadingAnchor, constant: 4),
        stepH.trailingAnchor.constraint(equalTo: stepperBox.trailingAnchor, constant: -4),
        stepH.topAnchor.constraint(equalTo: stepperBox.topAnchor, constant: 4),
        stepH.bottomAnchor.constraint(equalTo: stepperBox.bottomAnchor, constant: -4)
      ])
      self.ui.addRow(stepCard, self.ui.row(iconCode: IosPlayerIcon.FORWARD, title: IosPlayerUiText.t("快进快退秒数", "Seek step"), trailing: stepperBox))
      list.addArrangedSubview(stepCard)

      // Group 5: 播放 (8 toggles matching Android `PlayerSettings.kt`)
      list.addArrangedSubview(self.ui.sectionLabel(IosPlayerUiText.t("播放", "Playback")))
      let playCard = self.ui.card()
      addToggle(
        card: playCard,
        icon: IosPlayerIcon.CLOCK,
        title: IosPlayerUiText.t("进度条显示总时长", "Show total duration on progress bar"),
        subtitle: IosPlayerUiText.t("关闭则显示剩余时长", "Off: show remaining time"),
        get: { $0.isShowAllDuration },
        mutate: { $0.isShowAllDuration = $1 }
      )
      addToggle(
        card: playCard,
        icon: IosPlayerIcon.SKIP_NEXT,
        title: IosPlayerUiText.t("隐藏中央快进快退", "Hide centre seek buttons"),
        get: { $0.isHiddenFastSeekBtn },
        mutate: { $0.isHiddenFastSeekBtn = $1 }
      )
      addToggle(
        card: playCard,
        icon: IosPlayerIcon.PAUSE,
        title: IosPlayerUiText.t("进入后台暂停", "Pause in background"),
        get: { $0.pauseOnBackground },
        mutate: { $0.pauseOnBackground = $1 }
      )
      if curKernel != "mpv" {
        addToggle(
          card: playCard,
          icon: IosPlayerIcon.PIP,
          title: IosPlayerUiText.t("进入后台自动画中画", "Picture-in-picture in background"),
          subtitle: IosPlayerUiText.t("切到后台时自动开启画中画继续播放（AVPlayer）", "Keep playing in PiP when leaving the app (AVPlayer)"),
          get: { $0.autoPictureInPicture },
          mutate: { $0.autoPictureInPicture = $1 }
        )
      }
      addToggle(
        card: playCard,
        icon: IosPlayerIcon.BOLT,
        title: IosPlayerUiText.t("跳过提示", "Skip notice"),
        subtitle: IosPlayerUiText.t("跳过片头片尾时显示横幅与轻提示", "Show banner and short notice when intros/outros are skipped"),
        get: { $0.skipNotice },
        mutate: { $0.skipNotice = $1 }
      )
      addToggle(
        card: playCard,
        icon: IosPlayerIcon.DOUBLE_RIGHT,
        title: IosPlayerUiText.t("切集提示", "Episode switch notice"),
        subtitle: IosPlayerUiText.t("切集时显示「正在切换至 第X集」轻提示", "Show “Switching to episode X” when episode changes"),
        get: { $0.isShowEpisodeSwitchNotice },
        mutate: { $0.isShowEpisodeSwitchNotice = $1 }
      )
      addToggle(
        card: playCard,
        icon: IosPlayerIcon.ROTATE,
        title: IosPlayerUiText.t("优先横屏", "Prefer landscape"),
        get: { $0.isPriorityLandscape },
        mutate: { $0.isPriorityLandscape = $1 },
        extra: { [weak self] on in self?.onOrientationPreferenceChanged(on) }
      )
      addToggle(
        card: playCard,
        icon: IosPlayerIcon.TUNE,
        title: IosPlayerUiText.t("长按滑动调节倍速", "Slide to adjust long-press speed"),
        subtitle: IosPlayerUiText.t("关闭后长按仅使用固定倍速", "Off: long press always uses fixed speed"),
        get: { $0.isLongPressSpeedAdjustEnabled != false },
        mutate: { $0.isLongPressSpeedAdjustEnabled = $1 }
      )
      list.addArrangedSubview(playCard)

      // Group 6: 信息显示
      list.addArrangedSubview(self.ui.sectionLabel(IosPlayerUiText.t("信息显示", "On-screen info")))
      let infoCard = self.ui.card()
      addToggle(
        card: infoCard,
        icon: IosPlayerIcon.INFO,
        title: IosPlayerUiText.t("显示帧率与编码", "Show frame rate and codec"),
        subtitle: IosPlayerUiText.t("影响观影性能", "Costs some performance"),
        get: { $0.isShowStatsBar },
        mutate: { $0.isShowStatsBar = $1 }
      )
      addToggle(
        card: infoCard,
        icon: IosPlayerIcon.BOLT,
        title: IosPlayerUiText.t("始终显示网速", "Always show network speed"),
        subtitle: IosPlayerUiText.t("无需开启上方信息栏即可看到下载速度", "See download speed without opening info bar"),
        get: { $0.showNetSpeed },
        mutate: { $0.showNetSpeed = $1 }
      )
      list.addArrangedSubview(infoCard)
    }
    scrollRef = scroll
    if scrollY > 0 {
      DispatchQueue.main.async {
        scroll.layoutIfNeeded()
        scroll.setContentOffset(CGPoint(x: 0, y: scrollY), animated: false)
      }
    }
  }
}
