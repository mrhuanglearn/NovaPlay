import UIKit

/// Translucent dark in-player settings drawer matching `设置 -> 播放器` on iOS 15+.
final class IosPlayerSettingsDrawerController: UIViewController {
  private let controller: IosPlayerController
  private let onOpenSubtitles: () -> Void
  private let onOpenAudios: () -> Void
  private let onImportLocalSubtitle: () -> Void
  private let onImportUrlSubtitle: () -> Void
  private let onOrientationChanged: (Bool) -> Void

  private let dimmerView = UIView()
  private let cardContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()

  init(
    controller: IosPlayerController,
    onOpenSubtitles: @escaping () -> Void,
    onOpenAudios: @escaping () -> Void,
    onImportLocalSubtitle: @escaping () -> Void,
    onImportUrlSubtitle: @escaping () -> Void,
    onOrientationChanged: @escaping (Bool) -> Void
  ) {
    self.controller = controller
    self.onOpenSubtitles = onOpenSubtitles
    self.onOpenAudios = onOpenAudios
    self.onImportLocalSubtitle = onImportLocalSubtitle
    self.onImportUrlSubtitle = onImportUrlSubtitle
    self.onOrientationChanged = onOrientationChanged
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    overrideUserInterfaceStyle = .dark
    setupLayout()
    rebuildRows()
  }

  private func setupLayout() {
    dimmerView.backgroundColor = UIColor(white: 0, alpha: 0.45)
    dimmerView.translatesAutoresizingMaskIntoConstraints = false
    let tap = UITapGestureRecognizer(target: self, action: #selector(closeDrawer))
    dimmerView.addGestureRecognizer(tap)
    view.addSubview(dimmerView)

    cardContainer.layer.cornerRadius = 18
    cardContainer.clipsToBounds = true
    cardContainer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(cardContainer)

    let headerRow = UIStackView()
    headerRow.axis = .horizontal
    headerRow.alignment = .center
    headerRow.translatesAutoresizingMaskIntoConstraints = false

    let headerTitle = UILabel()
    headerTitle.text = IosPlayerUiText.t("播放设置", "Player Settings")
    headerTitle.font = UIFont.systemFont(ofSize: 16, weight: .bold)
    headerTitle.textColor = .white

    let closeBtn = UIButton(type: .system)
    closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    closeBtn.tintColor = UIColor(white: 0.75, alpha: 1.0)
    closeBtn.addTarget(self, action: #selector(closeDrawer), for: .touchUpInside)

    headerRow.addArrangedSubview(headerTitle)
    headerRow.addArrangedSubview(UIView())
    headerRow.addArrangedSubview(closeBtn)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.showsVerticalScrollIndicator = true

    contentStack.axis = .vertical
    contentStack.spacing = 6
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentStack)

    let body = cardContainer.contentView
    body.addSubview(headerRow)
    body.addSubview(scrollView)

    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      dimmerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dimmerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      dimmerView.topAnchor.constraint(equalTo: view.topAnchor),
      dimmerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      cardContainer.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
      cardContainer.topAnchor.constraint(equalTo: safe.topAnchor, constant: 12),
      cardContainer.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
      cardContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
      cardContainer.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 12),

      headerRow.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
      headerRow.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -14),
      headerRow.topAnchor.constraint(equalTo: body.topAnchor, constant: 14),

      scrollView.leadingAnchor.constraint(equalTo: body.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 8),
      scrollView.bottomAnchor.constraint(equalTo: body.bottomAnchor),

      contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 14),
      contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -14),
      contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 4),
      contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18),
      contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -28)
    ])
    let preferredWidth = cardContainer.widthAnchor.constraint(equalToConstant: 340)
    preferredWidth.priority = .defaultHigh
    preferredWidth.isActive = true
  }

  @objc private func closeDrawer() {
    dismiss(animated: true)
  }

  private func rebuildRows() {
    for sub in contentStack.arrangedSubviews {
      contentStack.removeArrangedSubview(sub)
      sub.removeFromSuperview()
    }

    let p = controller.playbackConfig
    let k = controller.kernel
    let accent = IosPlayerUiText.accentColor(hex: p.accentColorHex)
    let activeKernel = k.activeKernelId

    // 1. 音轨与字幕
    addSectionHeader(IosPlayerUiText.t("音轨与字幕", "Audio & Subtitles"))
    let subCount = k.subtitleTracks().count
    let subStatus = k.subtitlesEnabled ? IosPlayerUiText.t("已开启", "On") : IosPlayerUiText.t("关闭", "Off")
    addActionRow(
      symbol: "captions.bubble",
      title: IosPlayerUiText.t("字幕轨道", "Subtitle Track"),
      trailingText: "\(subStatus) (\(subCount))"
    ) { [weak self] in
      self?.dismiss(animated: true) { self?.onOpenSubtitles() }
    }

    let audioCount = k.audioTracks().count
    addActionRow(
      symbol: "waveform",
      title: IosPlayerUiText.t("音频轨道", "Audio Track"),
      trailingText: "\(audioCount)"
    ) { [weak self] in
      self?.dismiss(animated: true) { self?.onOpenAudios() }
    }

    addActionRow(
      symbol: "folder",
      title: IosPlayerUiText.t("从「文件」导入本地字幕…", "Import Subtitle File…"),
      trailingText: ".srt/.ass/.vtt"
    ) { [weak self] in
      self?.dismiss(animated: true) { self?.onImportLocalSubtitle() }
    }

    addActionRow(
      symbol: "link",
      title: IosPlayerUiText.t("加载外挂字幕 URL…", "Load Subtitle URL…"),
      trailingText: nil
    ) { [weak self] in
      self?.dismiss(animated: true) { self?.onImportUrlSubtitle() }
    }

    if controller.canMarkHeadTail {
      addActionRow(
        symbol: "forward.frame",
        title: IosPlayerUiText.t("将当前位置记为片头结束", "Mark Current as Intro End"),
        trailingText: IosPlayerUiText.clock(k.positionMs)
      ) { [weak self] in
        self?.controller.markIntro()
        self?.dismiss(animated: true)
      }
      addActionRow(
        symbol: "backward.frame",
        title: IosPlayerUiText.t("将当前位置记为片尾起点", "Mark Current as Outro Start"),
        trailingText: IosPlayerUiText.clock(k.positionMs)
      ) { [weak self] in
        self?.controller.markOutro()
        self?.dismiss(animated: true)
      }
    }

    // 2. 解码
    addSectionHeader(IosPlayerUiText.t("解码", "Decoding"))
    let hwSub = (activeKernel == "avplayer")
      ? IosPlayerUiText.t("AVPlayer 始终启用 Apple VideoToolbox 硬解；此开关对 VLC 内核生效", "AVPlayer always uses VideoToolbox HW decode; applies to VLC")
      : IosPlayerUiText.t("关闭后使用 FFmpeg 软解（更兼容但更耗电）", "Off: FFmpeg software decode (more compatible, higher power)")
    addToggleRow(
      symbol: "cpu",
      title: IosPlayerUiText.t("硬件加速", "Hardware Acceleration"),
      subtitle: hwSub,
      isOn: p.hwDecode,
      accent: accent
    ) { [weak self] val in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.hwDecode = val
      self.controller.updatePlayback(next)
      self.rebuildRows()
    }

    // 3. 画面比例
    addSectionHeader(IosPlayerUiText.t("画面比例", "Aspect"))
    for mode in ["fit", "zoom", "fill"] {
      let selected = (p.fitMode == mode) || (mode == "fit" && !["fit", "zoom", "fill"].contains(p.fitMode))
      addOptionRow(
        symbol: mode == "fit" ? "aspectratio" : (mode == "zoom" ? "arrow.up.left.and.arrow.down.right" : "rectangle.expand.vertical"),
        title: IosPlayerUiText.fitModePanelLabel(mode),
        subtitle: nil,
        selected: selected,
        accent: accent
      ) { [weak self] in
        guard let self = self else { return }
        self.controller.setFitMode(mode)
        self.rebuildRows()
      }
    }

    // 4. 播放内核 (iOS Native Capabilities)
    addSectionHeader(IosPlayerUiText.t("播放内核", "Player Kernel"))
    addOptionRow(
      symbol: "play.tv",
      title: "AVPlayer (SYSTEM)",
      subtitle: IosPlayerUiText.t("系统硬解 · 原生支持画中画 (PiP) 与 AirPlay 隔空投屏", "Apple VideoToolbox · Native PiP & AirPlay"),
      selected: activeKernel == "avplayer",
      accent: accent
    ) { [weak self] in
      guard let self = self else { return }
      self.controller.selectPlayerKernel("avplayer")
      self.rebuildRows()
    }

    let vlcSub = IosPlayerKernel.isVlcAvailable
      ? IosPlayerUiText.t("FFmpeg 多格式软硬解 (MKV/FLV/AVI/ASS) · 暂不支持系统画中画", "FFmpeg multi-format (MKV/FLV/AVI/ASS) · No system PiP")
      : IosPlayerUiText.t("当前构建为轻量版（未链接 MobileVLCKit），将自动回退至 AVPlayer", "Slim build without MobileVLCKit; falls back to AVPlayer")
    addOptionRow(
      symbol: "film.stack",
      title: "VLC (FFmpeg)",
      subtitle: vlcSub,
      selected: activeKernel == "vlc",
      accent: accent
    ) { [weak self] in
      guard let self = self else { return }
      self.controller.selectPlayerKernel("vlc")
      self.rebuildRows()
    }

    // 5. 快进快退秒数
    addSectionHeader(IosPlayerUiText.t("快进快退秒数", "Seek Step"))
    addStepperRow(
      symbol: "goforward",
      title: IosPlayerUiText.t("快进快退秒数", "Seek Step"),
      valueText: IosPlayerUiText.t("\(p.fastForwardSeconds) 秒", "\(p.fastForwardSeconds) s"),
      canMinus: p.fastForwardSeconds > 5,
      canPlus: p.fastForwardSeconds < 120,
      onMinus: { [weak self] in
        guard let self = self else { return }
        var next = self.controller.playbackConfig
        next.fastForwardSeconds = max(5, next.fastForwardSeconds - 5)
        self.controller.updatePlayback(next)
        self.rebuildRows()
      },
      onPlus: { [weak self] in
        guard let self = self else { return }
        var next = self.controller.playbackConfig
        next.fastForwardSeconds = min(120, next.fastForwardSeconds + 5)
        self.controller.updatePlayback(next)
        self.rebuildRows()
      }
    )

    // 6. 播放
    addSectionHeader(IosPlayerUiText.t("播放", "Playback"))
    addToggleRow(
      symbol: "clock",
      title: IosPlayerUiText.t("进度条显示总时长", "Show Total Duration"),
      subtitle: IosPlayerUiText.t("关闭则显示剩余时长", "Off: show remaining time"),
      isOn: p.isShowAllDuration,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.isShowAllDuration = v
      self.controller.updatePlayback(next)
    }

    addToggleRow(
      symbol: "forward.end.alt",
      title: IosPlayerUiText.t("隐藏快进快退按钮", "Hide Seek Buttons"),
      subtitle: nil,
      isOn: p.isHiddenFastSeekBtn,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.isHiddenFastSeekBtn = v
      self.controller.updatePlayback(next)
    }

    addToggleRow(
      symbol: "pause.circle",
      title: IosPlayerUiText.t("进入后台暂停", "Pause in Background"),
      subtitle: nil,
      isOn: p.pauseOnBackground,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.pauseOnBackground = v
      self.controller.updatePlayback(next)
    }

    let pipSub = (activeKernel == "avplayer")
      ? IosPlayerUiText.t("切到后台时自动开启 iOS 系统画中画", "Automatically start iOS PiP when leaving the app")
      : IosPlayerUiText.t("iOS 系统画中画仅在 AVPlayer 内核下可用", "iOS system PiP requires AVPlayer kernel")
    addToggleRow(
      symbol: "pip",
      title: IosPlayerUiText.t("进入后台自动画中画", "Auto Picture-in-Picture"),
      subtitle: pipSub,
      isOn: p.autoPictureInPicture,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.autoPictureInPicture = v
      self.controller.updatePlayback(next)
    }

    addToggleRow(
      symbol: "bolt",
      title: IosPlayerUiText.t("跳过提示", "Skip Notice"),
      subtitle: IosPlayerUiText.t("跳过片头片尾时显示轻提示", "Show notice when intros/outros are skipped"),
      isOn: p.skipNotice,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.skipNotice = v
      self.controller.updatePlayback(next)
    }

    addToggleRow(
      symbol: "chevron.forward.2",
      title: IosPlayerUiText.t("切集提示", "Episode Switch Notice"),
      subtitle: IosPlayerUiText.t("切集时显示「正在切换至 第X集」", "Show notice when switching episodes"),
      isOn: p.isShowEpisodeSwitchNotice,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.isShowEpisodeSwitchNotice = v
      self.controller.updatePlayback(next)
    }

    addToggleRow(
      symbol: "rotate.right",
      title: IosPlayerUiText.t("优先横屏", "Prefer Landscape"),
      subtitle: nil,
      isOn: p.isPriorityLandscape,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.isPriorityLandscape = v
      self.controller.updatePlayback(next)
      self.onOrientationChanged(v)
    }

    addToggleRow(
      symbol: "slider.vertical.3",
      title: IosPlayerUiText.t("长按滑动调节倍速", "Slide to Adjust Long-Press Speed"),
      subtitle: IosPlayerUiText.t("关闭后长按仅使用固定倍速", "Off: long-press uses fixed boost speed"),
      isOn: p.isLongPressSpeedAdjustEnabled != false,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.isLongPressSpeedAdjustEnabled = v
      self.controller.updatePlayback(next)
    }

    // 7. 信息显示
    addSectionHeader(IosPlayerUiText.t("信息显示", "On-Screen Info"))
    addToggleRow(
      symbol: "info.circle",
      title: IosPlayerUiText.t("显示帧率与编码", "Show FPS & Codec"),
      subtitle: IosPlayerUiText.t("显示内核、分辨率、编码与帧率", "Displays kernel, codec, FPS and speed"),
      isOn: p.isShowStatsBar,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.isShowStatsBar = v
      self.controller.updatePlayback(next)
    }

    addToggleRow(
      symbol: "speedometer",
      title: IosPlayerUiText.t("始终显示网速", "Always Show Network Speed"),
      subtitle: IosPlayerUiText.t("无需开启上方信息栏即可看到下载速度", "Show live download speed on screen"),
      isOn: p.showNetSpeed,
      accent: accent
    ) { [weak self] v in
      guard let self = self else { return }
      var next = self.controller.playbackConfig
      next.showNetSpeed = v
      self.controller.updatePlayback(next)
    }
  }

  // MARK: - Row Builders

  private func addSectionHeader(_ text: String) {
    let container = UIView()
    let lbl = UILabel()
    lbl.text = text
    lbl.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    lbl.textColor = UIColor(white: 0.62, alpha: 1.0)
    lbl.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(lbl)
    NSLayoutConstraint.activate([
      lbl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
      lbl.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      lbl.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
      lbl.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2)
    ])
    contentStack.addArrangedSubview(container)
  }

  private func makeRowCard() -> UIView {
    let card = UIView()
    card.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    card.layer.cornerRadius = 10
    return card
  }

  private func addActionRow(symbol: String, title: String, trailingText: String?, onTap: @escaping () -> Void) {
    let card = makeRowCard()
    let icon = UIImageView(image: UIImage(systemName: symbol))
    icon.tintColor = UIColor(white: 0.85, alpha: 1.0)
    icon.contentMode = .scaleAspectFit
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

    let lbl = UILabel()
    lbl.text = title
    lbl.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    lbl.textColor = .white

    let trail = UILabel()
    trail.text = trailingText
    trail.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    trail.textColor = UIColor(white: 0.68, alpha: 1.0)

    let chev = UIImageView(image: UIImage(systemName: "chevron.right"))
    chev.tintColor = UIColor(white: 0.5, alpha: 1.0)
    chev.widthAnchor.constraint(equalToConstant: 12).isActive = true

    let row = UIStackView(arrangedSubviews: [icon, lbl, UIView(), trail, chev])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
      row.topAnchor.constraint(equalTo: card.topAnchor, constant: 11),
      row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -11)
    ])

    let btn = BlockTapGesture(action: onTap)
    card.addGestureRecognizer(btn)
    contentStack.addArrangedSubview(card)
  }

  private func addOptionRow(
    symbol: String,
    title: String,
    subtitle: String?,
    selected: Bool,
    accent: UIColor,
    onSelect: @escaping () -> Void
  ) {
    let card = makeRowCard()
    if selected {
      card.backgroundColor = accent.withAlphaComponent(0.18)
      card.layer.borderWidth = 1
      card.layer.borderColor = accent.withAlphaComponent(0.65).cgColor
    }

    let icon = UIImageView(image: UIImage(systemName: symbol))
    icon.tintColor = selected ? accent : UIColor(white: 0.85, alpha: 1.0)
    icon.contentMode = .scaleAspectFit
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

    let titleLbl = UILabel()
    titleLbl.text = title
    titleLbl.font = UIFont.systemFont(ofSize: 14, weight: selected ? .semibold : .medium)
    titleLbl.textColor = selected ? accent : .white

    let textStack = UIStackView(arrangedSubviews: [titleLbl])
    textStack.axis = .vertical
    textStack.spacing = 2
    if let sub = subtitle, !sub.isEmpty {
      let subLbl = UILabel()
      subLbl.text = sub
      subLbl.font = UIFont.systemFont(ofSize: 11.5)
      subLbl.textColor = UIColor(white: 0.68, alpha: 1.0)
      subLbl.numberOfLines = 2
      textStack.addArrangedSubview(subLbl)
    }

    let check = UIImageView(image: UIImage(systemName: "checkmark"))
    check.tintColor = accent
    check.isHidden = !selected
    check.widthAnchor.constraint(equalToConstant: 16).isActive = true

    let row = UIStackView(arrangedSubviews: [icon, textStack, UIView(), check])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
      row.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
      row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10)
    ])

    card.addGestureRecognizer(BlockTapGesture(action: onSelect))
    contentStack.addArrangedSubview(card)
  }

  private func addToggleRow(
    symbol: String,
    title: String,
    subtitle: String?,
    isOn: Bool,
    accent: UIColor,
    onChange: @escaping (Bool) -> Void
  ) {
    let card = makeRowCard()
    let icon = UIImageView(image: UIImage(systemName: symbol))
    icon.tintColor = UIColor(white: 0.85, alpha: 1.0)
    icon.contentMode = .scaleAspectFit
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

    let titleLbl = UILabel()
    titleLbl.text = title
    titleLbl.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    titleLbl.textColor = .white

    let textStack = UIStackView(arrangedSubviews: [titleLbl])
    textStack.axis = .vertical
    textStack.spacing = 2
    if let sub = subtitle, !sub.isEmpty {
      let subLbl = UILabel()
      subLbl.text = sub
      subLbl.font = UIFont.systemFont(ofSize: 11.5)
      subLbl.textColor = UIColor(white: 0.65, alpha: 1.0)
      subLbl.numberOfLines = 2
      textStack.addArrangedSubview(subLbl)
    }

    let sw = BlockSwitch()
    sw.isOn = isOn
    sw.onTintColor = accent
    sw.onToggle = onChange

    let row = UIStackView(arrangedSubviews: [icon, textStack, UIView(), sw])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
      row.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
      row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
    ])

    contentStack.addArrangedSubview(card)
  }

  private func addStepperRow(
    symbol: String,
    title: String,
    valueText: String,
    canMinus: Bool,
    canPlus: Bool,
    onMinus: @escaping () -> Void,
    onPlus: @escaping () -> Void
  ) {
    let card = makeRowCard()
    let icon = UIImageView(image: UIImage(systemName: symbol))
    icon.tintColor = UIColor(white: 0.85, alpha: 1.0)
    icon.contentMode = .scaleAspectFit
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

    let titleLbl = UILabel()
    titleLbl.text = title
    titleLbl.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    titleLbl.textColor = .white

    let minusBtn = BlockButton(type: .system)
    minusBtn.setTitle("−", for: .normal)
    minusBtn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
    minusBtn.tintColor = canMinus ? .white : UIColor(white: 0.4, alpha: 1.0)
    minusBtn.isEnabled = canMinus
    minusBtn.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
    minusBtn.layer.cornerRadius = 8
    minusBtn.widthAnchor.constraint(equalToConstant: 30).isActive = true
    minusBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true
    minusBtn.onTap = onMinus

    let valLbl = UILabel()
    valLbl.text = valueText
    valLbl.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    valLbl.textColor = .white
    valLbl.textAlignment = .center
    valLbl.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

    let plusBtn = BlockButton(type: .system)
    plusBtn.setTitle("+", for: .normal)
    plusBtn.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .bold)
    plusBtn.tintColor = canPlus ? .white : UIColor(white: 0.4, alpha: 1.0)
    plusBtn.isEnabled = canPlus
    plusBtn.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
    plusBtn.layer.cornerRadius = 8
    plusBtn.widthAnchor.constraint(equalToConstant: 30).isActive = true
    plusBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true
    plusBtn.onTap = onPlus

    let row = UIStackView(arrangedSubviews: [icon, titleLbl, UIView(), minusBtn, valLbl, plusBtn])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
      row.topAnchor.constraint(equalTo: card.topAnchor, constant: 9),
      row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -9)
    ])

    contentStack.addArrangedSubview(card)
  }
}

private final class BlockTapGesture: UITapGestureRecognizer {
  private let action: () -> Void
  init(action: @escaping () -> Void) {
    self.action = action
    super.init(target: nil, action: nil)
    addTarget(self, action: #selector(fire))
  }
  @objc private func fire() { action() }
}

private final class BlockSwitch: UISwitch {
  var onToggle: ((Bool) -> Void)?
  override init(frame: CGRect) {
    super.init(frame: frame)
    addTarget(self, action: #selector(changed), for: .valueChanged)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func changed() { onToggle?(isOn) }
}

private final class BlockButton: UIButton {
  var onTap: (() -> Void)?
  override init(frame: CGRect) {
    super.init(frame: frame)
    addTarget(self, action: #selector(tapped), for: .touchUpInside)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func tapped() { onTap?() }
}
