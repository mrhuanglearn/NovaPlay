import Flutter
import UIKit

/// Singleton bridge implementing Pigeon `NativePlayerHostApi` (Dart -> Swift) on iOS 15+.
final class NativePlayerHost: NativePlayerHostApi {
  static let shared = NativePlayerHost()

  private var flutterApi: NativePlayerFlutterApi?
  private weak var activeController: IosPlayerController?
  private weak var activeViewController: NativePlayerViewController?

  private init() {}

  func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    NativePlayerHostApiSetup.setUp(binaryMessenger: messenger, api: self)
    flutterApi = NativePlayerFlutterApi(binaryMessenger: messenger)
  }

  func didClose(controller: IosPlayerController) {
    if activeController === controller {
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

      let kernel = IosPlayerKernel(
        requestedKernel: request.playbackConfig.kernel,
        hwDecode: request.playbackConfig.hwDecode
      )
      let danmakuView = IosDanmakuView(frame: .zero)
      var vcRef: NativePlayerViewController?

      let controller = IosPlayerController(
        request: request,
        kernel: kernel,
        danmakuView: danmakuView,
        flutterApi: api,
        onDismissPage: {
          DispatchQueue.main.async {
            if let vc = vcRef, vc.presentingViewController != nil {
              vc.dismiss(animated: true)
            }
          }
        }
      )

      let playerVC = NativePlayerViewController(controller: controller)
      playerVC.modalPresentationStyle = .fullScreen
      playerVC.modalTransitionStyle = .crossDissolve
      vcRef = playerVC

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

  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    guard let root = activeScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? activeScene?.windows.first?.rootViewController else {
      return nil
    }
    var top = root
    while let presented = top.presentedViewController, !presented.isBeingDismissed {
      top = presented
    }
    return top
  }
}
