import Foundation
import MediaPlayer
import UIKit

protocol IosPlayerControllerUiDelegate: AnyObject {
  func controllerDidChangeState()
  func controllerDidShowNotice(_ text: String)
  func controllerDidShowToast(_ text: String, long: Bool)
  func controllerDidUpdateSubtitleCue(_ text: String?)
  func controllerDidUpdateMetrics()
  func controllerDidSkipRange(fromMs: Int64)
  func controllerPictureInPictureDidStart(origin: IosPipOrigin)
  func controllerDidPauseFromBackgroundPiPClose()
  func controllerRequestRestorePiP(completion: @escaping (Bool) -> Void)
  func controllerDidBeginNewEpisode()
  func controllerDidChangeOrientationConfig(_ mode: String)
}

extension IosPlayerControllerUiDelegate {
  func controllerDidBeginNewEpisode() {}
  func controllerDidChangeOrientationConfig(_ mode: String) {}
}

/// iOS counterpart of Android's `PlayerController.kt`, implementing the exact Pigeon ask/answer state machine.
final class IosPlayerController: IosPlayerKernelDelegate {
  let request: OpenPlayerRequest
  let kernel: IosPlayerKernel
  let danmakuView: IosDanmakuView
  private let flutterApi: NativePlayerFlutterApi
  private let onDismissPage: (Bool) -> Bool

  weak var uiDelegate: IosPlayerControllerUiDelegate?

  private(set) var line: Int
  private(set) var episode: Int
  private(set) var quality: Int
  private(set) var qualityNames: [String] = []
  private var requestId: Int64 = 0
  private var pendingStartMs: Int64
  private(set) var playbackConfig: PlaybackConfig
  private(set) var danmakuConfig: DanmakuConfig
  private(set) var currentSpeed: Double
  private(set) var state: String = "idle"
  private(set) var errorMessage: String?
  private(set) var failed: Bool = false
  private var loaded: Bool = false
  private(set) var isClosed: Bool = false

  private static let maxHeadTailMs: Int64 = 600_000
  private static let minAutoOutroDurationMs: Int64 = 180_000
  private static let minMainContentMs: Int64 = 90_000

  private var introEndMs: Int64 = 0
  private var outroBeforeEndMs: Int64 = 0
  private var outroDone: Bool = false
  private var outroHitTicks: Int = 0
  private var resolvingSource: Bool = false
  var isResolvingSource: Bool { resolvingSource }
  private var autoSkippedIntroThisEpisode: Bool = false
  private var skipRanges: [(Int64, Int64)] = []
  private var skippedRangeIndices = Set<Int>()

  private var extraSubtitles: [SubtitleOption] = []
  private var lastPayload: SourcePayload?
  private(set) var probedVideoSize: CGSize = .zero
  private var lastReportedDecodedSize: CGSize = .zero
  private var heartbeatTimer: Timer?

  var danmakuSearchListener: (([DanmakuSearchResultItem]) -> Void)?
  var danmakuEpisodesListener: (([EpisodeItem]) -> Void)?
  var danmakuCountListener: ((Int) -> Void)?
  private(set) var danmakuAnimeTitle: String?
  private(set) var danmakuEpisodeTitle: String?
  private(set) var tmdbMatches: [TmdbEpisodeItem]

  private var remoteCommandsRegistered = false
  private var lastNowPlayingSignature: String = ""
  private var lastNowPlayingPosMs: Int64 = -10_000

  init(
    request: OpenPlayerRequest,
    kernel: IosPlayerKernel,
    danmakuView: IosDanmakuView,
    flutterApi: NativePlayerFlutterApi,
    onDismissPage: @escaping (Bool) -> Bool
  ) {
    self.request = request
    self.kernel = kernel
    self.danmakuView = danmakuView
    self.flutterApi = flutterApi
    self.onDismissPage = onDismissPage

    self.line = Int(request.startLineIndex)
    self.episode = Int(request.startEpisodeIndex)
    self.quality = max(0, Int(request.startQualityIndex ?? 0))
    self.pendingStartMs = request.startPositionSeconds * 1000
    var initialPlayback = request.playbackConfig
    if IosPlayerUiText.normalizeIosKernel(initialPlayback.kernel) == "mpv" {
      initialPlayback.autoPictureInPicture = false
    }
    self.playbackConfig = initialPlayback
    self.danmakuConfig = request.danmakuConfig
    self.currentSpeed = initialPlayback.speed
    self.tmdbMatches = request.tmdbEpisodes ?? []
    if let w = request.initialSource?.videoWidth ?? request.initialVideoWidth,
       let h = request.initialSource?.videoHeight ?? request.initialVideoHeight,
       w > 0, h > 0 {
      self.probedVideoSize = CGSize(width: CGFloat(w), height: CGFloat(h))
    }

    IosPlayerUiText.applyLocale(initialPlayback.uiLocale)
    kernel.delegate = self
    kernel.hwDecode = playbackConfig.hwDecode
    kernel.selectKernelBackend(playbackConfig.kernel, notifyFallback: true)
    kernel.fitMode = playbackConfig.fitMode
    kernel.speed = Float(currentSpeed)
    kernel.autoPictureInPicture = playbackConfig.autoPictureInPicture
    kernel.applySubtitlePreferences(lang: playbackConfig.subtitleLang, fontFamily: playbackConfig.subtitleFontFamily)
    kernel.applyAudioPreference(lang: playbackConfig.audioLang)
    danmakuView.kernel = kernel
    danmakuView.configure(danmakuConfig)
    applyHeadTail()
    setupRemoteTransportControls()
  }

  var title: String { request.title }
  var isLive: Bool { request.epgProgrammes != nil }
  var epgProgrammes: [EpgProgramme] { request.epgProgrammes ?? [] }
  var hasPrevious: Bool { episode > 0 }
  var hasNext: Bool { episode + 1 < episodeNames().count }
  var episodeName: String? {
    let list = episodeNames()
    return (episode >= 0 && episode < list.count) ? list[episode] : nil
  }
  var qualityName: String? {
    (quality >= 0 && quality < qualityNames.count) ? qualityNames[quality] : nil
  }
  var canMarkHeadTail: Bool { !isLive && kernel.durationMs > 0 }

  func episodeNames(forLine lineIdx: Int? = nil) -> [String] {
    let idx = lineIdx ?? line
    if idx >= 0 && idx < request.lines.count && !request.lines[idx].episodes.isEmpty {
      return request.lines[idx].episodes.map { $0.episodeName }
    }
    return request.episodes.map { $0.episodeName }
  }

  func lineNames() -> [String] {
    request.lines.map { $0.lineName }
  }

  func start() {
    danmakuView.startDisplayLink()
    requestEpisode(lineIndex: line, episodeIndex: episode, isInitialLoad: true)
    startHeartbeat()
  }

  private func startHeartbeat() {
    heartbeatTimer?.invalidate()
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      self?.onHeartbeatTick()
    }
    RunLoop.main.add(timer, forMode: .common)
    heartbeatTimer = timer
  }

  private func onHeartbeatTick() {
    guard !isClosed else { return }
    if resolvingSource {
      updateNowPlayingInfo()
      return
    }
    let hb = Heartbeat(
      sessionId: request.sessionId,
      positionSeconds: Double(kernel.positionMs) / 1000.0,
      durationSeconds: Double(kernel.durationMs) / 1000.0
    )
    flutterApi.onHeartbeat(heartbeat: hb) { _ in }
    maybeSkipOutro()
    updateNowPlayingInfo()
  }

  func requestEpisode(lineIndex: Int, episodeIndex: Int, refreshDanmaku: Bool = true, isInitialLoad: Bool = false) {
    let isEpisodeSwitch = refreshDanmaku && !isInitialLoad
    if isEpisodeSwitch {
      uiDelegate?.controllerDidBeginNewEpisode()
    }
    line = lineIndex
    episode = episodeIndex
    errorMessage = nil
    failed = false
    resolvingSource = true
    outroDone = false
    outroHitTicks = 0
    autoSkippedIntroThisEpisode = false
    skippedRangeIndices.removeAll()
    state = "buffering"
    if loaded { kernel.pause() }
    if isEpisodeSwitch {
      probedVideoSize = .zero
      lastReportedDecodedSize = .zero
      extraSubtitles.removeAll()
      danmakuAnimeTitle = nil
      danmakuEpisodeTitle = nil
    }
    requestId += 1
    let epReq = EpisodeRequest(
      sessionId: request.sessionId,
      requestId: requestId,
      lineIndex: Int64(lineIndex),
      episodeIndex: Int64(episodeIndex),
      qualityIndex: Int64(quality)
    )
    flutterApi.onEpisodeRequest(request: epReq) { _ in }
    if refreshDanmaku {
      let dmReq = DanmakuRequest(
        sessionId: request.sessionId,
        lineIndex: Int64(lineIndex),
        episodeIndex: Int64(episodeIndex)
      )
      flutterApi.onDanmakuRequest(request: dmReq) { _ in }
    }
    updateNowPlayingInfo()
    uiDelegate?.controllerDidChangeState()
  }

  // MARK: - Pigeon Answers from Dart

  func onSource(_ payload: SourcePayload) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.isClosed, payload.requestId == self.requestId else { return }
      self.resolvingSource = false
      guard payload.success, let url = payload.url, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        let msg = IosPlayerUiText.sourceFailed(payload.errorMessage)
        self.flutterApi.onErrorReported(
          report: ErrorReport(sessionId: self.request.sessionId, message: msg, fatal: true, code: nil)
        ) { _ in }
        self.uiDelegate?.controllerDidShowToast(msg, long: false)
        if self.loaded && msg.contains("未匹配") {
          self.kernel.play()
          return
        }
        self.showError(msg)
        return
      }

      self.loadPayload(payload, url: url, autoPlay: true)
      self.uiDelegate?.controllerDidChangeState()
    }
  }

  private func loadPayload(_ payload: SourcePayload, url: String, autoPlay: Bool) {
    loaded = true
    let sortedQualities = (payload.qualities ?? []).sorted { $0.qualityIndex < $1.qualityIndex }
    qualityNames = sortedQualities.map { $0.qualityName }
    if !qualityNames.isEmpty {
      quality = min(max(0, quality), qualityNames.count - 1)
    }
    lastPayload = payload
    if let w = payload.videoWidth, let h = payload.videoHeight, w > 0, h > 0 {
      probedVideoSize = CGSize(width: CGFloat(w), height: CGFloat(h))
      uiDelegate?.controllerDidUpdateMetrics()
    }

    var start = pendingStartMs
    if start <= 0 && introEndMs > 0 && introEndMs <= Self.maxHeadTailMs {
      start = introEndMs
      autoSkippedIntroThisEpisode = true
      if playbackConfig.skipNotice {
        uiDelegate?.controllerDidShowNotice(IosPlayerUiText.t("已跳过片头", "Intro skipped"))
      }
    }
    pendingStartMs = 0

    let subs = (payload.subtitles ?? []) + extraSubtitles
    kernel.load(
      url: url,
      audioUrl: payload.audioUrl,
      headers: payload.headers ?? [:],
      startMs: start,
      subtitles: subs,
      autoPlay: autoPlay
    )
  }

  /// Display-oriented decoded video dimensions, preferring container-rotated `probedVideoSize` when `MobileVLCKit`
  /// reports unrotated coded dimensions that are an exact 90°/270° transpose.
  var effectiveDisplayVideoSize: CGSize {
    let kSize = kernel.videoSize
    guard kSize.width > 0 && kSize.height > 0 else { return .zero }
    if kernel.isUsingVlc,
       probedVideoSize.width > 0,
       probedVideoSize.height > 0,
       abs(kSize.width - probedVideoSize.height) <= 2,
       abs(kSize.height - probedVideoSize.width) <= 2 {
      return probedVideoSize
    }
    return kSize
  }

  func seedInitialProbedSize(_ size: CGSize) {
    guard size.width > 0 && size.height > 0 else { return }
    probedVideoSize = size
  }

  func onProbedVideoSize(sessionId: String, lineIndex: Int, episodeIndex: Int, width: Int, height: Int) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self,
            !self.isClosed,
            sessionId == self.request.sessionId,
            lineIndex == self.line,
            episodeIndex == self.episode,
            width > 0,
            height > 0 else { return }
      let nextProbed = CGSize(width: CGFloat(width), height: CGFloat(height))
      let kSize = self.kernel.videoSize
      let isVlcTranspose = self.kernel.isUsingVlc
        && kSize.width > 0
        && kSize.height > 0
        && abs(kSize.width - nextProbed.height) <= 2
        && abs(kSize.height - nextProbed.width) <= 2
      if !self.resolvingSource && kSize.width > 0 && kSize.height > 0 && !isVlcTranspose {
        return
      }
      self.probedVideoSize = nextProbed
      if isVlcTranspose {
        self.kernelDidUpdateMetrics()
      } else {
        self.uiDelegate?.controllerDidUpdateMetrics()
      }
    }
  }

  /// Start directly with Dart's pre-resolved `initialSource` without sending a duplicate `onEpisodeRequest`,
  /// matching Android `PlayerController.start()`.
  func start(withInitialSource payload: SourcePayload) {
    danmakuView.startDisplayLink()
    resolvingSource = true
    state = "buffering"
    requestId += 1
    let dmReq = DanmakuRequest(
      sessionId: request.sessionId,
      lineIndex: Int64(line),
      episodeIndex: Int64(episode)
    )
    flutterApi.onDanmakuRequest(request: dmReq) { _ in }
    uiDelegate?.controllerDidChangeState()
    var p = payload
    p.requestId = requestId
    onSource(p)
    startHeartbeat()
  }

  func onDanmaku(_ payload: DanmakuPayload) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.isClosed else { return }
      self.danmakuAnimeTitle = payload.animeTitle
      self.danmakuEpisodeTitle = payload.episodeTitle
      guard let data = payload.commentsJson.data(using: .utf8),
            let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
      let parsed: [IosDanmakuView.Comment] = arr.compactMap { item in
        guard let t = (item["t"] as? NSNumber)?.doubleValue,
              let m = (item["m"] as? NSNumber)?.intValue,
              let c = (item["c"] as? NSNumber)?.intValue,
              let x = item["x"] as? String else { return nil }
        return IosDanmakuView.Comment(time: t, mode: m, color: c, text: x)
      }
      self.danmakuView.setComments(parsed)
      self.danmakuCountListener?(self.danmakuView.commentCount)
      self.uiDelegate?.controllerDidChangeState()
    }
  }

  func onTmdbMatches(_ matches: [TmdbEpisodeItem]) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.isClosed else { return }
      self.tmdbMatches = matches
      self.uiDelegate?.controllerDidChangeState()
    }
  }

  func onDanmakuSearchResults(_ results: [DanmakuSearchResultItem]) {
    DispatchQueue.main.async { [weak self] in
      self?.danmakuSearchListener?(results)
    }
  }

  func onDanmakuEpisodes(_ episodes: [EpisodeItem]) {
    DispatchQueue.main.async { [weak self] in
      self?.danmakuEpisodesListener?(episodes)
    }
  }

  func onRuntimeConfig(_ patch: RuntimeConfigPatch) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.isClosed else { return }
      if let nextP = patch.playbackConfig {
        let oldMode = IosPlayerUiText.effectiveOrientationMode(self.playbackConfig)
        let oldPriority = self.playbackConfig.isPriorityLandscape
        self.applyPlaybackChange(nextP, reportToDart: false)
        let newMode = IosPlayerUiText.effectiveOrientationMode(self.playbackConfig)
        if oldMode != newMode || oldPriority != self.playbackConfig.isPriorityLandscape {
          self.uiDelegate?.controllerDidChangeOrientationConfig(newMode)
        }
      }
      if let nextD = patch.danmakuConfig {
        self.danmakuConfig = nextD
        self.danmakuView.configure(nextD)
      }
    }
  }

  func toast(_ message: String, long: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self, !self.isClosed else { return }
      self.uiDelegate?.controllerDidShowToast(message, long: long)
    }
  }

  // MARK: - User Actions

  func togglePause() {
    if kernel.isPlaying {
      kernel.pause()
    } else {
      kernel.play()
    }
  }

  func seekTo(_ ms: Int64) {
    let dur = kernel.durationMs
    let target = dur > 0 ? min(max(0, ms), dur) : max(0, ms)
    outroHitTicks = 0
    if dur > 0 && outroBeforeEndMs > 0 && target >= dur - outroBeforeEndMs {
      outroDone = true
    }
    for (idx, range) in skipRanges.enumerated() {
      if target >= range.0 && target < range.1 {
        skippedRangeIndices.insert(idx)
      }
    }
    state = "buffering"
    uiDelegate?.controllerDidChangeState()
    kernel.seekTo(target)
  }

  func seekBy(seconds: Int) {
    seekTo(kernel.positionMs + Int64(seconds) * 1000)
  }

  func setSpeed(_ v: Double) {
    currentSpeed = v
    kernel.speed = Float(v)
    updateNowPlayingInfo()
    uiDelegate?.controllerDidChangeState()
  }

  func setFitMode(_ mode: String) {
    var next = playbackConfig
    next.fitMode = mode
    updatePlayback(next)
  }

  var copyableErrorText: String {
    if let diag = kernel.lastDiagnosticReport, !diag.isEmpty {
      return diag
    }
    return errorMessage ?? ""
  }

  func selectPlayerKernel(_ targetKernel: String) {
    let targetNorm = IosPlayerUiText.normalizeIosKernel(targetKernel)
    let prevActive = kernel.activeKernelId
    let savedPositionMs = max(pendingStartMs, kernel.positionMs)
    var next = playbackConfig
    next.kernel = targetNorm
    if targetNorm == "mpv" {
      next.autoPictureInPicture = false
    }
    playbackConfig = next
    kernel.autoPictureInPicture = next.autoPictureInPicture
    kernel.selectKernelBackend(targetNorm, notifyFallback: true)
    if prevActive != kernel.activeKernelId {
      errorMessage = nil
      failed = false
      state = "buffering"
      if let payload = lastPayload,
         let mediaUrl = payload.url,
         !mediaUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let subs = (payload.subtitles ?? []) + extraSubtitles
        kernel.load(
          url: mediaUrl,
          audioUrl: payload.audioUrl,
          headers: payload.headers ?? [:],
          startMs: savedPositionMs,
          subtitles: subs
        )
        let shortName = IosPlayerUiText.kernelShortName(kernel.activeKernelId)
        uiDelegate?.controllerDidShowNotice(
          IosPlayerUiText.t("已切换至 \(shortName) 内核", "Switched to \(shortName)")
        )
      } else {
        pendingStartMs = savedPositionMs
        reportPreferences()
        requestEpisode(lineIndex: line, episodeIndex: episode, refreshDanmaku: false)
        return
      }
    }
    reportPreferences()
    uiDelegate?.controllerDidChangeState()
  }

  func updatePlayback(_ next: PlaybackConfig) {
    applyPlaybackChange(next, reportToDart: true)
  }

  private func applyPlaybackChange(_ rawNext: PlaybackConfig, reportToDart: Bool) {
    let old = playbackConfig
    let oldNormKernel = IosPlayerUiText.normalizeIosKernel(old.kernel)
    let nextNormKernel = IosPlayerUiText.normalizeIosKernel(rawNext.kernel)
    var next = rawNext
    if nextNormKernel == "mpv" {
      next.autoPictureInPicture = false
    }
    playbackConfig = next
    let prevActiveKernel = kernel.activeKernelId
    let savedPositionMs = max(pendingStartMs, kernel.positionMs)
    let kernelChanged = (oldNormKernel != nextNormKernel)
    let hwChanged = (old.hwDecode != next.hwDecode) && (prevActiveKernel == "vlc" || nextNormKernel == "vlc")

    kernel.hwDecode = next.hwDecode
    if kernelChanged {
      kernel.selectKernelBackend(next.kernel, notifyFallback: true)
    }
    let activeKernelSwitched = (prevActiveKernel != kernel.activeKernelId)
    if old.fitMode != next.fitMode {
      kernel.fitMode = next.fitMode
    }
    if old.speed != next.speed && abs(currentSpeed - old.speed) < 0.001 {
      currentSpeed = next.speed
      kernel.speed = Float(next.speed)
    }
    kernel.autoPictureInPicture = next.autoPictureInPicture
    if old.subtitleLang != next.subtitleLang || old.subtitleFontFamily != next.subtitleFontFamily {
      kernel.applySubtitlePreferences(lang: next.subtitleLang, fontFamily: next.subtitleFontFamily)
    }
    if old.audioLang != next.audioLang {
      kernel.applyAudioPreference(lang: next.audioLang)
    }
    if (activeKernelSwitched || hwChanged),
       let payload = lastPayload,
       let mediaUrl = payload.url,
       !mediaUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      errorMessage = nil
      failed = false
      state = "buffering"
      let subs = (payload.subtitles ?? []) + extraSubtitles
      kernel.load(
        url: mediaUrl,
        audioUrl: payload.audioUrl,
        headers: payload.headers ?? [:],
        startMs: savedPositionMs,
        subtitles: subs
      )
    }
    if reportToDart {
      reportPreferences()
    }
    uiDelegate?.controllerDidChangeState()
  }

  func setDanmakuEnabled(_ on: Bool) {
    danmakuConfig.enabled = on
    danmakuView.configure(danmakuConfig)
    reportPreferences()
    uiDelegate?.controllerDidChangeState()
  }

  func updateDanmaku(_ next: DanmakuConfig, save: Bool = true) {
    danmakuConfig = next
    danmakuView.configure(next)
    if save {
      reportPreferences()
    }
    uiDelegate?.controllerDidChangeState()
  }

  func reportPreferences() {
    let report = PreferenceReport(
      sessionId: request.sessionId,
      playbackConfig: playbackConfig,
      danmakuConfig: danmakuConfig
    )
    flutterApi.onPreferenceReported(report: report) { _ in }
  }

  func selectQuality(_ index: Int) {
    guard index >= 0 && index < qualityNames.count && index != quality else { return }
    let nextName = qualityNames[index]
    quality = index
    pendingStartMs = max(pendingStartMs, kernel.positionMs)
    uiDelegate?.controllerDidShowNotice(
      IosPlayerUiText.t("正在切换至 \(nextName)", "Switching to \(nextName)")
    )
    requestEpisode(lineIndex: line, episodeIndex: episode, refreshDanmaku: false)
  }

  @discardableResult
  func nextEpisode() -> Bool {
    let next = episode + 1
    let names = episodeNames()
    guard next < names.count else { return false }
    pendingStartMs = 0
    if playbackConfig.isShowEpisodeSwitchNotice {
      uiDelegate?.controllerDidShowNotice(IosPlayerUiText.switchingTo(names[next]))
    }
    requestEpisode(lineIndex: line, episodeIndex: next)
    return true
  }

  @discardableResult
  func previousEpisode() -> Bool {
    let prev = episode - 1
    let names = episodeNames()
    guard prev >= 0 && prev < names.count else { return false }
    pendingStartMs = 0
    if playbackConfig.isShowEpisodeSwitchNotice {
      uiDelegate?.controllerDidShowNotice(IosPlayerUiText.switchingTo(names[prev]))
    }
    requestEpisode(lineIndex: line, episodeIndex: prev)
    return true
  }

  func selectLineEpisode(lineIndex: Int, episodeIndex: Int) {
    guard lineIndex >= 0 && lineIndex < max(1, request.lines.count) else { return }
    let names = episodeNames(forLine: lineIndex)
    guard episodeIndex >= 0 && episodeIndex < names.count else { return }
    pendingStartMs = 0
    if lineIndex != line || episodeIndex != episode {
      if playbackConfig.isShowEpisodeSwitchNotice {
        uiDelegate?.controllerDidShowNotice(IosPlayerUiText.switchingTo(names[episodeIndex]))
      }
    }
    requestEpisode(lineIndex: lineIndex, episodeIndex: episodeIndex)
  }

  func addExternalSubtitle(url: String, name: String) {
    let sub = SubtitleOption(url: url, name: name, language: nil, mimeType: nil)
    extraSubtitles.removeAll { $0.url == url }
    extraSubtitles.append(sub)
    kernel.addExternalSubtitleHot(sub, headers: lastPayload?.headers ?? [:])
    uiDelegate?.controllerDidChangeState()
  }

  func danmakuPrompt(completion: @escaping (DanmakuPromptInfo?) -> Void) {
    flutterApi.getDanmakuPromptInfo(sessionId: request.sessionId) { result in
      DispatchQueue.main.async {
        completion(try? result.get())
      }
    }
  }

  func searchDanmaku(keyword: String) {
    flutterApi.onDanmakuSearchRequest(request: DanmakuSearchRequest(sessionId: request.sessionId, keyword: keyword)) { _ in }
  }

  func pickDanmakuAnime(animeId: Int64) {
    flutterApi.onDanmakuEpisodesRequest(sessionId: request.sessionId, animeId: animeId) { _ in }
  }

  func pickDanmakuEpisode(index: Int) {
    flutterApi.onDanmakuRequest(
      request: DanmakuRequest(sessionId: request.sessionId, lineIndex: Int64(line), episodeIndex: Int64(index))
    ) { _ in }
  }

  func markIntro() {
    let pos = kernel.positionMs
    let dur = kernel.durationMs
    guard pos > 0 && dur > 0 else { return }
    let maxAllowed = min(Self.maxHeadTailMs, dur / 3)
    if pos > maxAllowed {
      uiDelegate?.controllerDidShowToast(IosPlayerUiText.t("片头位置过长，请在正片前 1/3 内标记", "Intro position too far into episode"), long: false)
      return
    }
    introEndMs = pos
    flutterApi.onHeadTailMarked(sessionId: request.sessionId, type: "intro", seconds: Double(pos) / 1000.0) { _ in }
    uiDelegate?.controllerDidShowToast(IosPlayerUiText.introMarked(pos), long: false)
  }

  func markOutro() {
    let dur = kernel.durationMs
    let before = dur - kernel.positionMs
    guard dur > 0 && before > 0 else { return }
    let maxAllowed = min(Self.maxHeadTailMs, dur / 3)
    if before > maxAllowed {
      uiDelegate?.controllerDidShowToast(IosPlayerUiText.t("片尾时长过长，请在结束前 1/3 内标记", "Outro too far before end"), long: false)
      return
    }
    outroBeforeEndMs = before
    outroDone = true
    outroHitTicks = 0
    flutterApi.onHeadTailMarked(sessionId: request.sessionId, type: "outro", seconds: Double(before) / 1000.0) { _ in }
    uiDelegate?.controllerDidShowToast(IosPlayerUiText.outroMarked(before), long: false)
    if hasNext { _ = nextEpisode() }
  }

  func dismissError() {
    guard errorMessage != nil else { return }
    errorMessage = nil
    uiDelegate?.controllerDidChangeState()
  }

  func retry() {
    reload()
  }

  func reload() {
    errorMessage = nil
    failed = false
    if kernel.positionMs > 0 {
      pendingStartMs = kernel.positionMs
    }
    requestEpisode(lineIndex: line, episodeIndex: episode, refreshDanmaku: false)
  }

  func undoSkip(toMs: Int64) {
    seekTo(max(0, toMs))
  }

  private func showError(_ message: String) {
    guard !isClosed else { return }
    errorMessage = message
    failed = true
    uiDelegate?.controllerDidChangeState()
  }

  private func applyHeadTail() {
    guard let json = request.headTailSectionsJson,
          let data = json.data(using: .utf8),
          let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
    skipRanges.removeAll()
    for obj in arr {
      guard let type = obj["type"] as? String else { continue }
      switch type {
      case "intro":
        if let endMs = (obj["endMs"] as? NSNumber)?.int64Value {
          introEndMs = min(max(0, endMs), Self.maxHeadTailMs)
        }
      case "outro":
        if let beforeMs = (obj["beforeEndMs"] as? NSNumber)?.int64Value {
          outroBeforeEndMs = min(max(0, beforeMs), Self.maxHeadTailMs)
        }
      case "range":
        if let s = (obj["startMs"] as? NSNumber)?.int64Value,
           let e = (obj["endMs"] as? NSNumber)?.int64Value,
           e > s && s >= 0 {
          skipRanges.append((s, e))
        }
      default:
        break
      }
    }
  }

  private func maybeSkipOutro() {
    guard !resolvingSource else { return }
    let pos = kernel.positionMs
    let dur = kernel.durationMs
    guard dur > 0 && state == "playing" else { return }
    for (idx, range) in skipRanges.enumerated() {
      if range.1 <= dur && pos >= range.0 && pos < range.1 && !skippedRangeIndices.contains(idx) {
        skippedRangeIndices.insert(idx)
        let originPos = pos
        kernel.seekTo(range.1)
        if playbackConfig.skipNotice {
          uiDelegate?.controllerDidSkipRange(fromMs: originPos)
        }
        return
      }
    }
    guard !outroDone && outroBeforeEndMs > 0 && outroBeforeEndMs <= Self.maxHeadTailMs else { return }
    guard dur >= Self.minAutoOutroDurationMs && outroBeforeEndMs <= dur / 3 else { return }
    let effIntro = (introEndMs > 0 && introEndMs <= dur / 3) ? introEndMs : 0
    let outroAt = dur - outroBeforeEndMs
    guard outroAt - effIntro >= Self.minMainContentMs else { return }
    guard pos >= outroAt && pos <= dur + 5_000 else {
      outroHitTicks = 0
      return
    }
    outroHitTicks += 1
    guard outroHitTicks >= 2 else { return }
    outroDone = true
    outroHitTicks = 0
    guard hasNext else { return }
    if playbackConfig.skipNotice {
      uiDelegate?.controllerDidShowNotice(IosPlayerUiText.t("已跳过片尾", "Outro skipped"))
    }
    _ = nextEpisode()
  }

  // MARK: - Kernel Delegate

  func kernelDidChangeState(_ nextState: String) {
    if resolvingSource { return }
    state = nextState
    if nextState == "playing" {
      failed = false
      errorMessage = nil
      if autoSkippedIntroThisEpisode {
        let dur = kernel.durationMs
        if dur > 0 {
          autoSkippedIntroThisEpisode = false
          if dur < introEndMs + 60_000 { kernel.seekTo(0) }
        }
      }
    }
    danmakuView.paused = (nextState != "playing")
    NativePlayerHost.shared.syncIdleTimer()
    uiDelegate?.controllerDidChangeState()
    flutterApi.onStateChanged(event: StateEvent(sessionId: request.sessionId, state: nextState)) { _ in }
    updateNowPlayingInfo()
    if nextState == "ended" && !nextEpisode() {
      requestSmoothDismissOrClose(completed: true)
    }
  }

  func kernelDidFail(message: String, code: Int?) {
    flutterApi.onErrorReported(
      report: ErrorReport(sessionId: request.sessionId, message: message, fatal: false, code: code.map { Int64($0) })
    ) { _ in }
    showError(message)
  }

  func kernelDidUpdateSubtitleCue(_ text: String?) {
    uiDelegate?.controllerDidUpdateSubtitleCue(text)
  }

  func kernelDidUpdateMetrics() {
    let kSize = effectiveDisplayVideoSize
    if !resolvingSource && kSize.width > 0 && kSize.height > 0 && kSize != lastReportedDecodedSize {
      lastReportedDecodedSize = kSize
      flutterApi.onVideoSizeDetected(
        sessionId: request.sessionId,
        lineIndex: Int64(line),
        episodeIndex: Int64(episode),
        width: Int64(kSize.width.rounded()),
        height: Int64(kSize.height.rounded())
      ) { _ in }
    }
    uiDelegate?.controllerDidUpdateMetrics()
  }

  func kernelDidFallbackNotice(_ message: String) {
    uiDelegate?.controllerDidShowToast(message, long: true)
  }

  func kernelPictureInPictureDidStart(origin: IosPipOrigin) {
    uiDelegate?.controllerPictureInPictureDidStart(origin: origin)
  }

  func kernelPictureInPictureDidPauseInBackground() {
    state = "paused"
    danmakuView.paused = true
    updateNowPlayingInfo(force: true)
    uiDelegate?.controllerDidPauseFromBackgroundPiPClose()
  }

  func syncNowPlayingAfterBackgroundPause() {
    updateNowPlayingInfo(force: true)
    uiDelegate?.controllerDidChangeState()
  }

  func kernelPictureInPictureDidCloseSession() {
    // PiP closed in non-auto-background scenarios: completely close the player page & session
    requestSmoothDismissOrClose(completed: false)
  }

  func kernelPictureInPictureRestoreUI(completion: @escaping (Bool) -> Void) {
    if let delegate = uiDelegate {
      delegate.controllerRequestRestorePiP(completion: completion)
    } else {
      completion(true)
    }
  }

  // MARK: - Lock Screen & Dynamic Island (MPNowPlayingInfoCenter)

  private func setupRemoteTransportControls() {
    guard !remoteCommandsRegistered else { return }
    remoteCommandsRegistered = true
    let cc = MPRemoteCommandCenter.shared()
    cc.playCommand.isEnabled = true
    cc.playCommand.addTarget { [weak self] _ in
      guard let self = self else { return .commandFailed }
      if (self.kernel.isUsingMpv || IosPlayerUiText.normalizeIosKernel(self.playbackConfig.kernel) == "mpv")
        && UIApplication.shared.applicationState == .background {
        self.kernel.pause()
        self.updateNowPlayingInfo(force: true)
        return .commandFailed
      }
      self.kernel.play()
      return .success
    }
    cc.pauseCommand.isEnabled = true
    cc.pauseCommand.addTarget { [weak self] _ in
      self?.kernel.pause()
      return .success
    }
    cc.togglePlayPauseCommand.isEnabled = true
    cc.togglePlayPauseCommand.addTarget { [weak self] _ in
      guard let self = self else { return .commandFailed }
      if (self.kernel.isUsingMpv || IosPlayerUiText.normalizeIosKernel(self.playbackConfig.kernel) == "mpv")
        && UIApplication.shared.applicationState == .background {
        self.kernel.pause()
        self.updateNowPlayingInfo(force: true)
        return .commandFailed
      }
      self.togglePause()
      return .success
    }
    cc.nextTrackCommand.isEnabled = true
    cc.nextTrackCommand.addTarget { [weak self] _ in
      guard let self = self else { return .commandFailed }
      return self.nextEpisode() ? .success : .noSuchContent
    }
    cc.previousTrackCommand.isEnabled = true
    cc.previousTrackCommand.addTarget { [weak self] _ in
      guard let self = self else { return .commandFailed }
      return self.previousEpisode() ? .success : .noSuchContent
    }
    cc.changePlaybackPositionCommand.isEnabled = true
    cc.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self = self, let posEv = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      self.seekTo(Int64(posEv.positionTime * 1000.0))
      return .success
    }
  }

  private func clearRemoteTransportControls() {
    guard remoteCommandsRegistered else { return }
    remoteCommandsRegistered = false
    let cc = MPRemoteCommandCenter.shared()
    cc.playCommand.removeTarget(nil)
    cc.pauseCommand.removeTarget(nil)
    cc.togglePlayPauseCommand.removeTarget(nil)
    cc.nextTrackCommand.removeTarget(nil)
    cc.previousTrackCommand.removeTarget(nil)
    cc.changePlaybackPositionCommand.removeTarget(nil)
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private func updateNowPlayingInfo(force: Bool = false) {
    guard !isClosed else { return }
    let pos = kernel.positionMs
    let dur = kernel.durationMs
    let rate = kernel.isPlaying ? currentSpeed : 0.0
    let ep = episodeName ?? ""
    let sig = "\(title)|\(ep)|\(dur)|\(String(format: "%.2f", rate))"
    if !force && sig == lastNowPlayingSignature && abs(pos - lastNowPlayingPosMs) < 5000 {
      return
    }
    lastNowPlayingSignature = sig
    lastNowPlayingPosMs = pos

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(pos) / 1000.0,
      MPNowPlayingInfoPropertyPlaybackRate: rate
    ]
    if !ep.isEmpty {
      info[MPMediaItemPropertyAlbumTitle] = ep
    }
    if dur > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = Double(dur) / 1000.0
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  // MARK: - Teardown

  private func requestSmoothDismissOrClose(completed: Bool) {
    guard !isClosed else { return }
    if Thread.isMainThread {
      if !onDismissPage(completed) {
        close(completed: completed, dismissVC: false)
      }
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self = self, !self.isClosed else { return }
        if !self.onDismissPage(completed) {
          self.close(completed: completed, dismissVC: false)
        }
      }
    }
  }

  func close(completed: Bool = false, dismissVC: Bool = true) {
    guard !isClosed else { return }
    isClosed = true
    heartbeatTimer?.invalidate()
    heartbeatTimer = nil
    danmakuView.stopDisplayLink()
    let finalPosSec = Double(kernel.positionMs) / 1000.0
    clearRemoteTransportControls()
    kernel.releaseKernel()
    NativePlayerHost.shared.didClose(controller: self)
    flutterApi.onPageClosed(
      event: PageClosedEvent(sessionId: request.sessionId, positionSeconds: finalPosSec, completed: completed)
    ) { _ in }
    if dismissVC {
      _ = onDismissPage(completed)
    }
  }
}
