import Foundation
import Network
import UIKit
#if canImport(CoreTelephony)
import CoreTelephony
#endif

/// First-install first-launch network permission prompts for iOS.
///
/// Sequences:
///   1. Wireless Data prompt (WLAN / WLAN & Cellular, triggered on CH/A iPhones via CoreTelephony + captive portal HEAD).
///   2. Local Network prompt (triggered via entitlement-free Bonjour `_http._tcp` NWBrowser after Wireless Data finishes).
///
/// Gated by sandboxed `UserDefaults` flags so uninstalling and reinstalling triggers it again once on first open,
/// while subsequent launches return immediately.
final class IosFirstLaunchPermissions {
  static let shared = IosFirstLaunchPermissions()

  private static let wirelessKey = "uzv.ios.firstLaunchWirelessPrompted.v1"
  private static let localNetKey = "uzv.ios.firstLaunchLocalNetPrompted.v1"

  private enum Phase {
    case idle
    case waitingForWireless
    case waitingAfterWireless
    case waitingForLocalNet
    case probingLocalNet
    case finished
  }

  private var phase: Phase = .idle
  private var sawSystemAlertResign = false
  private var observers: [NSObjectProtocol] = []
  private var browser: NWBrowser?
  #if canImport(CoreTelephony)
  private var cellularData: CTCellularData?
  #endif

  private init() {}

  func startIfNeeded() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.startIfNeeded()
      }
      return
    }
    guard phase == .idle else { return }

    let defaults = UserDefaults.standard
    let wirelessDone = defaults.bool(forKey: Self.wirelessKey)
    let localNetDone = defaults.bool(forKey: Self.localNetKey)
    if wirelessDone && localNetDone {
      phase = .finished
      return
    }

    let nc = NotificationCenter.default
    observers.append(
      nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
        self?.handleWillResignActive()
      }
    )
    observers.append(
      nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
        self?.handleDidBecomeActive()
      }
    )

    if !wirelessDone {
      phase = .waitingForWireless
      if UIApplication.shared.applicationState == .active {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
          self?.tryStartWirelessProbe()
        }
      }
    } else {
      phase = .waitingForLocalNet
      if UIApplication.shared.applicationState == .active {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
          self?.tryStartLocalNetworkProbe()
        }
      }
    }
  }

  private func handleWillResignActive() {
    if phase == .waitingAfterWireless {
      sawSystemAlertResign = true
    }
  }

  private func handleDidBecomeActive() {
    switch phase {
    case .waitingForWireless:
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
        self?.tryStartWirelessProbe()
      }
    case .waitingAfterWireless:
      phase = .waitingForLocalNet
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.tryStartLocalNetworkProbe()
      }
    case .waitingForLocalNet:
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        self?.tryStartLocalNetworkProbe()
      }
    default:
      break
    }
  }

  private func tryStartWirelessProbe() {
    guard phase == .waitingForWireless, UIApplication.shared.applicationState == .active else { return }
    UserDefaults.standard.set(true, forKey: Self.wirelessKey)
    sawSystemAlertResign = false
    phase = .waitingAfterWireless

    #if canImport(CoreTelephony)
    let cd = CTCellularData()
    self.cellularData = cd
    cd.cellularDataRestrictionDidUpdateNotifier = { _ in }
    #endif

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 6
    config.timeoutIntervalForResource = 6
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config)
    if let url = URL(string: "https://captive.apple.com/hotspot-detect.html") {
      var req = URLRequest(url: url)
      req.httpMethod = "HEAD"
      session.dataTask(with: req) { _, _, _ in
        session.finishTasksAndInvalidate()
      }.resume()
    } else {
      session.finishTasksAndInvalidate()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
      guard let self = self else { return }
      if self.phase == .waitingAfterWireless,
         !self.sawSystemAlertResign,
         UIApplication.shared.applicationState == .active {
        self.phase = .waitingForLocalNet
        self.tryStartLocalNetworkProbe()
      }
    }
  }

  private func tryStartLocalNetworkProbe() {
    guard phase == .waitingForLocalNet, UIApplication.shared.applicationState == .active else { return }
    UserDefaults.standard.set(true, forKey: Self.localNetKey)
    phase = .probingLocalNet

    let newBrowser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: NWParameters())
    self.browser = newBrowser
    newBrowser.browseResultsChangedHandler = { _, _ in }
    newBrowser.stateUpdateHandler = { [weak self] state in
      switch state {
      case .ready:
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
          self?.finish()
        }
      case .failed, .cancelled:
        self?.finish()
      default:
        break
      }
    }
    newBrowser.start(queue: .main)

    DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) { [weak self] in
      self?.finish()
    }
  }

  private func finish() {
    guard phase != .finished else { return }
    phase = .finished
    browser?.cancel()
    browser = nil
    #if canImport(CoreTelephony)
    cellularData?.cellularDataRestrictionDidUpdateNotifier = nil
    cellularData = nil
    #endif
    let nc = NotificationCenter.default
    for token in observers {
      nc.removeObserver(token)
    }
    observers.removeAll()
  }
}
