import Flutter
import UIKit

/// Singleton bridge implementing Pigeon `NativePlayerHostApi` (Dart -> Swift) on iOS 15+.
final class NativePlayerHost: NativePlayerHostApi {
  static let shared = NativePlayerHost()

  private var flutterApi: NativePlayerFlutterApi?
  private var activeController: IosPlayerController?
  private var activeViewController: NativePlayerViewController?
  private weak var pendingForegroundDismissVC: UIViewController?
  private var pipWindowHostView: UIView?
  private var fgObserver: NSObjectProtocol?

  private init() {
    fgObserver = NotificationCenter.default.addObserver(
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
    }
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
  }

  func forceStopAll() {
    DispatchQueue.main.async { [weak self] in
      self?.activeController?.close(completed: false, dismissVC: true)
    }
  }

  func openPlayerPage(request: OpenPlayerRequest) throws {
    guard let api = flutterApi else {
      throw PigeonError(code: "not_registered", message: "NativePlayerFlutterApi not initialized", details: nil)
    }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      // Cleanly close any existing session (e.g. a leftover PiP session) before presenting the new one
      if let prev = self.activeController, !prev.isClosed {
        prev.close(completed: false, dismissVC: true)
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
              }
              vc.dismiss(animated: isActive)
            }
          }
        }
      )

      let playerVC = NativePlayerViewController(controller: controller)
      playerVC.modalPresentationStyle = .fullScreen
      playerVC.modalTransitionStyle = .crossDissolve
      vcWeakRef = playerVC

      self.activeController = controller
      self.activeViewController = playerVC

      guard let presenter = Self.topViewController() else {
        controller.close(completed: false, dismissVC: false)
        return
      }
      presenter.present(playerVC, animated: true) {
        controller.start()
      }
    }
  }

  func provideSource(payload: SourcePayload) throws {
    activeController?.onSource(payload)
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
