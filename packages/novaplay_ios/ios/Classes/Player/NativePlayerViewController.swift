import AVKit
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

/// iOS 15.0+ native player view controller matching Android's `NativePlayerActivity.kt` + `PlayerControlsView.kt` 1:1.
final class NativePlayerViewController: UIViewController, IosPlayerControllerUiDelegate, UIGestureRecognizerDelegate, UIDocumentPickerDelegate {
  private let controller: IosPlayerController
  private let ui: IosPlayerUi
  private lazy var overlayHost = IosPlayerOverlayHost(
    containerView: view,
    ui: ui,
    onHaptic: { [weak self] in self?.fireSelectionHaptic() },
    onWillOpenOverlay: { [weak self] in
      self?.hideControlsWorkItem?.cancel()
      self?.hideControlsAnimated(false)
    },
    onDidCloseMenu: { [weak self] in
      if self?.controlsVisible == true {
        self?.scheduleAutoHide()
      }
    }
  )
  private lazy var panels = IosPlayerPanels(
    controller: controller,
    ui: ui,
    host: overlayHost,
    onHaptic: { [weak self] in self?.fireSelectionHaptic() },
    onShowToast: { [weak self] msg, long in self?.controllerDidShowToast(msg, long: long) },
    onOrientationPreferenceChanged: { [weak self] preferLand in
      guard let self = self else { return }
      self.orientationStep = preferLand ? .landscapeRight : .portrait
      self.applyOrientationStep()
    }
  )

  private enum OrientationStep {
    case landscapeRight
    case landscapeLeft
    case portrait

    var mask: UIInterfaceOrientationMask {
      switch self {
      case .landscapeRight: return .landscapeRight
      case .landscapeLeft: return .landscapeLeft
      case .portrait: return .portrait
      }
    }

    var legacyOrientation: UIInterfaceOrientation {
      switch self {
      case .landscapeRight: return .landscapeRight
      case .landscapeLeft: return .landscapeLeft
      case .portrait: return .portrait
      }
    }
  }

  private var orientationStep: OrientationStep
  private var builtForLandscape: Bool?
  private var builtCutoutInset: CGFloat = -1
  private var controlsVisible: Bool = true
  private var screenLocked: Bool = false
  private var dismissedForPiP: Bool = false
  private var seekWaitUntil: TimeInterval = 0

  private var hideControlsWorkItem: DispatchWorkItem?
  private var hideNoticeWorkItem: DispatchWorkItem?
  private var hideToastWorkItem: DispatchWorkItem?
  private var hideHintWorkItem: DispatchWorkItem?
  private var hideLockWorkItem: DispatchWorkItem?
  private var hideFlashWorkItem: DispatchWorkItem?
  private var skipCountdownTimer: Timer?
  private var skipCountdownRemaining: Int = 0
  private var skipReturnPosMs: Int64 = 0
  private var uiRefreshTimer: Timer?
  private var bgObserver: NSObjectProtocol?

  // Persistent hierarchy layers
  private let hiddenVolumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 20))
  private let hiddenAirPlayTrigger = AVRoutePickerView(frame: CGRect(x: -2000, y: -2000, width: 34, height: 34))
  private var systemVolumeSlider: UISlider? {
    hiddenVolumeView.subviews.compactMap { $0 as? UISlider }.first
  }

  private let sidecarSubtitleLabel = PlayerInsetLabel(insets: UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))
  private let controlsLayer = UIView()
  private var topBarView: UIView?
  private var bottomBarView: UIView?

  // Dynamic controls rebuilt per orientation
  private weak var titleView: UILabel?
  private weak var resolutionChip: PlayerInsetLabel?
  private weak var episodeChip: PlayerInsetLabel?
  private weak var pipTopButton: UIView?
  private weak var audioTopButton: UIView?
  private weak var subtitleTopButton: UIView?
  private weak var clockLabel: UILabel?
  private weak var batteryIcon: BatteryView?
  private weak var batteryPercentLabel: UILabel?

  private weak var rewindCenterBtn: UIView?
  private weak var forwardCenterBtn: UIView?
  private weak var playCircleBtn: PlayerTappableView?
  private var playShownState: Bool?
  private weak var prevCircleBtn: PlayerCircleButton?
  private weak var nextCircleBtn: PlayerCircleButton?
  private weak var markHeadTailBtn: PlayerTappableView?
  private weak var markHeadTailLabel: UILabel?
  private var markIsOutro: Bool = false
  private weak var danmakuPill: PlayerPillView?
  private weak var episodesPill: PlayerPillView?
  private weak var epgPill: PlayerPillView?
  private weak var qualityPill: PlayerPillView?
  private weak var speedPill: PlayerPillView?
  private weak var statsLineChip: PlayerInsetLabel?
  private weak var positionLabel: UILabel?
  private weak var rightTimeLabel: UILabel?
  private weak var seekSlider: ThinSliderView?

  // Overlays outside `controlsLayer`
  private let loadingBox = UIView()
  private let loadingSpeedLabel = UILabel()
  private let cornerSpeedLabel = UILabel()
  private let topNoticeLabel = PlayerInsetLabel(insets: UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14))
  private let hintRow = UIStackView()
  private let hintWrap = UIView()
  private let seekHintLayer = UIView()
  private var seekHintIcon: PlayerIconView!
  private var seekHintLabel: UILabel!
  private var seekHintBar: ThinSliderView!
  private var seekHintBarLeadConstraint: NSLayoutConstraint?
  private var seekHintBarTrailConstraint: NSLayoutConstraint?
  private let centreFlash = UIView()
  private let skipBanner = UIView()
  private weak var skipBannerSubLabel: UILabel?
  private let lockLayer = UIView()
  private weak var lockInfoLabel: UILabel?
  private weak var lockProgressBar: ThinSliderView?
  private let errorLayer = UIView()
  private let errorTitleLabel = UILabel()
  private let errorDetailTextView = UITextView()
  private var errorScrollHeightConstraint: NSLayoutConstraint!
  private var shownErrorText: String?
  private let toastLabel = PlayerInsetLabel(insets: UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16))

  // Gesture state
  private enum PanMode { case none, seek, brightness, volume }
  private var panMode: PanMode = .none
  private var panStartPosMs: Int64 = 0
  private var panTargetPosMs: Int64 = 0
  private var panStartBrightness: CGFloat = 0.5
  private var panStartVolume: Float = 0.5
  private var savedSpeedBeforeBoost: Double?
  private var longPressOriginY: CGFloat = 0

  private static let clockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "HH:mm"
    return f
  }()

  init(controller: IosPlayerController) {
    self.controller = controller
    self.ui = IosPlayerUi(accentHex: controller.playbackConfig.accentColorHex)
    self.orientationStep = controller.playbackConfig.isPriorityLandscape ? .landscapeRight : .portrait
    super.init(nibName: nil, bundle: nil)
    controller.uiDelegate = self
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    uiRefreshTimer?.invalidate()
    skipCountdownTimer?.invalidate()
    if let obs = bgObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  override var prefersStatusBarHidden: Bool {
    !controlsVisible || view.bounds.width > view.bounds.height
  }

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  override var prefersHomeIndicatorAutoHidden: Bool { !controlsVisible }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    orientationStep.mask
  }

  override var shouldAutorotate: Bool { true }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    UIDevice.current.isBatteryMonitoringEnabled = true
    _ = panels // attach danmaku listeners immediately
    setupBaseHierarchy()
    setupGestures()
    setupBackgroundObserver()
    startPeriodicUiTick()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    dismissedForPiP = false
    applyOrientationStep()
    rebuildControlsIfNeeded(force: builtForLandscape == nil)
    showControls()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed && !dismissedForPiP && !controller.isClosed {
      uiRefreshTimer?.invalidate()
      skipCountdownTimer?.invalidate()
      controller.close(completed: false, dismissVC: false)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    rebuildControlsIfNeeded(force: false)
    updateErrorDetailHeightIfNeeded()
  }

  private func setupBackgroundObserver() {
    bgObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      if self.controller.playbackConfig.pauseOnBackground && !self.controller.kernel.isInPictureInPicture {
        self.controller.kernel.pause()
      }
    }
  }

  private func startPeriodicUiTick() {
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      guard let self = self, !self.controller.isClosed else { return }
      self.refreshInfoLayer()
      if self.controlsVisible || !self.lockLayer.isHidden {
        self.refreshControlsState()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    uiRefreshTimer = timer
  }

  private func applyOrientationStep() {
    if #available(iOS 16.0, *) {
      setNeedsUpdateOfSupportedInterfaceOrientations()
      view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: orientationStep.mask)) { _ in }
    } else {
      UIDevice.current.setValue(orientationStep.legacyOrientation.rawValue, forKey: "orientation")
      UIViewController.attemptRotationToDeviceOrientation()
    }
    setNeedsStatusBarAppearanceUpdate()
  }

  private func restorePortraitBeforeExit() {
    guard orientationStep != .portrait else { return }
    orientationStep = .portrait
    applyOrientationStep()
  }

  private func cycleOrientationStep() {
    switch orientationStep {
    case .landscapeRight:
      orientationStep = .landscapeLeft
    case .landscapeLeft:
      orientationStep = .portrait
    case .portrait:
      orientationStep = .landscapeRight
    }
    applyOrientationStep()
  }

  // MARK: - Base Hierarchy (Video, Danmaku, HUDs, Error, Panel/Menu Hosts)

  private func setupBaseHierarchy() {
    view.addSubview(hiddenVolumeView)
    view.addSubview(hiddenAirPlayTrigger)

    let videoView = controller.kernel.videoView
    videoView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(videoView)

    let danmakuView = controller.danmakuView
    danmakuView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(danmakuView)

    sidecarSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    sidecarSubtitleLabel.numberOfLines = 0
    sidecarSubtitleLabel.textAlignment = .center
    sidecarSubtitleLabel.textColor = .white
    sidecarSubtitleLabel.font = UIFont.systemFont(ofSize: 16.5, weight: .semibold)
    ui.applyRounded(sidecarSubtitleLabel, fill: IosPlayerUi.argb(0x8C00_0000), radius: 6)
    sidecarSubtitleLabel.clipsToBounds = true
    sidecarSubtitleLabel.isHidden = true
    view.addSubview(sidecarSubtitleLabel)

    controlsLayer.translatesAutoresizingMaskIntoConstraints = false
    controlsLayer.backgroundColor = .clear
    view.addSubview(controlsLayer)

    // Center Loading Box (`RingSpinnerView` + download speed)
    loadingBox.translatesAutoresizingMaskIntoConstraints = false
    ui.applyRounded(loadingBox, fill: IosPlayerUi.argb(0x8000_0000), radius: 14, stroke: IosPlayerUi.argb(0x1BFF_FFFF), strokeWidth: 1)
    let spinner = RingSpinnerView()
    loadingSpeedLabel.translatesAutoresizingMaskIntoConstraints = false
    loadingSpeedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    loadingSpeedLabel.textColor = IosPlayerUi.argb(0xE6FF_FFFF)
    loadingSpeedLabel.textAlignment = .center
    loadingSpeedLabel.text = "0.0 KB/s"
    let loadStack = UIStackView(arrangedSubviews: [spinner, loadingSpeedLabel])
    loadStack.translatesAutoresizingMaskIntoConstraints = false
    loadStack.axis = .vertical
    loadStack.alignment = .center
    loadStack.spacing = 8
    loadingBox.addSubview(loadStack)
    NSLayoutConstraint.activate([
      loadingBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
      spinner.widthAnchor.constraint(equalToConstant: 30),
      spinner.heightAnchor.constraint(equalToConstant: 30),
      loadStack.leadingAnchor.constraint(equalTo: loadingBox.leadingAnchor, constant: 20),
      loadStack.trailingAnchor.constraint(equalTo: loadingBox.trailingAnchor, constant: -20),
      loadStack.topAnchor.constraint(equalTo: loadingBox.topAnchor, constant: 14),
      loadStack.bottomAnchor.constraint(equalTo: loadingBox.bottomAnchor, constant: -14)
    ])
    loadingBox.isUserInteractionEnabled = false
    loadingBox.isHidden = true
    view.addSubview(loadingBox)

    // Top Notice (`64pt` from top)
    topNoticeLabel.translatesAutoresizingMaskIntoConstraints = false
    topNoticeLabel.isUserInteractionEnabled = false
    topNoticeLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
    topNoticeLabel.textColor = .white
    topNoticeLabel.clipsToBounds = true
    ui.applyRounded(topNoticeLabel, fill: IosPlayerUi.argb(0xB300_0000), radius: 18)
    topNoticeLabel.isHidden = true
    view.addSubview(topNoticeLabel)

    // Persistent Top Corner Net Speed (`8pt` from top)
    cornerSpeedLabel.translatesAutoresizingMaskIntoConstraints = false
    cornerSpeedLabel.isUserInteractionEnabled = false
    cornerSpeedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    cornerSpeedLabel.textColor = IosPlayerUi.argb(0x8DFF_FFFF)
    cornerSpeedLabel.textAlignment = .center
    cornerSpeedLabel.layer.shadowColor = UIColor.black.cgColor
    cornerSpeedLabel.layer.shadowOpacity = 0.45
    cornerSpeedLabel.layer.shadowRadius = 2.5
    cornerSpeedLabel.layer.shadowOffset = CGSize(width: 0, height: 1)
    cornerSpeedLabel.isHidden = true
    view.addSubview(cornerSpeedLabel)

    // Top Gesture / Long-Press Speed Hint (`36pt` from top)
    hintWrap.translatesAutoresizingMaskIntoConstraints = false
    hintWrap.isUserInteractionEnabled = false
    ui.applyRounded(hintWrap, fill: IosPlayerUi.argb(0xA600_0000), radius: 16)
    hintRow.translatesAutoresizingMaskIntoConstraints = false
    hintRow.axis = .horizontal
    hintRow.alignment = .center
    hintRow.spacing = 8
    hintWrap.addSubview(hintRow)
    NSLayoutConstraint.activate([
      hintRow.leadingAnchor.constraint(equalTo: hintWrap.leadingAnchor, constant: 14),
      hintRow.trailingAnchor.constraint(equalTo: hintWrap.trailingAnchor, constant: -14),
      hintRow.topAnchor.constraint(equalTo: hintWrap.topAnchor, constant: 7),
      hintRow.bottomAnchor.constraint(equalTo: hintWrap.bottomAnchor, constant: -7)
    ])
    hintWrap.isHidden = true
    view.addSubview(hintWrap)

    // Bottom Seek Preview Hint (`»» 09:03` + `2pt` preview bar)
    seekHintLayer.translatesAutoresizingMaskIntoConstraints = false
    seekHintLayer.isUserInteractionEnabled = false
    seekHintLayer.isHidden = true
    seekHintIcon = ui.icon(IosPlayerIcon.DOUBLE_RIGHT, size: 20)
    seekHintLabel = ui.text("", size: 15, mono: true)
    let seekTextWrap = UIView()
    seekTextWrap.translatesAutoresizingMaskIntoConstraints = false
    ui.applyRounded(seekTextWrap, fill: IosPlayerUi.argb(0x9900_0000), radius: 14)
    let seekH = UIStackView(arrangedSubviews: [seekHintIcon, seekHintLabel])
    seekH.translatesAutoresizingMaskIntoConstraints = false
    seekH.axis = .horizontal
    seekH.alignment = .center
    seekH.spacing = 8
    seekTextWrap.addSubview(seekH)
    seekHintBar = ThinSliderView(fillColor: .white, trackColor: IosPlayerUi.argb(0x40FF_FFFF), thumbSize: 0, trackHeight: 2)
    seekHintBar.isUserInteractionEnabled = false
    seekHintLayer.addSubview(seekTextWrap)
    seekHintLayer.addSubview(seekHintBar)
    let sbLead = seekHintBar.leadingAnchor.constraint(equalTo: seekHintLayer.leadingAnchor, constant: 16)
    let sbTrail = seekHintBar.trailingAnchor.constraint(equalTo: seekHintLayer.trailingAnchor, constant: -16)
    seekHintBarLeadConstraint = sbLead
    seekHintBarTrailConstraint = sbTrail
    NSLayoutConstraint.activate([
      seekH.leadingAnchor.constraint(equalTo: seekTextWrap.leadingAnchor, constant: 12),
      seekH.trailingAnchor.constraint(equalTo: seekTextWrap.trailingAnchor, constant: -12),
      seekH.topAnchor.constraint(equalTo: seekTextWrap.topAnchor, constant: 5),
      seekH.bottomAnchor.constraint(equalTo: seekTextWrap.bottomAnchor, constant: -5),
      seekTextWrap.centerXAnchor.constraint(equalTo: seekHintLayer.centerXAnchor),
      seekTextWrap.bottomAnchor.constraint(equalTo: seekHintLayer.bottomAnchor, constant: -56),
      sbLead,
      sbTrail,
      seekHintBar.bottomAnchor.constraint(equalTo: seekHintLayer.safeAreaLayoutGuide.bottomAnchor, constant: -2)
    ])
    view.addSubview(seekHintLayer)

    // Double-tap Play/Pause Centre Flash (`56x56pt`)
    centreFlash.translatesAutoresizingMaskIntoConstraints = false
    centreFlash.isUserInteractionEnabled = false
    centreFlash.isHidden = true
    view.addSubview(centreFlash)

    // Bottom-Right Skip Banner (`已跳过片段，是否返回原播放进度？`)
    skipBanner.translatesAutoresizingMaskIntoConstraints = false
    ui.applyRounded(skipBanner, fill: IosPlayerUi.argb(0xEB1C_1C22), radius: 14, stroke: IosPlayerUi.argb(0x29FF_FFFF), strokeWidth: 0.8)
    skipBanner.isHidden = true
    view.addSubview(skipBanner)

    // Lock Layer
    lockLayer.translatesAutoresizingMaskIntoConstraints = false
    lockLayer.backgroundColor = .clear
    lockLayer.isHidden = true
    view.addSubview(lockLayer)

    // Full-screen Error Layer (`取消` / `复制错误信息` / `重试`)
    buildErrorLayer()
    view.addSubview(errorLayer)

    // Slide-in Panel Host & Anchored Menu Host
    view.addSubview(overlayHost.panelHost)
    view.addSubview(overlayHost.menuHost)

    // Bottom Toast
    toastLabel.translatesAutoresizingMaskIntoConstraints = false
    toastLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    toastLabel.textColor = .white
    toastLabel.numberOfLines = 2
    toastLabel.textAlignment = .center
    toastLabel.clipsToBounds = true
    ui.applyRounded(toastLabel, fill: IosPlayerUi.argb(0xE619_191E), radius: 16, stroke: IosPlayerUi.argb(0x24FF_FFFF), strokeWidth: 0.6)
    toastLabel.isHidden = true
    view.addSubview(toastLabel)

    NSLayoutConstraint.activate([
      videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      videoView.topAnchor.constraint(equalTo: view.topAnchor),
      videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      danmakuView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      danmakuView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      danmakuView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      danmakuView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      sidecarSubtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      sidecarSubtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      sidecarSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
      sidecarSubtitleLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),

      controlsLayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controlsLayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controlsLayer.topAnchor.constraint(equalTo: view.topAnchor),
      controlsLayer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      loadingBox.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      loadingBox.centerYAnchor.constraint(equalTo: view.centerYAnchor),

      topNoticeLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      topNoticeLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 54),
      topNoticeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
      topNoticeLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

      cornerSpeedLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cornerSpeedLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),

      hintWrap.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      hintWrap.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 28),

      seekHintLayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      seekHintLayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      seekHintLayer.topAnchor.constraint(equalTo: view.topAnchor),
      seekHintLayer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      centreFlash.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      centreFlash.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      centreFlash.widthAnchor.constraint(equalToConstant: 56),
      centreFlash.heightAnchor.constraint(equalToConstant: 56),

      skipBanner.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      skipBanner.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -76),
      skipBanner.widthAnchor.constraint(lessThanOrEqualToConstant: 290),

      lockLayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      lockLayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      lockLayer.topAnchor.constraint(equalTo: view.topAnchor),
      lockLayer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      errorLayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      errorLayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      errorLayer.topAnchor.constraint(equalTo: view.topAnchor),
      errorLayer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      overlayHost.panelHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      overlayHost.panelHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      overlayHost.panelHost.topAnchor.constraint(equalTo: view.topAnchor),
      overlayHost.panelHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      overlayHost.menuHost.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      overlayHost.menuHost.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      overlayHost.menuHost.topAnchor.constraint(equalTo: view.topAnchor),
      overlayHost.menuHost.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      toastLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -42),
      toastLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      toastLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
    ])
  }

  private func buildErrorLayer() {
    errorLayer.translatesAutoresizingMaskIntoConstraints = false
    errorLayer.backgroundColor = IosPlayerUi.argb(0xCC00_0000)
    errorLayer.isHidden = true

    errorTitleLabel.translatesAutoresizingMaskIntoConstraints = false
    errorTitleLabel.font = UIFont.systemFont(ofSize: 17, weight: .bold)
    errorTitleLabel.textColor = .white
    errorTitleLabel.textAlignment = .center
    errorTitleLabel.numberOfLines = 2

    errorDetailTextView.translatesAutoresizingMaskIntoConstraints = false
    errorDetailTextView.backgroundColor = .clear
    errorDetailTextView.textColor = IosPlayerUi.argb(0xFFE0_E0E0)
    errorDetailTextView.font = UIFont.systemFont(ofSize: 13)
    errorDetailTextView.isEditable = false
    errorDetailTextView.isSelectable = true
    errorDetailTextView.textAlignment = .center
    errorDetailTextView.textContainerInset = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
    errorScrollHeightConstraint = errorDetailTextView.heightAnchor.constraint(equalToConstant: 64)

    func makeErrorBtn(_ label: String, emphasized: Bool, action: @escaping () -> Void) -> PlayerTappableView {
      let b = PlayerTappableView()
      ui.applyRounded(
        b,
        fill: emphasized ? IosPlayerUi.argb(0x44FF_FFFF) : IosPlayerUi.argb(0x22FF_FFFF),
        radius: 18,
        stroke: IosPlayerUi.argb(0x44FF_FFFF),
        strokeWidth: 1
      )
      let lbl = ui.text(label, size: 14)
      lbl.isUserInteractionEnabled = false
      b.addSubview(lbl)
      NSLayoutConstraint.activate([
        lbl.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 18),
        lbl.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -18),
        lbl.topAnchor.constraint(equalTo: b.topAnchor, constant: 8),
        lbl.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -8)
      ])
      b.onTap = { [weak self] in
        self?.fireSelectionHaptic()
        action()
      }
      return b
    }

    let btnRow = UIStackView(arrangedSubviews: [
      makeErrorBtn(IosPlayerUiText.t("取消", "Cancel"), emphasized: false) { [weak self] in
        self?.controller.dismissError()
      },
      makeErrorBtn(IosPlayerUiText.t("复制错误信息", "Copy error"), emphasized: false) { [weak self] in
        guard let self = self else { return }
        UIPasteboard.general.string = self.controller.copyableErrorText
        self.controllerDidShowToast(IosPlayerUiText.t("已复制错误信息", "Error copied"), long: false)
      },
      makeErrorBtn(IosPlayerUiText.t("重试", "Retry"), emphasized: true) { [weak self] in
        self?.controller.retry()
      }
    ])
    btnRow.axis = .horizontal
    btnRow.alignment = .center
    btnRow.spacing = 12

    let box = UIStackView(arrangedSubviews: [errorTitleLabel, errorDetailTextView, btnRow])
    box.translatesAutoresizingMaskIntoConstraints = false
    box.axis = .vertical
    box.alignment = .center
    box.spacing = 14
    errorLayer.addSubview(box)
    NSLayoutConstraint.activate([
      errorScrollHeightConstraint,
      errorDetailTextView.widthAnchor.constraint(lessThanOrEqualTo: errorLayer.widthAnchor, constant: -56),
      errorDetailTextView.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
      box.centerXAnchor.constraint(equalTo: errorLayer.centerXAnchor),
      box.centerYAnchor.constraint(equalTo: errorLayer.centerYAnchor),
      box.leadingAnchor.constraint(greaterThanOrEqualTo: errorLayer.leadingAnchor, constant: 28),
      box.trailingAnchor.constraint(lessThanOrEqualTo: errorLayer.trailingAnchor, constant: -28)
    ])
  }

  private func updateErrorDetailHeightIfNeeded() {
    guard !errorLayer.isHidden, view.bounds.height > 0 else { return }
    let maxW = max(240, view.bounds.width - 64)
    let fit = errorDetailTextView.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
    let maxH = floor(view.bounds.height * 0.4)
    let nextH = max(36, min(maxH, ceil(fit.height + 4)))
    if abs(errorScrollHeightConstraint.constant - nextH) > 1 {
      errorScrollHeightConstraint.constant = nextH
    }
  }

  // MARK: - Orientation-Adaptive Controls Rebuild (1:1 `PlayerControlsView.rebuild()`)

  private func rebuildControlsIfNeeded(force: Bool) {
    guard view.bounds.width > 0, view.bounds.height > 0 else { return }
    let land = view.bounds.width > view.bounds.height
    let safe = view.safeAreaInsets
    let cutout = max(safe.left, safe.right)
    if !force && builtForLandscape == land && abs(builtCutoutInset - cutout) < 0.5 {
      return
    }
    builtForLandscape = land
    builtCutoutInset = cutout

    overlayHost.closeMenu()
    if overlayHost.isPanelOpen {
      overlayHost.closePanel()
    }

    controlsLayer.subviews.forEach { $0.removeFromSuperview() }
    playShownState = nil

    let edgeMargin = (land ? 20.0 : 16.0) + cutout
    seekHintBarLeadConstraint?.constant = 16.0 + cutout
    seekHintBarTrailConstraint?.constant = -(16.0 + cutout)

    let top = buildTopBar(landscape: land, cutoutInset: cutout)
    topBarView = top
    controlsLayer.addSubview(top)

    let rightLock = buildLockEdgeButton(closed: false)
    controlsLayer.addSubview(rightLock)
    if land {
      let leftLock = buildLockEdgeButton(closed: false)
      controlsLayer.addSubview(leftLock)
      NSLayoutConstraint.activate([
        leftLock.leadingAnchor.constraint(equalTo: controlsLayer.leadingAnchor, constant: edgeMargin),
        leftLock.centerYAnchor.constraint(equalTo: controlsLayer.centerYAnchor)
      ])
    }

    // Center Fast Rewind / Fast Forward (`44x44pt` hit areas, `50pt` gap)
    let centerSeekRow = UIView()
    centerSeekRow.translatesAutoresizingMaskIntoConstraints = false
    let rwBtn = PlayerTappableView()
    let rwIc = ui.icon(IosPlayerIcon.REWIND, size: 31)
    rwBtn.addSubview(rwIc)
    rwBtn.onTap = { [weak self] in
      guard let self = self else { return }
      self.touchControls(haptic: true)
      self.stepByConfiguredSeconds(forward: false)
    }
    let fwBtn = PlayerTappableView()
    let fwIc = ui.icon(IosPlayerIcon.FORWARD, size: 31)
    fwBtn.addSubview(fwIc)
    fwBtn.onTap = { [weak self] in
      guard let self = self else { return }
      self.touchControls(haptic: true)
      self.stepByConfiguredSeconds(forward: true)
    }
    rewindCenterBtn = rwBtn
    forwardCenterBtn = fwBtn
    centerSeekRow.addSubview(rwBtn)
    centerSeekRow.addSubview(fwBtn)
    NSLayoutConstraint.activate([
      rwBtn.leadingAnchor.constraint(equalTo: centerSeekRow.leadingAnchor),
      rwBtn.topAnchor.constraint(equalTo: centerSeekRow.topAnchor),
      rwBtn.bottomAnchor.constraint(equalTo: centerSeekRow.bottomAnchor),
      rwBtn.widthAnchor.constraint(equalToConstant: 44),
      rwBtn.heightAnchor.constraint(equalToConstant: 44),
      rwIc.centerXAnchor.constraint(equalTo: rwBtn.centerXAnchor),
      rwIc.centerYAnchor.constraint(equalTo: rwBtn.centerYAnchor),

      fwBtn.leadingAnchor.constraint(equalTo: rwBtn.trailingAnchor, constant: 50),
      fwBtn.trailingAnchor.constraint(equalTo: centerSeekRow.trailingAnchor),
      fwBtn.topAnchor.constraint(equalTo: centerSeekRow.topAnchor),
      fwBtn.bottomAnchor.constraint(equalTo: centerSeekRow.bottomAnchor),
      fwBtn.widthAnchor.constraint(equalToConstant: 44),
      fwBtn.heightAnchor.constraint(equalToConstant: 44),
      fwIc.centerXAnchor.constraint(equalTo: fwBtn.centerXAnchor),
      fwIc.centerYAnchor.constraint(equalTo: fwBtn.centerYAnchor)
    ])
    controlsLayer.addSubview(centerSeekRow)

    let bottom = buildBottomBar(landscape: land, cutoutInset: cutout)
    bottomBarView = bottom
    controlsLayer.addSubview(bottom)

    NSLayoutConstraint.activate([
      top.leadingAnchor.constraint(equalTo: controlsLayer.leadingAnchor),
      top.trailingAnchor.constraint(equalTo: controlsLayer.trailingAnchor),
      top.topAnchor.constraint(equalTo: controlsLayer.topAnchor),

      rightLock.trailingAnchor.constraint(equalTo: controlsLayer.trailingAnchor, constant: -edgeMargin),
      rightLock.centerYAnchor.constraint(equalTo: controlsLayer.centerYAnchor),

      centerSeekRow.centerXAnchor.constraint(equalTo: controlsLayer.centerXAnchor),
      centerSeekRow.centerYAnchor.constraint(equalTo: controlsLayer.centerYAnchor),

      bottom.leadingAnchor.constraint(equalTo: controlsLayer.leadingAnchor),
      bottom.trailingAnchor.constraint(equalTo: controlsLayer.trailingAnchor),
      bottom.bottomAnchor.constraint(equalTo: controlsLayer.bottomAnchor)
    ])

    buildLockLayer(landscape: land, cutoutInset: cutout)
    refreshControlsState()
    refreshInfoLayer()
  }

  private func buildLockEdgeButton(closed: Bool) -> PlayerTappableView {
    let btn = PlayerTappableView()
    let ic = ui.icon(closed ? IosPlayerIcon.LOCK : IosPlayerIcon.LOCK_OPEN, size: 27)
    btn.addSubview(ic)
    NSLayoutConstraint.activate([
      btn.widthAnchor.constraint(equalToConstant: 44),
      btn.heightAnchor.constraint(equalToConstant: 44),
      ic.centerXAnchor.constraint(equalTo: btn.centerXAnchor),
      ic.centerYAnchor.constraint(equalTo: btn.centerYAnchor)
    ])
    btn.onTap = { [weak self] in
      guard let self = self else { return }
      self.fireSelectionHaptic()
      self.setScreenLocked(!closed)
    }
    return btn
  }

  private func buildTopBar(landscape: Bool, cutoutInset: CGFloat) -> UIView {
    let bar = PlayerGradientView(topColor: IosPlayerUi.argb(0x5900_0000), bottomColor: .clear)
    let topPad = max(10.0, landscape ? 10.0 : view.safeAreaInsets.top + 4.0)
    let sidePad = 16.0 + cutoutInset

    let row = UIStackView()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 0
    bar.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: sidePad),
      row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -sidePad),
      row.topAnchor.constraint(equalTo: bar.topAnchor, constant: topPad),
      row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -14)
    ])

    let backBtn = ui.circleButton(IosPlayerIcon.BACK, size: 38, iconSize: 20) { [weak self] in
      guard let self = self else { return }
      self.fireSelectionHaptic()
      self.restorePortraitBeforeExit()
      self.controller.close(completed: false, dismissVC: true)
    }
    row.addArrangedSubview(backBtn)
    row.setCustomSpacing(13, after: backBtn)

    // Title + Chips column
    let titleLbl = ui.text(controller.title, size: 16, medium: true)
    titleLbl.numberOfLines = 1
    titleLbl.lineBreakMode = .byTruncatingTail
    titleLbl.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    titleLbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleView = titleLbl

    let resChip = ui.chip()
    let epChip = ui.chip(maxWidth: landscape ? 240 : 108)
    resolutionChip = resChip
    episodeChip = epChip

    let chipRow = UIStackView(arrangedSubviews: [resChip, epChip])
    chipRow.axis = .horizontal
    chipRow.alignment = .center
    chipRow.spacing = 6

    let titleCol = UIStackView(arrangedSubviews: [titleLbl, chipRow])
    titleCol.axis = .vertical
    titleCol.alignment = .leading
    titleCol.spacing = 4
    titleCol.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    titleCol.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.addArrangedSubview(titleCol)
    row.setCustomSpacing(10, after: titleCol)

    // Flexible spacer that pushes all top-right action buttons and clock/battery to the right edge
    let topSpacer = UIView()
    topSpacer.translatesAutoresizingMaskIntoConstraints = false
    topSpacer.isUserInteractionEnabled = false
    topSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
    topSpacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
    row.addArrangedSubview(topSpacer)

    let actionsStack = UIStackView()
    actionsStack.axis = .horizontal
    actionsStack.alignment = .center
    actionsStack.spacing = 8
    actionsStack.setContentHuggingPriority(.required, for: .horizontal)
    actionsStack.setContentCompressionResistancePriority(.required, for: .horizontal)

    @discardableResult
    func addTopCircle(_ code: Int, onClick: @escaping (UIView) -> Void) -> PlayerCircleButton {
      let b = ui.circleButton(code, size: 34, iconSize: 21)
      b.onTap = { [weak self, weak b] in
        guard let self = self, let b = b else { return }
        self.touchControls(haptic: true)
        onClick(b)
      }
      actionsStack.addArrangedSubview(b)
      return b
    }

    audioTopButton = nil
    subtitleTopButton = nil
    pipTopButton = nil

    if landscape {
      addTopCircle(IosPlayerIcon.CAMERA) { [weak self] _ in self?.captureScreenshot() }
      addTopCircle(IosPlayerIcon.REFRESH) { [weak self] _ in self?.controller.reload() }
      addTopCircle(IosPlayerIcon.ROTATE) { [weak self] _ in self?.cycleOrientationStep() }
      pipTopButton = addTopCircle(IosPlayerIcon.PIP) { [weak self] _ in self?.enterPictureInPicture() }
      audioTopButton = addTopCircle(IosPlayerIcon.MUSIC) { [weak self] anchor in self?.showAudioMenu(anchor: anchor) }
      subtitleTopButton = addTopCircle(IosPlayerIcon.SUBTITLES) { [weak self] anchor in self?.showSubtitlesMenu(anchor: anchor) }

      // Compact 34pt circle AirPlay picker matching top bar buttons
      let airPlayWrap = UIView()
      airPlayWrap.translatesAutoresizingMaskIntoConstraints = false
      airPlayWrap.backgroundColor = IosPlayerUi.btnFill
      airPlayWrap.layer.cornerRadius = 17
      airPlayWrap.layer.borderColor = IosPlayerUi.btnStroke.cgColor
      airPlayWrap.layer.borderWidth = 0.6
      let picker = AVRoutePickerView(frame: .zero)
      picker.translatesAutoresizingMaskIntoConstraints = false
      picker.tintColor = .white
      picker.activeTintColor = ui.accent
      picker.prioritizesVideoDevices = true
      airPlayWrap.addSubview(picker)
      NSLayoutConstraint.activate([
        airPlayWrap.widthAnchor.constraint(equalToConstant: 34),
        airPlayWrap.heightAnchor.constraint(equalToConstant: 34),
        picker.centerXAnchor.constraint(equalTo: airPlayWrap.centerXAnchor),
        picker.centerYAnchor.constraint(equalTo: airPlayWrap.centerYAnchor),
        picker.widthAnchor.constraint(equalToConstant: 26),
        picker.heightAnchor.constraint(equalToConstant: 26)
      ])
      actionsStack.addArrangedSubview(airPlayWrap)

      addTopCircle(IosPlayerIcon.SETTINGS) { [weak self] _ in self?.panels.showSettings() }

      // Clock + Battery stack (`16pt` left margin)
      let clk = ui.text("00:00", size: 12.5, mono: true)
      clk.setContentHuggingPriority(.required, for: .horizontal)
      clk.setContentCompressionResistancePriority(.required, for: .horizontal)
      clockLabel = clk
      let bat = BatteryView()
      batteryIcon = bat
      let batTxt = ui.text("100%", size: 10.5, mono: true)
      batTxt.setContentHuggingPriority(.required, for: .horizontal)
      batTxt.setContentCompressionResistancePriority(.required, for: .horizontal)
      batteryPercentLabel = batTxt
      let batRow = UIStackView(arrangedSubviews: [bat, batTxt])
      batRow.axis = .horizontal
      batRow.alignment = .center
      batRow.spacing = 5
      batRow.setContentHuggingPriority(.required, for: .horizontal)
      batRow.setContentCompressionResistancePriority(.required, for: .horizontal)
      NSLayoutConstraint.activate([
        bat.widthAnchor.constraint(equalToConstant: 19),
        bat.heightAnchor.constraint(equalToConstant: 10)
      ])
      let statusCol = UIStackView(arrangedSubviews: [clk, batRow])
      statusCol.axis = .vertical
      statusCol.alignment = .leading
      statusCol.spacing = 3
      statusCol.setContentHuggingPriority(.required, for: .horizontal)
      statusCol.setContentCompressionResistancePriority(.required, for: .horizontal)
      row.addArrangedSubview(actionsStack)
      row.setCustomSpacing(16, after: actionsStack)
      row.addArrangedSubview(statusCol)
    } else {
      clockLabel = nil
      batteryIcon = nil
      batteryPercentLabel = nil
      addTopCircle(IosPlayerIcon.MORE) { [weak self] anchor in self?.showPortraitMoreMenu(anchor: anchor) }
      addTopCircle(IosPlayerIcon.ROTATE) { [weak self] _ in self?.cycleOrientationStep() }
      addTopCircle(IosPlayerIcon.SETTINGS) { [weak self] _ in self?.panels.showSettings() }
      row.addArrangedSubview(actionsStack)
    }

    return bar
  }

  private func buildBottomBar(landscape: Bool, cutoutInset: CGFloat) -> UIView {
    let bar = PlayerGradientView(topColor: .clear, bottomColor: IosPlayerUi.argb(0x7300_0000))
    let sidePad = 16.0 + cutoutInset
    let botPad = max(12.0, view.safeAreaInsets.bottom + 4.0)

    let vStack = UIStackView()
    vStack.translatesAutoresizingMaskIntoConstraints = false
    vStack.axis = .vertical
    vStack.alignment = .fill
    vStack.spacing = 0
    bar.addSubview(vStack)
    NSLayoutConstraint.activate([
      vStack.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: sidePad),
      vStack.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -sidePad),
      vStack.topAnchor.constraint(equalTo: bar.topAnchor, constant: 26),
      vStack.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -botPad)
    ])

    // Right-aligned statsLine chip (`6pt` above seek row)
    let statsRow = UIStackView()
    statsRow.axis = .horizontal
    statsRow.alignment = .center
    let sChip = ui.chip()
    statsLineChip = sChip
    statsRow.addArrangedSubview(UIView())
    statsRow.addArrangedSubview(sChip)
    vStack.addArrangedSubview(statsRow)
    vStack.setCustomSpacing(6, after: statsRow)

    // Seek row
    let posLbl = ui.text("00:00", size: 12, color: IosPlayerUi.argb(0xE6FF_FFFF), mono: true)
    posLbl.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
    positionLabel = posLbl

    let rightLbl = ui.text("00:00", size: 12, color: IosPlayerUi.argb(0x99FF_FFFF), mono: true)
    rightLbl.textAlignment = .right
    rightLbl.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
    rightTimeLabel = rightLbl

    let slider = ThinSliderView(fillColor: .white, trackColor: IosPlayerUi.argb(0x38FF_FFFF), thumbSize: 11, trackHeight: 3) { [weak self] f, done in
      guard let self = self else { return }
      let dur = self.controller.kernel.durationMs
      let targetMs = Int64(Double(dur) * Double(f))
      self.positionLabel?.text = IosPlayerUiText.clock(targetMs)
      self.rightTimeLabel?.text = IosPlayerUiText.rightTime(
        positionMs: targetMs,
        durationMs: dur,
        showTotal: self.controller.playbackConfig.isShowAllDuration
      )
      if done {
        self.hideSeekHint()
        self.beginSeekWait()
        self.controller.seekTo(targetMs)
        self.scheduleAutoHide()
      } else {
        self.hideControlsWorkItem?.cancel()
        self.showSeekHint(targetMs: targetMs, forward: targetMs >= self.controller.kernel.positionMs, showBar: false)
      }
    }
    seekSlider = slider

    let seekRow = UIStackView(arrangedSubviews: [posLbl, slider, rightLbl])
    seekRow.axis = .horizontal
    seekRow.alignment = .center
    seekRow.spacing = 10
    vStack.addArrangedSubview(seekRow)
    vStack.setCustomSpacing(8, after: seekRow)

    // Controls row
    let playBtn = PlayerTappableView()
    playBtn.backgroundColor = .white
    playBtn.layer.cornerRadius = 20
    NSLayoutConstraint.activate([
      playBtn.widthAnchor.constraint(equalToConstant: 40),
      playBtn.heightAnchor.constraint(equalToConstant: 40)
    ])
    playBtn.onTap = { [weak self] in
      guard let self = self else { return }
      self.touchControls(haptic: true)
      self.controller.togglePause()
      self.refreshControlsState()
    }
    playCircleBtn = playBtn

    let prevBtn = ui.circleButton(
      IosPlayerIcon.PREV,
      size: 32,
      iconSize: 19,
      fill: IosPlayerUi.argb(0x4D11_1114)
    ) { [weak self] in
      guard let self = self else { return }
      self.touchControls(haptic: true)
      _ = self.controller.previousEpisode()
    }
    let nextBtn = ui.circleButton(
      IosPlayerIcon.NEXT,
      size: 32,
      iconSize: 19,
      fill: IosPlayerUi.argb(0x4D11_1114)
    ) { [weak self] in
      guard let self = self else { return }
      self.touchControls(haptic: true)
      _ = self.controller.nextEpisode()
    }
    prevCircleBtn = prevBtn
    nextCircleBtn = nextBtn

    // Mark Intro / Outro button
    let markBtn = PlayerTappableView()
    ui.applyRounded(markBtn, fill: IosPlayerUi.btnFill, radius: 10, stroke: IosPlayerUi.btnStroke, strokeWidth: 0.6)
    let markIc = ui.icon(IosPlayerIcon.SKIP_NEXT, size: 11)
    let markLbl = ui.text("", size: 13.5)
    markLbl.isUserInteractionEnabled = false
    let markH = UIStackView(arrangedSubviews: [markIc, markLbl])
    markH.translatesAutoresizingMaskIntoConstraints = false
    markH.axis = .horizontal
    markH.alignment = .center
    markH.spacing = 8
    markH.isUserInteractionEnabled = false
    markBtn.addSubview(markH)
    NSLayoutConstraint.activate([
      markBtn.heightAnchor.constraint(equalToConstant: landscape ? 38 : 32),
      markH.leadingAnchor.constraint(equalTo: markBtn.leadingAnchor, constant: 14),
      markH.trailingAnchor.constraint(equalTo: markBtn.trailingAnchor, constant: -13),
      markH.centerYAnchor.constraint(equalTo: markBtn.centerYAnchor)
    ])
    markBtn.onTap = { [weak self] in
      guard let self = self else { return }
      self.touchControls(haptic: true)
      if self.markIsOutro {
        self.controller.markOutro()
      } else {
        self.controller.markIntro()
      }
    }
    markHeadTailBtn = markBtn
    markHeadTailLabel = markLbl

    let dmPill = ui.pill(IosPlayerUiText.t("弹", "Danmaku"), leading: IosPlayerIcon.FORUM) { [weak self] in
      guard let self = self else { return }
      self.touchControls(haptic: true)
      self.panels.showDanmaku()
    }
    let epPill = ui.pill(
      controller.isLive ? IosPlayerUiText.t("频道", "Channels") : IosPlayerUiText.t("选集", "Episodes"),
      leading: IosPlayerIcon.MENU
    ) { [weak self] in
      guard let self = self else { return }
      self.touchControls(haptic: true)
      self.panels.showEpisodesOrChannels()
    }
    let epg = ui.pill(IosPlayerUiText.t("节目单", "EPG"), leading: IosPlayerIcon.CLOCK) { [weak self] in
      guard let self = self else { return }
      self.touchControls(haptic: true)
      self.panels.showEpg()
    }
    epg.isHidden = controller.epgProgrammes.isEmpty

    let qPill = ui.pill("", trailing: IosPlayerIcon.UNFOLD)
    qPill.onTap = { [weak self, weak qPill] in
      guard let self = self, let anchor = qPill else { return }
      self.touchControls(haptic: true)
      self.showQualityMenu(anchor: anchor)
    }

    let spPill = ui.pill("1.0x", mono: true)
    spPill.onTap = { [weak self, weak spPill] in
      guard let self = self, let anchor = spPill else { return }
      self.touchControls(haptic: true)
      self.overlayHost.showSpeedMenu(anchor: anchor, current: self.controller.currentSpeed) { [weak self] nextSp in
        self?.controller.setSpeed(nextSp)
      }
    }

    danmakuPill = dmPill
    episodesPill = epPill
    epgPill = epg
    qualityPill = qPill
    speedPill = spPill

    let mainRow = UIStackView(arrangedSubviews: [playBtn, prevBtn, nextBtn])
    mainRow.axis = .horizontal
    mainRow.alignment = .center
    mainRow.spacing = 8

    if landscape {
      mainRow.addArrangedSubview(markBtn)
      let spacer = UIView()
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      mainRow.addArrangedSubview(spacer)
      mainRow.addArrangedSubview(dmPill)
      mainRow.addArrangedSubview(epPill)
      mainRow.addArrangedSubview(epg)
      mainRow.addArrangedSubview(qPill)
      mainRow.addArrangedSubview(spPill)
      vStack.addArrangedSubview(mainRow)
    } else {
      let spacer = UIView()
      spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
      mainRow.addArrangedSubview(spacer)
      mainRow.addArrangedSubview(qPill)
      mainRow.addArrangedSubview(spPill)
      vStack.addArrangedSubview(mainRow)

      let secondRowWrap = UIView()
      secondRowWrap.translatesAutoresizingMaskIntoConstraints = false
      let secondRow = UIStackView(arrangedSubviews: [dmPill, epPill, epg, markBtn, UIView()])
      secondRow.translatesAutoresizingMaskIntoConstraints = false
      secondRow.axis = .horizontal
      secondRow.alignment = .center
      secondRow.spacing = 8
      secondRowWrap.addSubview(secondRow)
      NSLayoutConstraint.activate([
        secondRow.leadingAnchor.constraint(equalTo: secondRowWrap.leadingAnchor, constant: 8),
        secondRow.trailingAnchor.constraint(equalTo: secondRowWrap.trailingAnchor),
        secondRow.topAnchor.constraint(equalTo: secondRowWrap.topAnchor, constant: 12),
        secondRow.bottomAnchor.constraint(equalTo: secondRowWrap.bottomAnchor)
      ])
      vStack.addArrangedSubview(secondRowWrap)
    }

    return bar
  }

  private func buildLockLayer(landscape: Bool, cutoutInset: CGFloat) {
    lockLayer.subviews.forEach { $0.removeFromSuperview() }
    let edgeMargin = (landscape ? 20.0 : 16.0) + cutoutInset

    let rightClosed = buildLockEdgeButton(closed: true)
    lockLayer.addSubview(rightClosed)
    NSLayoutConstraint.activate([
      rightClosed.trailingAnchor.constraint(equalTo: lockLayer.trailingAnchor, constant: -edgeMargin),
      rightClosed.centerYAnchor.constraint(equalTo: lockLayer.centerYAnchor)
    ])
    if landscape {
      let leftClosed = buildLockEdgeButton(closed: true)
      lockLayer.addSubview(leftClosed)
      NSLayoutConstraint.activate([
        leftClosed.leadingAnchor.constraint(equalTo: lockLayer.leadingAnchor, constant: edgeMargin),
        leftClosed.centerYAnchor.constraint(equalTo: lockLayer.centerYAnchor)
      ])
    }

    let infoLbl = ui.text("", size: 10.5, color: IosPlayerUi.argb(0xE6FF_FFFF), mono: true)
    lockInfoLabel = infoLbl
    let bar = ThinSliderView(fillColor: ui.accent, trackColor: IosPlayerUi.argb(0x33FF_FFFF), thumbSize: 0, trackHeight: 2)
    bar.isUserInteractionEnabled = false
    lockProgressBar = bar
    lockLayer.addSubview(infoLbl)
    lockLayer.addSubview(bar)
    NSLayoutConstraint.activate([
      infoLbl.leadingAnchor.constraint(equalTo: lockLayer.leadingAnchor, constant: 27 + cutoutInset),
      infoLbl.bottomAnchor.constraint(equalTo: lockLayer.safeAreaLayoutGuide.bottomAnchor, constant: -22),
      bar.leadingAnchor.constraint(equalTo: lockLayer.leadingAnchor, constant: 19 + cutoutInset),
      bar.trailingAnchor.constraint(equalTo: lockLayer.trailingAnchor, constant: -(19 + cutoutInset)),
      bar.bottomAnchor.constraint(equalTo: lockLayer.safeAreaLayoutGuide.bottomAnchor, constant: -4)
    ])
  }

  // MARK: - Menus (`Quality`, `Subtitles`, `Audio`, Portrait `•••` More)

  private func showQualityMenu(anchor: UIView) {
    let names = controller.qualityNames
    guard !names.isEmpty else { return }
    let items = names.enumerated().map { idx, qName in
      IosPlayerMenuItem(label: qName, selected: idx == controller.quality) { [weak self] in
        self?.controller.selectQuality(idx)
      }
    }
    overlayHost.showMenu(anchor: anchor, above: true, items: items)
  }

  private func subtitleMenuItems(dividerBeforeFirst: Bool) -> [IosPlayerMenuItem] {
    let tracks = controller.kernel.subtitleTracks()
    let subOn = controller.kernel.subtitlesEnabled
    var items: [IosPlayerMenuItem] = [
      IosPlayerMenuItem(
        label: IosPlayerUiText.t("关闭字幕", "Subtitles off"),
        selected: !subOn,
        dividerBefore: dividerBeforeFirst
      ) { [weak self] in
        self?.controller.kernel.selectSubtitle(-1)
      }
    ]
    for t in tracks {
      items.append(IosPlayerMenuItem(label: t.label, selected: subOn && t.selected) { [weak self] in
        self?.controller.kernel.selectSubtitle(t.index)
      })
    }
    items.append(IosPlayerMenuItem(label: IosPlayerUiText.t("加载字幕…", "Load subtitles…")) { [weak self] in
      self?.presentLoadSubtitleDialog()
    })
    return items
  }

  private func showSubtitlesMenu(anchor: UIView) {
    overlayHost.showMenu(anchor: anchor, above: false, items: subtitleMenuItems(dividerBeforeFirst: false))
  }

  private func showAudioMenu(anchor: UIView) {
    let tracks = controller.kernel.audioTracks()
    guard !tracks.isEmpty else { return }
    var items: [IosPlayerMenuItem] = []
    for t in tracks {
      items.append(IosPlayerMenuItem(label: t.label, selected: t.selected) { [weak self] in
        self?.controller.kernel.selectAudio(t.index)
      })
    }
    overlayHost.showMenu(anchor: anchor, above: false, items: items)
  }

  private func showPortraitMoreMenu(anchor: UIView) {
    var items: [IosPlayerMenuItem] = [
      IosPlayerMenuItem(label: IosPlayerUiText.t("截图", "Screenshot")) { [weak self] in
        self?.captureScreenshot()
      },
      IosPlayerMenuItem(label: IosPlayerUiText.t("重新加载", "Reload")) { [weak self] in
        self?.controller.reload()
      }
    ]
    if controller.kernel.isPictureInPictureSupported {
      items.append(IosPlayerMenuItem(label: IosPlayerUiText.t("画中画", "Picture-in-picture")) { [weak self] in
        self?.enterPictureInPicture()
      })
    }
    items.append(IosPlayerMenuItem(label: IosPlayerUiText.t("无线投屏 (AirPlay)", "AirPlay")) { [weak self] in
      self?.triggerHiddenAirPlayPicker()
    })
    items += subtitleMenuItems(dividerBeforeFirst: true)

    let audio = controller.kernel.audioTracks()
    if audio.count >= 2 {
      for (i, t) in audio.enumerated() {
        items.append(IosPlayerMenuItem(label: t.label, selected: t.selected, dividerBefore: i == 0) { [weak self] in
          self?.controller.kernel.selectAudio(t.index)
        })
      }
    }
    overlayHost.showMenu(anchor: anchor, above: false, items: items)
  }

  private func triggerHiddenAirPlayPicker() {
    for sub in hiddenAirPlayTrigger.subviews {
      if let btn = sub as? UIButton {
        btn.sendActions(for: .touchUpInside)
        return
      }
    }
  }

  private func presentLoadSubtitleDialog() {
    let sheet = UIAlertController(
      title: IosPlayerUiText.t("加载字幕", "Load subtitles"),
      message: nil,
      preferredStyle: .actionSheet
    )
    sheet.overrideUserInterfaceStyle = .dark
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("本地字幕", "Local file"), style: .default) { [weak self] _ in
      self?.presentLocalSubtitleFilePicker()
    })
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("字幕链接", "Subtitle link"), style: .default) { [weak self] _ in
      self?.presentSubtitleUrlAlert()
    })
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    if let pop = sheet.popoverPresentationController {
      pop.sourceView = view
      pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    }
    present(sheet, animated: true)
  }

  private func presentLocalSubtitleFilePicker() {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    picker.overrideUserInterfaceStyle = .dark
    present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let picked = urls.first else { return }
    let ext = picked.pathExtension.lowercased()
    guard ["srt", "vtt", "ass", "ssa", "sub"].contains(ext) else {
      controllerDidShowToast(
        IosPlayerUiText.t("请选择 .srt / .ass / .vtt 字幕文件", "Please choose a .srt / .ass / .vtt file"),
        long: false
      )
      return
    }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("novaplay-subs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dst = dir.appendingPathComponent(picked.lastPathComponent)
    try? FileManager.default.removeItem(at: dst)
    do {
      try FileManager.default.copyItem(at: picked, to: dst)
      self.controller.addExternalSubtitle(url: dst.path, name: picked.lastPathComponent)
      controllerDidShowToast(
        IosPlayerUiText.t("已加载本地字幕：\(picked.lastPathComponent)", "Subtitles loaded: \(picked.lastPathComponent)"),
        long: false
      )
    } catch {
      self.controller.addExternalSubtitle(url: picked.path, name: picked.lastPathComponent)
    }
  }

  private func presentSubtitleUrlAlert() {
    let alert = UIAlertController(
      title: IosPlayerUiText.t("字幕链接", "Subtitle link"),
      message: nil,
      preferredStyle: .alert
    )
    alert.overrideUserInterfaceStyle = .dark
    alert.addTextField { tf in
      tf.placeholder = IosPlayerUiText.t("请输入字幕链接", "Subtitle URL")
      tf.keyboardType = .URL
      tf.autocorrectionType = .no
      tf.autocapitalizationType = .none
    }
    alert.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: IosPlayerUiText.t("确定", "OK"), style: .default) { [weak self] _ in
      guard let self = self else { return }
      let raw = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard raw.hasPrefix("http://") || raw.hasPrefix("https://") else {
        self.controllerDidShowToast(IosPlayerUiText.t("加载字幕失败：链接无效", "Invalid subtitle URL"), long: false)
        return
      }
      let lastComp = URL(string: raw)?.lastPathComponent ?? ""
      let name = lastComp.isEmpty ? "subtitle" : lastComp
      self.controller.addExternalSubtitle(url: raw, name: name)
      self.controllerDidShowToast(IosPlayerUiText.t("已加载字幕：\(name)", "Subtitles loaded: \(name)"), long: false)
    })
    present(alert, animated: true)
  }

  // MARK: - Actions (PiP, Screenshot, Seek Step, Lock, Visibility)

  private func enterPictureInPicture() {
    guard controller.kernel.isUsingAvPlayer else {
      controllerDidShowToast(
        IosPlayerUiText.t("iOS 系统画中画仅在 AVPlayer 内核下可用", "iOS system PiP requires AVPlayer kernel"),
        long: false
      )
      return
    }
    guard controller.kernel.isPictureInPictureSupported else {
      controllerDidShowToast(IosPlayerUiText.t("画中画不可用", "Picture-in-picture is not available"), long: false)
      return
    }
    dismissedForPiP = true
    overlayHost.closeMenu()
    overlayHost.closePanel()
    hideControlsAnimated(false)
    restorePortraitBeforeExit()
    controller.kernel.togglePictureInPicture()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self, self.presentingViewController != nil else { return }
      self.dismiss(animated: true)
    }
  }

  private func captureScreenshot() {
    if controller.playbackConfig.hapticEnabled {
      IosHaptics.play(kind: "medium")
    }
    controller.kernel.captureScreenshot { [weak self] _, msg in
      self?.controllerDidShowToast(msg, long: false)
    }
  }

  private func stepByConfiguredSeconds(forward: Bool) {
    let sec = Int(controller.playbackConfig.fastForwardSeconds)
    beginSeekWait()
    controller.seekBy(seconds: forward ? sec : -sec)
    refreshControlsState()
  }

  private func beginSeekWait() {
    seekWaitUntil = CACurrentMediaTime() + 0.45
    refreshInfoLayer()
  }

  private func fireSelectionHaptic() {
    if controller.playbackConfig.hapticEnabled {
      IosHaptics.play(kind: "selection")
    }
  }

  private func touchControls(haptic: Bool) {
    if haptic {
      fireSelectionHaptic()
    }
    scheduleAutoHide()
  }

  private func setScreenLocked(_ locked: Bool) {
    screenLocked = locked
    if locked {
      hideControlsAnimated(false)
      overlayHost.closeMenu()
      overlayHost.closePanel()
      showLockLayerBriefly()
    } else {
      hideLockWorkItem?.cancel()
      lockLayer.isHidden = true
      showControls()
    }
  }

  private func showLockLayerBriefly() {
    lockLayer.isHidden = false
    refreshControlsState()
    hideLockWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      self?.lockLayer.isHidden = true
    }
    hideLockWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
  }

  private func toggleControlsVisibility() {
    if overlayHost.isMenuOpen {
      overlayHost.closeMenu()
      return
    }
    if overlayHost.isPanelOpen {
      overlayHost.closePanel()
      return
    }
    if screenLocked {
      if lockLayer.isHidden {
        showLockLayerBriefly()
      } else {
        hideLockWorkItem?.cancel()
        lockLayer.isHidden = true
      }
      return
    }
    if controlsVisible {
      hideControlsAnimated(true)
    } else {
      showControls()
    }
  }

  private func showControls() {
    guard !screenLocked else { return }
    if !controlsVisible {
      controlsVisible = true
      controlsLayer.isHidden = false
      controlsLayer.alpha = 0
      topBarView?.transform = CGAffineTransform(translationX: 0, y: -18)
      bottomBarView?.transform = CGAffineTransform(translationX: 0, y: 18)
      UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
        self.controlsLayer.alpha = 1
        self.topBarView?.transform = .identity
        self.bottomBarView?.transform = .identity
      }
      setNeedsStatusBarAppearanceUpdate()
      setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    refreshControlsState()
    refreshInfoLayer()
    scheduleAutoHide()
  }

  private func hideControlsAnimated(_ animated: Bool) {
    hideControlsWorkItem?.cancel()
    guard controlsVisible else { return }
    controlsVisible = false
    setNeedsStatusBarAppearanceUpdate()
    setNeedsUpdateOfHomeIndicatorAutoHidden()
    if animated {
      UIView.animate(withDuration: 0.16, animations: {
        self.controlsLayer.alpha = 0
      }) { _ in
        if !self.controlsVisible {
          self.controlsLayer.isHidden = true
        }
      }
    } else {
      controlsLayer.alpha = 0
      controlsLayer.isHidden = true
    }
    refreshInfoLayer()
  }

  private func scheduleAutoHide() {
    hideControlsWorkItem?.cancel()
    guard controlsVisible && !screenLocked && !overlayHost.isMenuOpen && !overlayHost.isPanelOpen else { return }
    let item = DispatchWorkItem { [weak self] in
      guard let self = self,
            self.controlsVisible,
            !(self.seekSlider?.isDraggingSlider ?? false),
            self.controller.kernel.isPlaying else { return }
      self.hideControlsAnimated(true)
    }
    hideControlsWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: item)
  }

  // MARK: - HUDs & Skip Banner

  private func showTopHint(iconCode: Int, label: String, fraction: CGFloat?) {
    hintRow.arrangedSubviews.forEach {
      hintRow.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    hintRow.addArrangedSubview(ui.icon(iconCode, size: 17, color: IosPlayerUi.argb(0xD9FF_FFFF)))
    if let frac = fraction {
      let bar = ThinSliderView(fillColor: .white, trackColor: IosPlayerUi.argb(0x40FF_FFFF), thumbSize: 0, trackHeight: 3)
      bar.isUserInteractionEnabled = false
      bar.fraction = frac
      bar.widthAnchor.constraint(equalToConstant: 78).isActive = true
      hintRow.addArrangedSubview(bar)
    }
    hintRow.addArrangedSubview(ui.text(label, size: 13.5, color: IosPlayerUi.argb(0xD9FF_FFFF), mono: true))
    hintWrap.isHidden = false
    hideHintWorkItem?.cancel()
  }

  private func hideTopHint(after delay: TimeInterval = 0) {
    hideHintWorkItem?.cancel()
    if delay <= 0 {
      hintWrap.isHidden = true
    } else {
      let item = DispatchWorkItem { [weak self] in self?.hintWrap.isHidden = true }
      hideHintWorkItem = item
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  private func showSeekHint(targetMs: Int64, forward: Bool, showBar: Bool) {
    let dur = controller.kernel.durationMs
    seekHintIcon.code = forward ? IosPlayerIcon.DOUBLE_RIGHT : IosPlayerIcon.DOUBLE_LEFT
    seekHintLabel.text = IosPlayerUiText.clock(targetMs)
    seekHintBar.fraction = dur > 0 ? CGFloat(Double(targetMs) / Double(dur)) : 0
    seekHintBar.isHidden = !(showBar && !controlsVisible)
    seekHintLayer.isHidden = false
  }

  private func hideSeekHint() {
    seekHintLayer.isHidden = true
  }

  private func flashDoubleTapPlayState(paused: Bool) {
    centreFlash.subviews.forEach { $0.removeFromSuperview() }
    let ic = ui.icon(paused ? IosPlayerIcon.PAUSE : IosPlayerIcon.PLAY, size: 56)
    centreFlash.addSubview(ic)
    NSLayoutConstraint.activate([
      ic.centerXAnchor.constraint(equalTo: centreFlash.centerXAnchor),
      ic.centerYAnchor.constraint(equalTo: centreFlash.centerYAnchor)
    ])
    centreFlash.layer.removeAllAnimations()
    centreFlash.alpha = 1
    centreFlash.isHidden = false
    hideFlashWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      UIView.animate(withDuration: 0.18, animations: { self.centreFlash.alpha = 0 }) { _ in
        self.centreFlash.isHidden = true
      }
    }
    hideFlashWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: item)
  }

  private func presentSkipBanner(fromMs: Int64) {
    skipCountdownTimer?.invalidate()
    skipReturnPosMs = fromMs
    skipCountdownRemaining = 5
    skipBanner.subviews.forEach { $0.removeFromSuperview() }

    let title = ui.text(
      IosPlayerUiText.t("已跳过片段，是否返回原播放进度？", "Skipped section, return to previous position?"),
      size: 13,
      bold: true
    )
    title.numberOfLines = 2
    let sub = ui.text(
      IosPlayerUiText.t("5 秒后自动关闭", "Closes in 5s"),
      size: 11.5,
      color: IosPlayerUi.textDim
    )
    skipBannerSubLabel = sub

    let returnBtn = PlayerTappableView()
    ui.applyRounded(returnBtn, fill: IosPlayerUi.withAlpha(ui.accent, 0.18), radius: 8)
    let retLbl = ui.text(IosPlayerUiText.t("返回", "Return"), size: 12, color: ui.accent, bold: true)
    retLbl.isUserInteractionEnabled = false
    returnBtn.addSubview(retLbl)
    NSLayoutConstraint.activate([
      retLbl.leadingAnchor.constraint(equalTo: returnBtn.leadingAnchor, constant: 12),
      retLbl.trailingAnchor.constraint(equalTo: returnBtn.trailingAnchor, constant: -12),
      retLbl.topAnchor.constraint(equalTo: returnBtn.topAnchor, constant: 5),
      retLbl.bottomAnchor.constraint(equalTo: returnBtn.bottomAnchor, constant: -5)
    ])
    returnBtn.onTap = { [weak self] in
      guard let self = self else { return }
      self.skipCountdownTimer?.invalidate()
      self.skipBanner.isHidden = true
      self.fireSelectionHaptic()
      self.controller.undoSkip(toMs: self.skipReturnPosMs)
      self.refreshControlsState()
    }

    let keepBtn = PlayerTappableView()
    ui.applyRounded(keepBtn, fill: IosPlayerUi.argb(0x1FFF_FFFF), radius: 8)
    let keepLbl = ui.text(IosPlayerUiText.t("继续观看", "Continue"), size: 12, color: IosPlayerUi.argb(0xCCFF_FFFF))
    keepLbl.isUserInteractionEnabled = false
    keepBtn.addSubview(keepLbl)
    NSLayoutConstraint.activate([
      keepLbl.leadingAnchor.constraint(equalTo: keepBtn.leadingAnchor, constant: 12),
      keepLbl.trailingAnchor.constraint(equalTo: keepBtn.trailingAnchor, constant: -12),
      keepLbl.topAnchor.constraint(equalTo: keepBtn.topAnchor, constant: 5),
      keepLbl.bottomAnchor.constraint(equalTo: keepBtn.bottomAnchor, constant: -5)
    ])
    keepBtn.onTap = { [weak self] in
      guard let self = self else { return }
      self.skipCountdownTimer?.invalidate()
      self.skipBanner.isHidden = true
      self.fireSelectionHaptic()
    }

    let btns = UIStackView(arrangedSubviews: [UIView(), returnBtn, keepBtn])
    btns.axis = .horizontal
    btns.alignment = .center
    btns.spacing = 8

    let v = UIStackView(arrangedSubviews: [title, sub, btns])
    v.translatesAutoresizingMaskIntoConstraints = false
    v.axis = .vertical
    v.alignment = .fill
    v.spacing = 4
    v.setCustomSpacing(10, after: sub)
    skipBanner.addSubview(v)
    NSLayoutConstraint.activate([
      v.leadingAnchor.constraint(equalTo: skipBanner.leadingAnchor, constant: 14),
      v.trailingAnchor.constraint(equalTo: skipBanner.trailingAnchor, constant: -14),
      v.topAnchor.constraint(equalTo: skipBanner.topAnchor, constant: 12),
      v.bottomAnchor.constraint(equalTo: skipBanner.bottomAnchor, constant: -12)
    ])
    skipBanner.isHidden = false

    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] t in
      guard let self = self else { t.invalidate(); return }
      self.skipCountdownRemaining -= 1
      if self.skipCountdownRemaining <= 0 {
        t.invalidate()
        self.skipBanner.isHidden = true
      } else {
        self.skipBannerSubLabel?.text = IosPlayerUiText.t(
          "\(self.skipCountdownRemaining) 秒后自动关闭",
          "Closes in \(self.skipCountdownRemaining)s"
        )
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    skipCountdownTimer = timer
  }

  // MARK: - Gestures (Tap, Double Tap, Horizontal Seek, Brightness/Volume, Long-Press Speed + Slide)

  private func setupGestures() {
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.delegate = self
    view.addGestureRecognizer(doubleTap)

    let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
    singleTap.numberOfTapsRequired = 1
    singleTap.require(toFail: doubleTap)
    singleTap.delegate = self
    view.addGestureRecognizer(singleTap)

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.maximumNumberOfTouches = 1
    pan.delegate = self
    view.addGestureRecognizer(pan)

    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    longPress.minimumPressDuration = 0.42
    longPress.delegate = self
    view.addGestureRecognizer(longPress)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if !errorLayer.isHidden {
      return false
    }
    if overlayHost.isMenuOpen {
      return gestureRecognizer is UITapGestureRecognizer && (gestureRecognizer as? UITapGestureRecognizer)?.numberOfTapsRequired == 1
    }
    if overlayHost.isPanelOpen {
      if let hit = touch.view, hit.isDescendant(of: overlayHost.panelHost) {
        // Let backdrop tap inside `panelHost` work via its own `PlayerTappableView`, block video gestures
        return false
      }
    }
    if let hit = touch.view, hit.isDescendant(of: controller.kernel.videoView) {
      return true
    }
    var cur: UIView? = touch.view
    while let v = cur, v !== view {
      if v is UIControl || v is AVRoutePickerView || v is UITextField || v is UITextView || v === skipBanner {
        return false
      }
      cur = v.superview
    }
    return true
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    if let otherView = otherGestureRecognizer.view,
       otherView.isDescendant(of: controller.kernel.videoView) {
      return true
    }
    return false
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    if let otherView = otherGestureRecognizer.view,
       otherView.isDescendant(of: controller.kernel.videoView) {
      return true
    }
    return false
  }

  @objc private func handleSingleTap(_ gr: UITapGestureRecognizer) {
    toggleControlsVisibility()
  }

  @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
    guard !screenLocked, !overlayHost.isMenuOpen, !overlayHost.isPanelOpen else { return }
    if controller.playbackConfig.hapticEnabled {
      IosHaptics.play(kind: "light")
    }
    let wasPlaying = controller.kernel.isPlaying
    controller.togglePause()
    flashDoubleTapPlayState(paused: wasPlaying)
    refreshControlsState()
  }

  @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
    guard !screenLocked, !overlayHost.isMenuOpen, !overlayHost.isPanelOpen else { return }
    let w = max(1, view.bounds.width)
    let h = max(1, view.bounds.height)
    let translation = gr.translation(in: view)

    switch gr.state {
    case .began:
      panMode = .none
      panStartPosMs = controller.kernel.positionMs
      panTargetPosMs = panStartPosMs
      panStartBrightness = UIScreen.main.brightness
      panStartVolume = systemVolumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume

    case .changed:
      if panMode == .none {
        let ax = abs(translation.x)
        let ay = abs(translation.y)
        guard max(ax, ay) >= 12 else { return }
        if ax > ay * 1.15 {
          guard !controller.isLive && controller.kernel.durationMs > 0 else { return }
          panMode = .seek
        } else {
          let locX = gr.location(in: view).x
          panMode = (locX < w * 0.5) ? .brightness : .volume
        }
      }

      switch panMode {
      case .seek:
        let dur = controller.kernel.durationMs
        let deltaMs = IosPlayerUiText.swipeSeekMs(dx: translation.x, width: w)
        panTargetPosMs = max(0, min(dur, panStartPosMs + deltaMs))
        showSeekHint(targetMs: panTargetPosMs, forward: panTargetPosMs >= panStartPosMs, showBar: true)

      case .brightness:
        let nextB = max(0.0, min(1.0, panStartBrightness - (translation.y / (h * 0.72))))
        UIScreen.main.brightness = nextB
        showTopHint(iconCode: IosPlayerIcon.BRIGHTNESS, label: "\(Int((nextB * 100).rounded()))%", fraction: nextB)

      case .volume:
        let nextV = max(Float(0.0), min(Float(1.0), panStartVolume - Float(translation.y / (h * 0.72))))
        systemVolumeSlider?.value = nextV
        let ic: Int
        if nextV <= 0.001 {
          ic = IosPlayerIcon.VOLUME_MUTE
        } else if nextV < 0.5 {
          ic = IosPlayerIcon.VOLUME_DOWN
        } else {
          ic = IosPlayerIcon.VOLUME_UP
        }
        showTopHint(iconCode: ic, label: "\(Int((nextV * 100).rounded()))%", fraction: CGFloat(nextV))

      case .none:
        break
      }

    case .ended, .cancelled, .failed:
      if panMode == .seek && gr.state == .ended {
        beginSeekWait()
        controller.seekTo(panTargetPosMs)
      }
      hideSeekHint()
      hideTopHint(after: 0.35)
      panMode = .none

    default:
      break
    }
  }

  @objc private func handleLongPress(_ gr: UILongPressGestureRecognizer) {
    guard !screenLocked, !controller.isLive, !overlayHost.isMenuOpen, !overlayHost.isPanelOpen else { return }
    switch gr.state {
    case .began:
      guard controller.kernel.isPlaying else { return }
      if controller.playbackConfig.hapticEnabled {
        IosHaptics.play(kind: "medium")
      }
      savedSpeedBeforeBoost = controller.currentSpeed
      longPressOriginY = gr.location(in: view).y
      let base = controller.playbackConfig.longPressSpeed
      controller.kernel.speed = Float(base)
      showTopHint(iconCode: IosPlayerIcon.FORWARD, label: IosPlayerUiText.speed(base), fraction: nil)

    case .changed:
      guard savedSpeedBeforeBoost != nil else { return }
      let upPt = longPressOriginY - gr.location(in: view).y
      let adjusted = IosPlayerUiText.longPressSlideSpeed(
        base: controller.playbackConfig.longPressSpeed,
        upPt: upPt,
        ptPerStep: 50.0,
        enabled: controller.playbackConfig.isLongPressSpeedAdjustEnabled
      )
      controller.kernel.speed = Float(adjusted)
      showTopHint(iconCode: IosPlayerIcon.FORWARD, label: IosPlayerUiText.speed(adjusted), fraction: nil)

    case .ended, .cancelled, .failed:
      if let restore = savedSpeedBeforeBoost {
        savedSpeedBeforeBoost = nil
        controller.kernel.speed = Float(restore)
      }
      hideTopHint(after: 0)

    default:
      break
    }
  }

  // MARK: - Refresh State & Metrics (1:1 `PlayerControlsView.refresh()` & `refreshInfo()`)

  private func refreshControlsState() {
    guard builtForLandscape != nil else { return }
    let k = controller.kernel
    let cfg = controller.playbackConfig

    let playing = k.isPlaying
    if playShownState != playing, let playBtn = playCircleBtn {
      playShownState = playing
      playBtn.subviews.forEach { $0.removeFromSuperview() }
      if playing {
        let bars = PauseBarsView(color: .black)
        playBtn.addSubview(bars)
        NSLayoutConstraint.activate([
          bars.widthAnchor.constraint(equalToConstant: 26),
          bars.heightAnchor.constraint(equalToConstant: 26),
          bars.centerXAnchor.constraint(equalTo: playBtn.centerXAnchor),
          bars.centerYAnchor.constraint(equalTo: playBtn.centerYAnchor)
        ])
      } else {
        let tri = ui.icon(IosPlayerIcon.PLAY, size: 26, color: .black)
        playBtn.addSubview(tri)
        NSLayoutConstraint.activate([
          tri.centerXAnchor.constraint(equalTo: playBtn.centerXAnchor),
          tri.centerYAnchor.constraint(equalTo: playBtn.centerYAnchor)
        ])
      }
    }

    prevCircleBtn?.isEnabled = controller.hasPrevious
    prevCircleBtn?.alpha = controller.hasPrevious ? 1.0 : 0.45
    nextCircleBtn?.isEnabled = controller.hasNext
    nextCircleBtn?.alpha = controller.hasNext ? 1.0 : 0.45

    let hideCenterSeek = cfg.isHiddenFastSeekBtn || !loadingBox.isHidden
    rewindCenterBtn?.isHidden = hideCenterSeek
    forwardCenterBtn?.isHidden = hideCenterSeek

    let live = controller.isLive
    danmakuPill?.isHidden = live
    danmakuPill?.alpha = controller.danmakuConfig.enabled ? 1.0 : 0.6
    episodesPill?.labelView.text = live ? IosPlayerUiText.t("频道", "Channels") : IosPlayerUiText.t("选集", "Episodes")
    epgPill?.isHidden = controller.epgProgrammes.isEmpty

    if let qName = controller.qualityName, controller.qualityNames.count > 1 {
      qualityPill?.isHidden = false
      qualityPill?.labelView.text = qName
    } else {
      qualityPill?.isHidden = true
    }

    speedPill?.isHidden = live
    speedPill?.labelView.text = IosPlayerUiText.speed(controller.currentSpeed)

    pipTopButton?.isHidden = !k.isPictureInPictureSupported
    audioTopButton?.isHidden = (k.audioTracks().count <= 1)
    subtitleTopButton?.isHidden = !(!live || k.subtitleTracks().count > 1)

    titleView?.text = controller.title
    if let ep = controller.episodeName, !ep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      episodeChip?.text = ep
      episodeChip?.isHidden = false
    } else {
      episodeChip?.isHidden = true
    }
    if k.videoSize.width > 0 && k.videoSize.height > 0 {
      resolutionChip?.text = "\(Int(k.videoSize.width))x\(Int(k.videoSize.height))"
      resolutionChip?.isHidden = false
    } else {
      resolutionChip?.isHidden = true
    }

    let pos = k.positionMs
    let dur = k.durationMs
    if let mark = IosPlayerUiText.markButton(positionMs: pos, durationMs: dur, allowed: controller.canMarkHeadTail) {
      markHeadTailBtn?.isHidden = false
      markIsOutro = (mark == false)
      markHeadTailLabel?.text = mark ? IosPlayerUiText.t("记片头", "Mark intro") : IosPlayerUiText.t("记片尾", "Mark outro")
    } else {
      markHeadTailBtn?.isHidden = true
    }

    if let slider = seekSlider, !slider.isDraggingSlider {
      slider.fraction = dur > 0 ? CGFloat(Double(pos) / Double(dur)) : 0
      slider.secondary = dur > 0 ? CGFloat(Double(k.bufferedMs) / Double(dur)) : 0
      positionLabel?.text = IosPlayerUiText.clock(pos)
      rightTimeLabel?.text = IosPlayerUiText.rightTime(positionMs: pos, durationMs: dur, showTotal: cfg.isShowAllDuration)
    }

    let nowStr = Self.clockFormatter.string(from: Date())
    clockLabel?.text = nowStr
    let batLvl = UIDevice.current.batteryLevel
    if batLvl >= 0 {
      batteryIcon?.level = CGFloat(batLvl)
      batteryPercentLabel?.text = "\(Int((batLvl * 100).rounded()))%"
    } else {
      batteryIcon?.level = 1.0
      batteryPercentLabel?.text = "100%"
    }

    lockInfoLabel?.text = "\(nowStr)  |  \(IosPlayerUiText.clock(pos)) / \(IosPlayerUiText.clock(dur))"
    lockProgressBar?.fraction = dur > 0 ? CGFloat(Double(pos) / Double(dur)) : 0
  }

  private func refreshInfoLayer() {
    let k = controller.kernel
    let cfg = controller.playbackConfig
    refreshErrorLayer()

    let inPip = k.isInPictureInPicture
    let buffering = ((controller.state == "buffering" || controller.state == "idle" || CACurrentMediaTime() < seekWaitUntil)
      && !controller.failed && !inPip)
    let wasLoading = !loadingBox.isHidden
    loadingBox.isHidden = !buffering
    loadingSpeedLabel.text = IosPlayerUiText.bufferingSpeed(k.downloadBytesPerSec)

    if wasLoading != buffering && builtForLandscape != nil {
      let hideCenterSeek = cfg.isHiddenFastSeekBtn || buffering
      rewindCenterBtn?.isHidden = hideCenterSeek
      forwardCenterBtn?.isHidden = hideCenterSeek
    }

    // Bottom bar `statsLine` chip
    if cfg.isShowStatsBar {
      var parts: [String] = []
      parts.append(IosPlayerUiText.kernelShortName(k.activeKernelId))
      if let codec = IosPlayerUiText.codecName(k.videoCodecName) { parts.append(codec) }
      if let fps = IosPlayerUiText.fps(k.nominalFps) { parts.append(fps) }
      if k.downloadBytesPerSec > 0 { parts.append(IosPlayerUiText.netSpeed(k.downloadBytesPerSec)) }
      statsLineChip?.text = parts.joined(separator: " · ")
      statsLineChip?.isHidden = parts.isEmpty
    } else if cfg.showNetSpeed && k.downloadBytesPerSec > 0 {
      statsLineChip?.text = "↓ " + IosPlayerUiText.netSpeed(k.downloadBytesPerSec)
      statsLineChip?.isHidden = false
    } else {
      statsLineChip?.isHidden = true
    }

    // Persistent top corner net speed when controls are hidden
    if cfg.showNetSpeed && k.downloadBytesPerSec > 0 && !controlsVisible && !buffering && !inPip {
      cornerSpeedLabel.text = IosPlayerUiText.netSpeed(k.downloadBytesPerSec)
      cornerSpeedLabel.isHidden = false
    } else {
      cornerSpeedLabel.isHidden = true
    }
  }

  private func refreshErrorLayer() {
    let err = controller.errorMessage
    guard err != shownErrorText else { return }
    shownErrorText = err
    guard let msg = err else {
      errorLayer.isHidden = true
      return
    }
    hideControlsAnimated(false)
    overlayHost.closeMenu()
    overlayHost.closePanel()
    errorTitleLabel.text = IosPlayerUiText.errorTitle(msg)
    errorDetailTextView.text = IosPlayerUiText.errorDetail(msg)
    errorLayer.alpha = 0
    errorLayer.isHidden = false
    updateErrorDetailHeightIfNeeded()
    UIView.animate(withDuration: 0.2) {
      self.errorLayer.alpha = 1
    }
  }

  // MARK: - IosPlayerControllerUiDelegate

  func controllerDidChangeState() {
    ui.accent = IosPlayerUiText.accentColor(hex: controller.playbackConfig.accentColorHex)
    refreshControlsState()
    refreshInfoLayer()
    if controlsVisible {
      scheduleAutoHide()
    }
  }

  func controllerDidUpdateMetrics() {
    refreshInfoLayer()
    if controlsVisible || !lockLayer.isHidden {
      refreshControlsState()
    }
  }

  func controllerDidUpdateSubtitleCue(_ text: String?) {
    if let t = text, !t.isEmpty {
      sidecarSubtitleLabel.text = t
      sidecarSubtitleLabel.isHidden = false
    } else {
      sidecarSubtitleLabel.isHidden = true
    }
  }

  func controllerDidShowNotice(_ text: String) {
    topNoticeLabel.text = text
    topNoticeLabel.alpha = 1
    topNoticeLabel.isHidden = false
    hideNoticeWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      UIView.animate(withDuration: 0.2, animations: { self.topNoticeLabel.alpha = 0 }) { _ in
        self.topNoticeLabel.isHidden = true
      }
    }
    hideNoticeWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
  }

  func controllerDidShowToast(_ text: String, long: Bool) {
    toastLabel.text = text
    toastLabel.alpha = 1
    toastLabel.isHidden = false
    hideToastWorkItem?.cancel()
    let delay = long ? 3.5 : 2.0
    let item = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      UIView.animate(withDuration: 0.22, animations: { self.toastLabel.alpha = 0 }) { _ in
        self.toastLabel.isHidden = true
      }
    }
    hideToastWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  func controllerDidSkipRange(fromMs: Int64) {
    presentSkipBanner(fromMs: fromMs)
  }

  func controllerRequestRestorePiP(completion: @escaping (Bool) -> Void) {
    dismissedForPiP = false
    if presentingViewController != nil {
      completion(true)
      return
    }
    guard let top = NativePlayerHost.topViewController() else {
      completion(false)
      return
    }
    top.present(self, animated: true) {
      completion(true)
    }
  }
}
