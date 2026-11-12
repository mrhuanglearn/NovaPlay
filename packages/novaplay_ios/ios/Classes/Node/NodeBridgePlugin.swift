import Darwin
import Flutter
import Foundation
import os
import Security

private let nodeUsbLog = Logger(subsystem: "app.novaplay.player", category: "node")
private let dartUsbLog = Logger(subsystem: "app.novaplay.player", category: "dart")

private enum NodeUsbLogRedactor {
  private static let credRegex = try? NSRegularExpression(pattern: #"://[^/@\s]+@"#, options: [])

  static func sanitize(_ raw: String, maxLen: Int = 400) -> String {
    let singleLine = raw
      .replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
    let ns = singleLine as NSString
    let redacted: String
    if let rx = credRegex {
      redacted = rx.stringByReplacingMatches(
        in: singleLine,
        options: [],
        range: NSRange(location: 0, length: ns.length),
        withTemplate: "://***@"
      )
    } else {
      redacted = singleLine
    }
    if redacted.count <= maxLen {
      return redacted
    }
    return String(redacted.prefix(maxLen)) + "…"
  }
}

/// iOS counterpart of Android's `NodeBridgePlugin.kt`:
/// - `MethodChannel("uzv/node")`: `start()` and `send(channel, message)`
/// - `EventChannel("uzv/node/events")`: `{"channel": String, "message": String}` maps
final class NodeBridgePlugin: NSObject, FlutterStreamHandler {
  private let registrar: FlutterPluginRegistrar
  private var sink: FlutterEventSink?

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NodeBridgePlugin(registrar: registrar)
    let messenger = registrar.messenger()
    let method = FlutterMethodChannel(name: "uzv/node", binaryMessenger: messenger)
    method.setMethodCallHandler { [weak instance] call, result in
      instance?.handle(call, result: result)
    }
    let events = FlutterEventChannel(name: "uzv/node/events", binaryMessenger: messenger)
    events.setStreamHandler(instance)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      do {
        NodeHostIos.shared.attach(self)
        try NodeHostIos.shared.start(registrar: registrar)
        result(nil)
      } catch {
        result(FlutterError(code: "node_start_failed", message: error.localizedDescription, details: nil))
      }
    case "send":
      guard let args = call.arguments as? [String: Any],
            let channel = args["channel"] as? String,
            let message = args["message"] as? String else {
        result(FlutterError(code: "bad_args", message: "Missing channel or message", details: nil))
        return
      }
      let payload: [String: String] = ["c": channel, "m": message]
      guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
            var lineData = String(data: data, encoding: .utf8)?.appending("\n").data(using: .utf8) else {
        result(FlutterError(code: "encode_failed", message: "Could not encode frame", details: nil))
        return
      }
      NodeHostIos.shared.send(&lineData) { failure in
        DispatchQueue.main.async {
          if let (code, msg) = failure {
            result(FlutterError(code: code, message: msg, details: nil))
          } else {
            result(nil)
          }
        }
      }
    case "log":
      if let args = call.arguments as? [String: Any],
         let rawMsg = args["message"] as? String,
         !rawMsg.isEmpty {
        let safe = NodeUsbLogRedactor.sanitize(rawMsg)
        dartUsbLog.notice("[NovaPlay][Dart] \(safe, privacy: .public)")
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func deliver(_ event: [String: String]) {
    DispatchQueue.main.async { [weak self] in
      self?.sink?(event)
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    NodeHostIos.shared.attach(self)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    NodeHostIos.shared.detach(self)
    return nil
  }
}

private final class NodeHostIos {
  static let shared = NodeHostIos()

  private let lock = NSLock()
  private weak var listener: NodeBridgePlugin?
  private var clientFd: Int32 = -1
  private var started = false
  private var readyLine: String?
  private var firstFailure: String?
  private let sendQueue = DispatchQueue(label: "app.novaplay.node.send")
  private let token: String = {
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return bytes.map { String(format: "%02x", $0) }.joined()
  }()

  func attach(_ plugin: NodeBridgePlugin) {
    lock.lock()
    listener = plugin
    lock.unlock()
  }

  func detach(_ plugin: NodeBridgePlugin) {
    lock.lock()
    if listener === plugin {
      listener = nil
    }
    lock.unlock()
  }

  private func emit(channel: String, message: String) {
    lock.lock()
    let target = listener
    lock.unlock()
    target?.deliver(["channel": channel, "message": message])
  }

  private func emitStatus(_ line: String) {
    let safe = NodeUsbLogRedactor.sanitize(line)
    nodeUsbLog.notice("[NovaPlay][Node] \(safe, privacy: .public)")
    emit(channel: "status", message: line)
  }

  func start(registrar: FlutterPluginRegistrar) throws {
    lock.lock()
    if started {
      let replay = readyLine
      lock.unlock()
      if let replay = replay {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
          self?.emitStatus(replay)
        }
      }
      return
    }
    started = true
    readyLine = nil
    lock.unlock()

    let projectDir: URL
    do {
      projectDir = try NodeAssetsIos.install(registrar: registrar)
    } catch {
      lock.lock()
      started = false
      lock.unlock()
      throw error
    }

    let (srvFd, port) = try openLoopbackServer()
    let dataDir = try prepareDataDirectory()
    let mainJsPath = projectDir.appendingPathComponent("src/main.js").path

    Thread.detachNewThread { [weak self] in
      self?.acceptLoop(srvFd: srvFd)
    }

    Thread.detachNewThread { [weak self] in
      guard let self = self else { return }
      let args = [
        "node",
        "--jitless",
        mainJsPath,
        "--bridge-port=\(port)",
        "--bridge-token=\(self.token)",
        "--data-dir=\(dataDir)"
      ]
      let portStr = String(port)
      var errBuf = [CChar](repeating: 0, count: 512)

      let cDup: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
      defer {
        for ptr in cDup {
          if let ptr = ptr { free(ptr) }
        }
      }
      let constPtrs: [UnsafePointer<CChar>?] = cDup.map { UnsafePointer($0) }
      let rc: Int32 = constPtrs.withUnsafeBufferPointer { argvBuf in
        portStr.withCString { portCStr in
          self.token.withCString { tokenCStr in
            dataDir.withCString { dataCStr in
              uzv_ios_start_node(
                Int32(args.count),
                argvBuf.baseAddress,
                portCStr,
                tokenCStr,
                dataCStr,
                &errBuf,
                Int32(errBuf.count)
              )
            }
          }
        }
      }

      if rc < 0 {
        let detail = String(cString: errBuf)
        self.lock.lock()
        self.started = false
        let reason = detail.isEmpty ? (self.firstFailure ?? "start code \(rc)") : detail
        if self.firstFailure == nil { self.firstFailure = reason }
        self.lock.unlock()
        Darwin.close(srvFd)
        self.emitStatus("Node runtime failed: \(reason)")
        return
      }

      self.lock.lock()
      self.readyLine = nil
      self.lock.unlock()
      self.emitStatus("Node runtime exited with code \(rc)")
    }
  }

  func send(_ data: inout Data, done: @escaping ((String, String)?) -> Void) {
    let copy = data
    sendQueue.async { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      let fd = self.clientFd
      self.lock.unlock()
      guard fd >= 0 else {
        done(("not_connected", "Node runtime is not connected"))
        return
      }
      let failure: (String, String)? = copy.withUnsafeBytes { rawBuf in
        guard let base = rawBuf.baseAddress else { return nil }
        var written = 0
        while written < rawBuf.count {
          let n = Darwin.write(fd, base.advanced(by: written), rawBuf.count - written)
          if n <= 0 {
            return ("send_failed", String(cString: strerror(errno)))
          }
          written += n
        }
        return nil
      }
      done(failure)
    }
  }

  private func openLoopbackServer() throws -> (Int32, UInt16) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
    }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindRc = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        Darwin.bind(fd, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if bindRc != 0 {
      let code = Int(errno)
      Darwin.close(fd)
      throw NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "bind(127.0.0.1) failed"])
    }
    if Darwin.listen(fd, 1) != 0 {
      let code = Int(errno)
      Darwin.close(fd)
      throw NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
    }

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameRc = withUnsafeMutablePointer(to: &bound) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        Darwin.getsockname(fd, saPtr, &len)
      }
    }
    if nameRc != 0 {
      let code = Int(errno)
      Darwin.close(fd)
      throw NSError(domain: NSPOSIXErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "getsockname() failed"])
    }
    return (fd, UInt16(bigEndian: bound.sin_port))
  }

  private func acceptLoop(srvFd: Int32) {
    let connFd = Darwin.accept(srvFd, nil, nil)
    Darwin.close(srvFd)
    guard connFd >= 0 else { return }

    var noSigPipe: Int32 = 1
    setsockopt(connFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    defer {
      lock.lock()
      if clientFd == connFd { clientFd = -1 }
      readyLine = nil
      lock.unlock()
      Darwin.close(connFd)
    }

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    var handshakeVerified = false

    while true {
      let n = Darwin.read(connFd, &chunk, chunk.count)
      if n <= 0 { break }
      buffer.append(contentsOf: chunk[0..<n])

      while let nlIndex = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer.subdata(in: 0..<nlIndex)
        buffer.removeSubrange(0...nlIndex)
        if lineData.isEmpty { continue }

        guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else {
          if !handshakeVerified { return }
          continue
        }

        if !handshakeVerified {
          guard (obj["hello"] as? String) == token else { return }
          handshakeVerified = true
          lock.lock()
          clientFd = connFd
          lock.unlock()
          continue
        }

        guard let channel = obj["c"] as? String,
              let message = obj["m"] as? String else { continue }
        if channel == "status" {
          if message.hasPrefix("Node ready") {
            lock.lock()
            readyLine = message
            lock.unlock()
          }
          if !message.hasPrefix("[log]") && (
            message.hasPrefix("Node ") ||
            message.hasPrefix("catpaw") ||
            message.hasPrefix("error:") ||
            message.hasPrefix("rejection:") ||
            message.contains("[redirect]")
          ) {
            let safe = NodeUsbLogRedactor.sanitize(message)
            nodeUsbLog.notice("[NovaPlay][Node] \(safe, privacy: .public)")
          }
        } else if channel == "catpaw",
                  let msgData = message.data(using: .utf8),
                  let ev = (try? JSONSerialization.jsonObject(with: msgData)) as? [String: Any],
                  let evType = ev["type"] as? String {
          if evType == "port", let p = ev["port"] as? Int {
            nodeUsbLog.notice("[NovaPlay][Node] catpaw worker port=\(p, privacy: .public)")
          } else if evType == "result" {
            let act = (ev["action"] as? String) ?? "-"
            let ok = (ev["ok"] as? Bool) ?? false
            let errRaw = (ev["error"] as? String) ?? "-"
            let errSafe = NodeUsbLogRedactor.sanitize(errRaw, maxLen: 200)
            nodeUsbLog.notice(
              "[NovaPlay][Node] catpaw result action=\(act, privacy: .public) ok=\(ok, privacy: .public) err=\(errSafe, privacy: .public)"
            )
          }
        }
        emit(channel: channel, message: message)
      }
    }
  }

  private func prepareDataDirectory() throws -> String {
    let fm = FileManager.default
    let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var dir = base.appendingPathComponent("node-data", isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var rv = URLResourceValues()
    rv.isExcludedFromBackup = true
    try? dir.setResourceValues(rv)
    return dir.path
  }
}

private enum NodeAssetsIos {
  static func install(registrar: FlutterPluginRegistrar) throws -> URL {
    let fm = FileManager.default
    let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var target = appSupport.appendingPathComponent("nodejs-project", isDirectory: true)
    let stampFile = target.appendingPathComponent(".version")

    let info = Bundle.main.infoDictionary ?? [:]
    let shortVer = (info["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    let buildVer = (info["CFBundleVersion"] as? String) ?? "1"
    let execMtime: TimeInterval = {
      guard let execPath = Bundle.main.executablePath,
            let attrs = try? fm.attributesOfItem(atPath: execPath),
            let date = attrs[.modificationDate] as? Date else { return 0 }
      return date.timeIntervalSince1970
    }()
    let stamp = "\(shortVer)+\(buildVer)+\(Int64(execMtime))"

    if let existing = try? String(contentsOf: stampFile, encoding: .utf8),
       existing == stamp,
       fm.fileExists(atPath: target.appendingPathComponent("src/main.js").path) {
      return target
    }

    let assetRel = registrar.lookupKey(forAsset: "assets/nodejs")
    let candidates = [
      (Bundle.main.bundlePath as NSString).appendingPathComponent(assetRel),
      (Bundle.main.bundlePath as NSString).appendingPathComponent("Frameworks/App.framework/flutter_assets/assets/nodejs")
    ]
    guard let srcPath = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
      throw NSError(
        domain: "NovaPlayNode",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "Bundled assets/nodejs directory not found in App.framework"]
      )
    }

    if fm.fileExists(atPath: target.path) {
      try fm.removeItem(at: target)
    }
    try fm.copyItem(at: URL(fileURLWithPath: srcPath, isDirectory: true), to: target)
    try stamp.write(to: stampFile, atomically: true, encoding: .utf8)

    var rv = URLResourceValues()
    rv.isExcludedFromBackup = true
    try? target.setResourceValues(rv)
    return target
  }
}
