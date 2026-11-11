import Flutter
import UIKit

@objc(NovaPlayIosPlugin)
public class NovaPlayIosPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()

    // 1. Taptic Engine haptics bridge ("设置" -> "功能设置" -> "触感反馈")
    let hapticsChannel = FlutterMethodChannel(name: "uzv/haptics", binaryMessenger: messenger)
    hapticsChannel.setMethodCallHandler { call, result in
      IosHaptics.play(kind: call.method)
      result(nil)
    }

    // 2. App process exit bridge (used after backup restore / app reset so singleton runtimes restart cleanly)
    let appChannel = FlutterMethodChannel(name: "uzv/app", binaryMessenger: messenger)
    appChannel.setMethodCallHandler { call, result in
      guard call.method == "exit" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(nil)
      NativePlayerHost.shared.forceStopAll()
      UserDefaults.standard.synchronize()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        Darwin.exit(0)
      }
    }

    // 3. Embedded Node.js (CatPaw spider host) loopback TCP bridge
    NodeBridgePlugin.register(with: registrar)

    // 4. Pigeon NativePlayerHostApi & NativePlayerFlutterApi
    NativePlayerHost.shared.register(with: registrar)
  }
}

enum IosHaptics {
  static func play(kind: String) {
    let fire = {
      switch kind {
      case "selection":
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        gen.selectionChanged()
      case "heavy":
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.prepare()
        gen.impactOccurred()
      case "medium":
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.prepare()
        gen.impactOccurred()
      default:
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred()
      }
    }
    if Thread.isMainThread {
      fire()
    } else {
      DispatchQueue.main.async(execute: fire)
    }
  }
}
