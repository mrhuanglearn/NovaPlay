import Foundation
import Metal
import OSLog
import QuartzCore
import UIKit

private let mpvUsbLog = Logger(subsystem: "app.novaplay.player", category: "mpv")

/// Metal-backed drawable view (`CAMetalLayer`) used by `libmpv` (`vo=gpu-next`, `gpu-context=moltenvk`).
final class MpvMetalView: UIView {
  override class var layerClass: AnyClass {
    CAMetalLayer.self
  }

  var metalLayer: CAMetalLayer {
    // swiftlint:disable:next force_cast
    layer as! CAMetalLayer
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
    metalLayer.device = MTLCreateSystemDefaultDevice()
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.framebufferOnly = false
    metalLayer.isOpaque = true
    metalLayer.backgroundColor = UIColor.black.cgColor
    metalLayer.contentsScale = scale
    let screenBounds = UIScreen.main.bounds
    metalLayer.drawableSize = CGSize(
      width: max(64, screenBounds.width * scale),
      height: max(64, screenBounds.height * scale)
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let scale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
    metalLayer.contentsScale = scale
    if bounds.width > 1 && bounds.height > 1 {
      let target = CGSize(
        width: (bounds.width * scale).rounded(),
        height: (bounds.height * scale).rounded()
      )
      if metalLayer.drawableSize != target {
        metalLayer.drawableSize = target
      }
      if let cb = onLayoutReady {
        onLayoutReady = nil
        cb()
      }
    }
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
  let selected: Bool
  let isDefault: Bool
  let isExternal: Bool
  let channels: Int
}

/// Native iOS `libmpv` playback engine driving `UzvIosMpvBridge` on a `MpvMetalView`.
final class IosMpvEngine {
  static var isAvailable: Bool {
    uzv_ios_mpv_is_available()
  }

  static var probeDetail: String {
    String(cString: uzv_ios_mpv_probe_detail())
  }

  weak var delegate: IosMpvEngineDelegate?
  private weak var metalView: MpvMetalView?

  private var instance: OpaquePointer?
  private let lock = NSLock()
  private var isRunningEvents = false
  private let eventExitGroup = DispatchGroup()

  private var pendingLoadClosure: (() -> Void)?
  private var loadSerial: UInt64 = 0
  private var awaitingStartFile = false
  private var fileLoaded = false
  private var loadingFile = false
  private var reachedEof = false
  private var userPaused = false
  private var pausedForCache = false
  private var isSeeking = false
  private var lastPublishedState = "idle"

  private var defaultUserAgent: String = "Mozilla/5.0"
  private var userAgentOverridden = false
  private var referrerOverridden = false
  private var pendingSidecars: [SubtitleOption] = []
  private var pendingExternalAudioUrl: String?
  private var subtitlesDisabledByUser = false
  private var preferredAudioLang: String?
  private var preferredSubtitleLang: String?
  private var preferredSubtitleFont: String?

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
      guard oldValue != hwDecode, let inst = instance else { return }
      _ = uzv_ios_mpv_set_property_string(inst, "hwdec", hwDecode ? "videotoolbox" : "no")
    }
  }

  var fitMode: String = "fit" {
    didSet {
      applyFitMode()
    }
  }

  var speed: Float = 1.0 {
    didSet {
      guard let inst = instance, speed > 0 else { return }
      _ = uzv_ios_mpv_set_property_double(inst, "speed", Double(speed))
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

  init(metalView: MpvMetalView, hwDecode: Bool, fitMode: String, speed: Float) {
    self.metalView = metalView
    self.hwDecode = hwDecode
    self.fitMode = fitMode
    self.speed = speed
  }

  private func createInitializedHandle(view: MpvMetalView, vo: String) -> (OpaquePointer?, String?) {
    guard let inst = uzv_ios_mpv_create() else {
      return (nil, "libmpv unavailable (\(Self.probeDetail))")
    }

    let layerPtr = Unmanaged.passUnretained(view.metalLayer).toOpaque()
    let wid = Int64(Int(bitPattern: layerPtr))
    _ = uzv_ios_mpv_set_option_int64(inst, "wid", wid)
    _ = uzv_ios_mpv_set_option_string(inst, "vo", vo)
    _ = uzv_ios_mpv_set_option_string(inst, "gpu-api", "vulkan")
    _ = uzv_ios_mpv_set_option_string(inst, "gpu-context", "moltenvk")
    _ = uzv_ios_mpv_set_option_string(inst, "hwdec", hwDecode ? "videotoolbox" : "no")
    _ = uzv_ios_mpv_set_option_string(inst, "hwdec-codecs", "all")
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
    _ = uzv_ios_mpv_set_option_string(inst, "network-timeout", "20")
    _ = uzv_ios_mpv_set_option_string(inst, "cache", "yes")
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

  private func ensureInitialized() -> String? {
    if instance != nil { return nil }
    guard let view = metalView else {
      return "MPV rendering view missing"
    }

    var activeVo = "gpu-next"
    var (maybeInst, firstErr) = createInitializedHandle(view: view, vo: activeVo)
    if maybeInst == nil {
      activeVo = "gpu"
      let (fallbackInst, fallbackErr) = createInitializedHandle(view: view, vo: activeVo)
      maybeInst = fallbackInst
      if maybeInst == nil {
        return fallbackErr ?? firstErr ?? "mpv_initialize failed"
      }
    }
    guard let inst = maybeInst else {
      return firstErr ?? "mpv_initialize failed"
    }

    instance = inst
    if let ua = getString(inst, "user-agent"), !ua.isEmpty {
      defaultUserAgent = ua
    }
    applyFitMode()
    if speed > 0 {
      _ = uzv_ios_mpv_set_property_double(inst, "speed", Double(speed))
    }
    if let aLang = preferredAudioLang {
      _ = uzv_ios_mpv_set_property_string(inst, "alang", aLang)
    }
    if let sLang = preferredSubtitleLang {
      _ = uzv_ios_mpv_set_property_string(inst, "slang", sLang)
    }
    if let sFont = preferredSubtitleFont, !sFont.isEmpty {
      _ = uzv_ios_mpv_set_property_string(inst, "sub-font", sFont)
    }

    _ = uzv_ios_mpv_observe_property(inst, Self.obsTimePos, "time-pos", 5)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsDuration, "duration", 5)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsPause, "pause", 3)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsCacheStall, "paused-for-cache", 3)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsVideoW, "video-params/w", 4)
    _ = uzv_ios_mpv_observe_property(inst, Self.obsVideoH, "video-params/h", 4)

    lock.lock()
    isRunningEvents = true
    lock.unlock()

    eventExitGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.runEventLoop(inst: inst)
    }

    startStatsTimer()
    mpvUsbLog.notice("[NovaPlay][MPV] initialized vo=\(activeVo, privacy: .public) hwdec=\(self.hwDecode, privacy: .public)")
    return nil
  }

  func load(
    url: String,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    subtitles: [SubtitleOption]
  ) {
    loadSerial &+= 1
    let serial = loadSerial
    let executeLoad = { [weak self] in
      guard let self = self, self.loadSerial == serial else { return }
      self.performLoadNow(url: url, audioUrl: audioUrl, headers: headers, startMs: startMs, subtitles: subtitles)
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
        guard let self = self, self.loadSerial == serial, let job = self.pendingLoadClosure else { return }
        self.pendingLoadClosure = nil
        self.metalView?.onLayoutReady = nil
        job()
      }
    }
  }

  private func performLoadNow(
    url: String,
    audioUrl: String?,
    headers: [String: String],
    startMs: Int64,
    subtitles: [SubtitleOption]
  ) {
    if let initErr = ensureInitialized() {
      mpvUsbLog.error("[NovaPlay][MPV] init error: \(initErr, privacy: .public)")
      delegate?.mpvEngineDidFail(
        message: "MPV " + IosPlayerUiText.t("初始化失败", "init failed"),
        diagnostic: initErr,
        code: -3
      )
      return
    }
    guard let inst = instance else { return }

    awaitingStartFile = true
    fileLoaded = false
    loadingFile = true
    reachedEof = false
    userPaused = false
    pausedForCache = false
    isSeeking = false
    positionMs = max(0, startMs)
    durationMs = 0
    videoSize = .zero
    nominalFps = nil
    videoCodecName = nil
    downloadBytesPerSec = 0
    videoBitrateBps = 0
    pendingSidecars = subtitles
    pendingExternalAudioUrl = nil

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

    _ = setListOption(inst, name: "http-header-fields", values: headerLines)
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
      let rc = setListOption(inst, name: "audio-files", values: [cleanAudio])
      if rc < 0 {
        pendingExternalAudioUrl = cleanAudio
      }
    } else {
      _ = setListOption(inst, name: "audio-files", values: [])
    }

    _ = uzv_ios_mpv_set_property_string(inst, "hwdec", hwDecode ? "videotoolbox" : "no")
    _ = uzv_ios_mpv_set_property_string(inst, "sid", subtitlesDisabledByUser ? "no" : "auto")
    _ = uzv_ios_mpv_set_property_string(inst, "aid", "auto")
    _ = uzv_ios_mpv_set_property_flag(inst, "pause", false)
    if speed > 0 {
      _ = uzv_ios_mpv_set_property_double(inst, "speed", Double(speed))
    }
    applyFitMode()

    let startOpt = String(format: "start=%.3f", Double(max(0, startMs)) / 1000.0)
    var loadRc = uzv_ios_mpv_command5(inst, "loadfile", url, "replace", "-1", startOpt)
    if loadRc == -4 {
      loadRc = uzv_ios_mpv_command4(inst, "loadfile", url, "replace", startOpt)
    }
    if loadRc < 0 {
      loadingFile = false
      awaitingStartFile = false
      let errStr = String(cString: uzv_ios_mpv_error_string(Int32(loadRc)))
      delegate?.mpvEngineDidFail(
        message: "MPV " + IosPlayerUiText.t("加载失败", "load failed") + " (\(errStr))",
        diagnostic: "mpv loadfile rc=\(loadRc): \(errStr)",
        code: Int(loadRc)
      )
      return
    }
    publishStateIfNeeded()
  }

  private func setListOption(_ inst: OpaquePointer, name: String, values: [String]) -> Int32 {
    var rc = uzv_ios_mpv_command4(inst, "change-list", name, "clr", "")
    for item in values {
      let r = uzv_ios_mpv_command4(inst, "change-list", name, "append", item)
      if rc >= 0 && r < 0 { rc = r }
    }
    return rc
  }

  private func applyFitMode() {
    guard let inst = instance else { return }
    let keepAspect: Bool
    let panscan: Double
    switch fitMode {
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
    _ = uzv_ios_mpv_set_property_flag(inst, "keepaspect", keepAspect)
    _ = uzv_ios_mpv_set_property_double(inst, "panscan", panscan)
  }

  func play() {
    guard let inst = instance else { return }
    userPaused = false
    _ = uzv_ios_mpv_set_property_flag(inst, "pause", false)
    if speed > 0 {
      _ = uzv_ios_mpv_set_property_double(inst, "speed", Double(speed))
    }
    publishStateIfNeeded()
  }

  func pause() {
    guard let inst = instance else { return }
    userPaused = true
    _ = uzv_ios_mpv_set_property_flag(inst, "pause", true)
    publishStateIfNeeded()
  }

  func seekTo(_ ms: Int64) {
    guard let inst = instance else { return }
    let clamped = durationMs > 0 ? min(max(0, ms), durationMs) : max(0, ms)
    positionMs = clamped
    isSeeking = true
    let secStr = String(format: "%.3f", Double(clamped) / 1000.0)
    _ = uzv_ios_mpv_command3(inst, "seek", secStr, "absolute")
    publishStateIfNeeded()
  }

  func addExternalSubtitle(_ sub: SubtitleOption) {
    pendingSidecars.append(sub)
    guard let inst = instance, fileLoaded else { return }
    _ = uzv_ios_mpv_command5(inst, "sub-add", sub.url, "select", sub.name, sub.language ?? "")
    subtitlesDisabledByUser = false
  }

  func applyAudioPreference(lang: String?) {
    preferredAudioLang = lang?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let inst = instance {
      _ = uzv_ios_mpv_set_property_string(inst, "alang", preferredAudioLang ?? "")
    }
  }

  func applySubtitlePreferences(lang: String?, fontFamily: String?) {
    preferredSubtitleLang = lang?.trimmingCharacters(in: .whitespacesAndNewlines)
    preferredSubtitleFont = fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let inst = instance {
      _ = uzv_ios_mpv_set_property_string(inst, "slang", preferredSubtitleLang ?? "")
      if let font = preferredSubtitleFont, !font.isEmpty {
        _ = uzv_ios_mpv_set_property_string(inst, "sub-font", font)
      }
    }
  }

  // MARK: - Tracks

  private func parseTracks(ofType targetType: String) -> [MpvParsedTrack] {
    guard let inst = instance else { return [] }
    let count = Int(uzv_ios_mpv_get_property_int64(inst, "track-list/count", 0))
    guard count > 0 else { return [] }
    var out: [MpvParsedTrack] = []
    for i in 0..<count {
      let prefix = "track-list/\(i)/"
      guard let type = getString(inst, prefix + "type"), type == targetType else { continue }
      let id = Int(uzv_ios_mpv_get_property_int64(inst, prefix + "id", -1))
      guard id >= 0 else { continue }
      let lang = getString(inst, prefix + "lang")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let title = getString(inst, prefix + "title")?.trimmingCharacters(in: .whitespacesAndNewlines)
      let selected = uzv_ios_mpv_get_property_flag(inst, prefix + "selected", false)
      let isDef = uzv_ios_mpv_get_property_flag(inst, prefix + "default", false)
      let isExt = uzv_ios_mpv_get_property_flag(inst, prefix + "external", false)
      let ch = Int(uzv_ios_mpv_get_property_int64(inst, prefix + "demux-channel-count", 0))
      out.append(MpvParsedTrack(
        id: id,
        type: type,
        lang: (lang?.isEmpty == false) ? lang : nil,
        title: (title?.isEmpty == false) ? title : nil,
        selected: selected,
        isDefault: isDef,
        isExternal: isExt,
        channels: ch
      ))
    }
    return out
  }

  var subtitlesEnabled: Bool {
    !subtitlesDisabledByUser && parseTracks(ofType: "sub").contains(where: { $0.selected })
  }

  func subtitleTracks() -> [IosTrackOption] {
    let subs = parseTracks(ofType: "sub")
    return subs.enumerated().map { idx, t in
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
    guard let inst = instance else { return }
    if index < 0 {
      subtitlesDisabledByUser = true
      _ = uzv_ios_mpv_set_property_string(inst, "sid", "no")
      return
    }
    let subs = parseTracks(ofType: "sub")
    guard index < subs.count else { return }
    subtitlesDisabledByUser = false
    _ = uzv_ios_mpv_set_property_int64(inst, "sid", Int64(subs[index].id))
  }

  func audioTracks() -> [IosTrackOption] {
    let audios = parseTracks(ofType: "audio")
    return audios.enumerated().map { idx, t in
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
    guard let inst = instance else { return }
    if index < 0 {
      _ = uzv_ios_mpv_set_property_string(inst, "aid", "auto")
      return
    }
    let audios = parseTracks(ofType: "audio")
    guard index < audios.count else { return }
    _ = uzv_ios_mpv_set_property_int64(inst, "aid", Int64(audios[index].id))
  }

  // MARK: - Screenshot

  func captureVideoFrame() -> UIImage? {
    guard let inst = instance, fileLoaded else { return nil }
    let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("novaplay-mpv-shot-\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: tmpURL) }
    let rc = uzv_ios_mpv_command3(inst, "screenshot-to-file", tmpURL.path, "video")
    if rc >= 0, let data = try? Data(contentsOf: tmpURL), let img = UIImage(data: data) {
      return img
    }
    return nil
  }

  // MARK: - Event Loop & Telemetry

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

      DispatchQueue.main.async { [weak self] in
        self?.handleEventOnMain(ev)
      }
    }
  }

  private func handleEventOnMain(_ ev: UzvIosMpvEvent) {
    guard let inst = instance else { return }
    switch ev.event_id {
    case 6: // START_FILE
      awaitingStartFile = false
    case 8: // FILE_LOADED
      fileLoaded = true
      loadingFile = false
      if let extAudio = pendingExternalAudioUrl {
        pendingExternalAudioUrl = nil
        _ = uzv_ios_mpv_command3(inst, "audio-add", extAudio, "select")
      }
      for sub in pendingSidecars {
        _ = uzv_ios_mpv_command5(inst, "sub-add", sub.url, "auto", sub.name, sub.language ?? "")
      }
      refreshVideoMetadata(inst: inst)
      mpvUsbLog.notice("[NovaPlay][MPV] FILE_LOADED codec=\(self.videoCodecName ?? "unknown", privacy: .public) size=\(Int(self.videoSize.width), privacy: .public)x\(Int(self.videoSize.height), privacy: .public)")
      publishStateIfNeeded()
      delegate?.mpvEngineDidUpdateMetrics()
    case 7: // END_FILE
      guard !awaitingStartFile else { return }
      fileLoaded = false
      if ev.end_reason == 0 { // EOF
        reachedEof = true
        loadingFile = false
        publishStateIfNeeded()
      } else if ev.end_reason == 4 { // ERROR
        loadingFile = false
        let errStr = String(cString: uzv_ios_mpv_error_string(ev.end_error))
        let logs = (copyStringAndFree(uzv_ios_mpv_copy_recent_logs(inst)) ?? "")
          .components(separatedBy: .newlines)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
          .suffix(3)
          .joined(separator: " | ")
        let shortMsg = "MPV " + IosPlayerUiText.t("播放失败", "playback failed") + " (\(errStr))"
        let fullDiag = logs.isEmpty ? shortMsg : "\(shortMsg)\n\(logs)"
        mpvUsbLog.error("[NovaPlay][MPV] END_FILE error: \(fullDiag, privacy: .public)")
        delegate?.mpvEngineDidFail(message: shortMsg, diagnostic: fullDiag, code: Int(ev.end_error))
      }
    case 17: // VIDEO_RECONFIG
      refreshVideoMetadata(inst: inst)
      delegate?.mpvEngineDidUpdateMetrics()
    case 20: // SEEK
      isSeeking = true
      publishStateIfNeeded()
    case 21: // PLAYBACK_RESTART
      isSeeking = false
      publishStateIfNeeded()
    case 22: // PROPERTY_CHANGE
      switch ev.reply_userdata {
      case Self.obsTimePos:
        let sec = uzv_ios_mpv_get_property_double(inst, "time-pos", -1)
        if sec >= 0 {
          positionMs = Int64((sec * 1000.0).rounded())
          delegate?.mpvEngineDidUpdateMetrics()
        }
      case Self.obsDuration:
        let dur = uzv_ios_mpv_get_property_double(inst, "duration", -1)
        if dur > 0 {
          durationMs = Int64((dur * 1000.0).rounded())
          delegate?.mpvEngineDidUpdateMetrics()
        }
      case Self.obsPause:
        userPaused = uzv_ios_mpv_get_property_flag(inst, "pause", userPaused)
        publishStateIfNeeded()
      case Self.obsCacheStall:
        pausedForCache = uzv_ios_mpv_get_property_flag(inst, "paused-for-cache", false)
        publishStateIfNeeded()
      case Self.obsVideoW, Self.obsVideoH:
        refreshVideoMetadata(inst: inst)
        delegate?.mpvEngineDidUpdateMetrics()
      default:
        break
      }
    default:
      break
    }
  }

  private func refreshVideoMetadata(inst: OpaquePointer) {
    let w = uzv_ios_mpv_get_property_int64(inst, "video-params/w", 0)
    let h = uzv_ios_mpv_get_property_int64(inst, "video-params/h", 0)
    if w > 0 && h > 0 {
      videoSize = CGSize(width: CGFloat(w), height: CGFloat(h))
    }
    let fpsEst = uzv_ios_mpv_get_property_double(inst, "estimated-vf-fps", 0)
    let fpsCont = uzv_ios_mpv_get_property_double(inst, "container-fps", 0)
    let bestFps = fpsEst > 0 ? fpsEst : fpsCont
    if bestFps > 0 {
      nominalFps = bestFps
    }
    if let fmt = getString(inst, "video-format")?.uppercased(), !fmt.isEmpty {
      switch fmt {
      case "HEVC", "H265": videoCodecName = "HEVC"
      case "H264", "AVC1": videoCodecName = "H.264"
      default: videoCodecName = fmt
      }
    }
  }

  private func startStatsTimer() {
    statsTimer?.invalidate()
    let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.sampleStats()
    }
    RunLoop.main.add(t, forMode: .common)
    statsTimer = t
  }

  private func sampleStats() {
    guard let inst = instance, fileLoaded else { return }
    let cacheSpeed = uzv_ios_mpv_get_property_double(inst, "cache-speed", 0)
    downloadBytesPerSec = max(0, cacheSpeed)
    let vBitrate = uzv_ios_mpv_get_property_double(inst, "video-bitrate", 0)
    videoBitrateBps = max(0, vBitrate)
    if nominalFps == nil || videoSize == .zero {
      refreshVideoMetadata(inst: inst)
    }
    delegate?.mpvEngineDidUpdateMetrics()
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
    pendingLoadClosure = nil
    metalView?.onLayoutReady = nil
    awaitingStartFile = false
    fileLoaded = false
    loadingFile = false
    reachedEof = false
    if let inst = instance {
      _ = uzv_ios_mpv_command2(inst, "stop", nil)
    }
    lastPublishedState = "idle"
  }

  func destroy() {
    statsTimer?.invalidate()
    statsTimer = nil
    pendingLoadClosure = nil
    metalView?.onLayoutReady = nil

    guard let inst = instance else { return }
    instance = nil

    lock.lock()
    isRunningEvents = false
    lock.unlock()
    uzv_ios_mpv_wakeup(inst)

    let exitGroup = eventExitGroup
    DispatchQueue.global(qos: .utility).async {
      _ = exitGroup.wait(timeout: .now() + 2.0)
      uzv_ios_mpv_destroy(inst)
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
