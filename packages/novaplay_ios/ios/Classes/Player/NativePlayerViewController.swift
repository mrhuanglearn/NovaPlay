import AVKit
import MediaPlayer
import UIKit
import UniformTypeIdentifiers

final class NativePlayerViewController: UIViewController, IosPlayerControllerUiDelegate, UIGestureRecognizerDelegate, UIDocumentPickerDelegate {
  private let controller: IosPlayerController
  private var preferLandscape: Bool
  private var controlsVisible: Bool = true
  private var screenLocked: Bool = false
  private var isScrubbingSlider: Bool = false
  private var hideControlsWorkItem: DispatchWorkItem?
  private var dismissedForPiP: Bool = false

  // Layers & HUDs
  private let topGradient = CAGradientLayer()
  private let bottomGradient = CAGradientLayer()
  private let controlsContainer = UIView()
  private let topBar = UIView()
  private let bottomBar = UIView()

  private let backButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let badgeLabel = UILabel()
  private let danmakuBindButton = UIButton(type: .system)
  private let airPlayPicker = AVRoutePickerView(frame: .zero)
  private let pipButton = UIButton(type: .system)
  private let screenshotButton = UIButton(type: .system)
  private let settingsButton = UIButton(type: .system)

  private let lockButton = UIButton(type: .system)
  private let statsBarLabel = PaddingLabel(insets: UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8))
  private let sidecarSubtitleLabel = PaddingLabel(insets: UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10))

  // Centered Buffering + Net Speed Box (matches Android 1:1 calibrated center)
  private let bufferingCard = UIView()
  private let bufferingSpinner = UIActivityIndicatorView(style: .medium)
  private let bufferingSpeedLabel = UILabel()

  // Center Gesture / Boost / Notice / Toast Overlays
  private let gestureHudLabel = PaddingLabel(insets: UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14))
  private let speedBoostPill = PaddingLabel(insets: UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14))
  private let topNoticeLabel = PaddingLabel(insets: UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12))
  private let toastLabel = PaddingLabel(insets: UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16))

  // Error Card Overlay
  private let errorCard = UIView()
  private let errorTitleLabel = UILabel()
  private let errorBodyLabel = UILabel()
  private let errorCancelBtn = UIButton(type: .system)
  private let errorCopyBtn = UIButton(type: .system)
  private let errorRetryBtn = UIButton(type: .system)

  // Bottom Controls
  private let currentTimeLabel = UILabel()
  private let progressSlider = UISlider()
  private let rightTimeLabel = UILabel()
  private let markHeadTailBtn = UIButton(type: .system)

  private let playPauseBtn = UIButton(type: .system)
  private let prevEpBtn = UIButton(type: .system)
  private let nextEpBtn = UIButton(type: .system)
  private let rewindBtn = UIButton(type: .system)
  private let forwardBtn = UIButton(type: .system)
  private let danmakuToggleBtn = UIButton(type: .system)
  private let danmakuStyleBtn = UIButton(type: .system)
  private let episodeBtn = UIButton(type: .system)
  private let qualityBtn = UIButton(type: .system)
  private let speedBtn = UIButton(type: .system)
  private let fitBtn = UIButton(type: .system)
  private let rotateBtn = UIButton(type: .system)

  // Hidden system volume slider for smooth right-side vertical swipe volume control
  private let hiddenVolumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 100, height: 20))
  private var systemVolumeSlider: UISlider? {
    hiddenVolumeView.subviews.compactMap { $0 as? UISlider }.first
  }

  // Gesture state
  private enum PanMode { case none, seek, brightness, volume }
  private var panMode: PanMode = .none
  private var panStartPosMs: Int64 = 0
  private var panTargetPosMs: Int64 = 0
  private var panStartBrightness: CGFloat = 0.5
  private var panStartVolume: Float = 0.5
  private var savedSpeedBeforeBoost: Double?
  private var longPressStartPoint: CGPoint = .zero

  private var bgObserver: NSObjectProtocol?

  init(controller: IosPlayerController) {
    self.controller = controller
    self.preferLandscape = controller.playbackConfig.isPriorityLandscape
    super.init(nibName: nil, bundle: nil)
    controller.uiDelegate = self
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if let obs = bgObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  override var prefersStatusBarHidden: Bool {
    !controlsVisible || traitCollection.verticalSizeClass == .compact
  }

  override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

  override var prefersHomeIndicatorAutoHidden: Bool { !controlsVisible }

  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    preferLandscape ? .landscape : .portrait
  }

  override var shouldAutorotate: Bool { true }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    setupHierarchy()
    setupGestures()
    setupBackgroundObserver()
    refreshUI()
    scheduleAutoHide()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    dismissedForPiP = false
    applyPreferredOrientation()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed && !dismissedForPiP && !controller.isClosed {
      controller.close(completed: false, dismissVC: false)
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    topGradient.frame = topBar.bounds
    bottomGradient.frame = bottomBar.bounds
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

  private func applyPreferredOrientation() {
    if #available(iOS 16.0, *) {
      setNeedsUpdateOfSupportedInterfaceOrientations()
      let mask: UIInterfaceOrientationMask = preferLandscape ? .landscapeRight : .portrait
      view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    } else {
      let target: UIInterfaceOrientation = preferLandscape ? .landscapeRight : .portrait
      UIDevice.current.setValue(target.rawValue, forKey: "orientation")
      UIViewController.attemptRotationToDeviceOrientation()
    }
  }

  private func restorePortraitBeforeExit() {
    guard preferLandscape else { return }
    preferLandscape = false
    applyPreferredOrientation()
  }

  // MARK: - View Hierarchy

  private func setupHierarchy() {
    view.addSubview(hiddenVolumeView)

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
    sidecarSubtitleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    sidecarSubtitleLabel.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
    sidecarSubtitleLabel.layer.cornerRadius = 6
    sidecarSubtitleLabel.clipsToBounds = true
    sidecarSubtitleLabel.isHidden = true
    view.addSubview(sidecarSubtitleLabel)

    statsBarLabel.translatesAutoresizingMaskIntoConstraints = false
    statsBarLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    statsBarLabel.textColor = UIColor(white: 0.92, alpha: 1.0)
    statsBarLabel.backgroundColor = UIColor(white: 0.06, alpha: 0.72)
    statsBarLabel.layer.cornerRadius = 6
    statsBarLabel.clipsToBounds = true
    statsBarLabel.isHidden = true
    view.addSubview(statsBarLabel)

    controlsContainer.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controlsContainer)

    setupTopBar()
    setupBottomBar()
    setupLockButton()
    setupBufferingCard()
    setupFloatingHuds()
    setupErrorCard()

    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      videoView.topAnchor.constraint(equalTo: view.topAnchor),
      videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      danmakuView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      danmakuView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      danmakuView.topAnchor.constraint(equalTo: safe.topAnchor),
      danmakuView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      sidecarSubtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      sidecarSubtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: 24),
      sidecarSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -24),
      sidecarSubtitleLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -58),

      statsBarLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
      statsBarLabel.topAnchor.constraint(equalTo: safe.topAnchor, constant: 54),

      controlsContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controlsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controlsContainer.topAnchor.constraint(equalTo: view.topAnchor),
      controlsContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    ])
  }

  private func setupTopBar() {
    topBar.translatesAutoresizingMaskIntoConstraints = false
    topGradient.colors = [UIColor(white: 0, alpha: 0.78).cgColor, UIColor.clear.cgColor]
    topBar.layer.insertSublayer(topGradient, at: 0)
    controlsContainer.addSubview(topBar)

    styleIconButton(backButton, symbol: "chevron.left", pointSize: 18)
    backButton.addTarget(self, action: #selector(onTapBack), for: .touchUpInside)

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textColor = .white
    titleLabel.lineBreakMode = .byTruncatingTail

    badgeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    badgeLabel.textColor = UIColor(white: 0.82, alpha: 1.0)

    let titleStack = UIStackView(arrangedSubviews: [titleLabel, badgeLabel])
    titleStack.axis = .vertical
    titleStack.spacing = 2

    danmakuBindButton.setTitle(IosPlayerUiText.t("弹幕匹配", "Danmaku"), for: .normal)
    stylePillButton(danmakuBindButton)
    danmakuBindButton.addTarget(self, action: #selector(onTapDanmakuSearch), for: .touchUpInside)

    airPlayPicker.tintColor = .white
    airPlayPicker.activeTintColor = IosPlayerUiText.accentColor(hex: controller.playbackConfig.accentColorHex)
    airPlayPicker.prioritizesVideoDevices = true
    airPlayPicker.translatesAutoresizingMaskIntoConstraints = false

    styleIconButton(pipButton, symbol: "pip.enter", pointSize: 16)
    pipButton.addTarget(self, action: #selector(onTapPiP), for: .touchUpInside)

    styleIconButton(screenshotButton, symbol: "camera", pointSize: 16)
    screenshotButton.addTarget(self, action: #selector(onTapScreenshot), for: .touchUpInside)

    styleIconButton(settingsButton, symbol: "gearshape", pointSize: 17)
    settingsButton.addTarget(self, action: #selector(onTapSettings), for: .touchUpInside)

    let row = UIStackView(arrangedSubviews: [
      backButton, titleStack, UIView(), danmakuBindButton, airPlayPicker, pipButton, screenshotButton, settingsButton
    ])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10
    row.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(row)

    let safe = controlsContainer.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      topBar.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor),
      topBar.topAnchor.constraint(equalTo: controlsContainer.topAnchor),

      row.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 12),
      row.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -12),
      row.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
      row.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -14),
      backButton.widthAnchor.constraint(equalToConstant: 36),
      backButton.heightAnchor.constraint(equalToConstant: 36),
      airPlayPicker.widthAnchor.constraint(equalToConstant: 32),
      airPlayPicker.heightAnchor.constraint(equalToConstant: 32)
    ])
  }

  private func setupBottomBar() {
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomGradient.colors = [UIColor.clear.cgColor, UIColor(white: 0, alpha: 0.82).cgColor]
    bottomBar.layer.insertSublayer(bottomGradient, at: 0)
    controlsContainer.addSubview(bottomBar)

    currentTimeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    currentTimeLabel.textColor = .white
    currentTimeLabel.text = "00:00"

    rightTimeLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    rightTimeLabel.textColor = UIColor(white: 0.86, alpha: 1.0)
    rightTimeLabel.text = "00:00"

    let accent = IosPlayerUiText.accentColor(hex: controller.playbackConfig.accentColorHex)
    progressSlider.minimumTrackTintColor = accent
    progressSlider.maximumTrackTintColor = UIColor(white: 1.0, alpha: 0.28)
    progressSlider.addTarget(self, action: #selector(onSliderTouchDown), for: .touchDown)
    progressSlider.addTarget(self, action: #selector(onSliderChanged), for: .valueChanged)
    progressSlider.addTarget(self, action: #selector(onSliderTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])

    stylePillButton(markHeadTailBtn)
    markHeadTailBtn.isHidden = true
    markHeadTailBtn.addTarget(self, action: #selector(onTapMarkHeadTail), for: .touchUpInside)

    let progressRow = UIStackView(arrangedSubviews: [currentTimeLabel, progressSlider, rightTimeLabel, markHeadTailBtn])
    progressRow.axis = .horizontal
    progressRow.alignment = .center
    progressRow.spacing = 10

    styleIconButton(playPauseBtn, symbol: "pause.fill", pointSize: 20)
    playPauseBtn.addTarget(self, action: #selector(onTapPlayPause), for: .touchUpInside)

    styleIconButton(prevEpBtn, symbol: "backward.end.fill", pointSize: 15)
    prevEpBtn.addTarget(self, action: #selector(onTapPrevEp), for: .touchUpInside)

    styleIconButton(nextEpBtn, symbol: "forward.end.fill", pointSize: 15)
    nextEpBtn.addTarget(self, action: #selector(onTapNextEp), for: .touchUpInside)

    styleIconButton(rewindBtn, symbol: "gobackward.10", pointSize: 16)
    rewindBtn.addTarget(self, action: #selector(onTapRewind), for: .touchUpInside)

    styleIconButton(forwardBtn, symbol: "goforward.10", pointSize: 16)
    forwardBtn.addTarget(self, action: #selector(onTapForward), for: .touchUpInside)

    stylePillButton(danmakuToggleBtn)
    danmakuToggleBtn.addTarget(self, action: #selector(onTapDanmakuToggle), for: .touchUpInside)

    styleIconButton(danmakuStyleBtn, symbol: "slider.horizontal.3", pointSize: 15)
    danmakuStyleBtn.addTarget(self, action: #selector(onTapDanmakuStyle), for: .touchUpInside)

    stylePillButton(episodeBtn)
    episodeBtn.setTitle(IosPlayerUiText.t("选集", "Episodes"), for: .normal)
    episodeBtn.addTarget(self, action: #selector(onTapEpisodes), for: .touchUpInside)

    stylePillButton(qualityBtn)
    qualityBtn.addTarget(self, action: #selector(onTapQuality), for: .touchUpInside)

    stylePillButton(speedBtn)
    speedBtn.addTarget(self, action: #selector(onTapSpeed), for: .touchUpInside)

    stylePillButton(fitBtn)
    fitBtn.addTarget(self, action: #selector(onTapFitMode), for: .touchUpInside)

    styleIconButton(rotateBtn, symbol: "rotate.right", pointSize: 16)
    rotateBtn.addTarget(self, action: #selector(onTapRotate), for: .touchUpInside)

    let actionsScroll = UIScrollView()
    actionsScroll.showsHorizontalScrollIndicator = false
    let rightCluster = UIStackView(arrangedSubviews: [
      danmakuToggleBtn, danmakuStyleBtn, episodeBtn, qualityBtn, speedBtn, fitBtn, rotateBtn
    ])
    rightCluster.axis = .horizontal
    rightCluster.alignment = .center
    rightCluster.spacing = 8
    rightCluster.translatesAutoresizingMaskIntoConstraints = false
    actionsScroll.addSubview(rightCluster)
    NSLayoutConstraint.activate([
      rightCluster.leadingAnchor.constraint(equalTo: actionsScroll.contentLayoutGuide.leadingAnchor),
      rightCluster.trailingAnchor.constraint(equalTo: actionsScroll.contentLayoutGuide.trailingAnchor),
      rightCluster.topAnchor.constraint(equalTo: actionsScroll.contentLayoutGuide.topAnchor),
      rightCluster.bottomAnchor.constraint(equalTo: actionsScroll.contentLayoutGuide.bottomAnchor),
      rightCluster.heightAnchor.constraint(equalTo: actionsScroll.frameLayoutGuide.heightAnchor),
      actionsScroll.heightAnchor.constraint(equalToConstant: 36)
    ])

    let leftCluster = UIStackView(arrangedSubviews: [playPauseBtn, prevEpBtn, nextEpBtn, rewindBtn, forwardBtn])
    leftCluster.axis = .horizontal
    leftCluster.alignment = .center
    leftCluster.spacing = 8

    let actionRow = UIStackView(arrangedSubviews: [leftCluster, UIView(), actionsScroll])
    actionRow.axis = .horizontal
    actionRow.alignment = .center
    actionRow.spacing = 8

    let vStack = UIStackView(arrangedSubviews: [progressRow, actionRow])
    vStack.axis = .vertical
    vStack.spacing = 8
    vStack.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.addSubview(vStack)

    let safe = controlsContainer.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      bottomBar.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: controlsContainer.bottomAnchor),

      vStack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 14),
      vStack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -14),
      vStack.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 14),
      vStack.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -6)
    ])
  }

  private func setupLockButton() {
    lockButton.translatesAutoresizingMaskIntoConstraints = false
    lockButton.backgroundColor = UIColor(white: 0.08, alpha: 0.65)
    lockButton.tintColor = .white
    lockButton.layer.cornerRadius = 20
    lockButton.setImage(UIImage(systemName: "lock.open"), for: .normal)
    lockButton.addTarget(self, action: #selector(onTapLock), for: .touchUpInside)
    view.addSubview(lockButton)

    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      lockButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
      lockButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      lockButton.widthAnchor.constraint(equalToConstant: 40),
      lockButton.heightAnchor.constraint(equalToConstant: 40)
    ])
  }

  private func setupBufferingCard() {
    bufferingCard.translatesAutoresizingMaskIntoConstraints = false
    bufferingCard.backgroundColor = UIColor(white: 0.08, alpha: 0.82)
    bufferingCard.layer.cornerRadius = 14
    bufferingCard.isUserInteractionEnabled = false
    view.addSubview(bufferingCard)

    bufferingSpinner.color = .white
    bufferingSpinner.startAnimating()
    bufferingSpinner.translatesAutoresizingMaskIntoConstraints = false

    bufferingSpeedLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    bufferingSpeedLabel.textColor = UIColor(white: 0.92, alpha: 1.0)
    bufferingSpeedLabel.textAlignment = .center
    bufferingSpeedLabel.numberOfLines = 1
    bufferingSpeedLabel.lineBreakMode = .byClipping
    bufferingSpeedLabel.text = "0.0 KB/s"
    bufferingSpeedLabel.translatesAutoresizingMaskIntoConstraints = false

    bufferingCard.addSubview(bufferingSpinner)
    bufferingCard.addSubview(bufferingSpeedLabel)

    NSLayoutConstraint.activate([
      bufferingCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      bufferingCard.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      bufferingCard.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
      bufferingCard.heightAnchor.constraint(equalToConstant: 80),

      bufferingSpinner.centerXAnchor.constraint(equalTo: bufferingCard.centerXAnchor),
      bufferingSpinner.topAnchor.constraint(equalTo: bufferingCard.topAnchor, constant: 16),

      bufferingSpeedLabel.centerXAnchor.constraint(equalTo: bufferingCard.centerXAnchor),
      bufferingSpeedLabel.leadingAnchor.constraint(equalTo: bufferingCard.leadingAnchor, constant: 10),
      bufferingSpeedLabel.trailingAnchor.constraint(equalTo: bufferingCard.trailingAnchor, constant: -10),
      bufferingSpeedLabel.bottomAnchor.constraint(equalTo: bufferingCard.bottomAnchor, constant: -12)
    ])
  }

  private func setupFloatingHuds() {
    for hud in [gestureHudLabel, speedBoostPill, topNoticeLabel, toastLabel] {
      hud.translatesAutoresizingMaskIntoConstraints = false
      hud.backgroundColor = UIColor(white: 0.08, alpha: 0.82)
      hud.textColor = .white
      hud.layer.cornerRadius = 8
      hud.clipsToBounds = true
      hud.isHidden = true
      hud.isUserInteractionEnabled = false
      view.addSubview(hud)
    }
    gestureHudLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
    speedBoostPill.font = UIFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
    topNoticeLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    toastLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)

    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      gestureHudLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      gestureHudLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -56),

      speedBoostPill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      speedBoostPill.topAnchor.constraint(equalTo: safe.topAnchor, constant: 18),

      topNoticeLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
      topNoticeLabel.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),

      toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      toastLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -72)
    ])
  }

  private func setupErrorCard() {
    errorCard.translatesAutoresizingMaskIntoConstraints = false
    errorCard.backgroundColor = UIColor(white: 0.11, alpha: 0.94)
    errorCard.layer.cornerRadius = 16
    errorCard.isHidden = true
    view.addSubview(errorCard)

    errorTitleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    errorTitleLabel.textColor = UIColor(red: 1.0, green: 0.76, blue: 0.28, alpha: 1.0)
    errorTitleLabel.textAlignment = .center
    errorTitleLabel.text = "⚠️ " + IosPlayerUiText.t("获取播放链接失败", "Playback Error")

    errorBodyLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
    errorBodyLabel.textColor = UIColor(white: 0.88, alpha: 1.0)
    errorBodyLabel.textAlignment = .center
    errorBodyLabel.numberOfLines = 6

    stylePillButton(errorCancelBtn)
    errorCancelBtn.setTitle(IosPlayerUiText.t("取消", "Dismiss"), for: .normal)
    errorCancelBtn.addTarget(self, action: #selector(onTapErrorCancel), for: .touchUpInside)

    stylePillButton(errorCopyBtn)
    errorCopyBtn.setTitle(IosPlayerUiText.t("复制错误信息", "Copy Error"), for: .normal)
    errorCopyBtn.addTarget(self, action: #selector(onTapErrorCopy), for: .touchUpInside)

    stylePillButton(errorRetryBtn)
    errorRetryBtn.backgroundColor = IosPlayerUiText.accentColor(hex: controller.playbackConfig.accentColorHex)
    errorRetryBtn.setTitle(IosPlayerUiText.t("重试", "Retry"), for: .normal)
    errorRetryBtn.addTarget(self, action: #selector(onTapErrorRetry), for: .touchUpInside)

    let btnRow = UIStackView(arrangedSubviews: [errorCancelBtn, errorCopyBtn, errorRetryBtn])
    btnRow.axis = .horizontal
    btnRow.spacing = 10
    btnRow.distribution = .fillProportionally

    let stack = UIStackView(arrangedSubviews: [errorTitleLabel, errorBodyLabel, btnRow])
    stack.axis = .vertical
    stack.spacing = 14
    stack.alignment = .center
    stack.translatesAutoresizingMaskIntoConstraints = false
    errorCard.addSubview(stack)

    NSLayoutConstraint.activate([
      errorCard.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      errorCard.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      errorCard.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
      errorCard.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
      errorCard.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),

      stack.leadingAnchor.constraint(equalTo: errorCard.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: errorCard.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: errorCard.topAnchor, constant: 18),
      stack.bottomAnchor.constraint(equalTo: errorCard.bottomAnchor, constant: -18)
    ])
  }

  private func styleIconButton(_ btn: UIButton, symbol: String, pointSize: CGFloat) {
    let cfg = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    btn.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
    btn.tintColor = .white
    btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
  }

  private func stylePillButton(_ btn: UIButton) {
    btn.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    btn.setTitleColor(.white, for: .normal)
    btn.backgroundColor = UIColor(white: 1.0, alpha: 0.16)
    btn.layer.cornerRadius = 14
    btn.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
  }

  // MARK: - Gestures

  private func setupGestures() {
    let singleTap = UITapGestureRecognizer(target: self, action: #selector(onSingleTap))
    singleTap.delegate = self

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(onDoubleTap))
    doubleTap.numberOfTapsRequired = 2
    doubleTap.delegate = self
    singleTap.require(toFail: doubleTap)

    let pan = UIPanGestureRecognizer(target: self, action: #selector(onPan(_:)))
    pan.delegate = self

    let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
    longPress.minimumPressDuration = 0.35
    longPress.delegate = self

    view.addGestureRecognizer(singleTap)
    view.addGestureRecognizer(doubleTap)
    view.addGestureRecognizer(pan)
    view.addGestureRecognizer(longPress)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
    if let touchedView = touch.view, touchedView is UIControl {
      return false
    }
    return true
  }

  @objc private func onSingleTap() {
    setControlsVisible(!controlsVisible)
  }

  @objc private func onDoubleTap() {
    guard !screenLocked else {
      setControlsVisible(true)
      return
    }
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "light") }
    controller.togglePause()
  }

  @objc private func onPan(_ gr: UIPanGestureRecognizer) {
    guard !screenLocked else { return }
    let translation = gr.translation(in: view)
    let loc = gr.location(in: view)

    switch gr.state {
    case .began:
      panMode = .none
      panStartPosMs = controller.kernel.positionMs
      panStartBrightness = UIScreen.main.brightness
      panStartVolume = systemVolumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume
    case .changed:
      if panMode == .none {
        if abs(translation.x) > 14 && abs(translation.x) > abs(translation.y) {
          panMode = controller.isLive ? .none : .seek
        } else if abs(translation.y) > 14 {
          panMode = (loc.x < view.bounds.width * 0.5) ? .brightness : .volume
        }
      }
      switch panMode {
      case .seek:
        let deltaMs = IosPlayerUiText.swipeSeekMs(dx: translation.x, width: max(1, view.bounds.width))
        let dur = controller.kernel.durationMs
        panTargetPosMs = dur > 0 ? min(max(0, panStartPosMs + deltaMs), dur) : max(0, panStartPosMs + deltaMs)
        let diffSec = (panTargetPosMs - panStartPosMs) / 1000
        let sign = diffSec >= 0 ? "+" : ""
        gestureHudLabel.text = "\(IosPlayerUiText.clock(panTargetPosMs)) / \(IosPlayerUiText.clock(dur)) (\(sign)\(diffSec)s)"
        gestureHudLabel.isHidden = false
      case .brightness:
        let next = min(1.0, max(0.02, panStartBrightness - (translation.y / max(160, view.bounds.height * 0.7))))
        UIScreen.main.brightness = next
        gestureHudLabel.text = IosPlayerUiText.t("亮度", "Brightness") + " \(Int((next * 100).rounded()))%"
        gestureHudLabel.isHidden = false
      case .volume:
        let next = min(Float(1.0), max(Float(0.0), panStartVolume - Float(translation.y / max(160, view.bounds.height * 0.7))))
        systemVolumeSlider?.value = next
        gestureHudLabel.text = IosPlayerUiText.t("音量", "Volume") + " \(Int((next * 100).rounded()))%"
        gestureHudLabel.isHidden = false
      case .none:
        break
      }
    case .ended, .cancelled:
      if panMode == .seek {
        controller.seekTo(panTargetPosMs)
      }
      panMode = .none
      gestureHudLabel.isHidden = true
    default:
      break
    }
  }

  @objc private func onLongPress(_ gr: UILongPressGestureRecognizer) {
    guard !screenLocked, controller.kernel.isPlaying else { return }
    switch gr.state {
    case .began:
      if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "medium") }
      savedSpeedBeforeBoost = controller.currentSpeed
      longPressStartPoint = gr.location(in: view)
      let boost = controller.playbackConfig.longPressSpeed
      controller.setSpeed(boost)
      speedBoostPill.text = "⏩ " + IosPlayerUiText.t("长按倍速 ", "Hold for ") + IosPlayerUiText.speed(boost)
      speedBoostPill.isHidden = false
    case .changed:
      guard controller.playbackConfig.isLongPressSpeedAdjustEnabled != false else { return }
      let loc = gr.location(in: view)
      let upPt = longPressStartPoint.y - loc.y
      let dx = loc.x - longPressStartPoint.x
      let effectiveDelta = abs(upPt) >= abs(dx) ? upPt : (dx * 0.625)
      let adjusted = IosPlayerUiText.longPressSlideSpeed(
        base: controller.playbackConfig.longPressSpeed,
        upPt: effectiveDelta,
        ptPerStep: 50.0,
        enabled: controller.playbackConfig.isLongPressSpeedAdjustEnabled
      )
      if abs(adjusted - controller.currentSpeed) >= 0.1 {
        if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "selection") }
        controller.setSpeed(adjusted)
        speedBoostPill.text = "⏩ " + IosPlayerUiText.t("滑动倍速 ", "Boost ") + IosPlayerUiText.speed(adjusted)
      }
    case .ended, .cancelled, .failed:
      if let prev = savedSpeedBeforeBoost {
        controller.setSpeed(prev)
      }
      savedSpeedBeforeBoost = nil
      speedBoostPill.isHidden = true
    default:
      break
    }
  }

  // MARK: - Controls Visibility

  private func setControlsVisible(_ visible: Bool) {
    controlsVisible = visible
    UIView.animate(withDuration: 0.2) {
      self.controlsContainer.alpha = (visible && !self.screenLocked) ? 1.0 : 0.0
      self.lockButton.alpha = visible ? 1.0 : 0.0
      self.setNeedsStatusBarAppearanceUpdate()
      self.setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
    if visible {
      scheduleAutoHide()
    } else {
      hideControlsWorkItem?.cancel()
    }
  }

  private func scheduleAutoHide() {
    hideControlsWorkItem?.cancel()
    guard controlsVisible, controller.state == "playing", !isScrubbingSlider else { return }
    let work = DispatchWorkItem { [weak self] in
      self?.setControlsVisible(false)
    }
    hideControlsWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: work)
  }

  // MARK: - Button Actions

  @objc private func onTapBack() {
    restorePortraitBeforeExit()
    controller.close(completed: false, dismissVC: true)
  }

  @objc private func onTapLock() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "selection") }
    screenLocked.toggle()
    lockButton.setImage(UIImage(systemName: screenLocked ? "lock.fill" : "lock.open"), for: .normal)
    setControlsVisible(true)
  }

  @objc private func onTapPlayPause() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "light") }
    controller.togglePause()
    scheduleAutoHide()
  }

  @objc private func onTapPrevEp() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "selection") }
    _ = controller.previousEpisode()
  }

  @objc private func onTapNextEp() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "selection") }
    _ = controller.nextEpisode()
  }

  @objc private func onTapRewind() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "selection") }
    controller.seekBy(seconds: -Int(controller.playbackConfig.fastForwardSeconds))
  }

  @objc private func onTapForward() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "selection") }
    controller.seekBy(seconds: Int(controller.playbackConfig.fastForwardSeconds))
  }

  @objc private func onSliderTouchDown() {
    isScrubbingSlider = true
    hideControlsWorkItem?.cancel()
  }

  @objc private func onSliderChanged() {
    let dur = controller.kernel.durationMs
    let previewMs = Int64(Double(progressSlider.value) * Double(dur))
    currentTimeLabel.text = IosPlayerUiText.clock(previewMs)
    rightTimeLabel.text = IosPlayerUiText.rightTime(
      positionMs: previewMs,
      durationMs: dur,
      showTotal: controller.playbackConfig.isShowAllDuration
    )
  }

  @objc private func onSliderTouchUp() {
    let dur = controller.kernel.durationMs
    let targetMs = Int64(Double(progressSlider.value) * Double(dur))
    isScrubbingSlider = false
    controller.seekTo(targetMs)
    scheduleAutoHide()
  }

  @objc private func onTapMarkHeadTail() {
    guard let isIntro = IosPlayerUiText.markButton(
      positionMs: controller.kernel.positionMs,
      durationMs: controller.kernel.durationMs,
      allowed: controller.canMarkHeadTail
    ) else { return }
    if isIntro {
      controller.markIntro()
    } else {
      controller.markOutro()
    }
  }

  @objc private func onTapPiP() {
    guard controller.kernel.isUsingAvPlayer else {
      controllerDidShowToast(
        IosPlayerUiText.t("iOS 系统画中画仅在 AVPlayer 内核下可用", "iOS system PiP requires AVPlayer kernel"),
        long: false
      )
      return
    }
    guard controller.kernel.isPictureInPictureSupported else {
      controllerDidShowToast(IosPlayerUiText.t("当前设备不支持画中画", "PiP not supported on this device"), long: false)
      return
    }
    dismissedForPiP = true
    restorePortraitBeforeExit()
    controller.kernel.togglePictureInPicture()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self = self, self.presentingViewController != nil else { return }
      self.dismiss(animated: true)
    }
  }

  @objc private func onTapScreenshot() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "medium") }
    controller.kernel.captureScreenshot { [weak self] _, msg in
      self?.controllerDidShowToast(msg, long: false)
    }
  }

  @objc private func onTapRotate() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "selection") }
    preferLandscape.toggle()
    applyPreferredOrientation()
  }

  @objc private func onTapDanmakuToggle() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "selection") }
    controller.setDanmakuEnabled(!controller.danmakuConfig.enabled)
  }

  @objc private func onTapErrorCancel() {
    controller.dismissError()
  }

  @objc private func onTapErrorCopy() {
    UIPasteboard.general.string = controller.copyableErrorText
    controllerDidShowToast(IosPlayerUiText.t("已复制完整诊断信息", "Diagnostic info copied"), long: false)
  }

  @objc private func onTapErrorRetry() {
    controller.retry()
  }

  // MARK: - Action Sheets & Menus

  @objc private func onTapSpeed() {
    let sheet = UIAlertController(title: IosPlayerUiText.t("播放倍速", "Playback Speed"), message: nil, preferredStyle: .actionSheet)
    for sp in IosPlayerUiText.speeds.reversed() {
      let check = abs(controller.currentSpeed - sp) < 0.01 ? "✓ " : ""
      sheet.addAction(UIAlertAction(title: check + IosPlayerUiText.speedMenuLabel(sp), style: .default) { [weak self] _ in
        self?.controller.setSpeed(sp)
      })
    }
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    presentSheet(sheet, anchor: speedBtn)
  }

  @objc private func onTapFitMode() {
    if controller.playbackConfig.hapticEnabled { IosHaptics.play(kind: "selection") }
    let next = IosPlayerUiText.nextFitMode(controller.playbackConfig.fitMode)
    controller.setFitMode(next)
    controllerDidShowToast(IosPlayerUiText.fitModeLabel(next), long: false)
  }

  @objc private func onTapQuality() {
    let names = controller.qualityNames
    guard !names.isEmpty else { return }
    let sheet = UIAlertController(title: IosPlayerUiText.t("切换画质", "Quality"), message: nil, preferredStyle: .actionSheet)
    for (idx, name) in names.enumerated() {
      let check = (controller.quality == idx) ? "✓ " : ""
      sheet.addAction(UIAlertAction(title: check + name, style: .default) { [weak self] _ in
        self?.controller.selectQuality(idx)
      })
    }
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    presentSheet(sheet, anchor: qualityBtn)
  }

  @objc private func onTapEpisodes() {
    let lines = controller.lineNames()
    if lines.count > 1 {
      let lineSheet = UIAlertController(
        title: IosPlayerUiText.t("选择播放线路与剧集", "Lines & Episodes"),
        message: IosPlayerUiText.t("当前线路：", "Current Line: ") + (lines[safe: controller.line] ?? ""),
        preferredStyle: .actionSheet
      )
      for (lIdx, lName) in lines.enumerated() {
        let mark = (lIdx == controller.line) ? "✓ " : ""
        lineSheet.addAction(UIAlertAction(title: "\(mark)\(lName) (\(controller.episodeNames(forLine: lIdx).count))", style: .default) { [weak self] _ in
          self?.presentEpisodeList(forLine: lIdx)
        })
      }
      lineSheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
      presentSheet(lineSheet, anchor: episodeBtn)
    } else {
      presentEpisodeList(forLine: controller.line)
    }
  }

  private func presentEpisodeList(forLine lineIdx: Int) {
    let eps = controller.episodeNames(forLine: lineIdx)
    let sheet = UIAlertController(
      title: IosPlayerUiText.t("选择剧集", "Select Episode"),
      message: nil,
      preferredStyle: .actionSheet
    )
    for (eIdx, eName) in eps.enumerated() {
      let mark = (lineIdx == controller.line && eIdx == controller.episode) ? "✓ " : ""
      sheet.addAction(UIAlertAction(title: mark + eName, style: .default) { [weak self] _ in
        self?.controller.selectLineEpisode(lineIndex: lineIdx, episodeIndex: eIdx)
      })
    }
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    presentSheet(sheet, anchor: episodeBtn)
  }

  @objc private func onTapDanmakuStyle() {
    let cfg = controller.danmakuConfig
    let sheet = UIAlertController(
      title: IosPlayerUiText.t("弹幕设置", "Danmaku Settings") + " (\(controller.danmakuView.commentCount))",
      message: String(format: "%@ %.0f%% · %@ %.0fpt · %@ %.1fx",
                      IosPlayerUiText.t("不透明度", "Opacity"), cfg.opacity * 100,
                      IosPlayerUiText.t("字号", "Size"), cfg.fontSize,
                      IosPlayerUiText.t("速度", "Speed"), cfg.scrollSpeed),
      preferredStyle: .actionSheet
    )
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("搜索/手动匹配弹幕…", "Search & Match Danmaku…"), style: .default) { [weak self] _ in
      self?.onTapDanmakuSearch()
    })
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("显示区域：半屏 / 1/4屏 / 满屏切换", "Cycle Display Area"), style: .default) { [weak self] _ in
      guard let self = self else { return }
      var next = self.controller.danmakuConfig
      next.area = (next.area < 0.35) ? 0.5 : ((next.area < 0.7) ? 0.85 : 0.25)
      self.controller.updateDanmaku(next)
      self.controllerDidShowToast(IosPlayerUiText.t("弹幕区域：", "Area: ") + "\(Int(next.area * 100))%", long: false)
    })
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("字号调节（小 / 中 / 大）", "Cycle Font Size"), style: .default) { [weak self] _ in
      guard let self = self else { return }
      var next = self.controller.danmakuConfig
      next.fontSize = (next.fontSize < 16) ? 18 : ((next.fontSize < 21) ? 22 : 14)
      self.controller.updateDanmaku(next)
      self.controllerDidShowToast("\(Int(next.fontSize)) pt", long: false)
    })
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("不透明度（100% / 75% / 50%）", "Cycle Opacity"), style: .default) { [weak self] _ in
      guard let self = self else { return }
      var next = self.controller.danmakuConfig
      next.opacity = (next.opacity > 0.85) ? 0.75 : ((next.opacity > 0.6) ? 0.5 : 1.0)
      self.controller.updateDanmaku(next)
      self.controllerDidShowToast("\(Int(next.opacity * 100))%", long: false)
    })
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("颜色模式：", "Color: ") + IosPlayerUiText.danmakuColorModeLabel(cfg.colorMode), style: .default) { [weak self] _ in
      guard let self = self else { return }
      var next = self.controller.danmakuConfig
      let modes = IosPlayerUiText.danmakuColorModes
      let curIdx = modes.firstIndex(of: next.colorMode) ?? 0
      next.colorMode = modes[(curIdx + 1) % modes.count]
      self.controller.updateDanmaku(next)
      self.controllerDidShowToast(IosPlayerUiText.danmakuColorModeLabel(next.colorMode), long: false)
    })
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("弹幕时间偏移 -0.5 秒", "Danmaku Delay -0.5s"), style: .default) { [weak self] _ in
      guard let self = self else { return }
      var next = self.controller.danmakuConfig
      next.delaySeconds -= 0.5
      self.controller.updateDanmaku(next)
      self.controllerDidShowToast(String(format: "%+.1f s", next.delaySeconds), long: false)
    })
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("弹幕时间偏移 +0.5 秒", "Danmaku Delay +0.5s"), style: .default) { [weak self] _ in
      guard let self = self else { return }
      var next = self.controller.danmakuConfig
      next.delaySeconds += 0.5
      self.controller.updateDanmaku(next)
      self.controllerDidShowToast(String(format: "%+.1f s", next.delaySeconds), long: false)
    })
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    presentSheet(sheet, anchor: danmakuStyleBtn)
  }

  @objc private func onTapDanmakuSearch() {
    controller.danmakuPrompt { [weak self] info in
      guard let self = self else { return }
      let alert = UIAlertController(
        title: IosPlayerUiText.t("搜索弹幕番剧", "Search Danmaku"),
        message: nil,
        preferredStyle: .alert
      )
      alert.addTextField { tf in
        tf.text = info?.keyword ?? self.controller.title
        tf.placeholder = IosPlayerUiText.t("输入片名关键词", "Anime / Drama title")
      }
      alert.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
      alert.addAction(UIAlertAction(title: IosPlayerUiText.t("搜索", "Search"), style: .default) { [weak self] _ in
        guard let self = self, let kw = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !kw.isEmpty else { return }
        self.controller.danmakuSearchListener = { [weak self] items in
          self?.presentDanmakuAnimeResults(items)
        }
        self.controller.searchDanmaku(keyword: kw)
      })
      self.present(alert, animated: true)
    }
  }

  private func presentDanmakuAnimeResults(_ results: [DanmakuSearchResultItem]) {
    guard !results.isEmpty else {
      controllerDidShowToast(IosPlayerUiText.t("未搜索到匹配的弹幕库条目", "No danmaku matches found"), long: false)
      return
    }
    let sheet = UIAlertController(title: IosPlayerUiText.t("选择番剧", "Select Title"), message: nil, preferredStyle: .actionSheet)
    for item in results.prefix(20) {
      sheet.addAction(UIAlertAction(title: "\(item.animeTitle) (\(item.episodeCount))", style: .default) { [weak self] _ in
        guard let self = self else { return }
        self.controller.danmakuEpisodesListener = { [weak self] eps in
          self?.presentDanmakuEpisodeResults(eps)
        }
        self.controller.pickDanmakuAnime(animeId: item.animeId)
      })
    }
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    presentSheet(sheet, anchor: danmakuBindButton)
  }

  private func presentDanmakuEpisodeResults(_ episodes: [EpisodeItem]) {
    guard !episodes.isEmpty else { return }
    let sheet = UIAlertController(title: IosPlayerUiText.t("选择对应集数弹幕", "Select Danmaku Episode"), message: nil, preferredStyle: .actionSheet)
    for ep in episodes.prefix(60) {
      sheet.addAction(UIAlertAction(title: ep.episodeName, style: .default) { [weak self] _ in
        self?.controller.pickDanmakuEpisode(index: Int(ep.episodeIndex))
      })
    }
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    presentSheet(sheet, anchor: danmakuBindButton)
  }

  @objc private func onTapSettings() {
    hideControlsWorkItem?.cancel()
    let drawer = IosPlayerSettingsDrawerController(
      controller: controller,
      onOpenSubtitles: { [weak self] in self?.presentSubtitleTrackPicker() },
      onOpenAudios: { [weak self] in self?.presentAudioTrackPicker() },
      onImportLocalSubtitle: { [weak self] in self?.presentLocalSubtitleFilePicker() },
      onImportUrlSubtitle: { [weak self] in self?.presentExternalSubtitlePrompt() },
      onOrientationChanged: { [weak self] preferLand in
        guard let self = self else { return }
        self.preferLandscape = preferLand
        self.applyPreferredOrientation()
      }
    )
    present(drawer, animated: true)
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
        IosPlayerUiText.t("请选择 .srt / .ass / .vtt 字幕文件", "Please choose a .srt / .ass / .vtt subtitle file"),
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
        IosPlayerUiText.t("已加载本地字幕：\(picked.lastPathComponent)", "Loaded subtitle: \(picked.lastPathComponent)"),
        long: false
      )
    } catch {
      self.controller.addExternalSubtitle(url: picked.path, name: picked.lastPathComponent)
    }
  }

  private func presentSubtitleTrackPicker() {
    let sheet = UIAlertController(title: IosPlayerUiText.t("选择字幕轨道", "Subtitles"), message: nil, preferredStyle: .actionSheet)
    let offCheck = !controller.kernel.subtitlesEnabled ? "✓ " : ""
    sheet.addAction(UIAlertAction(title: offCheck + IosPlayerUiText.t("关闭字幕", "Off"), style: .default) { [weak self] _ in
      self?.controller.kernel.selectSubtitle(-1)
    })
    for t in controller.kernel.subtitleTracks() {
      let check = t.selected ? "✓ " : ""
      sheet.addAction(UIAlertAction(title: check + t.label, style: .default) { [weak self] _ in
        self?.controller.kernel.selectSubtitle(t.index)
      })
    }
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    presentSheet(sheet, anchor: settingsButton)
  }

  private func presentAudioTrackPicker() {
    let sheet = UIAlertController(title: IosPlayerUiText.t("选择音轨", "Audio Tracks"), message: nil, preferredStyle: .actionSheet)
    for t in controller.kernel.audioTracks() {
      let check = t.selected ? "✓ " : ""
      sheet.addAction(UIAlertAction(title: check + t.label, style: .default) { [weak self] _ in
        self?.controller.kernel.selectAudio(t.index)
      })
    }
    sheet.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    presentSheet(sheet, anchor: settingsButton)
  }

  private func presentExternalSubtitlePrompt() {
    let alert = UIAlertController(
      title: IosPlayerUiText.t("加载外挂字幕", "Load External Subtitle"),
      message: IosPlayerUiText.t("支持 .srt / .vtt / .ass 链接", "Supports .srt / .vtt / .ass URL"),
      preferredStyle: .alert
    )
    alert.addTextField { tf in
      tf.placeholder = "https://example.com/sub.srt"
      tf.keyboardType = .URL
    }
    alert.addAction(UIAlertAction(title: IosPlayerUiText.t("取消", "Cancel"), style: .cancel))
    alert.addAction(UIAlertAction(title: IosPlayerUiText.t("加载", "Load"), style: .default) { [weak self] _ in
      guard let self = self, let url = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return }
      let name = URL(string: url)?.lastPathComponent ?? "External"
      self.controller.addExternalSubtitle(url: url, name: name)
    })
    present(alert, animated: true)
  }

  private func presentSheet(_ sheet: UIAlertController, anchor: UIView) {
    sheet.overrideUserInterfaceStyle = .dark
    if let pop = sheet.popoverPresentationController {
      pop.sourceView = anchor
      pop.sourceRect = anchor.bounds
    }
    present(sheet, animated: true)
  }

  // MARK: - Refresh UI & Delegate Callbacks

  private func refreshUI() {
    let p = controller.playbackConfig
    let k = controller.kernel

    titleLabel.text = controller.title

    var badges: [String] = []
    if k.videoSize.width > 0 && k.videoSize.height > 0 {
      badges.append("\(Int(k.videoSize.width))x\(Int(k.videoSize.height))")
    }
    if let ep = controller.episodeName, !ep.isEmpty {
      badges.append(ep)
    }
    badgeLabel.text = badges.joined(separator: "  ·  ")
    badgeLabel.isHidden = badges.isEmpty

    let playing = (controller.state == "playing" && k.isPlaying)
    styleIconButton(playPauseBtn, symbol: playing ? "pause.fill" : "play.fill", pointSize: 20)

    let multiEp = controller.episodeNames().count > 1
    prevEpBtn.isHidden = !multiEp
    nextEpBtn.isHidden = !multiEp
    prevEpBtn.isEnabled = controller.hasPrevious
    nextEpBtn.isEnabled = controller.hasNext
    episodeBtn.isHidden = (controller.episodeNames().count <= 1 && controller.lineNames().count <= 1)

    let seekSec = Int(p.fastForwardSeconds)
    rewindBtn.isHidden = p.isHiddenFastSeekBtn || controller.isLive
    forwardBtn.isHidden = p.isHiddenFastSeekBtn || controller.isLive
    let rwSym = [5, 10, 15, 30].contains(seekSec) ? "gobackward.\(seekSec)" : "gobackward"
    let fwSym = [5, 10, 15, 30].contains(seekSec) ? "goforward.\(seekSec)" : "goforward"
    styleIconButton(rewindBtn, symbol: rwSym, pointSize: 16)
    styleIconButton(forwardBtn, symbol: fwSym, pointSize: 16)

    progressSlider.isHidden = controller.isLive
    rightTimeLabel.isHidden = controller.isLive

    let dmOn = controller.danmakuConfig.enabled
    danmakuToggleBtn.setTitle(dmOn ? IosPlayerUiText.t("弹幕 开", "DM On") : IosPlayerUiText.t("弹幕 关", "DM Off"), for: .normal)
    danmakuToggleBtn.backgroundColor = dmOn
      ? IosPlayerUiText.accentColor(hex: p.accentColorHex).withAlphaComponent(0.85)
      : UIColor(white: 1.0, alpha: 0.16)

    if let qName = controller.qualityName, !controller.qualityNames.isEmpty {
      qualityBtn.isHidden = false
      qualityBtn.setTitle(qName, for: .normal)
    } else {
      qualityBtn.isHidden = true
    }

    let accent = IosPlayerUiText.accentColor(hex: p.accentColorHex)
    airPlayPicker.activeTintColor = accent
    airPlayPicker.isHidden = !k.isUsingAvPlayer
    pipButton.alpha = k.isUsingAvPlayer ? 1.0 : 0.45

    if let family = p.subtitleFontFamily?.trimmingCharacters(in: .whitespacesAndNewlines),
       !family.isEmpty,
       let customFont = UIFont(name: family, size: 17) {
      sidecarSubtitleLabel.font = customFont
    } else {
      sidecarSubtitleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    }

    speedBtn.isHidden = controller.isLive
    speedBtn.setTitle(IosPlayerUiText.speed(controller.currentSpeed), for: .normal)
    fitBtn.setTitle(IosPlayerUiText.fitModeLabel(p.fitMode), for: .normal)

    // Error Card & Buffering Card
    if let err = controller.errorMessage {
      errorTitleLabel.text = IosPlayerUiText.errorTitle(err)
      errorBodyLabel.text = IosPlayerUiText.errorDetail(err)
      errorCard.isHidden = false
      bufferingCard.isHidden = true
    } else {
      errorCard.isHidden = true
      let showBuffering = (!controller.failed && (controller.state == "buffering" || controller.state == "idle"))
      bufferingCard.isHidden = !showBuffering
      bufferingSpeedLabel.isHidden = false
      bufferingSpeedLabel.text = IosPlayerUiText.bufferingSpeed(k.downloadBytesPerSec)
    }

    updateMetricsLabels()
  }

  private func updateMetricsLabels() {
    let k = controller.kernel
    let p = controller.playbackConfig

    if !isScrubbingSlider {
      currentTimeLabel.text = IosPlayerUiText.clock(k.positionMs)
      rightTimeLabel.text = IosPlayerUiText.rightTime(
        positionMs: k.positionMs,
        durationMs: k.durationMs,
        showTotal: p.isShowAllDuration
      )
      if k.durationMs > 0 {
        progressSlider.value = Float(Double(k.positionMs) / Double(k.durationMs))
      } else {
        progressSlider.value = 0
      }
    }

    if !bufferingCard.isHidden {
      bufferingSpeedLabel.text = IosPlayerUiText.bufferingSpeed(k.downloadBytesPerSec)
    }

    if let isIntro = IosPlayerUiText.markButton(
      positionMs: k.positionMs,
      durationMs: k.durationMs,
      allowed: controller.canMarkHeadTail
    ) {
      markHeadTailBtn.isHidden = false
      markHeadTailBtn.setTitle(isIntro ? IosPlayerUiText.t("记片头", "Mark Intro") : IosPlayerUiText.t("记片尾", "Mark Outro"), for: .normal)
    } else {
      markHeadTailBtn.isHidden = true
    }

    if p.isShowStatsBar {
      var parts: [String] = [k.activeBackendSummary]
      if let codec = k.videoCodecName { parts.append(codec) }
      if let fps = k.nominalFps, fps > 0 {
        parts.append(fps.truncatingRemainder(dividingBy: 1.0) == 0 ? "\(Int(fps)) FPS" : String(format: "%.1f FPS", fps))
      }
      if k.videoSize.width > 0 && k.videoSize.height > 0 {
        parts.append("\(Int(k.videoSize.width))x\(Int(k.videoSize.height))")
      }
      parts.append(IosPlayerUiText.netSpeed(k.downloadBytesPerSec))
      statsBarLabel.text = parts.joined(separator: " · ")
      statsBarLabel.isHidden = false
    } else if p.showNetSpeed && k.downloadBytesPerSec > 0 && bufferingCard.isHidden {
      statsBarLabel.text = "↓ " + IosPlayerUiText.netSpeed(k.downloadBytesPerSec)
      statsBarLabel.isHidden = false
    } else {
      statsBarLabel.isHidden = true
    }
  }

  func controllerDidChangeState() {
    refreshUI()
    scheduleAutoHide()
  }

  func controllerDidUpdateMetrics() {
    updateMetricsLabels()
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
    topNoticeLabel.isHidden = false
    topNoticeLabel.alpha = 1.0
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
      guard let self = self, self.topNoticeLabel.text == text else { return }
      UIView.animate(withDuration: 0.25, animations: { self.topNoticeLabel.alpha = 0.0 }) { _ in
        self.topNoticeLabel.isHidden = true
      }
    }
  }

  func controllerDidShowToast(_ text: String, long: Bool) {
    toastLabel.text = text
    toastLabel.isHidden = false
    toastLabel.alpha = 1.0
    let delay = long ? 3.5 : 2.0
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self = self, self.toastLabel.text == text else { return }
      UIView.animate(withDuration: 0.25, animations: { self.toastLabel.alpha = 0.0 }) { _ in
        self.toastLabel.isHidden = true
      }
    }
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

private final class PaddingLabel: UILabel {
  private let insets: UIEdgeInsets
  init(insets: UIEdgeInsets) {
    self.insets = insets
    super.init(frame: .zero)
  }
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: insets))
  }
  override var intrinsicContentSize: CGSize {
    let s = super.intrinsicContentSize
    guard s.width > 0 && s.height > 0 else { return s }
    return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    (index >= 0 && index < count) ? self[index] : nil
  }
}
