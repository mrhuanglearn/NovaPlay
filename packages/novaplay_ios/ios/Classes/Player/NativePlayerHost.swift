import Flutter
import os
import UIKit

private let hostOrientLog = Logger(subsystem: "app.novaplay.player", category: "orient")

/// Singleton bridge implementing Pigeon `NativePlayerHostApi` (Dart -> Swift) on iOS 15+.
final class NativePlayerHost: NativePlayerHostApi {
  static let shared = NativePlayerHost()

  private var flutterApi: NativePlayerFlutterApi?
  private var activeController: IosPlayerController?
  private var activeViewController: NativePlayerViewController?
  private weak var pendingForegroundDismissVC: UIViewController?
  private var pipWindowHostView: UIView?
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var openSerial = 0

  private init() {
    let nc = NotificationCenter.default
    let fgObs = nc.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      if let staleVC = self.pendingForegroundDismissVC {
        self.pendingForegroundDismissVC = nil
        if staleVC.presentingViewController != nil {
          staleVC.dismiss(animated: false)
        }
      }
      self.syncIdleTimer(forceReassert: true)
    }
    let activeObs = nc.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.syncIdleTimer(forceReassert: true)
    }
    let bgObs = nc.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.syncIdleTimer()
    }
    lifecycleObservers = [fgObs, activeObs, bgObs]
  }

  func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    NativePlayerHostApiSetup.setUp(binaryMessenger: messenger, api: self)
    flutterApi = NativePlayerFlutterApi(binaryMessenger: messenger)
  }

  /// Keeps `AVPlayerLayer` attached to a `UIWindow` while `NativePlayerViewController` is dismissed for in-app PiP.
  func parkVideoViewForInAppPiP(_ videoView: UIView) {
    guard let window = Self.keyWindow() else { return }
    let host: UIView
    if let existing = pipWindowHostView, existing.window === window {
      host = existing
    } else {
      pipWindowHostView?.removeFromSuperview()
      let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
      v.alpha = 0.01
      v.clipsToBounds = true
      v.isUserInteractionEnabled = false
      window.insertSubview(v, at: 0)
      pipWindowHostView = v
      host = v
    }
    videoView.removeFromSuperview()
    videoView.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(videoView)
    NSLayoutConstraint.activate([
      videoView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      videoView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      videoView.topAnchor.constraint(equalTo: host.topAnchor),
      videoView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
    ])
  }

  func removeParkedVideoViewHost() {
    pipWindowHostView?.removeFromSuperview()
    pipWindowHostView = nil
  }

  func didClose(controller: IosPlayerController) {
    if activeController === controller {
      removeParkedVideoViewHost()
      activeController = nil
      activeViewController = nil
    }
    syncIdleTimer()
  }

  /// Keeps iOS screen awake across all three kernels (`AVPlayer`, `MPV` `CAMetalLayer`, `MobileVLCKit`)
  /// whenever the fullscreen player is presented or in-app PiP is actively playing/buffering, and reliably
  /// restores `isIdleTimerDisabled = false` on session close or backgrounding.
  func syncIdleTimer(forceReassert: Bool = false) {
    let apply = { [weak self] in
      guard let self = self else { return }
      let appActive = UIApplication.shared.applicationState == .active
      let shouldKeepAwake: Bool
      if !appActive {
        shouldKeepAwake = false
      } else if let ctrl = self.activeController, !ctrl.isClosed {
        let vcVisible = self.activeViewController.map { !$0.isDismissedForPiP && !$0.isBeingDismissed } ?? false
        let activelyPlayingOrBuffering = ctrl.kernel.isPlaying || ctrl.state == "playing" || ctrl.state == "buffering"
        shouldKeepAwake = vcVisible || activelyPlayingOrBuffering
      } else {
        shouldKeepAwake = false
      }
      if shouldKeepAwake {
        if forceReassert && UIApplication.shared.isIdleTimerDisabled {
          UIApplication.shared.isIdleTimerDisabled = false
        }
        if !UIApplication.shared.isIdleTimerDisabled {
          UIApplication.shared.isIdleTimerDisabled = true
        }
      } else if UIApplication.shared.isIdleTimerDisabled {
        UIApplication.shared.isIdleTimerDisabled = false
      }
    }
    if Thread.isMainThread {
      apply()
    } else {
      DispatchQueue.main.async(execute: apply)
    }
  }

  func forceStopAll() {
    DispatchQueue.main.async { [weak self] in
      self?.activeController?.close(completed: false, dismissVC: true)
    }
  }

  func openPlayerPage(request: OpenPlayerRequest, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let api = flutterApi else {
      completion(.failure(PigeonError(code: "not_registered", message: "NativePlayerFlutterApi not initialized", details: nil)))
      return
    }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else {
        completion(.success(()))
        return
      }
      self.openSerial += 1
      let serial = self.openSerial
      // Cleanly close any existing session (e.g. a leftover PiP session) before opening the new one
      if let prevVC = self.activeViewController, prevVC.presentingViewController != nil {
        prevVC.dismiss(animated: false)
      }
      if let prev = self.activeController, !prev.isClosed {
        prev.close(completed: false, dismissVC: false)
      }
      self.removeParkedVideoViewHost()
      self.pendingForegroundDismissVC = nil

      let kernel = IosPlayerKernel(
        requestedKernel: request.playbackConfig.kernel,
        hwDecode: request.playbackConfig.hwDecode
      )
      let danmakuView = IosDanmakuView(frame: .zero)
      weak var vcWeakRef: NativePlayerViewController?

      let controller = IosPlayerController(
        request: request,
        kernel: kernel,
        danmakuView: danmakuView,
        flutterApi: api,
        onDismissPage: { [weak self] in
          DispatchQueue.main.async {
            guard let vc = vcWeakRef else { return }
            if vc.presentingViewController != nil {
              let isActive = UIApplication.shared.applicationState == .active
              if !isActive {
                self?.pendingForegroundDismissVC = vc
                vc.dismiss(animated: false)
              } else if !vc.isExitingPlayer {
                vc.exitPlayerSmoothly(completed: true)
              }
            }
          }
        }
      )
      self.activeController = controller
      self.activeViewController = nil

      let mode = IosPlayerUiText.effectiveOrientationMode(request.playbackConfig)
      let isPhone = UIDevice.current.userInterfaceIdiom == .phone
      let initialSource = request.initialSource
      let knownSize: CGSize? = {
        if let w = initialSource?.videoWidth, let h = initialSource?.videoHeight, w > 0, h > 0 {
          return CGSize(width: CGFloat(w), height: CGFloat(h))
        }
        if let w = request.initialVideoWidth, let h = request.initialVideoHeight, w > 0, h > 0 {
          return CGSize(width: CGFloat(w), height: CGFloat(h))
        }
        return nil
      }()

      var launched = false
      func presentWith(size: CGSize?, aborted: Bool = false) {
        guard !launched else { return }
        launched = true
        guard !aborted, serial == self.openSerial, !controller.isClosed else {
          if aborted && !controller.isClosed {
            controller.close(completed: false, dismissVC: false)
          }
          completion(.success(()))
          return
        }
        let initialLandscape: Bool
        switch mode {
        case "landscape": initialLandscape = true
        case "portrait": initialLandscape = false
        default: initialLandscape = !isPhone ? true : (size.map { $0.width >= $0.height } ?? true)
        }
        var effectiveSource = initialSource
        if let s = size {
          controller.seedInitialProbedSize(s)
          if var src = effectiveSource, src.videoWidth == nil {
            src.videoWidth = Int64(s.width)
            src.videoHeight = Int64(s.height)
            effectiveSource = src
          }
        }
        let sizeDesc = size.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil"
        hostOrientLog.notice(
          "[NovaPlay][Orient] open mode=\(mode, privacy: .public) initialLandscape=\(initialLandscape, privacy: .public) size=\(sizeDesc, privacy: .public) hasInitialSource=\(effectiveSource != nil, privacy: .public)"
        )

        let playerVC = NativePlayerViewController(
          controller: controller,
          initialLandscape: initialLandscape
        )
        playerVC.modalPresentationStyle = .fullScreen
        playerVC.modalTransitionStyle = .crossDissolve
        vcWeakRef = playerVC
        self.activeViewController = playerVC

        guard let presenter = Self.topViewController() else {
          controller.close(completed: false, dismissVC: false)
          completion(.success(()))
          return
        }
        presenter.present(playerVC, animated: true) { [weak self] in
          self?.syncIdleTimer(forceReassert: true)
        }
        if let src = effectiveSource {
          controller.start(withInitialSource: src)
        } else {
          controller.start()
        }
        self.syncIdleTimer()
        completion(.success(()))
      }

      let budgetMs = min(max(Int64(0), request.probeBudgetMs ?? 0), 260)
      let trimmedUrl = initialSource?.url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let canFastProbe = mode == "auto"
        && isPhone
        && budgetMs > 0
        && request.epgProgrammes == nil
        && knownSize == nil
        && initialSource?.success == true
        && !trimmedUrl.isEmpty

      guard canFastProbe else {
        presentWith(size: knownSize)
        return
      }

      let forwardedHeaders = initialSource?.headers ?? [:]
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(budgetMs) + 30)) {
        presentWith(size: nil)
      }
      api.onProbeVideoSize(
        sessionId: request.sessionId,
        lineIndex: request.startLineIndex,
        episodeIndex: request.startEpisodeIndex,
        url: trimmedUrl,
        headers: forwardedHeaders,
        budgetMs: budgetMs
      ) { res in
        DispatchQueue.main.async {
          if case .success(let maybeSize) = res, let p = maybeSize {
            if p.width < 0 {
              presentWith(size: nil, aborted: true)
            } else if p.width > 0 && p.height > 0 {
              presentWith(size: CGSize(width: CGFloat(p.width), height: CGFloat(p.height)))
            } else {
              presentWith(size: nil)
            }
          } else {
            presentWith(size: nil)
          }
        }
      }
    }
  }

  func provideSource(payload: SourcePayload) throws {
    activeController?.onSource(payload)
  }

  func updateVideoSize(sessionId: String, lineIndex: Int64, episodeIndex: Int64, width: Int64, height: Int64) throws {
    activeController?.onProbedVideoSize(
      sessionId: sessionId,
      lineIndex: Int(lineIndex),
      episodeIndex: Int(episodeIndex),
      width: Int(width),
      height: Int(height)
    )
  }

  func updateDanmaku(payload: DanmakuPayload) throws {
    activeController?.onDanmaku(payload)
  }

  func updateLineTmdbMatches(sessionId: String, matches: [TmdbEpisodeItem]) throws {
    activeController?.onTmdbMatches(matches)
  }

  func updateRuntimeConfig(sessionId: String, patch: RuntimeConfigPatch) throws {
    activeController?.onRuntimeConfig(patch)
  }

  func provideDanmakuSearchResults(sessionId: String, results: [DanmakuSearchResultItem]) throws {
    activeController?.onDanmakuSearchResults(results)
  }

  func provideDanmakuEpisodesResults(sessionId: String, episodes: [EpisodeItem]) throws {
    activeController?.onDanmakuEpisodes(episodes)
  }

  func showToast(message: String, long: Bool) throws -> Bool {
    guard let ctrl = activeController, !ctrl.isClosed else { return false }
    ctrl.toast(message, long: long)
    return true
  }

  static func keyWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    return activeScene?.windows.first(where: { $0.isKeyWindow }) ?? activeScene?.windows.first
  }

  static func topViewController() -> UIViewController? {
    guard let root = keyWindow()?.rootViewController else {
      return nil
    }
    var top = root
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }
}
