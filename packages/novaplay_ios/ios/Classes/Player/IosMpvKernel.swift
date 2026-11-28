import Foundation
import Metal
import OSLog
import QuartzCore
import UIKit

private let mpvUsbLog = Logger(subsystem: "app.novaplay.player", category: "mpv")

/// `CAMetalLayer` subclass guarding against MoltenVK 1x1 drawable clobbers.
private final class NovaMpvMetalLayer: CAMetalLayer {
  override var drawableSize: CGSize {
    get { super.drawableSize }
    set {
      guard newValue.width > 1, newValue.height > 1 else { return }
      super.drawableSize = newValue
    }
  }
}

/// Metal-backed drawable view (`CAMetalLayer`) used by `libmpv` (`vo=gpu-next`, `gpu-context=moltenvk`).
final class MpvMetalView: UIView {
  override class var layerClass: AnyClass {
    NovaMpvMetalLayer.self
  }

  var metalLayer: CAMetalLayer {
    // swiftlint:disable:next force_cast
    layer as! CAMetalLayer
  }

  var layerWid: Int64 {
    Int64(Int(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque()))
  }

  var onLayoutReady: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    configureMetalLayer()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureMetalLayer()
  }

  private func configureMetalLayer() {
    backgroundColor = .black
    isOpaque = true
    let scale = UIScreen.main.nativeScale
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = false
    metalLayer.isOpaque = true
    metalLayer.presentsWithTransaction = false
    metalLayer.allowsNextDrawableTimeout = true
    metalLayer.backgroundColor = UIColor.black.cgColor
    metalLayer.contentsScale = scale
    metalLayer.contentsGravity = .resizeAspect
  }

  func ensureDeviceAttached() {
    if metalLayer.device == nil {
      metalLayer.device = MTLCreateSystemDefaultDevice()
    }
    let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
    let refBounds = (bounds.width > 1 && bounds.height > 1) ? bounds : UIScreen.main.bounds
    let target = CGSize(
      width: max(64, (refBounds.width * scale).rounded()),
      height: max(64, (refBounds.height * scale).rounded())
    )
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    metalLayer.contentsScale = scale
    metalLayer.drawableSize = target
    CATransaction.commit()
    uzv_ios_mpv_notify_layer_resized(layerWid, Int32(target.width), Int32(target.height))
  }

  func syncDrawableSizeIfNeeded(forceNotify: Bool = false) {
    guard !isHidden || metalLayer.device != nil else { return }
    let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
    guard bounds.width > 1, bounds.height > 1 else { return }
    let target = CGSize(
      width: (bounds.width * scale).rounded(),
      height: (bounds.height * scale).rounded()
    )
    let changed = (metalLayer.contentsScale != scale) || (metalLayer.drawableSize != target)
    if changed {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      if metalLayer.contentsScale != scale {
        metalLayer.contentsScale = scale
      }
      if metalLayer.drawableSize != target {
        metalLayer.drawableSize = target
      }
      CATransaction.commit()
    }
    if changed || forceNotify {
      uzv_ios_mpv_notify_layer_resized(layerWid, Int32(target.width), Int32(target.height))
    }
    if let cb = onLayoutReady {
      onLayoutReady = nil
      cb()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    syncDrawableSizeIfNeeded()
  }
}

protocol IosMpvEngineDelegate: AnyObject {
  func mpvEngineDidChangeState(_ state: String)
  func mpvEngineDidUpdateMetrics()
  func mpvEngineDidFail(message: String, diagnostic: String, code: Int)
}

private struct MpvParsedTrack {
  let id: Int
  let type: String
  let lang: String?
  let title: String?
  var selected: Bool
  let isDefault: Bool
  let isExternal: Bool
  let channels: Int
}

private struct MpvMetadataSnapshot {
  let videoSize: CGSize?
  let nominalFps: Double?
  let videoCodecName: String?
}

/// Native iOS `libmpv` playback engine driving `UzvIosMpvBridge` on a `MpvMetalView`.
///
/// All `libmpv` C calls execute off the UI thread on a dedicated serial `mpvQueue` (plus the blocking `wait_event`
/// thread), eliminating main-thread <-> MoltenVK `CAMetalLayer` swapchain deadlocks during rotation and stalls.
final class IosMpvEngine {
  static var isAvailable: Bool {
    uzv_ios_mpv_is_available()
  }

  static var probeDetail: String {
    String(cString: uzv_ios_mpv_probe_detail())
  }

  weak var delegate: IosMpvEngineDelegate?
  private weak var metalView: MpvMetalView?
  /// Retained across async `mpv_terminate_destroy` so MoltenVK's `wid` (`CAMetalLayer*`) never dangles on close.
  private var metalLayerRef: CAMetalLayer?
  private let metalLayerWid: Int64

  private let mpvQueue = DispatchQueue(label: "app.novaplay.mpv.cmd", qos: .userInitiated)
  /// Accessed exclusively on `mpvQueue` (except `uzv_ios_mpv_wakeup` under `lock` during `destroy()`).
  private var workerInst: OpaquePointer?
  private var wakeupInst: OpaquePointer?
  private let lock = NSLock()
  private var isRunningEvents = false
  private var isDestroyed = false
  private var statsInFlight = false
  private var sharedLoadSerial: UInt64 = 0
  private let eventExitGroup = DispatchGroup()

  private var pendingLoadClosure: (() -> Void)?
  private var awaitingStartFile = false
  private var fileLoaded = false
  private var loadingFile = false
  private var reachedEof = false
  private var userPaused = false
  private var pausedForCache = false
  private var isSeeking = false
  private var lastPublishedState = "idle"

  // Worker-queue-only HTTP header override tracking
  private var defaultUserAgent: String = "Mozilla/5.0"
  private var userAgentOverridden = false
  private var referrerOverridden = false
  private var workerFileLoaded = false

  private var subtitlesDisabledByUser = false
  private var preferredAudioLang: String?
  private var preferredSubtitleLang: String?
  private var preferredSubtitleFont: String?
  private var cachedSubtitleParsedTracks: [MpvParsedTrack] = []
  private var cachedAudioParsedTracks: [MpvParsedTrack] = []

  private(set) var positionMs: Int64 = 0
  private(set) var durationMs: Int64 = 0
  private(set) var videoSize: CGSize = .zero
  private(set) var nominalFps: Double?
  private(set) var videoCodecName: String?
  private(set) var downloadBytesPerSec: Double = 0
  private(set) var videoBitrateBps: Double = 0
  private var statsTimer: Timer?

  var hwDecode: Bool = true {
    didSet {
      guard oldValue != hwDecode else { return }
      let hw = hwDecode
      mpvQueue.async { [weak self] in
        guard let self = self, let inst = self.workerInst else { return }
        _ = uzv_ios_mpv_set_property_string_async(inst, 0, "hwdec", hw ? "videotoolbox-copy" : "no")
      }
    }
  }

  var fitMode: String = "fit" {
    didSet {
      guard oldValue != fitMode else { return }
      let mode = fitMode
      mpvQueue.async { [weak self] in
        guard let self = self, let inst = self.workerInst else { return }
        self.applyFitModeOnQueue(inst: inst, mode: mode)
      }
    }
  }

  var speed: Float = 1.0 {
    didSet {
      guard speed > 0, abs(oldValue - speed) > 0.0005 else { return }
      let sp = Double(speed)
      mpvQueue.async { [weak self] in
        guard let self = self, let inst = self.workerInst else { return }
        _ = uzv_ios_mpv_set_property_double_async(inst, 0, "speed", sp)
      }
    }
  }

  var isPlaying: Bool {
    computeState() == "playing"
  }

  private static let obsTimePos: UInt64 = 1
  private static let obsDuration: UInt64 = 2
  private static let obsPause: UInt64 = 3
  private static let obsCacheStall: UInt64 = 4
  private static let obsVideoW: UInt64 = 5
  private static let obsVideoH: UInt64 = 6
  private static let obsVideoRotate: UInt64 = 7
  private static let obsTrackCount: UInt64 = 8
  private static let obsAid: UInt64 = 9
  private static let obsSid: UInt64 = 10
  private var bgObserver: NSObjectProtocol?

  init(metalView: MpvMetalView, hwDecode: Bool, fitMode: String, speed: Float) {
    metalView.ensureDeviceAttached()
    self.metalView = metalView
    let layer = metalView.metalLayer
    self.metalLayerRef = layer
    let layerPtr = Unmanaged.passUnretained(layer).toOpaque()
    self.metalLayerWid = Int64(Int(bitPattern: layerPtr))
    self.hwDecode = hwDecode
    self.fitMode = fitMode
    self.speed = speed
    self.bgObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // MPV does not support iOS PiP and must never play or submit Metal frames in background
      self?.pause()
    }
  }

  deinit {
    if let obs = bgObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  private func bumpLoadSerial() -> UInt64 {
    lock.lock()
    sharedLoadSerial &+= 1
    let s = sharedLoadSerial
    lock.unlock()
    return s
  }

  private func currentLoadSerial() -> UInt64 {
    lock.lock()
    let s = sharedLoadSerial
    lock.unlock()
    return s
  }

  private func isCurrentlyDestroyed() -> Bool {
    lock.lock()
    let d = isDestroyed
    lock.unlock()
    return d
  }

  private func createInitializedHandleOnQueue(wid: Int64, hw: Bool, vo: String) -> (OpaquePointer?, String?) {
    guard let inst = uzv_ios_mpv_create() else {
      return (nil, "libmpv unavailable (\(Self.probeDetail))")
    }

    _ = uzv_ios_mpv_set_option_int64(inst, "wid", wid)
    _ = uzv_ios_mpv_set_option_string(inst, "vo", vo)
    _ = uzv_ios_mpv_set_option_string(inst, "gpu-api", "vulkan")
    _ = uzv_ios_mpv_set_option_string(inst, "gpu-context", "moltenvk")
    _ = uzv_ios_mpv_set_option_string(inst, "hwdec", hw ? "videotoolbox-copy" : "no")
    _ = uzv_ios_mpv_set_option_string(inst, "hwdec-codecs", "all")
    _ = uzv_ios_mpv_set_option_string(inst, "vd-lavc-threads", "0")
    _ = uzv_ios_mpv_set_option_string(inst, "idle", "yes")
    _ = uzv_ios_mpv_set_option_string(inst, "keep-open", "no")
    _ = uzv_ios_mpv_set_option_string(inst, "osd-level", "0")
    _ = uzv_ios_mpv_set_option_string(inst, "sub-auto", "no")
    _ = uzv_ios_mpv_set_option_string(inst, "subs-fallback", "yes")
    _ = uzv_ios_mpv_set_option_string(inst, "sub-codepage", "auto")
    _ = uzv_ios_mpv_set_option_string(inst, "audio-file-auto", "no")
    _ = uzv_ios_mpv_set_option_string(inst, "ytdl", "no")
    _ = uzv_ios_mpv_set_option_string(inst, "terminal", "no")
    _ = uzv_ios_mpv_set_option_string(inst, "tls-verify", "no")
    _ = uzv_ios_mpv_set_option_string(inst, "network-timeout", "15")
    _ = uzv_ios_mpv_set_option_string(inst, "demuxer-lavf-analyzeduration", "1")
    _ = uzv_ios_mpv_set_option_string(inst, "demuxer-lavf-probesize", "1572864")
    _ = uzv_ios_mpv_set_option_string(inst, "demuxer-lavf-o", "allowed_extensions=ALL")
    _ = uzv_ios_mpv_set_option_string(inst, "stream-lavf-o", "reconnect=1,reconnect_delay_max=4")
    _ = uzv_ios_mpv_set_option_string(inst, "cache", "yes")
    _ = uzv_ios_mpv_set_option_string(inst, "cache-pause", "yes")
    _ = uzv_ios_mpv_set_option_string(inst, "cache-pause-initial", "no")
    _ = uzv_ios_mpv_set_option_string(inst, "cache-pause-wait", "0.3")
    _ = uzv_ios_mpv_set_option_string(inst, "demuxer-max-bytes", "64MiB")
    _ = uzv_ios_mpv_set_option_string(inst, "demuxer-max-back-bytes", "32MiB")

    let initRc = uzv_ios_mpv_initialize(inst)
    if initRc < 0 {
      let errStr = String(cString: uzv_ios_mpv_error_string(initRc))
      let logs = copyStringAndFree(uzv_ios_mpv_copy_recent_logs(inst)) ?? ""
      uzv_ios_mpv_destroy(inst)
      let msg = "mpv_initialize(\(vo)) failed (\(errStr)) \(logs)".trimmingCharacters(in: .whitespacesAndNewlines)
      return (nil, msg)
    }
    return (inst, nil)
  }

  private func ensureInitializedOnQueue(
    hw: Bool,
    fit: String,
    sp: Double,
    aLang: String?,
    sLang: String?,
    sFont: String?
  ) -> String? {
    if workerInst != nil { return nil }
    if isCurrentlyDestroyed() { return "MPV engine destroyed" }
    guard metalLayerRef != nil, metalLayerWid != 0 else {
      return "MPV rendering view missing"
    }

    var activeVo = "gpu-next"
    var (maybeInst, firstErr) = createInitializedHandleOnQueue(wid: metalLayerWid, hw: hw, vo: activeVo)
    if maybeInst == nil {
      activeVo = "gpu"
      let (fallbackInst, fallbackErr) = createInitializedHandleOnQueue(wid: metalLayerWid, hw: hw, vo: activeVo)
      maybeInst = fallbackInst
      if maybeInst == nil {
        return fallbackErr ?? firstErr ?? "mpv_initialize failed"
      }
    }
    guard let inst = maybeInst else {
      return firstErr ?? "mpv_initialize failed"
    }

    if isCurrentlyDestroyed() {
      uzv_ios_mpv_destroy(inst)
      return "MPV engine destroyed"
    }

    workerInst = inst
    lock.lock()
    wakeupInst = inst
    isRunningEvents = true
    lock.unlock()

    if let ua = getString(inst, "user-agent"), !ua.isEmpty {
      defaultUserAgent = ua
    }
    applyFitModeOnQueue(inst: inst, mode: fit)
    if sp > 0 {
      _ = uzv_ios_mpv_set_property_double_async(inst, 0, "speed", sp)
    }
    if let aLang = aLang {
      _ = uzv_ios_mpv_set_property_string_async(inst, 0, "alang", aLang)
    }
    if let sLang = sLang {
      _ = uzv_ios_mpv_set_property_string_async(inst, 0, "slang", sLang)
    }
    if let sFont = sFont, !sFont.isEmpty {
      _ = uzv_ios_mpv_set_property_string_async(inst, 0, "sub-font", sFont)
    }

    _ = uzv_ios_mpv_observe_property(inst, Self.obsTimePos, "time-pos", 5)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsDuration, "duration", 5)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsPause, "pause", 3)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsCacheStall, "paused-for-cache", 3)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsVideoW, "video-params/w", 4)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsVideoH, "video-params/h", 4)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsVideoRotate, "video-params/rotate", 4)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsTrackCount, "track-list/count", 4)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsAid, "aid", 0)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsSid, "sid", 0)

    eventExitGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.runEventLoop(inst: inst)
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.isCurrentlyDestroyed() else { return }
      self.metalView?.syncDrawableSizeIfNeeded(forceNotify: true)
      self.startStatsTimer()
    }
    mpvUsbLog.notice("[NovaPlay][MPV] initialized vo=\(activeVo, privacy: .public) hwdec=\(hw, privacy: .public)")
    return nil
  }

  func load(
    url: String,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    subtitles: [SubtitleOption]
  ) {
    let serial = bumpLoadSerial()
    let executeLoad = { [weak self] in
      guard let self = self, self.currentLoadSerial() == serial else { return }
      self.scheduleLoadOnWorker(
        serial: serial,
        url: url,
        audioUrl: audioUrl,
        headers: headers,
        startMs: startMs,
        subtitles: subtitles
      )
    }

    if let view = metalView, view.bounds.width > 1 && view.bounds.height > 1 {
      executeLoad()
    } else {
      pendingLoadClosure = executeLoad
      metalView?.onLayoutReady = { [weak self] in
        guard let self = self, let job = self.pendingLoadClosure else { return }
        self.pendingLoadClosure = nil
        job()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
        guard let self = self, self.currentLoadSerial() == serial, let job = self.pendingLoadClosure else { return }
        self.pendingLoadClosure = nil
        self.metalView?.onLayoutReady = nil
        job()
      }
    }
  }

  private func scheduleLoadOnWorker(
    serial: UInt64,
    url: String,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    subtitles: [SubtitleOption]
  ) {
    let inBackground = UIApplication.shared.applicationState == .background
    awaitingStartFile = true
    fileLoaded = false
    loadingFile = true
    reachedEof = false
    userPaused = inBackground
    pausedForCache = false
    isSeeking = false
    positionMs = max(0, startMs)
    durationMs = 0
    videoSize = .zero
    nominalFps = nil
    videoCodecName = nil
    downloadBytesPerSec = 0
    videoBitrateBps = 0
    cachedAudioParsedTracks = []
    cachedSubtitleParsedTracks = []
    publishStateIfNeeded()

    let hw = hwDecode
    let fit = fitMode
    let sp = Double(speed)
    let subsDisabled = subtitlesDisabledByUser
    let aLang = preferredAudioLang
    let sLang = preferredSubtitleLang
    let sFont = preferredSubtitleFont

    mpvQueue.async { [weak self] in
      guard let self = self, self.currentLoadSerial() == serial, !self.isCurrentlyDestroyed() else { return }
      self.performLoadOnQueue(
        serial: serial,
        url: url,
        audioUrl: audioUrl,
        headers: headers,
        startMs: startMs,
        subtitles: subtitles,
        inBackground: inBackground,
        hw: hw,
        fit: fit,
        sp: sp,
        subsDisabled: subsDisabled,
        aLang: aLang,
        sLang: sLang,
        sFont: sFont
      )
    }
  }

  private func performLoadOnQueue(
    serial: UInt64,
    url: String,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    subtitles: [SubtitleOption],
    inBackground: Bool,
    hw: Bool,
    fit: String,
    sp: Double,
    subsDisabled: Bool,
    aLang: String?,
    sLang: String?,
    sFont: String?
  ) {
    if let initErr = ensureInitializedOnQueue(hw: hw, fit: fit, sp: sp, aLang: aLang, sLang: sLang, sFont: sFont) {
      mpvUsbLog.error("[NovaPlay][MPV] init error: \(initErr, privacy: .public)")
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.currentLoadSerial() == serial else { return }
        self.loadingFile = false
        self.awaitingStartFile = false
        self.delegate?.mpvEngineDidFail(
          message: "MPV " + IosPlayerUiText.t("初始化失败", "init failed"),
          diagnostic: initErr,
          code: -3
        )
      }
      return
    }
    guard let inst = workerInst, currentLoadSerial() == serial else { return }

    workerFileLoaded = false
    pendingWorkerSidecars = subtitles
    pendingWorkerExternalAudioUrl = nil

    var headerLines: [String] = []
    var reqUA: String?
    var reqRef: String?
    for (rawName, rawVal) in headers {
      let cleanName = rawName
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\n", with: "")
        .replacingOccurrences(of: ":", with: "")
        .trimmingCharacters(in: .whitespaces)
      let cleanVal = rawVal
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespaces)
      guard !cleanName.isEmpty else { continue }
      switch cleanName.lowercased() {
      case "user-agent":
        reqUA = cleanVal
      case "referer", "referrer":
        reqRef = cleanVal
      default:
        headerLines.append("\(cleanName): \(cleanVal)")
      }
    }

    _ = setListOptionOnQueue(inst, name: "http-header-fields", values: headerLines)
    if let ua = reqUA, !ua.isEmpty {
      _ = uzv_ios_mpv_set_property_string(inst, "user-agent", ua)
      userAgentOverridden = true
    } else if userAgentOverridden {
      _ = uzv_ios_mpv_set_property_string(inst, "user-agent", defaultUserAgent)
      userAgentOverridden = false
    }

    if let rf = reqRef, !rf.isEmpty {
      _ = uzv_ios_mpv_set_property_string(inst, "referrer", rf)
      referrerOverridden = true
    } else if referrerOverridden {
      _ = uzv_ios_mpv_set_property_string(inst, "referrer", "")
      referrerOverridden = false
    }

    let cleanAudio = (audioUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !cleanAudio.isEmpty {
      let rc = setListOptionOnQueue(inst, name: "audio-files", values: [cleanAudio])
      if rc < 0 {
        pendingWorkerExternalAudioUrl = cleanAudio
      }
    } else {
      _ = setListOptionOnQueue(inst, name: "audio-files", values: [])
    }

    _ = uzv_ios_mpv_set_property_string(inst, "hwdec", hw ? "videotoolbox-copy" : "no")
    _ = uzv_ios_mpv_set_property_string(inst, "sid", subsDisabled ? "no" : "auto")
    _ = uzv_ios_mpv_set_property_string(inst, "aid", "auto")
    _ = uzv_ios_mpv_set_property_flag(inst, "pause", inBackground)
    if sp > 0 {
      _ = uzv_ios_mpv_set_property_double(inst, "speed", sp)
    }
    applyFitModeOnQueue(inst: inst, mode: fit)

    let startOpt = String(format: "start=%.3f", Double(max(0, startMs)) / 1000.0)
    var loadRc = uzv_ios_mpv_command_async5(inst, 0, "loadfile", url, "replace", "-1", startOpt)
    if loadRc == -4 {
      loadRc = uzv_ios_mpv_command4(inst, "loadfile", url, "replace", startOpt)
    }
    if loadRc < 0 {
      let errStr = String(cString: uzv_ios_mpv_error_string(Int32(loadRc)))
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.currentLoadSerial() == serial else { return }
        self.loadingFile = false
        self.awaitingStartFile = false
        self.delegate?.mpvEngineDidFail(
          message: "MPV " + IosPlayerUiText.t("加载失败", "load failed") + " (\(errStr))",
          diagnostic: "mpv loadfile rc=\(loadRc): \(errStr)",
          code: Int(loadRc)
        )
      }
    }
  }

  private var pendingWorkerSidecars: [SubtitleOption] = []
  private var pendingWorkerExternalAudioUrl: String?

  private func setListOptionOnQueue(_ inst: OpaquePointer, name: String, values: [String]) -> Int32 {
    var rc = uzv_ios_mpv_command4(inst, "change-list", name, "clr", "")
    for item in values {
      let r = uzv_ios_mpv_command4(inst, "change-list", name, "append", item)
      if rc >= 0 && r < 0 { rc = r }
    }
    return rc
  }

  private func applyFitModeOnQueue(inst: OpaquePointer, mode: String) {
    let keepAspect: Bool
    let panscan: Double
    switch mode {
    case "fill":
      keepAspect = false
      panscan = 0.0
    case "zoom":
      keepAspect = true
      panscan = 1.0
    default:
      keepAspect = true
      panscan = 0.0
    }
    _ = uzv_ios_mpv_set_property_flag_async(inst, 0, "keepaspect", keepAspect)
    _ = uzv_ios_mpv_set_property_double_async(inst, 0, "panscan", panscan)
  }

  func play() {
    if UIApplication.shared.applicationState == .background {
      pause()
      return
    }
    userPaused = false
    let sp = Double(speed)
    publishStateIfNeeded()
    mpvQueue.async { [weak self] in
      guard let self = self, let inst = self.workerInst else { return }
      _ = uzv_ios_mpv_set_property_flag_async(inst, 0, "pause", false)
      if sp > 0 {
        _ = uzv_ios_mpv_set_property_double_async(inst, 0, "speed", sp)
      }
    }
  }

  func pause() {
    userPaused = true
    publishStateIfNeeded()
    mpvQueue.async { [weak self] in
      guard let self = self, let inst = self.workerInst else { return }
      _ = uzv_ios_mpv_set_property_flag_async(inst, 0, "pause", true)
    }
  }

  func seekTo(_ ms: Int64) {
    let clamped = durationMs > 0 ? min(max(0, ms), durationMs) : max(0, ms)
    positionMs = clamped
    isSeeking = true
    let secStr = String(format: "%.3f", Double(clamped) / 1000.0)
    publishStateIfNeeded()
    mpvQueue.async { [weak self] in
      guard let self = self, let inst = self.workerInst else { return }
      _ = uzv_ios_mpv_command_async3(inst, 0, "seek", secStr, "absolute")
    }
  }

  func addExternalSubtitle(_ sub: SubtitleOption) {
    subtitlesDisabledByUser = false
    let serial = currentLoadSerial()
    mpvQueue.async { [weak self] in
      guard let self = self, self.currentLoadSerial() == serial else { return }
      self.pendingWorkerSidecars.append(sub)
      guard let inst = self.workerInst, self.workerFileLoaded else { return }
      _ = uzv_ios_mpv_command_async5(inst, 0, "sub-add", sub.url, "select", sub.name, sub.language ?? "")
    }
  }

  func applyAudioPreference(lang: String?) {
    let trimmed = lang?.trimmingCharacters(in: .whitespacesAndNewlines)
    preferredAudioLang = trimmed
    mpvQueue.async { [weak self] in
      guard let self = self, let inst = self.workerInst else { return }
      _ = uzv_ios_mpv_set_property_string_async(inst, 0, "alang", trimmed ?? "")
    }
  }

  func applySubtitlePreferences(lang: String?, fontFamily: String?) {
    let trimmedLang = lang?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedFont = fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines)
    preferredSubtitleLang = trimmedLang
    preferredSubtitleFont = trimmedFont
    mpvQueue.async { [weak self] in
      guard let self = self, let inst = self.workerInst else { return }
      _ = uzv_ios_mpv_set_property_string_async(inst, 0, "slang", trimmedLang ?? "")
      if let font = trimmedFont, !font.isEmpty {
        _ = uzv_ios_mpv_set_property_string_async(inst, 0, "sub-font", font)
      }
    }
  }

  // MARK: - Tracks (Cached on Main Thread; Queried on `mpvQueue`)

  private func parseAllTracksOnQueue(inst: OpaquePointer) -> (subs: [MpvParsedTrack], audios: [MpvParsedTrack]) {
    let count = Int(uzv_ios_mpv_get_property_int64(inst, "track-list/count", 0))
    guard count > 0 else { return ([], []) }
    var subs: [MpvParsedTrack] = []
    var audios: [MpvParsedTrack] = []
    for i in 0..<count {
      let prefix = "track-list/\(i)/"
      guard let type = getString(inst, prefix + "type"), type == "sub" || type == "audio" else { continue }
      let id = Int(uzv_ios_mpv_get_property_int64(inst, prefix + "id", -1))
      guard id >= 0 else { continue }
      let lang = getString(inst, prefix + "lang")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let title = getString(inst, prefix + "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let selected = uzv_ios_mpv_get_property_flag(inst, prefix + "selected", false)
      let isDef = uzv_ios_mpv_get_property_flag(inst, prefix + "default", false)
      let isExt = uzv_ios_mpv_get_property_flag(inst, prefix + "external", false)
      let ch = type == "audio" ? Int(uzv_ios_mpv_get_property_int64(inst, prefix + "demux-channel-count", 0)) : 0
      let track = MpvParsedTrack(
        id: id,
        type: type,
        lang: (lang?.isEmpty == false) ? lang : nil,
        title: (title?.isEmpty == false) ? title : nil,
        selected: selected,
        isDefault: isDef,
        isExternal: isExt,
        channels: ch
      )
      if type == "sub" {
        subs.append(track)
      } else {
        audios.append(track)
      }
    }
    return (subs, audios)
  }

  var subtitlesEnabled: Bool {
    !subtitlesDisabledByUser && cachedSubtitleParsedTracks.contains(where: { $0.selected })
  }

  func subtitleTracks() -> [IosTrackOption] {
    cachedSubtitleParsedTracks.enumerated().map { idx, t in
      var parts: [String] = []
      if let title = t.title { parts.append(title) }
      if let lang = t.lang, !parts.contains(lang) { parts.append(lang) }
      if parts.isEmpty { parts.append("字幕 \(idx + 1)") }
      if t.isExternal { parts.append("外挂") }
      return IosTrackOption(
        index: idx,
        label: parts.joined(separator: " · "),
        language: t.lang,
        selected: !subtitlesDisabledByUser && t.selected
      )
    }
  }

  func selectSubtitle(_ index: Int) {
    if index < 0 {
      subtitlesDisabledByUser = true
      for i in cachedSubtitleParsedTracks.indices {
        cachedSubtitleParsedTracks[i].selected = false
      }
      mpvQueue.async { [weak self] in
        guard let self = self, let inst = self.workerInst else { return }
        _ = uzv_ios_mpv_set_property_string_async(inst, 0, "sid", "no")
      }
      return
    }
    guard index < cachedSubtitleParsedTracks.count else { return }
    subtitlesDisabledByUser = false
    let targetId = Int64(cachedSubtitleParsedTracks[index].id)
    for i in cachedSubtitleParsedTracks.indices {
      cachedSubtitleParsedTracks[i].selected = (i == index)
    }
    mpvQueue.async { [weak self] in
      guard let self = self, let inst = self.workerInst else { return }
      _ = uzv_ios_mpv_set_property_int64_async(inst, 0, "sid", targetId)
    }
  }

  func audioTracks() -> [IosTrackOption] {
    cachedAudioParsedTracks.enumerated().map { idx, t in
      var parts: [String] = []
      if let title = t.title { parts.append(title) }
      if let lang = t.lang, !parts.contains(lang) { parts.append(lang) }
      if t.channels > 0 { parts.append("\(t.channels)ch") }
      if parts.isEmpty { parts.append("音轨 \(idx + 1)") }
      return IosTrackOption(
        index: idx,
        label: parts.joined(separator: " · "),
        language: t.lang,
        selected: t.selected
      )
    }
  }

  func selectAudio(_ index: Int) {
    if index < 0 {
      mpvQueue.async { [weak self] in
        guard let self = self, let inst = self.workerInst else { return }
        _ = uzv_ios_mpv_set_property_string_async(inst, 0, "aid", "auto")
      }
      return
    }
    guard index < cachedAudioParsedTracks.count else { return }
    let targetId = Int64(cachedAudioParsedTracks[index].id)
    for i in cachedAudioParsedTracks.indices {
      cachedAudioParsedTracks[i].selected = (i == index)
    }
    mpvQueue.async { [weak self] in
      guard let self = self, let inst = self.workerInst else { return }
      _ = uzv_ios_mpv_set_property_int64_async(inst, 0, "aid", targetId)
    }
  }

  // MARK: - Async Screenshot

  func captureVideoFrame(completion: @escaping (UIImage?) -> Void) {
    guard fileLoaded else {
      completion(nil)
      return
    }
    mpvQueue.async { [weak self] in
      guard let self = self, let inst = self.workerInst, self.workerFileLoaded else {
        DispatchQueue.main.async { completion(nil) }
        return
      }
      let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("novaplay-mpv-shot-\(UUID().uuidString).jpg")
      defer { try? FileManager.default.removeItem(at: tmpURL) }
      let rc = uzv_ios_mpv_command3(inst, "screenshot-to-file", tmpURL.path, "video")
      let img: UIImage?
      if rc >= 0, let data = try? Data(contentsOf: tmpURL) {
        img = UIImage(data: data)
      } else {
        img = nil
      }
      DispatchQueue.main.async {
        completion(img)
      }
    }
  }

  // MARK: - Event Loop & Off-Main-Thread Telemetry

  private func runEventLoop(inst: OpaquePointer) {
    defer { eventExitGroup.leave() }
    while true {
      lock.lock()
      let keepRunning = isRunningEvents
      lock.unlock()
      if !keepRunning { break }

      let ev = uzv_ios_mpv_wait_event(inst, 0.5)
      if ev.event_id == 1 { // MPV_EVENT_SHUTDOWN
        lock.lock()
        isRunningEvents = false
        lock.unlock()
        break
      }
      if ev.event_id == 0 {
        continue
      }

      switch ev.event_id {
      case 6: // START_FILE
        let serial = currentLoadSerial()
        mpvQueue.async { [weak self] in
          guard let self = self, self.currentLoadSerial() == serial else { return }
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial else { return }
            self.awaitingStartFile = false
          }
        }

      case 8: // FILE_LOADED
        let serial = currentLoadSerial()
        mpvQueue.async { [weak self] in
          guard let self = self, self.currentLoadSerial() == serial, let qInst = self.workerInst else { return }
          self.workerFileLoaded = true
          if let extAudio = self.pendingWorkerExternalAudioUrl {
            self.pendingWorkerExternalAudioUrl = nil
            _ = uzv_ios_mpv_command_async3(qInst, 0, "audio-add", extAudio, "select")
          }
          for sub in self.pendingWorkerSidecars {
            _ = uzv_ios_mpv_command_async5(qInst, 0, "sub-add", sub.url, "auto", sub.name, sub.language ?? "")
          }
          let cachePaused = uzv_ios_mpv_get_property_flag(qInst, "paused-for-cache", false)
          let mpvPaused = uzv_ios_mpv_get_property_flag(qInst, "pause", false)
          let meta = self.readVideoMetadataOnQueue(inst: qInst)
          let tracks = self.parseAllTracksOnQueue(inst: qInst)
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial else { return }
            self.fileLoaded = true
            self.loadingFile = false
            self.isSeeking = false
            self.pausedForCache = cachePaused
            self.cachedSubtitleParsedTracks = tracks.subs
            self.cachedAudioParsedTracks = tracks.audios
            self.applyMetadataSnapshotOnMain(meta)
            self.metalView?.syncDrawableSizeIfNeeded(forceNotify: true)
            if UIApplication.shared.applicationState == .background {
              self.pause()
            } else {
              self.userPaused = mpvPaused
            }
            mpvUsbLog.notice("[NovaPlay][MPV] FILE_LOADED codec=\(self.videoCodecName ?? "unknown", privacy: .public) size=\(Int(self.videoSize.width), privacy: .public)x\(Int(self.videoSize.height), privacy: .public)")
            self.publishStateIfNeeded()
            self.delegate?.mpvEngineDidUpdateMetrics()
          }
        }

      case 7: // END_FILE
        let serial = currentLoadSerial()
        let endReason = ev.end_reason
        let endError = ev.end_error
        var errDiag: (short: String, full: String)?
        if endReason == 4 {
          let errStr = String(cString: uzv_ios_mpv_error_string(endError))
          let logs = (copyStringAndFree(uzv_ios_mpv_copy_recent_logs(inst)) ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(3)
            .joined(separator: " | ")
          let shortMsg = "MPV " + IosPlayerUiText.t("播放失败", "playback failed") + " (\(errStr))"
          let fullDiag = logs.isEmpty ? shortMsg : "\(shortMsg)\n\(logs)"
          errDiag = (shortMsg, fullDiag)
        }
        mpvQueue.async { [weak self] in
          guard let self = self, self.currentLoadSerial() == serial else { return }
          self.workerFileLoaded = false
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial, !self.awaitingStartFile else { return }
            self.fileLoaded = false
            self.isSeeking = false
            if endReason == 0 { // EOF
              self.reachedEof = true
              self.loadingFile = false
              self.publishStateIfNeeded()
            } else if endReason == 2 || endReason == 3 { // STOP / QUIT
              self.loadingFile = false
              self.pausedForCache = false
              self.publishStateIfNeeded()
            } else if endReason == 4, let diag = errDiag { // ERROR
              self.loadingFile = false
              self.pausedForCache = false
              mpvUsbLog.error("[NovaPlay][MPV] END_FILE error: \(diag.full, privacy: .public)")
              self.delegate?.mpvEngineDidFail(message: diag.short, diagnostic: diag.full, code: Int(endError))
            }
          }
        }

      case 17, 18: // VIDEO_RECONFIG / AUDIO_RECONFIG
        let serial = currentLoadSerial()
        mpvQueue.async { [weak self] in
          guard let self = self, self.currentLoadSerial() == serial, let qInst = self.workerInst else { return }
          let meta = self.readVideoMetadataOnQueue(inst: qInst)
          let tracks = self.parseAllTracksOnQueue(inst: qInst)
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial else { return }
            self.cachedSubtitleParsedTracks = tracks.subs
            self.cachedAudioParsedTracks = tracks.audios
            self.applyMetadataSnapshotOnMain(meta)
            self.delegate?.mpvEngineDidUpdateMetrics()
          }
        }

      case 20: // SEEK
        let serial = currentLoadSerial()
        mpvQueue.async { [weak self] in
          guard let self = self, self.currentLoadSerial() == serial else { return }
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial else { return }
            self.isSeeking = true
            self.publishStateIfNeeded()
          }
        }

      case 21: // PLAYBACK_RESTART
        let serial = currentLoadSerial()
        mpvQueue.async { [weak self] in
          guard let self = self, self.currentLoadSerial() == serial, let qInst = self.workerInst else { return }
          let cachePaused = uzv_ios_mpv_get_property_flag(qInst, "paused-for-cache", false)
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial else { return }
            self.isSeeking = false
            self.pausedForCache = cachePaused
            self.publishStateIfNeeded()
          }
        }

      case 22: // PROPERTY_CHANGE
        let serial = currentLoadSerial()
        switch ev.reply_userdata {
        case Self.obsTimePos:
          guard ev.prop_format == 5, ev.prop_double >= 0 else { break }
          let nextPos = Int64((ev.prop_double * 1000.0).rounded())
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial else { return }
            if self.isSeeking && nextPos != self.positionMs {
              self.isSeeking = false
              self.publishStateIfNeeded()
            }
            self.positionMs = nextPos
            self.delegate?.mpvEngineDidUpdateMetrics()
          }
        case Self.obsDuration:
          guard ev.prop_format == 5, ev.prop_double > 0 else { break }
          let nextDur = Int64((ev.prop_double * 1000.0).rounded())
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial else { return }
            self.durationMs = nextDur
            self.delegate?.mpvEngineDidUpdateMetrics()
          }
        case Self.obsPause:
          guard ev.prop_format == 3 else { break }
          let pausedVal = ev.prop_flag
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial else { return }
            self.userPaused = pausedVal
            self.publishStateIfNeeded()
          }
        case Self.obsCacheStall:
          guard ev.prop_format == 3 else { break }
          let cacheVal = ev.prop_flag
          DispatchQueue.main.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial else { return }
            self.pausedForCache = cacheVal
            self.publishStateIfNeeded()
          }
        case Self.obsVideoW, Self.obsVideoH, Self.obsVideoRotate:
          mpvQueue.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial, let qInst = self.workerInst else { return }
            let meta = self.readVideoMetadataOnQueue(inst: qInst)
            DispatchQueue.main.async { [weak self] in
              guard let self = self, self.currentLoadSerial() == serial else { return }
              self.applyMetadataSnapshotOnMain(meta)
              self.delegate?.mpvEngineDidUpdateMetrics()
            }
          }
        case Self.obsTrackCount, Self.obsAid, Self.obsSid:
          mpvQueue.async { [weak self] in
            guard let self = self, self.currentLoadSerial() == serial, let qInst = self.workerInst else { return }
            let tracks = self.parseAllTracksOnQueue(inst: qInst)
            DispatchQueue.main.async { [weak self] in
              guard let self = self, self.currentLoadSerial() == serial else { return }
              self.cachedSubtitleParsedTracks = tracks.subs
              self.cachedAudioParsedTracks = tracks.audios
              self.delegate?.mpvEngineDidUpdateMetrics()
            }
          }
        default:
          break
        }

      default:
        break
      }
    }
  }

  private func rotatedMpvDimsOnQueue(_ inst: OpaquePointer, _ wProp: String, _ hProp: String, _ rotProps: [String]) -> (Int64, Int64)? {
    var w = uzv_ios_mpv_get_property_int64(inst, wProp, 0)
    var h = uzv_ios_mpv_get_property_int64(inst, hProp, 0)
    guard w > 0 && h > 0 else { return nil }
    for prop in rotProps {
      let rot = uzv_ios_mpv_get_property_int64(inst, prop, Int64.min)
      if rot != Int64.min {
        if rot % 180 != 0 { swap(&w, &h) }
        break
      }
    }
    return (w, h)
  }

  private func readVideoMetadataOnQueue(inst: OpaquePointer) -> MpvMetadataSnapshot {
    let dims = rotatedMpvDimsOnQueue(inst, "video-out-params/dw", "video-out-params/dh", ["video-out-params/rotate"])
      ?? rotatedMpvDimsOnQueue(inst, "video-params/dw", "video-params/dh", ["video-params/rotate"])
      ?? rotatedMpvDimsOnQueue(inst, "video-params/w", "video-params/h", ["video-params/rotate", "current-tracks/video/demux-rotation", "track-list/0/demux-rotation"])
      ?? rotatedMpvDimsOnQueue(inst, "current-tracks/video/demux-w", "current-tracks/video/demux-h", ["current-tracks/video/demux-rotation", "track-list/0/demux-rotation"])
    let sz = dims.map { CGSize(width: CGFloat($0.0), height: CGFloat($0.1)) }

    let fpsEst = uzv_ios_mpv_get_property_double(inst, "estimated-vf-fps", 0)
    let fpsCont = uzv_ios_mpv_get_property_double(inst, "container-fps", 0)
    let bestFps = fpsEst > 0 ? fpsEst : fpsCont
    let fps: Double? = bestFps > 0 ? bestFps : nil

    var codec: String?
    if let fmt = getString(inst, "video-format")?.uppercased(), !fmt.isEmpty {
      switch fmt {
      case "HEVC", "H265": codec = "HEVC"
      case "H264", "AVC1": codec = "H.264"
      default: codec = fmt
      }
    }
    return MpvMetadataSnapshot(videoSize: sz, nominalFps: fps, videoCodecName: codec)
  }

  private func applyMetadataSnapshotOnMain(_ snap: MpvMetadataSnapshot) {
    if let sz = snap.videoSize, sz.width > 0 && sz.height > 0 {
      videoSize = sz
    }
    if let fps = snap.nominalFps, fps > 0 {
      nominalFps = fps
    }
    if let codec = snap.videoCodecName, !codec.isEmpty {
      videoCodecName = codec
    }
  }

  private func startStatsTimer() {
    statsTimer?.invalidate()
    let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
      self?.sampleStats()
    }
    RunLoop.main.add(t, forMode: .common)
    statsTimer = t
  }

  private func sampleStats() {
    guard fileLoaded || loadingFile else { return }
    let needMeta = fileLoaded && (nominalFps == nil || videoSize == .zero)
    let loadedNow = fileLoaded
    let serial = currentLoadSerial()

    lock.lock()
    if statsInFlight || isDestroyed {
      lock.unlock()
      return
    }
    statsInFlight = true
    lock.unlock()

    mpvQueue.async { [weak self] in
      guard let self = self else { return }
      defer {
        self.lock.lock()
        self.statsInFlight = false
        self.lock.unlock()
      }
      guard self.currentLoadSerial() == serial, let inst = self.workerInst else { return }
      let cacheSpeed = max(0, uzv_ios_mpv_get_property_double(inst, "cache-speed", 0))
      let vBitrate = loadedNow ? max(0, uzv_ios_mpv_get_property_double(inst, "video-bitrate", 0)) : 0
      let meta = needMeta ? self.readVideoMetadataOnQueue(inst: inst) : nil
      DispatchQueue.main.async { [weak self] in
        guard let self = self, self.currentLoadSerial() == serial, (self.fileLoaded || self.loadingFile) else { return }
        self.downloadBytesPerSec = cacheSpeed
        if loadedNow {
          self.videoBitrateBps = vBitrate
          if let meta = meta {
            self.applyMetadataSnapshotOnMain(meta)
          }
        }
        self.delegate?.mpvEngineDidUpdateMetrics()
      }
    }
  }

  private func computeState() -> String {
    if reachedEof { return "ended" }
    if !fileLoaded { return loadingFile ? "buffering" : "idle" }
    if pausedForCache || isSeeking { return "buffering" }
    if userPaused { return "paused" }
    return "playing"
  }

  private func publishStateIfNeeded() {
    let next = computeState()
    guard next != lastPublishedState else { return }
    lastPublishedState = next
    delegate?.mpvEngineDidChangeState(next)
  }

  func stopPlayback() {
    _ = bumpLoadSerial()
    pendingLoadClosure = nil
    metalView?.onLayoutReady = nil
    awaitingStartFile = false
    fileLoaded = false
    loadingFile = false
    reachedEof = false
    isSeeking = false
    pausedForCache = false
    cachedSubtitleParsedTracks = []
    cachedAudioParsedTracks = []
    lastPublishedState = "idle"
    mpvQueue.async { [weak self] in
      guard let self = self else { return }
      self.workerFileLoaded = false
      self.pendingWorkerSidecars = []
      self.pendingWorkerExternalAudioUrl = nil
      if let inst = self.workerInst {
        _ = uzv_ios_mpv_command_async2(inst, 0, "stop", nil)
      }
    }
  }

  func destroy() {
    if let obs = bgObserver {
      NotificationCenter.default.removeObserver(obs)
      bgObserver = nil
    }
    statsTimer?.invalidate()
    statsTimer = nil
    pendingLoadClosure = nil
    metalView?.onLayoutReady = nil
    _ = bumpLoadSerial()

    lock.lock()
    if isDestroyed {
      lock.unlock()
      return
    }
    isDestroyed = true
    isRunningEvents = false
    let wakeTarget = wakeupInst
    wakeupInst = nil
    lock.unlock()

    if let wakeTarget = wakeTarget {
      uzv_ios_mpv_wakeup(wakeTarget)
    }

    let retainedLayer = metalLayerRef
    metalLayerRef = nil
    let exitGroup = eventExitGroup
    mpvQueue.async {
      let inst = self.workerInst
      self.workerInst = nil
      self.workerFileLoaded = false
      _ = exitGroup.wait(timeout: .now() + 2.0)
      if let inst = inst {
        uzv_ios_mpv_destroy(inst)
      }
      withExtendedLifetime(retainedLayer) {}
    }
  }

  private func getString(_ inst: OpaquePointer, _ name: String) -> String? {
    copyStringAndFree(uzv_ios_mpv_get_property_string_copy(inst, name))
  }

  private func copyStringAndFree(_ raw: UnsafeMutablePointer<CChar>?) -> String? {
    guard let ptr = raw else { return nil }
    defer { uzv_ios_mpv_free_cstr(ptr) }
    return String(cString: ptr)
  }
}
