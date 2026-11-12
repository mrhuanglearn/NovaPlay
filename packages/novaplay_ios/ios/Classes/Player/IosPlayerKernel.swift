import AVFoundation
import AVKit
import CoreImage
import os
import Photos
import UIKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

private let playerUsbLog = Logger(subsystem: "app.novaplay.player", category: "player")

struct IosTrackOption {
  let index: Int
  let label: String
  let language: String?
  let selected: Bool
}

protocol IosPlayerKernelDelegate: AnyObject {
  func kernelDidChangeState(_ state: String)
  func kernelDidFail(message: String, code: Int?)
  func kernelDidUpdateSubtitleCue(_ text: String?)
  func kernelDidUpdateMetrics()
  func kernelDidFallbackNotice(_ message: String)
  func kernelPictureInPictureDidCloseSession()
  func kernelPictureInPictureRestoreUI(completion: @escaping (Bool) -> Void)
}

private final class AvLayerView: UIView {
  override static var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Touch-inert drawable host for `MobileVLCKit`.
/// `MobileVLCKit` (`VLCVideoUIView`) attaches its own internal `UITapGestureRecognizer` (for DVD menus)
/// and enables `userInteractionEnabled` on its drawable view, which otherwise preempts and cancels
/// `NativePlayerViewController`'s single-tap gesture recognizer (`singleTap.require(toFail: doubleTap)`).
private final class VlcDrawableContainerView: UIView {
  override init(frame: CGRect) {
    super.init(frame: frame)
    super.isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isUserInteractionEnabled: Bool {
    get { false }
    set {}
  }

  override func didAddSubview(_ subview: UIView) {
    super.didAddSubview(subview)
    disableInteractionsRecursively(on: subview)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    for sub in subviews {
      disableInteractionsRecursively(on: sub)
    }
  }

  override func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
    // Ignore internal gesture recognizers attached by MobileVLCKit.
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    return nil
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    return false
  }

  private func disableInteractionsRecursively(on view: UIView) {
    view.isUserInteractionEnabled = false
    if let recognizers = view.gestureRecognizers, !recognizers.isEmpty {
      for gr in recognizers {
        gr.isEnabled = false
        view.removeGestureRecognizer(gr)
      }
    }
    for child in view.subviews {
      disableInteractionsRecursively(on: child)
    }
  }
}

/// Unified video container hosting:
/// - `avLayerView` (`AVPlayerLayer` for `AVPlayer` + system PiP)
/// - `mpvMetalView` (`CAMetalLayer` for `libmpv` + `MoltenVK` + VideoToolbox)
/// - `vlcDrawableView` (drawable view for `MobileVLCKit`)
/// implementing canonical `PlaybackConfig.fitMode` values: `fit` (letterbox), `zoom` (aspect-fill crop), and `fill` (stretch).
final class PlayerVideoContainerView: UIView {
  fileprivate let avLayerView = AvLayerView(frame: .zero)
  fileprivate let mpvMetalView = MpvMetalView(frame: .zero)
  fileprivate let vlcDrawableView: UIView = VlcDrawableContainerView(frame: .zero)

  var playerLayer: AVPlayerLayer { avLayerView.playerLayer }

  var fitMode: String = "fit" {
    didSet { applyFitLayout() }
  }
  var naturalVideoSize: CGSize = .zero {
    didSet { applyFitLayout() }
  }
  var activeBackend: String = "avplayer" {
    didSet {
      avLayerView.isHidden = (activeBackend != "avplayer")
      mpvMetalView.isHidden = (activeBackend != "mpv")
      vlcDrawableView.isHidden = (activeBackend != "vlc")
      applyFitLayout()
    }
  }
  var onBoundsChangedForVlcFill: ((CGSize) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    clipsToBounds = true
    isUserInteractionEnabled = false
    avLayerView.backgroundColor = .black
    avLayerView.isUserInteractionEnabled = false
    mpvMetalView.backgroundColor = .black
    mpvMetalView.isHidden = true
    mpvMetalView.isUserInteractionEnabled = false
    vlcDrawableView.backgroundColor = .black
    vlcDrawableView.isHidden = true
    vlcDrawableView.isUserInteractionEnabled = false
    addSubview(avLayerView)
    addSubview(mpvMetalView)
    addSubview(vlcDrawableView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isUserInteractionEnabled: Bool {
    get { false }
    set {}
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    return nil
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    return false
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    avLayerView.frame = bounds
    mpvMetalView.frame = bounds
    applyFitLayout()
  }

  func bind(avPlayer: AVPlayer?) {
    avLayerView.playerLayer.player = avPlayer
    applyFitLayout()
  }

  fileprivate func applyFitLayout() {
    // 1. AVPlayerLayer gravity
    switch fitMode {
    case "zoom":
      avLayerView.playerLayer.videoGravity = .resizeAspectFill
    case "fill":
      avLayerView.playerLayer.videoGravity = .resize
    default:
      avLayerView.playerLayer.videoGravity = .resizeAspect
    }

    // 2. MPV Metal view always fills container bounds (aspect/panscan handled inside libmpv)
    mpvMetalView.frame = bounds

    // 3. VLC drawable frame & aspect ratio
    guard bounds.width > 0, bounds.height > 0 else {
      vlcDrawableView.frame = bounds
      return
    }
    switch fitMode {
    case "zoom":
      if naturalVideoSize.width > 0, naturalVideoSize.height > 0 {
        let scale = max(bounds.width / naturalVideoSize.width, bounds.height / naturalVideoSize.height)
        let w = naturalVideoSize.width * scale
        let h = naturalVideoSize.height * scale
        vlcDrawableView.frame = CGRect(
          x: (bounds.width - w) * 0.5,
          y: (bounds.height - h) * 0.5,
          width: w,
          height: h
        )
      } else {
        vlcDrawableView.frame = bounds
      }
      onBoundsChangedForVlcFill?(.zero)
    case "fill":
      vlcDrawableView.frame = bounds
      onBoundsChangedForVlcFill?(bounds.size)
    default:
      vlcDrawableView.frame = bounds
      onBoundsChangedForVlcFill?(.zero)
    }
  }
}

/// Triple-kernel iOS 15+ player facade:
/// - `avplayer`: Apple `AVPlayer` (VideoToolbox HW decode, native iOS system PiP, native AirPlay, DASH dual-stream, sidecar subtitles)
/// - `mpv`: `libmpv` (`vo=gpu-next`, `gpu-context=moltenvk`, `CAMetalLayer`, VideoToolbox HW vs FFmpeg SW decode, ASS/SSA/MKV/FLV/TS/DASH)
/// - `vlc`: `MobileVLCKit` (`libvlc` + FFmpeg multi-format MKV/FLV/AVI/TS/RMVB/ASS, VideoToolbox HW vs FFmpeg SW decode)
final class IosPlayerKernel: NSObject, AVPictureInPictureControllerDelegate, IosMpvEngineDelegate {
  weak var delegate: IosPlayerKernelDelegate?

  let videoView = PlayerVideoContainerView(frame: .zero)

  static var isMpvAvailable: Bool {
    IosMpvEngine.isAvailable
  }

  static var isVlcAvailable: Bool {
    #if canImport(MobileVLCKit)
    return true
    #else
    return false
    #endif
  }

  private(set) var preferredKernelId: String = "avplayer"
  private(set) var activeKernelId: String = "avplayer"
  private(set) var lastDiagnosticReport: String?
  var hwDecode: Bool = true {
    didSet {
      mpvEngine?.hwDecode = hwDecode
    }
  }
  var isUsingAvPlayer: Bool { activeKernelId == "avplayer" }
  var isUsingMpv: Bool { activeKernelId == "mpv" }
  var isUsingVlc: Bool { activeKernelId == "vlc" }

  var activeBackendSummary: String {
    switch activeKernelId {
    case "mpv":
      return hwDecode ? "MPV (VT HW)" : "MPV (FFmpeg SW)"
    case "vlc":
      return hwDecode ? "VLC (VT HW)" : "VLC (FFmpeg SW)"
    default:
      return "AVPlayer (VT HW)"
    }
  }

  // MARK: - AVPlayer State
  private let avPlayer = AVPlayer()
  private var secondaryAudioPlayer: AVPlayer?
  private var videoOutput: AVPlayerItemVideoOutput?
  private var pipController: AVPictureInPictureController?
  private var pipRestorePending = false

  private var timeObserver: Any?
  private var statusObs: NSKeyValueObservation?
  private var timeControlObs: NSKeyValueObservation?
  private var bufferEmptyObs: NSKeyValueObservation?
  private var likelyToKeepUpObs: NSKeyValueObservation?
  private var presentationSizeObs: NSKeyValueObservation?
  private var endObserver: NSObjectProtocol?
  private var failedEndObserver: NSObjectProtocol?
  private var shiftedSidecarIndexForCurrentItem: Bool = false

  // MARK: - MPV State
  private var mpvEngine: IosMpvEngine?
  private var mpvLoadedViaProxy: Bool = false
  private var mpvRetriedViaProxy: Bool = false

  // MARK: - MobileVLCKit State
  #if canImport(MobileVLCKit)
  private var vlcPlayer: VLCMediaPlayer?
  private var vlcStatsTimer: Timer?
  private var vlcAspectCString: UnsafeMutablePointer<CChar>?
  private var vlcPendingStartMs: Int64 = 0
  private var vlcAppliedInitialSeek: Bool = false
  private var vlcLoadedViaProxy: Bool = false
  #endif

  // MARK: - Shared Metrics & Tracks
  private(set) var positionMs: Int64 = 0
  private(set) var durationMs: Int64 = 0
  private(set) var bufferedMs: Int64 = 0
  private(set) var videoSize: CGSize = .zero
  private(set) var downloadBytesPerSec: Double = 0
  private(set) var videoCodecName: String?
  private(set) var nominalFps: Double?
  private(set) var state: String = "idle"
  private var isSeeking: Bool = false
  private var shouldAutoPlay: Bool = true

  private var lastBytesTotal: Int64 = -1
  private var lastProxyBytesTotal: Int64 = -1
  private var lastBytesSampleTime: TimeInterval = 0

  private struct ActiveLoadContext {
    let generation: UInt64
    let rawUrl: String
    let cleanUrl: URL
    let audioUrl: String?
    let effectiveHeaders: [String: String]
    let startMs: Int64
    let subtitles: [SubtitleOption]
    let proxyToken: String?
    var proxiedUrl: URL?
  }
  private var loadGeneration: UInt64 = 0
  private var activeLoad: ActiveLoadContext?
  private var cancelPendingProbe: (() -> Void)?
  private var didAutoFallbackFromAv: Bool = false
  private var didAutoFallbackToVlc: Bool = false
  private var vlcRetriedDirect: Bool = false
  private var lastAvFailureSummary: String?
  private var lastMpvFailureSummary: String?
  private var lastAvFailedRawUrl: String?

  var speed: Float = 1.0 {
    didSet {
      switch activeKernelId {
      case "avplayer":
        if isPlaying {
          avPlayer.rate = speed
          secondaryAudioPlayer?.rate = speed
        }
      case "mpv":
        mpvEngine?.speed = speed
      default:
        #if canImport(MobileVLCKit)
        vlcPlayer?.rate = speed
        #endif
      }
    }
  }

  var fitMode: String = "fit" {
    didSet {
      videoView.fitMode = fitMode
      mpvEngine?.fitMode = fitMode
    }
  }

  var autoPictureInPicture: Bool = true {
    didSet {
      pipController?.canStartPictureInPictureAutomaticallyFromInline = autoPictureInPicture && isUsingAvPlayer
    }
  }

  private struct LoadedSidecarSubtitle {
    let option: SubtitleOption
    var cues: [SubtitleCue]
  }
  private var sidecarSubtitles: [LoadedSidecarSubtitle] = []
  private var selectedSubtitleIdx: Int = -1
  private var preferredSubtitleLang: String?
  private var preferredSubtitleFontFamily: String?
  private var preferredAudioLang: String?
  private var selectedAudioIdx: Int = -1

  var isPlaying: Bool {
    switch activeKernelId {
    case "avplayer":
      return avPlayer.rate > 0.01 && avPlayer.timeControlStatus == .playing
    case "mpv":
      return mpvEngine?.isPlaying ?? false
    default:
      return state == "playing"
    }
  }

  var isInPictureInPicture: Bool {
    isUsingAvPlayer && (pipController?.isPictureInPictureActive ?? false)
  }

  init(requestedKernel: String = "avplayer", hwDecode: Bool = true) {
    self.hwDecode = hwDecode
    super.init()
    configureAudioSession()
    avPlayer.automaticallyWaitsToMinimizeStalling = true
    videoView.bind(avPlayer: avPlayer)
    setupPictureInPictureIfSupported()
    attachAvPeriodicObserver()
    videoView.onBoundsChangedForVlcFill = { [weak self] fillSize in
      self?.applyVlcFillAspect(fillSize)
    }
    selectKernelBackend(requestedKernel, notifyFallback: false)
  }

  func selectKernelBackend(_ rawKernel: String, notifyFallback: Bool = true) {
    let normalized = IosPlayerUiText.normalizeIosKernel(rawKernel)
    lastAvFailedRawUrl = nil
    switch normalized {
    case "mpv":
      if Self.isMpvAvailable {
        preferredKernelId = "mpv"
        applyActiveBackend("mpv")
      } else if Self.isVlcAvailable {
        preferredKernelId = "vlc"
        applyActiveBackend("vlc")
        if notifyFallback {
          delegate?.kernelDidFallbackNotice(
            IosPlayerUiText.t("当前构建未内置 MPV 内核，已自动切换至 VLC", "MPV not bundled in this build; using VLC")
          )
        }
      } else {
        preferredKernelId = "avplayer"
        applyActiveBackend("avplayer")
        if notifyFallback {
          delegate?.kernelDidFallbackNotice(
            IosPlayerUiText.t("当前构建未内置 MPV 内核，已自动回退至 AVPlayer", "MPV not bundled in this build; using AVPlayer")
          )
        }
      }
    case "vlc":
      #if canImport(MobileVLCKit)
      preferredKernelId = "vlc"
      applyActiveBackend("vlc")
      #else
      if Self.isMpvAvailable {
        preferredKernelId = "mpv"
        applyActiveBackend("mpv")
      } else {
        preferredKernelId = "avplayer"
        applyActiveBackend("avplayer")
      }
      if notifyFallback {
        delegate?.kernelDidFallbackNotice(
          IosPlayerUiText.t("当前构建未内置 VLC 内核，已自动回退", "VLC not bundled in this build; switched kernel")
        )
      }
      #endif
    default:
      preferredKernelId = "avplayer"
      applyActiveBackend("avplayer")
    }
  }

  private func ensureMpvEngine() -> IosMpvEngine {
    if let existing = mpvEngine {
      return existing
    }
    let engine = IosMpvEngine(
      metalView: videoView.mpvMetalView,
      hwDecode: hwDecode,
      fitMode: fitMode,
      speed: speed
    )
    engine.delegate = self
    engine.applyAudioPreference(lang: preferredAudioLang)
    engine.applySubtitlePreferences(lang: preferredSubtitleLang, fontFamily: preferredSubtitleFontFamily)
    mpvEngine = engine
    return engine
  }

  private func applyActiveBackend(_ target: String) {
    switch target {
    case "mpv":
      guard Self.isMpvAvailable else {
        if Self.isVlcAvailable {
          applyActiveBackend("vlc")
        } else {
          applyActiveBackend("avplayer")
        }
        return
      }
      if activeKernelId != "mpv" {
        stopAvPlaybackOnly()
        stopVlcPlaybackOnly()
        activeKernelId = "mpv"
        videoView.activeBackend = "mpv"
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false
      }
    case "vlc":
      #if canImport(MobileVLCKit)
      if activeKernelId != "vlc" {
        stopAvPlaybackOnly()
        stopMpvPlaybackOnly()
        activeKernelId = "vlc"
        videoView.activeBackend = "vlc"
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false
      }
      #else
      applyActiveBackend("avplayer")
      #endif
    default:
      if activeKernelId != "avplayer" {
        stopMpvPlaybackOnly()
        stopVlcPlaybackOnly()
        activeKernelId = "avplayer"
        videoView.activeBackend = "avplayer"
        pipController?.canStartPictureInPictureAutomaticallyFromInline = autoPictureInPicture
      }
    }
  }

  /// Picks the best available software/multi-format kernel (`mpv` preferred, then `vlc`) when `AVPlayer` cannot open a stream.
  private func preferredFallbackBackendAfterAvPlayer() -> String? {
    if Self.isMpvAvailable { return "mpv" }
    if Self.isVlcAvailable { return "vlc" }
    return nil
  }

  private func switchActiveBackendTemporarily(to backend: String, notice: String?) {
    applyActiveBackend(backend)
    if let notice = notice, !notice.isEmpty {
      delegate?.kernelDidFallbackNotice(notice)
    }
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay, .allowBluetoothA2DP])
    try? session.setActive(true)
  }

  private func setupPictureInPictureIfSupported() {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    if let ctrl = AVPictureInPictureController(playerLayer: videoView.playerLayer) {
      ctrl.delegate = self
      ctrl.canStartPictureInPictureAutomaticallyFromInline = autoPictureInPicture && isUsingAvPlayer
      pipController = ctrl
    }
  }

  private func attachAvPeriodicObserver() {
    let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
    timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
      guard let self = self, self.isUsingAvPlayer else { return }
      let sec = CMTimeGetSeconds(time)
      if sec.isFinite && sec >= 0 {
        self.positionMs = Int64(sec * 1000.0)
      }
      if let item = self.avPlayer.currentItem {
        let dur = CMTimeGetSeconds(item.duration)
        if dur.isFinite && dur > 0 {
          self.durationMs = Int64(dur * 1000.0)
        } else {
          self.durationMs = 0
        }
        if let firstRange = item.loadedTimeRanges.first?.timeRangeValue {
          let endSec = CMTimeGetSeconds(CMTimeAdd(firstRange.start, firstRange.duration))
          if endSec.isFinite && endSec >= 0 {
            self.bufferedMs = Int64(endSec * 1000.0)
          }
        }
      }
      self.sampleAvDownloadSpeed(from: self.avPlayer.currentItem)
      self.updateCurrentSidecarCue()
      self.delegate?.kernelDidUpdateMetrics()
    }
  }

  private func sampleAvDownloadSpeed(from item: AVPlayerItem?) {
    let now = CACurrentMediaTime()
    guard now - lastBytesSampleTime >= 0.5 else { return }
    let prevTime = lastBytesSampleTime
    lastBytesSampleTime = now

    if activeLoad?.proxyToken != nil {
      let proxyTotal = IosStreamProxy.shared.totalUpstreamBytesRead()
      if lastProxyBytesTotal >= 0 && prevTime > 0 && proxyTotal >= lastProxyBytesTotal {
        let dt = max(0.2, now - prevTime)
        let delta = Double(proxyTotal - lastProxyBytesTotal) / dt
        downloadBytesPerSec = delta > 0 ? delta : 0
      }
      lastProxyBytesTotal = proxyTotal
      if downloadBytesPerSec > 0 {
        return
      }
    }

    guard let item = item, let events = item.accessLog()?.events, !events.isEmpty else {
      downloadBytesPerSec = 0
      return
    }
    let totalBytes = events.reduce(Int64(0)) { acc, ev in
      acc + max(0, ev.numberOfBytesTransferred)
    }
    if lastBytesTotal >= 0 && prevTime > 0 && totalBytes >= lastBytesTotal {
      let dt = max(0.2, now - prevTime)
      let delta = Double(totalBytes - lastBytesTotal) / dt
      if delta > 0 {
        downloadBytesPerSec = delta
      } else if let lastEv = events.last, lastEv.observedBitrate.isFinite && lastEv.observedBitrate > 0 && state == "buffering" {
        downloadBytesPerSec = lastEv.observedBitrate / 8.0
      } else {
        downloadBytesPerSec = 0
      }
    } else if let lastEv = events.last, lastEv.observedBitrate.isFinite && lastEv.observedBitrate > 0 {
      downloadBytesPerSec = lastEv.observedBitrate / 8.0
    } else {
      downloadBytesPerSec = 0
    }
    lastBytesTotal = totalBytes
  }

  // MARK: - Load Media

  func load(
    url: String,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    subtitles: [SubtitleOption]
  ) {
    loadGeneration &+= 1
    let gen = loadGeneration
    cancelPendingProbe?()
    cancelPendingProbe = nil

    lastBytesTotal = -1
    lastProxyBytesTotal = IosStreamProxy.shared.totalUpstreamBytesRead()
    lastBytesSampleTime = CACurrentMediaTime()
    downloadBytesPerSec = 0
    positionMs = max(0, startMs)
    durationMs = 0
    bufferedMs = 0
    videoSize = .zero
    videoCodecName = nil
    nominalFps = nil
    selectedSubtitleIdx = -1
    selectedAudioIdx = -1
    shouldAutoPlay = true
    isSeeking = false
    didAutoFallbackFromAv = false
    didAutoFallbackToVlc = false
    vlcRetriedDirect = false
    mpvLoadedViaProxy = false
    mpvRetriedViaProxy = false
    lastAvFailureSummary = nil
    lastMpvFailureSummary = nil
    lastDiagnosticReport = nil
    delegate?.kernelDidUpdateSubtitleCue(nil)

    if preferredKernelId == "avplayer",
       lastAvFailedRawUrl == url,
       let fb = preferredFallbackBackendAfterAvPlayer() {
      didAutoFallbackFromAv = true
      if fb == "vlc" { didAutoFallbackToVlc = true }
      applyActiveBackend(fb)
    } else {
      applyActiveBackend(preferredKernelId)
    }
    updateState("buffering")

    let (parsedURL, effectiveHeaders) = IosUrlSanitizer.normalizeUrlAndHeaders(rawUrl: url, headers: headers)
    guard let mediaURL = parsedURL else {
      let msg = IosPlayerUiText.t("无效的播放地址", "Invalid playback URL")
      playerUsbLog.error("[NovaPlay][Player] invalid playback URL")
      lastDiagnosticReport = "\(msg)\nrawUrl=\(url.prefix(240))"
      delegate?.kernelDidFail(message: msg, code: -1)
      return
    }

    stopAvPlaybackOnly()
    stopMpvPlaybackOnly()
    stopVlcPlaybackOnly()
    loadSidecarSubtitles(subtitles, headers: effectiveHeaders)

    let scheme = (mediaURL.scheme ?? "").lowercased()
    let targetHost = mediaURL.isFileURL ? "local-file" : (mediaURL.host ?? "-")
    let targetExt = mediaURL.pathExtension.lowercased()
    let headerKeys = effectiveHeaders.keys.sorted().joined(separator: ",")
    let activeBackend = activeKernelId
    playerUsbLog.notice(
      "[NovaPlay][Player] load backend=\(activeBackend, privacy: .public) scheme=\(scheme, privacy: .public) host=\(targetHost, privacy: .public) ext=\(targetExt, privacy: .public) startMs=\(startMs, privacy: .public) headerKeys=[\(headerKeys, privacy: .public)]"
    )

    if mediaURL.isFileURL {
      activeLoad = ActiveLoadContext(
        generation: gen,
        rawUrl: url,
        cleanUrl: mediaURL,
        audioUrl: audioUrl,
        effectiveHeaders: effectiveHeaders,
        startMs: startMs,
        subtitles: subtitles,
        proxyToken: nil,
        proxiedUrl: mediaURL
      )
      if isUsingAvPlayer,
         IosStreamProxy.isLikelyVlcOnlyExtension(mediaURL.pathExtension),
         let fb = preferredFallbackBackendAfterAvPlayer() {
        didAutoFallbackFromAv = true
        if fb == "vlc" { didAutoFallbackToVlc = true }
        let extUpper = mediaURL.pathExtension.uppercased()
        let fbLabel = fb.uppercased()
        switchActiveBackendTemporarily(
          to: fb,
          notice: IosPlayerUiText.t("检测到 \(extUpper) 格式，已自动切换至 \(fbLabel) 内核", "Switched to \(fbLabel) for \(extUpper)")
        )
      }
      dispatchActiveBackendLoad(
        directOrProxiedURL: mediaURL,
        cleanURL: mediaURL,
        audioUrl: audioUrl,
        headers: effectiveHeaders,
        startMs: startMs,
        subtitles: subtitles,
        proxyToken: nil
      )
      return
    }

    if scheme == "http" || scheme == "https" {
      let token = IosStreamProxy.shared.registerSession(rootURL: mediaURL, headers: effectiveHeaders)
      let initialKind = IosStreamProxy.inferredKind(for: mediaURL)
      let initialFile = IosStreamProxy.inferredFileName(for: mediaURL)
      let defaultProxied = IosStreamProxy.shared.buildProxyURL(
        targetURL: mediaURL,
        token: token,
        kind: initialKind,
        fileName: initialFile
      ) ?? mediaURL

      activeLoad = ActiveLoadContext(
        generation: gen,
        rawUrl: url,
        cleanUrl: mediaURL,
        audioUrl: audioUrl,
        effectiveHeaders: effectiveHeaders,
        startMs: startMs,
        subtitles: subtitles,
        proxyToken: token,
        proxiedUrl: defaultProxied
      )

      // MPV sends arbitrary HTTP headers (Cookie, Referer, User-Agent, Origin) natively via FFmpeg libavformat,
      // and avoids double-proxying CatPaw's 127.0.0.1:2333 chunk proxy.
      if isUsingMpv {
        loadWithMpvPlayer(
          mediaURL: mediaURL,
          audioUrl: audioUrl,
          headers: effectiveHeaders,
          startMs: startMs,
          subtitles: subtitles,
          viaProxy: false
        )
        return
      }

      if isUsingVlc {
        #if canImport(MobileVLCKit)
        loadWithVlcPlayer(
          mediaURL: defaultProxied,
          audioUrl: audioUrl,
          headers: effectiveHeaders,
          startMs: startMs,
          subtitles: subtitles,
          proxyToken: token
        )
        return
        #else
        applyActiveBackend("avplayer")
        #endif
      }

      if IosStreamProxy.isLikelyVlcOnlyExtension(mediaURL.pathExtension),
         let fb = preferredFallbackBackendAfterAvPlayer() {
        didAutoFallbackFromAv = true
        if fb == "vlc" { didAutoFallbackToVlc = true }
        let extUpper = mediaURL.pathExtension.uppercased()
        let fbLabel = fb.uppercased()
        switchActiveBackendTemporarily(
          to: fb,
          notice: IosPlayerUiText.t("检测到 \(extUpper) 格式，已自动切换至 \(fbLabel) 内核", "Switched to \(fbLabel) for \(extUpper)")
        )
        if fb == "mpv" {
          loadWithMpvPlayer(
            mediaURL: mediaURL,
            audioUrl: audioUrl,
            headers: effectiveHeaders,
            startMs: startMs,
            subtitles: subtitles,
            viaProxy: false
          )
        } else {
          #if canImport(MobileVLCKit)
          loadWithVlcPlayer(
            mediaURL: defaultProxied,
            audioUrl: audioUrl,
            headers: effectiveHeaders,
            startMs: startMs,
            subtitles: subtitles,
            proxyToken: token
          )
          #endif
        }
        return
      }

      cancelPendingProbe = IosStreamProxy.shared.probe(token: token) { [weak self] probeRes in
        guard let self = self, self.loadGeneration == gen else { return }
        self.cancelPendingProbe = nil

        var probeHardFailure: (msg: String, code: Int)?
        if let httpCode = probeRes.statusCode,
           [401, 403, 404, 410, 451, 500, 502, 503, 504].contains(httpCode) {
          let shortMsg = IosPlayerUiText.t(
            "视频播放失败 (上游返回 HTTP \(httpCode)，请尝试切换线路)",
            "Playback failed (Upstream HTTP \(httpCode), please switch source)"
          )
          probeHardFailure = (shortMsg, httpCode)
        } else if probeRes.container == .html && (probeRes.statusCode ?? 200) < 400 {
          let shortMsg = IosPlayerUiText.t(
            "视频播放失败 (上游返回防盗链网页而非视频流，请尝试切换线路)",
            "Playback failed (Upstream returned HTML page instead of media)"
          )
          probeHardFailure = (shortMsg, -11828)
        } else if probeRes.statusCode == nil, let netErr = probeRes.errorDescription, !netErr.isEmpty {
          let shortMsg = IosPlayerUiText.t(
            "视频播放失败 (\(netErr))",
            "Playback failed (\(netErr))"
          )
          probeHardFailure = (shortMsg, -1001)
        }

        if let failure = probeHardFailure {
          if !self.didAutoFallbackFromAv, let fb = self.preferredFallbackBackendAfterAvPlayer() {
            self.didAutoFallbackFromAv = true
            if fb == "vlc" {
              self.didAutoFallbackToVlc = true
              self.vlcRetriedDirect = true
            }
            self.lastAvFailureSummary = failure.msg
            self.switchActiveBackendTemporarily(to: fb, notice: nil)
            if fb == "mpv" {
              self.loadWithMpvPlayer(
                mediaURL: mediaURL,
                audioUrl: audioUrl,
                headers: effectiveHeaders,
                startMs: startMs,
                subtitles: subtitles,
                viaProxy: false
              )
            } else {
              #if canImport(MobileVLCKit)
              self.loadWithVlcPlayer(
                mediaURL: mediaURL,
                audioUrl: audioUrl,
                headers: effectiveHeaders,
                startMs: startMs,
                subtitles: subtitles,
                proxyToken: nil
              )
              #endif
            }
            return
          }
          let diag = IosStreamProxy.shared.diagnosticsSummary(for: token) ?? "code=\(failure.code)"
          self.lastDiagnosticReport = "\(failure.msg)\n[\(diag)]"
          self.delegate?.kernelDidFail(message: failure.msg, code: failure.code)
          return
        }

        let resolvedKind = probeRes.container.proxyKind
        let resolvedFile = (probeRes.container == .unknown)
          ? IosStreamProxy.inferredFileName(for: probeRes.finalURL ?? mediaURL)
          : probeRes.container.proxyFileName
        let resolvedProxyURL = IosStreamProxy.shared.buildProxyURL(
          targetURL: mediaURL,
          token: token,
          kind: resolvedKind,
          fileName: resolvedFile
        ) ?? defaultProxied
        self.activeLoad?.proxiedUrl = resolvedProxyURL

        if probeRes.container.requiresVlc, let fb = self.preferredFallbackBackendAfterAvPlayer() {
          self.didAutoFallbackFromAv = true
          if fb == "vlc" { self.didAutoFallbackToVlc = true }
          let fmtLabel = probeRes.container.rawValue.uppercased()
          let fbLabel = fb.uppercased()
          self.switchActiveBackendTemporarily(
            to: fb,
            notice: IosPlayerUiText.t("检测到 \(fmtLabel) 格式，已自动切换至 \(fbLabel) 内核", "Switched to \(fbLabel) for \(fmtLabel)")
          )
          if fb == "mpv" {
            self.loadWithMpvPlayer(
              mediaURL: mediaURL,
              audioUrl: audioUrl,
              headers: effectiveHeaders,
              startMs: startMs,
              subtitles: subtitles,
              viaProxy: false
            )
          } else {
            #if canImport(MobileVLCKit)
            self.loadWithVlcPlayer(
              mediaURL: resolvedProxyURL,
              audioUrl: audioUrl,
              headers: effectiveHeaders,
              startMs: startMs,
              subtitles: subtitles,
              proxyToken: token
            )
            #endif
          }
          return
        }

        self.loadWithAvPlayer(
          mediaURL: resolvedProxyURL,
          audioUrl: audioUrl,
          headers: effectiveHeaders,
          startMs: startMs,
          proxyToken: token
        )
      }
      return
    }

    // Non-HTTP streaming protocols (rtmp://, rtsp://, mms://, udp://) -> MPV or VLC
    activeLoad = ActiveLoadContext(
      generation: gen,
      rawUrl: url,
      cleanUrl: mediaURL,
      audioUrl: audioUrl,
      effectiveHeaders: effectiveHeaders,
      startMs: startMs,
      subtitles: subtitles,
      proxyToken: nil,
      proxiedUrl: mediaURL
    )
    if isUsingAvPlayer, let fb = preferredFallbackBackendAfterAvPlayer() {
      didAutoFallbackFromAv = true
      if fb == "vlc" { didAutoFallbackToVlc = true }
      let fbLabel = fb.uppercased()
      switchActiveBackendTemporarily(
        to: fb,
        notice: IosPlayerUiText.t("检测到 \(scheme.uppercased()) 协议，已自动切换至 \(fbLabel) 内核", "Switched to \(fbLabel) for \(scheme.uppercased())")
      )
    }
    dispatchActiveBackendLoad(
      directOrProxiedURL: mediaURL,
      cleanURL: mediaURL,
      audioUrl: audioUrl,
      headers: effectiveHeaders,
      startMs: startMs,
      subtitles: subtitles,
      proxyToken: nil
    )
  }

  private func dispatchActiveBackendLoad(
    directOrProxiedURL: URL,
    cleanURL: URL,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    subtitles: [SubtitleOption],
    proxyToken: String?
  ) {
    switch activeKernelId {
    case "mpv":
      loadWithMpvPlayer(
        mediaURL: cleanURL,
        audioUrl: audioUrl,
        headers: headers,
        startMs: startMs,
        subtitles: subtitles,
        viaProxy: false
      )
    case "vlc":
      #if canImport(MobileVLCKit)
      loadWithVlcPlayer(
        mediaURL: directOrProxiedURL,
        audioUrl: audioUrl,
        headers: headers,
        startMs: startMs,
        subtitles: subtitles,
        proxyToken: proxyToken
      )
      #else
      applyActiveBackend("avplayer")
      loadWithAvPlayer(
        mediaURL: directOrProxiedURL,
        audioUrl: audioUrl,
        headers: headers,
        startMs: startMs,
        proxyToken: proxyToken
      )
      #endif
    default:
      loadWithAvPlayer(
        mediaURL: directOrProxiedURL,
        audioUrl: audioUrl,
        headers: headers,
        startMs: startMs,
        proxyToken: proxyToken
      )
    }
  }

  private func loadWithAvPlayer(
    mediaURL: URL,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    proxyToken: String?
  ) {
    cleanupAvItemObservers()
    shiftedSidecarIndexForCurrentItem = false
    var assetOptions: [String: Any] = [:]
    let isOwnProxy = IosStreamProxy.shared.isOwnProxyURL(mediaURL)
    if !isOwnProxy && !headers.isEmpty {
      assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = headers
      if #available(iOS 16.0, *) {
        if let ua = headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
          assetOptions[AVURLAssetHTTPUserAgentKey] = ua
        }
      }
    }
    let asset = AVURLAsset(url: mediaURL, options: assetOptions)
    let item = AVPlayerItem(asset: asset)
    item.audioTimePitchAlgorithm = .timeDomain

    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ])
    item.add(output)
    videoOutput = output

    observeAvItem(item, startMs: startMs)
    avPlayer.replaceCurrentItem(with: item)

    secondaryAudioPlayer?.pause()
    secondaryAudioPlayer = nil
    if let audioStr = audioUrl, !audioStr.isEmpty {
      let (parsedAudioURL, audioHeaders) = IosUrlSanitizer.normalizeUrlAndHeaders(rawUrl: audioStr, headers: headers)
      if let aURL = parsedAudioURL {
        let finalAudioURL: URL
        if let token = proxyToken, (aURL.scheme == "http" || aURL.scheme == "https") {
          finalAudioURL = IosStreamProxy.shared.buildProxyURL(
            targetURL: aURL,
            token: token,
            kind: IosStreamProxy.inferredKind(for: aURL),
            fileName: "audio.m4a"
          ) ?? aURL
        } else {
          finalAudioURL = aURL
        }
        var aOpts: [String: Any] = [:]
        if !IosStreamProxy.shared.isOwnProxyURL(finalAudioURL) && !audioHeaders.isEmpty {
          aOpts["AVURLAssetHTTPHeaderFieldsKey"] = audioHeaders
        }
        let aAsset = AVURLAsset(url: finalAudioURL, options: aOpts)
        let aItem = AVPlayerItem(asset: aAsset)
        aItem.audioTimePitchAlgorithm = .timeDomain
        secondaryAudioPlayer = AVPlayer(playerItem: aItem)
      }
    }
  }

  private func loadWithMpvPlayer(
    mediaURL: URL,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    subtitles: [SubtitleOption],
    viaProxy: Bool
  ) {
    let engine = ensureMpvEngine()
    mpvLoadedViaProxy = viaProxy
    let effectiveHeaders = IosStreamProxy.shared.isOwnProxyURL(mediaURL) ? [:] : headers
    let loadUrlString = mediaURL.isFileURL ? mediaURL.path : mediaURL.absoluteString
    engine.hwDecode = hwDecode
    engine.fitMode = fitMode
    engine.speed = speed
    engine.load(
      url: loadUrlString,
      audioUrl: audioUrl,
      headers: effectiveHeaders,
      startMs: startMs,
      subtitles: subtitles
    )
  }

  #if canImport(MobileVLCKit)
  private func loadWithVlcPlayer(
    mediaURL: URL,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    subtitles: [SubtitleOption],
    proxyToken: String?
  ) {
    stopVlcPlaybackOnly()
    let player = VLCMediaPlayer()
    player.delegate = self
    player.drawable = videoView.vlcDrawableView

    let maybeMedia: VLCMedia? = VLCMedia(url: mediaURL)
    guard let media = maybeMedia else {
      let msg = "VLC " + IosPlayerUiText.t("加载失败", "load failed")
      delegate?.kernelDidFail(message: msg, code: -2)
      return
    }
    media.addOption(":network-caching=2000")
    if hwDecode {
      media.addOption(":videotoolbox")
    } else {
      media.addOption(":no-videotoolbox")
      media.addOption(":avcodec-hw=none")
      media.addOption(":avcodec-threads=0")
    }
    let isOwnProxy = IosStreamProxy.shared.isOwnProxyURL(mediaURL)
    if !isOwnProxy {
      for (k, v) in headers {
        let lower = k.lowercased()
        if lower == "user-agent" {
          media.addOption(":http-user-agent=\(v)")
        } else if lower == "referer" || lower == "referrer" {
          media.addOption(":http-referrer=\(v)")
        }
      }
    }

    vlcPendingStartMs = max(0, startMs)
    vlcAppliedInitialSeek = (vlcPendingStartMs == 0)
    vlcLoadedViaProxy = isOwnProxy
    player.media = media
    vlcPlayer = player
    videoView.applyFitLayout()

    if let audioStr = audioUrl, !audioStr.isEmpty {
      let (parsedAudioURL, _) = IosUrlSanitizer.normalizeUrlAndHeaders(rawUrl: audioStr, headers: headers)
      if let aURL = parsedAudioURL {
        let slaveURL: URL
        if let token = proxyToken, (aURL.scheme == "http" || aURL.scheme == "https") {
          slaveURL = IosStreamProxy.shared.buildProxyURL(
            targetURL: aURL,
            token: token,
            kind: IosStreamProxy.inferredKind(for: aURL),
            fileName: "audio.m4a"
          ) ?? aURL
        } else {
          slaveURL = aURL
        }
        player.addPlaybackSlave(slaveURL, type: .audio, enforce: true)
      }
    }
    for sub in subtitles {
      if let sURL = parseMediaURL(sub.url), sURL.isFileURL {
        player.addPlaybackSlave(sURL, type: .subtitle, enforce: false)
      }
    }

    player.play()
    if abs(speed - 1.0) > 0.001 {
      player.rate = speed
    }

    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.sampleVlcMetrics()
    }
    RunLoop.main.add(timer, forMode: .common)
    vlcStatsTimer = timer
  }

  private func sampleVlcMetrics() {
    guard isUsingVlc, let player = vlcPlayer else { return }
    let activeStream = (state == "playing" || state == "paused")
    if activeStream {
      let curTime: VLCTime? = player.time
      if let rawMs = curTime?.intValue, rawMs >= 0 {
        positionMs = Int64(rawMs)
      }
      let mediaLen: VLCTime? = player.media?.length
      if let len = mediaLen?.intValue, len > 0 {
        durationMs = Int64(len)
      }
      let sz = player.videoSize
      if sz.width > 0 && sz.height > 0 && sz != videoSize {
        videoSize = sz
        videoView.naturalVideoSize = sz
      }
    }
    let now = CACurrentMediaTime()
    if activeLoad?.proxyToken != nil && vlcLoadedViaProxy {
      let proxyTotal = IosStreamProxy.shared.totalUpstreamBytesRead()
      if lastProxyBytesTotal >= 0 && lastBytesSampleTime > 0 && proxyTotal >= lastProxyBytesTotal {
        let dt = max(0.2, now - lastBytesSampleTime)
        let delta = Double(proxyTotal - lastProxyBytesTotal) / dt
        downloadBytesPerSec = delta > 0 ? delta : 0
      }
      lastProxyBytesTotal = proxyTotal
      lastBytesSampleTime = now
    } else if activeStream, let media = player.media {
      let totalRead = Int64(max(0, media.numberOfReadBytesOnInput))
      if lastBytesTotal >= 0 && lastBytesSampleTime > 0 && totalRead >= lastBytesTotal {
        let dt = max(0.2, now - lastBytesSampleTime)
        let delta = Double(totalRead - lastBytesTotal) / dt
        if delta > 0 {
          downloadBytesPerSec = delta
        } else if media.inputBitrate > 0 {
          downloadBytesPerSec = Double(media.inputBitrate) * 125_000.0
        } else {
          downloadBytesPerSec = 0
        }
      } else if media.inputBitrate > 0 {
        downloadBytesPerSec = Double(media.inputBitrate) * 125_000.0
      } else {
        downloadBytesPerSec = 0
      }
      lastBytesTotal = totalRead
      lastBytesSampleTime = now
    }
    updateCurrentSidecarCue()
    delegate?.kernelDidUpdateMetrics()
  }
  #endif

  // MARK: - IosMpvEngineDelegate

  func mpvEngineDidChangeState(_ nextState: String) {
    guard isUsingMpv else { return }
    if nextState == "playing" && !shouldAutoPlay {
      mpvEngine?.pause()
      return
    }
    updateState(nextState)
  }

  func mpvEngineDidUpdateMetrics() {
    guard isUsingMpv, let engine = mpvEngine else { return }
    positionMs = engine.positionMs
    if engine.durationMs > 0 {
      durationMs = engine.durationMs
    }
    if engine.videoSize.width > 0 && engine.videoSize.height > 0 && engine.videoSize != videoSize {
      videoSize = engine.videoSize
      videoView.naturalVideoSize = engine.videoSize
    }
    if let codec = engine.videoCodecName, !codec.isEmpty {
      videoCodecName = codec
    }
    if let fps = engine.nominalFps, fps > 0 {
      nominalFps = fps
    }
    if mpvLoadedViaProxy, activeLoad?.proxyToken != nil {
      let now = CACurrentMediaTime()
      if now - lastBytesSampleTime >= 0.45 {
        let proxyTotal = IosStreamProxy.shared.totalUpstreamBytesRead()
        if lastProxyBytesTotal >= 0 && lastBytesSampleTime > 0 && proxyTotal >= lastProxyBytesTotal {
          let dt = max(0.2, now - lastBytesSampleTime)
          let delta = Double(proxyTotal - lastProxyBytesTotal) / dt
          downloadBytesPerSec = delta > 0 ? delta : engine.downloadBytesPerSec
        }
        lastProxyBytesTotal = proxyTotal
        lastBytesSampleTime = now
      }
    } else {
      downloadBytesPerSec = engine.downloadBytesPerSec
    }
    updateCurrentSidecarCue()
    delegate?.kernelDidUpdateMetrics()
  }

  func mpvEngineDidFail(message: String, diagnostic: String, code: Int) {
    guard isUsingMpv else { return }
    let proxyDiag = IosStreamProxy.shared.diagnosticsSummary(for: activeLoad?.proxyToken)
    let hasHardHttpErr = (proxyDiag?.contains("HTTP 4") == true) || (proxyDiag?.contains("HTTP 5") == true)

    // 1. Retry once via IosStreamProxy if direct HTTP open failed
    if !mpvLoadedViaProxy,
       !mpvRetriedViaProxy,
       !hasHardHttpErr,
       let ctx = activeLoad,
       ctx.generation == loadGeneration,
       let proxied = ctx.proxiedUrl,
       !ctx.cleanUrl.isFileURL {
      playerUsbLog.notice("[NovaPlay][Player] MPV direct open failed -> retrying via IosStreamProxy")
      mpvRetriedViaProxy = true
      let resumeAt = max(ctx.startMs, positionMs)
      loadWithMpvPlayer(
        mediaURL: proxied,
        audioUrl: ctx.audioUrl,
        headers: ctx.effectiveHeaders,
        startMs: resumeAt,
        subtitles: ctx.subtitles,
        viaProxy: true
      )
      return
    }

    lastMpvFailureSummary = diagnostic
    // 2. Fallback to VLC if available and not yet attempted
    #if canImport(MobileVLCKit)
    if !didAutoFallbackToVlc,
       let ctx = activeLoad,
       ctx.generation == loadGeneration {
      playerUsbLog.notice("[NovaPlay][Player] MPV failed -> falling back to VLC")
      didAutoFallbackToVlc = true
      let resumeAt = max(ctx.startMs, positionMs)
      switchActiveBackendTemporarily(
        to: "vlc",
        notice: IosPlayerUiText.t("MPV 无法打开该片源，已自动切换至 VLC 内核", "MPV failed; switched to VLC")
      )
      loadWithVlcPlayer(
        mediaURL: ctx.proxiedUrl ?? ctx.cleanUrl,
        audioUrl: ctx.audioUrl,
        headers: ctx.effectiveHeaders,
        startMs: resumeAt,
        subtitles: ctx.subtitles,
        proxyToken: ctx.proxyToken
      )
      return
    }
    #endif

    var finalMsg = message
    if let proxyDiag = proxyDiag, !finalMsg.contains(proxyDiag) {
      finalMsg += " (\(proxyDiag))"
    }
    var reportLines: [String] = [diagnostic]
    if let avFail = lastAvFailureSummary {
      reportLines.append("AVPlayer: \(avFail)")
    }
    if let proxyDiag = proxyDiag {
      reportLines.append(proxyDiag)
    }
    lastDiagnosticReport = reportLines.joined(separator: "\n")
    delegate?.kernelDidFail(message: finalMsg, code: code)
  }

  private func applyVlcFillAspect(_ fillSize: CGSize) {
    #if canImport(MobileVLCKit)
    guard let player = vlcPlayer else { return }
    if let old = vlcAspectCString {
      free(old)
      vlcAspectCString = nil
    }
    if fillSize.width > 0 && fillSize.height > 0 {
      let ratio = "\(max(1, Int(fillSize.width.rounded()))):\(max(1, Int(fillSize.height.rounded())))"
      let dup = strdup(ratio)
      vlcAspectCString = dup
      player.videoAspectRatio = dup
    } else {
      player.videoAspectRatio = nil
    }
    #endif
  }

  private func parseMediaURL(_ raw: String) -> URL? {
    IosUrlSanitizer.normalizeUrlAndHeaders(rawUrl: raw, headers: [:]).url
  }

  private func describeAvFailure(item: AVPlayerItem) -> (short: String, full: String, code: Int?) {
    let nsErr = item.error as NSError?
    let code = nsErr?.code
    let localized = nsErr?.localizedDescription ?? IosPlayerUiText.t("无法打开", "Cannot open")
    let proxyDiag = IosStreamProxy.shared.diagnosticsSummary(for: activeLoad?.proxyToken)

    var extraParts: [String] = []
    if let nsErr = nsErr {
      extraParts.append("\(nsErr.domain)(\(nsErr.code))")
      if let under = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError {
        extraParts.append("underlying=\(under.domain)(\(under.code)): \(under.localizedDescription)")
      }
    }
    if let lastEv = item.errorLog()?.events.last {
      var evStr = "avLog=\(lastEv.errorDomain)(\(lastEv.errorStatusCode))"
      if let comment = lastEv.errorComment, !comment.isEmpty {
        evStr += ":\(comment)"
      }
      extraParts.append(evStr)
    }
    if let proxyDiag = proxyDiag {
      extraParts.append(proxyDiag)
    }

    var short = "AVPlayer " + IosPlayerUiText.t("播放失败", "playback failed") + " (\(localized))"
    if let proxyDiag = proxyDiag {
      short += " [\(proxyDiag)]"
    }
    let full = extraParts.isEmpty ? short : "\(short)\n" + extraParts.joined(separator: " | ")
    return (short, full, code)
  }

  private func fallbackFromAvPlayer(
    ctx: ActiveLoadContext,
    failureSummary: String,
    zhNoticePrefix: String,
    enNoticePrefix: String
  ) -> Bool {
    guard !didAutoFallbackFromAv,
          ctx.generation == loadGeneration,
          let fb = preferredFallbackBackendAfterAvPlayer() else {
      return false
    }
    didAutoFallbackFromAv = true
    if fb == "vlc" { didAutoFallbackToVlc = true }
    lastAvFailedRawUrl = ctx.rawUrl
    lastAvFailureSummary = failureSummary
    let resumeAt = max(ctx.startMs, positionMs)
    let fbLabel = fb.uppercased()
    switchActiveBackendTemporarily(
      to: fb,
      notice: IosPlayerUiText.t("\(zhNoticePrefix)，已自动切换至 \(fbLabel) 内核", "\(enNoticePrefix); switched to \(fbLabel)")
    )
    if fb == "mpv" {
      loadWithMpvPlayer(
        mediaURL: ctx.cleanUrl,
        audioUrl: ctx.audioUrl,
        headers: ctx.effectiveHeaders,
        startMs: resumeAt,
        subtitles: ctx.subtitles,
        viaProxy: false
      )
    } else {
      #if canImport(MobileVLCKit)
      loadWithVlcPlayer(
        mediaURL: ctx.proxiedUrl ?? ctx.cleanUrl,
        audioUrl: ctx.audioUrl,
        headers: ctx.effectiveHeaders,
        startMs: resumeAt,
        subtitles: ctx.subtitles,
        proxyToken: ctx.proxyToken
      )
      #endif
    }
    return true
  }

  private func observeAvItem(_ item: AVPlayerItem, startMs: Int64) {
    statusObs = item.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
      DispatchQueue.main.async {
        guard let self = self, self.isUsingAvPlayer else { return }
        switch it.status {
        case .readyToPlay:
          if let vTrack = it.asset.tracks(withMediaType: .video).first,
             !vTrack.isPlayable,
             let ctx = self.activeLoad {
            playerUsbLog.notice("[NovaPlay][Player] AVPlayer video track unplayable -> fallback")
            if self.fallbackFromAvPlayer(
              ctx: ctx,
              failureSummary: "AVAssetTrack.isPlayable=false",
              zhNoticePrefix: "当前设备不支持该视频编码硬解",
              enNoticePrefix: "Video codec unsupported by AVPlayer"
            ) {
              return
            }
          }
          if !self.shiftedSidecarIndexForCurrentItem {
            self.shiftedSidecarIndexForCurrentItem = true
            let embCount = self.avEmbeddedSubtitleOptions().count
            if embCount > 0 && !self.sidecarSubtitles.isEmpty && self.selectedSubtitleIdx >= 0 {
              self.selectedSubtitleIdx += embCount
            }
          }
          self.inspectAvTrackMetadata(on: it)
          let codec = self.videoCodecName ?? "unknown"
          playerUsbLog.notice("[NovaPlay][Player] AVPlayer readyToPlay codec=\(codec, privacy: .public)")
          self.applyAvPreferredTracks(on: it)
          if startMs > 0 {
            let target = CMTime(value: startMs, timescale: 1000)
            self.isSeeking = true
            it.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
              DispatchQueue.main.async {
                guard let self = self, self.isUsingAvPlayer else { return }
                self.isSeeking = false
                if self.shouldAutoPlay {
                  self.play()
                } else {
                  self.syncStateFromAvPlayer()
                }
              }
            }
          } else if self.shouldAutoPlay {
            self.play()
          }
        case .failed:
          let (shortMsg, fullDiag, code) = self.describeAvFailure(item: it)
          let safeDiag = fullDiag.replacingOccurrences(of: "\n", with: " | ")
          playerUsbLog.error("[NovaPlay][Player] AVPlayer failed: \(safeDiag, privacy: .public)")
          if let ctx = self.activeLoad,
             self.fallbackFromAvPlayer(
               ctx: ctx,
               failureSummary: fullDiag,
               zhNoticePrefix: "AVPlayer 无法打开该片源",
               enNoticePrefix: "AVPlayer cannot open stream"
             ) {
            return
          }
          self.lastDiagnosticReport = fullDiag
          self.delegate?.kernelDidFail(message: shortMsg, code: code)
        default:
          break
        }
      }
    }

    presentationSizeObs = item.observe(\.presentationSize, options: [.new, .initial]) { [weak self] it, _ in
      DispatchQueue.main.async {
        guard let self = self, self.isUsingAvPlayer else { return }
        self.videoSize = it.presentationSize
        self.videoView.naturalVideoSize = it.presentationSize
        self.delegate?.kernelDidUpdateMetrics()
      }
    }

    bufferEmptyObs = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.syncStateFromAvPlayer() }
    }

    likelyToKeepUpObs = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.syncStateFromAvPlayer() }
    }

    timeControlObs = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.syncStateFromAvPlayer() }
    }

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      guard let self = self, self.isUsingAvPlayer else { return }
      self.secondaryAudioPlayer?.pause()
      self.updateState("ended")
    }

    failedEndObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] note in
      guard let self = self, self.isUsingAvPlayer else { return }
      let noteErr = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
      let (baseShort, baseFull, baseCode) = self.describeAvFailure(item: item)
      let shortMsg: String
      let fullDiag: String
      let errCode = noteErr?.code ?? baseCode
      if let noteErr = noteErr, item.error == nil {
        shortMsg = "AVPlayer " + IosPlayerUiText.t("播放中断", "playback interrupted") + " (\(noteErr.localizedDescription))"
        fullDiag = "\(shortMsg)\n\(noteErr.domain)(\(noteErr.code)) | \(baseFull)"
      } else {
        shortMsg = baseShort
        fullDiag = baseFull
      }

      if self.positionMs < 2000,
         let ctx = self.activeLoad,
         self.fallbackFromAvPlayer(
           ctx: ctx,
           failureSummary: fullDiag,
           zhNoticePrefix: "AVPlayer 分片加载失败",
           enNoticePrefix: "AVPlayer segment failed"
         ) {
        return
      }
      self.lastDiagnosticReport = fullDiag
      self.delegate?.kernelDidFail(message: shortMsg, code: errCode)
    }
  }

  private func inspectAvTrackMetadata(on item: AVPlayerItem) {
    guard let vTrack = item.asset.tracks(withMediaType: .video).first else { return }
    if vTrack.nominalFrameRate > 0 {
      nominalFps = Double(vTrack.nominalFrameRate)
    }
    if let desc = vTrack.formatDescriptions.first {
      let cfDesc = desc as! CMFormatDescription
      let subType = CMFormatDescriptionGetMediaSubType(cfDesc)
      switch subType {
      case kCMVideoCodecType_HEVC, kCMVideoCodecType_DolbyVisionHEVC:
        videoCodecName = "HEVC"
      case kCMVideoCodecType_H264:
        videoCodecName = "H.264"
      case kCMVideoCodecType_AV1:
        videoCodecName = "AV1"
      case kCMVideoCodecType_VP9:
        videoCodecName = "VP9"
      default:
        let bytes: [CChar] = [
          CChar((subType >> 24) & 0xFF),
          CChar((subType >> 16) & 0xFF),
          CChar((subType >> 8) & 0xFF),
          CChar(subType & 0xFF),
          0
        ]
        let raw = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { videoCodecName = raw.uppercased() }
      }
    }
  }

  private func syncStateFromAvPlayer() {
    guard isUsingAvPlayer else { return }
    if isSeeking {
      updateState("buffering")
      return
    }
    switch avPlayer.timeControlStatus {
    case .waitingToPlayAtSpecifiedRate:
      updateState("buffering")
    case .playing:
      updateState("playing")
    case .paused:
      if state != "ended" && state != "idle" {
        updateState("paused")
      }
    @unknown default:
      break
    }
  }

  fileprivate func updateState(_ next: String) {
    guard state != next else { return }
    state = next
    delegate?.kernelDidChangeState(next)
  }

  // MARK: - Playback Controls

  private func resumeAvPlaybackWithStallProtection() {
    if #available(iOS 16.0, *) {
      avPlayer.defaultRate = speed
      secondaryAudioPlayer?.defaultRate = speed
    }
    avPlayer.play()
    if abs(speed - 1.0) > 0.001 {
      avPlayer.rate = speed
    }
    if let sec = secondaryAudioPlayer {
      sec.seek(to: avPlayer.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
      sec.play()
      if abs(speed - 1.0) > 0.001 {
        sec.rate = speed
      }
    }
  }

  func play() {
    shouldAutoPlay = true
    configureAudioSession()
    switch activeKernelId {
    case "avplayer":
      resumeAvPlaybackWithStallProtection()
      syncStateFromAvPlayer()
    case "mpv":
      mpvEngine?.play()
    default:
      #if canImport(MobileVLCKit)
      vlcPlayer?.play()
      vlcPlayer?.rate = speed
      updateState("playing")
      #endif
    }
  }

  func pause() {
    shouldAutoPlay = false
    switch activeKernelId {
    case "avplayer":
      avPlayer.pause()
      secondaryAudioPlayer?.pause()
    case "mpv":
      mpvEngine?.pause()
    default:
      #if canImport(MobileVLCKit)
      vlcPlayer?.pause()
      #endif
    }
    updateState("paused")
  }

  func seekTo(_ ms: Int64) {
    let clamped = durationMs > 0 ? min(max(0, ms), durationMs) : max(0, ms)
    positionMs = clamped
    isSeeking = true
    updateState("buffering")

    switch activeKernelId {
    case "avplayer":
      let target = CMTime(value: clamped, timescale: 1000)
      avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
        DispatchQueue.main.async {
          guard let self = self, self.isUsingAvPlayer else { return }
          self.isSeeking = false
          if let sec = self.secondaryAudioPlayer {
            sec.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
          }
          self.updateCurrentSidecarCue()
          if self.shouldAutoPlay {
            self.resumeAvPlaybackWithStallProtection()
          }
          self.syncStateFromAvPlayer()
        }
      }
    case "mpv":
      isSeeking = false
      mpvEngine?.seekTo(clamped)
      updateCurrentSidecarCue()
    default:
      #if canImport(MobileVLCKit)
      if let player = vlcPlayer {
        let seekTime: VLCTime? = VLCTime(number: NSNumber(value: clamped))
        if let st = seekTime {
          player.time = st
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
        guard let self = self, self.isUsingVlc else { return }
        self.isSeeking = false
        self.updateCurrentSidecarCue()
        if self.shouldAutoPlay {
          self.vlcPlayer?.play()
          self.vlcPlayer?.rate = self.speed
          self.updateState("playing")
        } else {
          self.updateState("paused")
        }
      }
      #endif
    }
  }

  // MARK: - Picture in Picture (iOS Native AVPlayer only)

  var isPictureInPictureSupported: Bool {
    guard isUsingAvPlayer else { return false }
    return pipController?.isPictureInPicturePossible == true || AVPictureInPictureController.isPictureInPictureSupported()
  }

  func togglePictureInPicture() {
    guard isUsingAvPlayer, let ctrl = pipController else { return }
    if ctrl.isPictureInPictureActive {
      ctrl.stopPictureInPicture()
    } else {
      ctrl.startPictureInPicture()
    }
  }

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipRestorePending = false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    pipRestorePending = true
    delegate?.kernelPictureInPictureRestoreUI(completion: completionHandler)
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    if !pipRestorePending {
      delegate?.kernelPictureInPictureDidCloseSession()
    }
    pipRestorePending = false
  }

  // MARK: - Tracks (Audio & Subtitles)

  func applySubtitlePreferences(lang: String?, fontFamily: String? = nil) {
    preferredSubtitleLang = lang
    preferredSubtitleFontFamily = fontFamily
    mpvEngine?.applySubtitlePreferences(lang: lang, fontFamily: fontFamily)
    if isUsingAvPlayer, let item = avPlayer.currentItem, item.status == .readyToPlay {
      applyAvPreferredTracks(on: item)
    }
  }

  func applyAudioPreference(lang: String?) {
    preferredAudioLang = lang
    mpvEngine?.applyAudioPreference(lang: lang)
    if isUsingAvPlayer, let item = avPlayer.currentItem, item.status == .readyToPlay {
      applyAvPreferredTracks(on: item)
    }
  }

  /// Adds an external subtitle track without restarting video playback when supported (`mpv` / `avplayer` sidecar / `vlc` slave).
  func addExternalSubtitleHot(_ sub: SubtitleOption, headers: [String: String]) {
    let newIndex = sidecarSubtitles.count
    sidecarSubtitles.append(LoadedSidecarSubtitle(option: sub, cues: []))
    fetchSidecarSubtitleAt(idx: newIndex, sub: sub, headers: headers)
    if isUsingMpv {
      mpvEngine?.addExternalSubtitle(sub)
      selectedSubtitleIdx = -1
      delegate?.kernelDidUpdateSubtitleCue(nil)
    } else if isUsingAvPlayer {
      selectedSubtitleIdx = avEmbeddedSubtitleOptions().count + newIndex
      updateCurrentSidecarCue()
    } else {
      #if canImport(MobileVLCKit)
      if let u = parseMediaURL(sub.url), u.isFileURL {
        vlcPlayer?.addPlaybackSlave(u, type: .subtitle, enforce: true)
      } else {
        selectedSubtitleIdx = 10_000 + newIndex
      }
      updateCurrentSidecarCue()
      #endif
    }
  }

  private func applyAvPreferredTracks(on item: AVPlayerItem) {
    if let aLang = preferredAudioLang, !aLang.isEmpty,
       let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
      if let hit = group.options.first(where: { ($0.extendedLanguageTag ?? "").lowercased().hasPrefix(aLang.lowercased()) }) {
        item.select(hit, in: group)
        if let idx = group.options.firstIndex(of: hit) { selectedAudioIdx = idx }
      }
    }
    if selectedSubtitleIdx < 0, let sLang = preferredSubtitleLang, !sLang.isEmpty {
      let embeddedCount = avEmbeddedSubtitleOptions().count
      if let embIdx = avEmbeddedSubtitleOptions().firstIndex(where: { ($0.extendedLanguageTag ?? "").lowercased().hasPrefix(sLang.lowercased()) }) {
        selectSubtitle(embIdx)
      } else if let sideIdx = sidecarSubtitles.firstIndex(where: { ($0.option.language ?? "").lowercased().hasPrefix(sLang.lowercased()) }) {
        selectSubtitle(embeddedCount + sideIdx)
      }
    }
  }

  private func avEmbeddedSubtitleOptions() -> [AVMediaSelectionOption] {
    guard isUsingAvPlayer,
          let item = avPlayer.currentItem,
          item.status == .readyToPlay,
          let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) else { return [] }
    return group.options
  }

  var subtitlesEnabled: Bool {
    if isUsingAvPlayer {
      return selectedSubtitleIdx >= 0
    }
    if isUsingMpv {
      return (mpvEngine?.subtitlesEnabled ?? false) || selectedSubtitleIdx >= 10_000
    }
    #if canImport(MobileVLCKit)
    if let cur = vlcPlayer?.currentVideoSubTitleIndex, cur >= 0 {
      return true
    }
    #endif
    return selectedSubtitleIdx >= 0
  }

  func subtitleTracks() -> [IosTrackOption] {
    var list: [IosTrackOption] = []
    if isUsingAvPlayer {
      let embedded = avEmbeddedSubtitleOptions()
      for (i, opt) in embedded.enumerated() {
        list.append(IosTrackOption(
          index: i,
          label: opt.displayName,
          language: opt.extendedLanguageTag,
          selected: selectedSubtitleIdx == i
        ))
      }
      for (j, side) in sidecarSubtitles.enumerated() {
        let idx = embedded.count + j
        list.append(IosTrackOption(
          index: idx,
          label: side.option.name,
          language: side.option.language,
          selected: selectedSubtitleIdx == idx
        ))
      }
      return list
    }

    if isUsingMpv {
      return mpvEngine?.subtitleTracks() ?? []
    }

    #if canImport(MobileVLCKit)
    if (state == "playing" || state == "paused"), let player = vlcPlayer {
      let names = (player.videoSubTitlesNames as Any as? [String]) ?? []
      let indexes = ((player.videoSubTitlesIndexes as Any as? [NSNumber]) ?? []).map { Int($0.int32Value) }
      let current = Int(player.currentVideoSubTitleIndex)
      var embeddedValidCount = 0
      for (pos, vlcIdx) in indexes.enumerated() where vlcIdx >= 0 {
        let label = pos < names.count ? names[pos] : "Track \(vlcIdx)"
        list.append(IosTrackOption(
          index: vlcIdx,
          label: label,
          language: nil,
          selected: current == vlcIdx && selectedSubtitleIdx < 10_000
        ))
        embeddedValidCount += 1
      }
      for (j, side) in sidecarSubtitles.enumerated() {
        let syntheticIdx = 10_000 + j
        list.append(IosTrackOption(
          index: syntheticIdx,
          label: side.option.name + (embeddedValidCount > 0 ? " (外挂)" : ""),
          language: side.option.language,
          selected: selectedSubtitleIdx == syntheticIdx
        ))
      }
    } else {
      for (j, side) in sidecarSubtitles.enumerated() {
        let syntheticIdx = 10_000 + j
        list.append(IosTrackOption(
          index: syntheticIdx,
          label: side.option.name,
          language: side.option.language,
          selected: selectedSubtitleIdx == syntheticIdx
        ))
      }
    }
    #endif
    return list
  }

  func selectSubtitle(_ index: Int) {
    selectedSubtitleIdx = index
    if isUsingAvPlayer {
      let embedded = avEmbeddedSubtitleOptions()
      if let item = avPlayer.currentItem,
         item.status == .readyToPlay,
         let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
        if index >= 0 && index < embedded.count {
          item.select(embedded[index], in: group)
        } else {
          item.select(nil, in: group)
        }
      }
      updateCurrentSidecarCue()
      return
    }

    if isUsingMpv {
      mpvEngine?.selectSubtitle(index)
      delegate?.kernelDidUpdateSubtitleCue(nil)
      return
    }

    #if canImport(MobileVLCKit)
    if let player = vlcPlayer {
      if index < 0 || index >= 10_000 {
        player.currentVideoSubTitleIndex = -1
      } else {
        player.currentVideoSubTitleIndex = Int32(index)
      }
    }
    updateCurrentSidecarCue()
    #endif
  }

  func audioTracks() -> [IosTrackOption] {
    if isUsingAvPlayer {
      guard let item = avPlayer.currentItem,
            item.status == .readyToPlay,
            let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return [] }
      let current = item.currentMediaSelection.selectedMediaOption(in: group)
      return group.options.enumerated().map { idx, opt in
        IosTrackOption(
          index: idx,
          label: opt.displayName,
          language: opt.extendedLanguageTag,
          selected: (selectedAudioIdx == idx) || (selectedAudioIdx < 0 && current == opt)
        )
      }
    }

    if isUsingMpv {
      return mpvEngine?.audioTracks() ?? []
    }

    #if canImport(MobileVLCKit)
    if (state == "playing" || state == "paused"), let player = vlcPlayer {
      let names = (player.audioTrackNames as Any as? [String]) ?? []
      let indexes = ((player.audioTrackIndexes as Any as? [NSNumber]) ?? []).map { Int($0.int32Value) }
      let current = Int(player.currentAudioTrackIndex)
      var result: [IosTrackOption] = []
      for (pos, vlcIdx) in indexes.enumerated() where vlcIdx >= 0 {
        let label = pos < names.count ? names[pos] : "Audio \(vlcIdx)"
        result.append(IosTrackOption(
          index: vlcIdx,
          label: label,
          language: nil,
          selected: current == vlcIdx
        ))
      }
      return result
    }
    #endif
    return []
  }

  func selectAudio(_ index: Int) {
    selectedAudioIdx = index
    if isUsingAvPlayer {
      guard let item = avPlayer.currentItem,
            item.status == .readyToPlay,
            let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) else { return }
      if index >= 0 && index < group.options.count {
        item.select(group.options[index], in: group)
      } else if let def = group.defaultOption {
        item.select(def, in: group)
      }
      return
    }

    if isUsingMpv {
      mpvEngine?.selectAudio(index)
      return
    }

    #if canImport(MobileVLCKit)
    vlcPlayer?.currentAudioTrackIndex = Int32(index)
    #endif
  }

  private func loadSidecarSubtitles(_ list: [SubtitleOption], headers: [String: String]) {
    sidecarSubtitles = list.map { LoadedSidecarSubtitle(option: $0, cues: []) }
    if !list.isEmpty && selectedSubtitleIdx < 0 && !isUsingMpv {
      selectedSubtitleIdx = isUsingAvPlayer ? avEmbeddedSubtitleOptions().count : 10_000
    }
    for (idx, sub) in list.enumerated() {
      fetchSidecarSubtitleAt(idx: idx, sub: sub, headers: headers)
    }
  }

  private func fetchSidecarSubtitleAt(idx: Int, sub: SubtitleOption, headers: [String: String]) {
    guard let u = parseMediaURL(sub.url) else { return }
    if u.isFileURL {
      let accessed = u.startAccessingSecurityScopedResource()
      let text = (try? String(contentsOf: u, encoding: .utf8)) ?? (try? String(contentsOf: u, encoding: .utf16))
      if accessed { u.stopAccessingSecurityScopedResource() }
      if let text = text {
        let cues = SidecarSubtitleParser.parse(text)
        DispatchQueue.main.async { [weak self] in
          guard let self = self, idx < self.sidecarSubtitles.count else { return }
          self.sidecarSubtitles[idx].cues = cues
          self.updateCurrentSidecarCue()
        }
      }
      return
    }
    var req = URLRequest(url: u)
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
      guard let data = data,
            let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { return }
      let cues = SidecarSubtitleParser.parse(text)
      DispatchQueue.main.async {
        guard let self = self, idx < self.sidecarSubtitles.count else { return }
        self.sidecarSubtitles[idx].cues = cues
        self.updateCurrentSidecarCue()
      }
    }.resume()
  }

  private func updateCurrentSidecarCue() {
    if isUsingMpv {
      delegate?.kernelDidUpdateSubtitleCue(nil)
      return
    }
    let sideIdx: Int
    if isUsingAvPlayer {
      sideIdx = selectedSubtitleIdx - avEmbeddedSubtitleOptions().count
    } else {
      sideIdx = selectedSubtitleIdx - 10_000
    }
    guard sideIdx >= 0 && sideIdx < sidecarSubtitles.count else {
      delegate?.kernelDidUpdateSubtitleCue(nil)
      return
    }
    let cues = sidecarSubtitles[sideIdx].cues
    let pos = positionMs
    let activeLines = cues.filter { pos >= $0.startMs && pos <= $0.endMs }.map { $0.text }
    delegate?.kernelDidUpdateSubtitleCue(activeLines.isEmpty ? nil : activeLines.joined(separator: "\n"))
  }

  // MARK: - Screenshot to Photos

  func captureScreenshot(completion: @escaping (Bool, String) -> Void) {
    if isUsingAvPlayer {
      guard let output = videoOutput, let item = avPlayer.currentItem else {
        completion(false, IosPlayerUiText.t("当前画面无法截图", "No video frame available"))
        return
      }
      let time = item.currentTime()
      guard let pixelBuffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
        completion(false, IosPlayerUiText.t("当前画面暂不可截图（可能受 DRM 保护）", "Cannot capture frame right now"))
        return
      }
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      let context = CIContext(options: nil)
      guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
        completion(false, IosPlayerUiText.t("生成截图失败", "Failed to render frame"))
        return
      }
      saveImageToPhotos(UIImage(cgImage: cgImage), completion: completion)
      return
    }

    if isUsingMpv, let mpvImg = mpvEngine?.captureVideoFrame() {
      saveImageToPhotos(mpvImg, completion: completion)
      return
    }

    // Drawable hierarchy fallback (VLC / Metal view)
    guard videoView.bounds.width > 0, videoView.bounds.height > 0 else {
      completion(false, IosPlayerUiText.t("当前画面无法截图", "No video frame available"))
      return
    }
    let renderer = UIGraphicsImageRenderer(bounds: videoView.bounds)
    let image = renderer.image { _ in
      videoView.drawHierarchy(in: videoView.bounds, afterScreenUpdates: false)
    }
    saveImageToPhotos(image, completion: completion)
  }

  private func saveImageToPhotos(_ uiImage: UIImage, completion: @escaping (Bool, String) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
      guard status == .authorized || status == .limited else {
        DispatchQueue.main.async {
          completion(false, IosPlayerUiText.t("未授予相册写入权限", "Photos permission denied"))
        }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
      }) { ok, err in
        DispatchQueue.main.async {
          if ok {
            completion(true, IosPlayerUiText.t("截图已保存至系统相册", "Screenshot saved to Photos"))
          } else {
            completion(false, err?.localizedDescription ?? IosPlayerUiText.t("保存截图失败", "Failed to save screenshot"))
          }
        }
      }
    }
  }

  // MARK: - Cleanup

  private func cleanupAvItemObservers() {
    statusObs?.invalidate(); statusObs = nil
    presentationSizeObs?.invalidate(); presentationSizeObs = nil
    bufferEmptyObs?.invalidate(); bufferEmptyObs = nil
    likelyToKeepUpObs?.invalidate(); likelyToKeepUpObs = nil
    timeControlObs?.invalidate(); timeControlObs = nil
    if let obs = endObserver {
      NotificationCenter.default.removeObserver(obs)
      endObserver = nil
    }
    if let obs = failedEndObserver {
      NotificationCenter.default.removeObserver(obs)
      failedEndObserver = nil
    }
  }

  private func stopAvPlaybackOnly() {
    cleanupAvItemObservers()
    if pipController?.isPictureInPictureActive == true {
      pipController?.stopPictureInPicture()
    }
    avPlayer.pause()
    avPlayer.replaceCurrentItem(with: nil)
    secondaryAudioPlayer?.pause()
    secondaryAudioPlayer = nil
  }

  private func stopMpvPlaybackOnly() {
    mpvEngine?.stopPlayback()
  }

  private func stopVlcPlaybackOnly() {
    #if canImport(MobileVLCKit)
    vlcStatsTimer?.invalidate()
    vlcStatsTimer = nil
    if let p = vlcPlayer {
      p.delegate = nil
      p.stop()
      p.drawable = nil
    }
    vlcPlayer = nil
    if let cstr = vlcAspectCString {
      free(cstr)
      vlcAspectCString = nil
    }
    #endif
  }

  func releaseKernel() {
    loadGeneration &+= 1
    cancelPendingProbe?()
    cancelPendingProbe = nil
    activeLoad = nil
    stopAvPlaybackOnly()
    mpvEngine?.destroy()
    mpvEngine = nil
    stopVlcPlaybackOnly()
    if let obs = timeObserver {
      avPlayer.removeTimeObserver(obs)
      timeObserver = nil
    }
    pipController?.delegate = nil
    pipController = nil
    videoView.bind(avPlayer: nil)
  }
}

#if canImport(MobileVLCKit)
extension IosPlayerKernel: VLCMediaPlayerDelegate {
  func mediaPlayerStateChanged(_ aNotification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.isUsingVlc, let player = self.vlcPlayer else { return }
      switch player.state {
      case .opening, .buffering:
        if player.isPlaying {
          self.updateState("playing")
        } else {
          self.updateState("buffering")
        }
      case .playing:
        if self.state != "playing" {
          let viaProxy = self.vlcLoadedViaProxy
          let hw = self.hwDecode
          playerUsbLog.notice("[NovaPlay][Player] VLC playing viaProxy=\(viaProxy, privacy: .public) hw=\(hw, privacy: .public)")
        }
        if !self.vlcAppliedInitialSeek && self.vlcPendingStartMs > 0 {
          self.vlcAppliedInitialSeek = true
          let initialTime: VLCTime? = VLCTime(number: NSNumber(value: self.vlcPendingStartMs))
          if let st = initialTime {
            player.time = st
          }
        }
        player.rate = self.speed
        self.updateState("playing")
      case .paused:
        self.updateState("paused")
      case .ended:
        self.updateState("ended")
      case .error:
        let proxyDiag = IosStreamProxy.shared.diagnosticsSummary(for: self.activeLoad?.proxyToken)
        let hasHardHttpErr = (proxyDiag?.contains("HTTP 4") == true) || (proxyDiag?.contains("HTTP 5") == true)
        if !self.vlcRetriedDirect,
           !hasHardHttpErr,
           self.vlcLoadedViaProxy,
           let ctx = self.activeLoad,
           ctx.generation == self.loadGeneration {
          playerUsbLog.notice("[NovaPlay][Player] VLC proxy open failed -> retrying direct upstream")
          self.vlcRetriedDirect = true
          let resumeAt = max(ctx.startMs, self.positionMs)
          self.loadWithVlcPlayer(
            mediaURL: ctx.cleanUrl,
            audioUrl: ctx.audioUrl,
            headers: ctx.effectiveHeaders,
            startMs: resumeAt,
            subtitles: ctx.subtitles,
            proxyToken: nil
          )
          return
        }
        var msg: String
        if let avSummary = self.lastAvFailureSummary, avSummary.hasPrefix("视频播放失败") || avSummary.hasPrefix("Playback failed") {
          msg = avSummary
        } else if self.lastAvFailureSummary != nil || self.lastMpvFailureSummary != nil {
          msg = IosPlayerUiText.t("多内核尝试均播放失败", "All playback kernels failed to open stream")
          if let proxyDiag = proxyDiag {
            msg += " (\(proxyDiag))"
          }
        } else {
          msg = "VLC " + IosPlayerUiText.t("播放失败", "playback failed")
          if let proxyDiag = proxyDiag {
            msg += " (\(proxyDiag))"
          }
        }
        playerUsbLog.error("[NovaPlay][Player] VLC failed: \(msg, privacy: .public)")
        var reportLines: [String] = [msg]
        if let avFail = self.lastAvFailureSummary {
          reportLines.append("AVPlayer: \(avFail)")
        }
        if let mpvFail = self.lastMpvFailureSummary {
          reportLines.append("MPV: \(mpvFail)")
        }
        if let host = self.activeLoad?.cleanUrl.host {
          reportLines.append("targetHost=\(host), ext=\(self.activeLoad?.cleanUrl.pathExtension ?? "")")
        }
        self.lastDiagnosticReport = reportLines.joined(separator: "\n")
        self.delegate?.kernelDidFail(message: msg, code: -2)
      case .stopped, .esAdded:
        break
      @unknown default:
        break
      }
    }
  }

  func mediaPlayerTimeChanged(_ aNotification: Notification) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.isUsingVlc, let player = self.vlcPlayer else { return }
      let curTime: VLCTime? = player.time
      if let ms = curTime?.intValue, ms >= 0 { self.positionMs = Int64(ms) }
      let mediaLen: VLCTime? = player.media?.length
      if let len = mediaLen?.intValue, len > 0 {
        self.durationMs = Int64(len)
      }
      if self.state == "buffering" && player.isPlaying && !self.isSeeking {
        self.updateState("playing")
      }
      self.updateCurrentSidecarCue()
      self.delegate?.kernelDidUpdateMetrics()
    }
  }
}
#endif
