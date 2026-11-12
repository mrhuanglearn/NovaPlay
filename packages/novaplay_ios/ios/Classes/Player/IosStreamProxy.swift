import Darwin
import Foundation
import os
import Security

private let proxyUsbLog = Logger(subsystem: "app.novaplay.player", category: "proxy")

enum IosStreamContainer: String {
  case hls = "hls"
  case mp4 = "mp4"
  case mkv = "mkv"
  case flv = "flv"
  case avi = "avi"
  case rawTs = "ts"
  case audio = "audio"
  case html = "html"
  case unknown = "unknown"

  var requiresVlc: Bool {
    switch self {
    case .mkv, .flv, .avi, .rawTs:
      return true
    default:
      return false
    }
  }

  var proxyFileName: String {
    switch self {
    case .hls: return "index.m3u8"
    case .mp4: return "stream.mp4"
    case .mkv: return "stream.mkv"
    case .flv: return "stream.flv"
    case .avi: return "stream.avi"
    case .rawTs: return "stream.ts"
    case .audio: return "stream.m4a"
    default: return "stream"
    }
  }

  var proxyKind: String {
    switch self {
    case .hls: return "hls"
    case .unknown: return "auto"
    default: return "bin"
    }
  }

  var defaultMimeType: String? {
    switch self {
    case .hls: return "application/vnd.apple.mpegurl"
    case .mp4: return "video/mp4"
    case .mkv: return "video/x-matroska"
    case .flv: return "video/x-flv"
    case .avi: return "video/x-msvideo"
    case .rawTs: return "video/mp2t"
    default: return nil
    }
  }
}

struct IosStreamProbeResult {
  let container: IosStreamContainer
  let statusCode: Int?
  let contentType: String?
  let finalURL: URL?
  let errorDescription: String?
}

enum IosUrlSanitizer {
  static let defaultSafariUserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

  private static let inlineHeaderKeyRegex = try? NSRegularExpression(
    pattern: #"^[A-Za-z][A-Za-z0-9_-]*="#,
    options: []
  )

  private static let inlineHeaderSplitRegex = try? NSRegularExpression(
    pattern: #"&(?=(?:User-Agent|UA|Referer|Referrer|Cookie|Origin|Authorization|Host|Accept|X-[A-Za-z0-9_-]+|Sec-[A-Za-z0-9_-]+)=)"#,
    options: [.caseInsensitive]
  )

  /// Normalizes a media URL and merges optional TVBox-style inline `|Key=Value` headers without
  /// double-encoding existing `%XX` hex sequences in signed CDN URLs.
  static func normalizeUrlAndHeaders(
    rawUrl: String,
    headers: [String: String]
  ) -> (url: URL?, headers: [String: String]) {
    let cleanedHeaders = sanitizeHeaderDictionary(headers)
    let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (nil, cleanedHeaders)
    }
    if trimmed.hasPrefix("/") {
      return (URL(fileURLWithPath: trimmed), cleanedHeaders)
    }

    let (urlPart, mergedHeaders) = extractInlinePipeHeaders(rawUrl: trimmed, baseHeaders: cleanedHeaders)
    if urlPart.lowercased().hasPrefix("file://") {
      if let u = URL(string: urlPart) ?? URL(string: sanitizePercentEncoding(urlPart)) {
        return (u, mergedHeaders)
      }
    }

    let sanitized = sanitizePercentEncoding(urlPart)
    if let u = URL(string: sanitized), u.scheme != nil {
      return (u, mergedHeaders)
    }
    if let u = URL(string: urlPart), u.scheme != nil {
      return (u, mergedHeaders)
    }
    return (nil, mergedHeaders)
  }

  static func sanitizeHeaderDictionary(_ raw: [String: String]) -> [String: String] {
    var out: [String: String] = [:]
    for (k, v) in raw {
      let cleanKey = k
        .replacingOccurrences(of: "\r", with: "")
        .replacingOccurrences(of: "\n", with: "")
        .replacingOccurrences(of: ":", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let cleanVal = v
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleanKey.isEmpty, !cleanVal.isEmpty else { continue }
      out[canonicalHeaderName(cleanKey)] = cleanVal
    }
    return out
  }

  private static func canonicalHeaderName(_ key: String) -> String {
    switch key.lowercased() {
    case "ua", "user-agent": return "User-Agent"
    case "referer", "referrer": return "Referer"
    case "cookie": return "Cookie"
    case "origin": return "Origin"
    case "authorization": return "Authorization"
    default: return key
    }
  }

  private static func extractInlinePipeHeaders(
    rawUrl: String,
    baseHeaders: [String: String]
  ) -> (String, [String: String]) {
    guard let schemeRange = rawUrl.range(of: "://") else {
      return (rawUrl, baseHeaders)
    }
    let afterScheme = rawUrl[schemeRange.upperBound...]
    guard let pipeIdx = afterScheme.firstIndex(of: "|") else {
      return (rawUrl, baseHeaders)
    }

    let urlPart = String(rawUrl[..<pipeIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
    let tail = String(rawUrl[rawUrl.index(after: pipeIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    let nsTail = tail as NSString
    guard let keyRx = inlineHeaderKeyRegex,
          keyRx.firstMatch(in: tail, options: [], range: NSRange(location: 0, length: nsTail.length)) != nil else {
      return (rawUrl, baseHeaders)
    }

    var merged = baseHeaders
    var parsedAny = false
    for pipeChunk in tail.components(separatedBy: "|") {
      let segments = splitAmpersandHeaders(pipeChunk)
      for seg in segments {
        guard let eqIdx = seg.firstIndex(of: "=") else { continue }
        let k = String(seg[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let v = String(seg[seg.index(after: eqIdx)...])
          .replacingOccurrences(of: "\r", with: " ")
          .replacingOccurrences(of: "\n", with: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, !v.isEmpty else { continue }
        merged[canonicalHeaderName(k)] = v
        parsedAny = true
      }
    }
    return (parsedAny ? urlPart : rawUrl, merged)
  }

  private static func splitAmpersandHeaders(_ chunk: String) -> [String] {
    guard let rx = inlineHeaderSplitRegex else { return [chunk] }
    let ns = chunk as NSString
    let matches = rx.matches(in: chunk, options: [], range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return [chunk] }
    var parts: [String] = []
    var start = 0
    for m in matches {
      let len = m.range.location - start
      if len > 0 {
        parts.append(ns.substring(with: NSRange(location: start, length: len)))
      }
      start = m.range.location + m.range.length
    }
    if start < ns.length {
      parts.append(ns.substring(from: start))
    }
    return parts
  }

  /// Encodes non-ASCII and unsafe URI characters while preserving existing `%[0-9A-Fa-f]{2}` sequences.
  static func sanitizePercentEncoding(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let bytes = Array(trimmed.utf8)
    let n = bytes.count
    guard n > 0 else { return "" }

    var authStart = -1
    var authEnd = -1
    if n >= 3 {
      for idx in 0..<(n - 2) {
        if bytes[idx] == 0x3A && bytes[idx + 1] == 0x2F && bytes[idx + 2] == 0x2F {
          authStart = idx + 3
          break
        }
      }
      if authStart >= 0 {
        authEnd = n
        for idx in authStart..<n {
          let b = bytes[idx]
          if b == 0x2F || b == 0x3F || b == 0x23 {
            authEnd = idx
            break
          }
        }
      }
    }

    var out = String()
    out.reserveCapacity(n + 16)
    var i = 0
    while i < n {
      let b = bytes[i]
      if b == 0x25 {
        if i + 2 < n && isHexAscii(bytes[i + 1]) && isHexAscii(bytes[i + 2]) {
          out.append(Character(UnicodeScalar(b)))
          out.append(Character(UnicodeScalar(bytes[i + 1])))
          out.append(Character(UnicodeScalar(bytes[i + 2])))
          i += 3
          continue
        }
        out.append("%25")
        i += 1
        continue
      }
      if isSafeUriAscii(b) || ((b == 0x5B || b == 0x5D) && i >= authStart && i < authEnd) {
        out.append(Character(UnicodeScalar(b)))
      } else {
        out.append(String(format: "%%%02X", b))
      }
      i += 1
    }
    return out
  }

  private static func isHexAscii(_ b: UInt8) -> Bool {
    (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
  }

  private static func isSafeUriAscii(_ b: UInt8) -> Bool {
    if (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) {
      return true
    }
    switch b {
    case 0x2D, 0x2E, 0x5F, 0x7E, // - . _ ~
         0x3A, 0x2F, 0x3F, 0x23, 0x40, // : / ? # @
         0x21, 0x24, 0x26, 0x27, 0x28, 0x29, // ! $ & ' ( )
         0x2A, 0x2B, 0x2C, 0x3B, 0x3D: // * + , ; =
      return true
    default:
      return false
    }
  }

  static func base64UrlEncode(_ text: String) -> String {
    Data(text.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  static func base64UrlDecode(_ encoded: String) -> String? {
    var s = encoded
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let rem = s.count % 4
    if rem > 0 {
      s += String(repeating: "=", count: 4 - rem)
    }
    guard let data = Data(base64Encoded: s) else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

enum IosMpegTsSanitizer {
  /// Scans for 188-byte MPEG-TS `0x47` sync packets so HLS `.ts` segments disguised with
  /// leading PNG/JPEG/GIF/BMP headers (common on Chinese VOD CDNs) play natively in `AVPlayer`.
  static func findSyncOffset(in data: Data) -> Int? {
    let count = data.count
    guard count > 0 else { return nil }
    return data.withUnsafeBytes { rawBuf -> Int? in
      guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return nil }
      if count < 189 {
        return ptr[0] == 0x47 ? 0 : nil
      }
      if ptr[0] == 0x47 && ptr[188] == 0x47 && (count < 377 || ptr[376] == 0x47) {
        return 0
      }
      let maxOffset = min(count - 188, 7600)
      guard maxOffset >= 1 else { return nil }
      for off in 1..<maxOffset {
        guard ptr[off] == 0x47 else { continue }
        if off + 564 < count {
          if ptr[off + 188] == 0x47 && ptr[off + 376] == 0x47 && ptr[off + 564] == 0x47 {
            return off
          }
        } else if off + 376 < count {
          if ptr[off + 188] == 0x47 && ptr[off + 376] == 0x47 {
            return off
          }
        }
      }
      return nil
    }
  }

  static func looksLikeFmp4Segment(_ data: Data) -> Bool {
    guard data.count >= 8 else { return false }
    let box = String(data: data.subdata(in: 4..<8), encoding: .ascii) ?? ""
    return box == "ftyp" || box == "styp" || box == "moof" || box == "sidx"
  }
}

enum IosHlsRewriter {
  private static let uriAttrRegex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#, options: [])
  private static let methodRegex = try? NSRegularExpression(
    pattern: #"METHOD="?([A-Za-z0-9_-]+)"?"#,
    options: [.caseInsensitive]
  )

  static func looksLikeHlsPlaylist(_ data: Data) -> Bool {
    guard !data.isEmpty else { return false }
    let prefixLen = min(data.count, 256)
    var slice = Array(data.prefix(prefixLen))
    if slice.count >= 3 && slice[0] == 0xEF && slice[1] == 0xBB && slice[2] == 0xBF {
      slice.removeFirst(3)
    }
    while let first = slice.first, first == 0x20 || first == 0x09 || first == 0x0D || first == 0x0A {
      slice.removeFirst()
    }
    guard slice.count >= 7 else { return false }
    let head = String(bytes: slice.prefix(7), encoding: .ascii) ?? ""
    return head.uppercased() == "#EXTM3U"
  }

  static func rewrite(
    playlist: String,
    baseURL: URL,
    proxyPort: UInt16,
    sessionToken: String
  ) -> String {
    var outLines: [String] = []
    var expectVariant = false
    var hasEncryption = false
    var hasByteRange = false

    let rawLines = playlist.components(separatedBy: .newlines)
    outLines.reserveCapacity(rawLines.count)

    for rawLine in rawLines {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty {
        continue
      }

      if line.hasPrefix("#") {
        let upper = line.uppercased()
        if upper.hasPrefix("#EXT-X-STREAM-INF") {
          expectVariant = true
        } else if upper.hasPrefix("#EXT-X-BYTERANGE") {
          hasByteRange = true
        } else if upper.hasPrefix("#EXT-X-KEY") || upper.hasPrefix("#EXT-X-SESSION-KEY") {
          if let rx = methodRegex {
            let ns = line as NSString
            if let m = rx.firstMatch(in: line, options: [], range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges >= 2 {
              let method = ns.substring(with: m.range(at: 1)).uppercased()
              hasEncryption = (method != "NONE")
            }
          }
        }

        if line.contains("URI=\""), let rx = uriAttrRegex {
          let isPlaylistAttr = upper.hasPrefix("#EXT-X-MEDIA:") || upper.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
          let isMapAttr = upper.hasPrefix("#EXT-X-MAP:")
          let nsMut = NSMutableString(string: line)
          let matches = rx.matches(in: line, options: [], range: NSRange(location: 0, length: nsMut.length))
          for match in matches.reversed() where match.numberOfRanges >= 2 {
            let origRef = nsMut.substring(with: match.range(at: 1))
            guard let resolved = resolveReference(origRef, baseURL: baseURL) else { continue }
            let proxied: String
            if isPlaylistAttr {
              proxied = buildProxyUrlString(port: proxyPort, token: sessionToken, targetURL: resolved, kind: "hls", fileName: "sub.m3u8", rawSeg: false)
            } else if isMapAttr {
              proxied = buildProxyUrlString(port: proxyPort, token: sessionToken, targetURL: resolved, kind: "raw", fileName: "init.mp4", rawSeg: false)
            } else {
              proxied = buildProxyUrlString(port: proxyPort, token: sessionToken, targetURL: resolved, kind: "key", fileName: "enc.key", rawSeg: false)
            }
            nsMut.replaceCharacters(in: match.range, with: "URI=\"\(proxied)\"")
          }
          outLines.append(nsMut as String)
        } else {
          outLines.append(line)
        }
        continue
      }

      guard let resolved = resolveReference(line, baseURL: baseURL) else {
        outLines.append(line)
        expectVariant = false
        hasByteRange = false
        continue
      }

      let ext = resolved.pathExtension.lowercased()
      if expectVariant || ext == "m3u8" || ext == "m3u" {
        outLines.append(buildProxyUrlString(port: proxyPort, token: sessionToken, targetURL: resolved, kind: "hls", fileName: "sub.m3u8", rawSeg: false))
      } else if ["m4s", "mp4", "cmfv", "cmfa"].contains(ext) {
        outLines.append(buildProxyUrlString(port: proxyPort, token: sessionToken, targetURL: resolved, kind: "raw", fileName: "seg.\(ext)", rawSeg: false))
      } else if ext == "vtt" || ext == "webvtt" {
        outLines.append(buildProxyUrlString(port: proxyPort, token: sessionToken, targetURL: resolved, kind: "raw", fileName: "seg.vtt", rawSeg: false))
      } else if ["aac", "mp3", "ac3", "ec3"].contains(ext) {
        outLines.append(buildProxyUrlString(port: proxyPort, token: sessionToken, targetURL: resolved, kind: "raw", fileName: "seg.\(ext)", rawSeg: false))
      } else {
        let rawFlag = hasEncryption || hasByteRange
        outLines.append(buildProxyUrlString(port: proxyPort, token: sessionToken, targetURL: resolved, kind: "ts", fileName: "seg.ts", rawSeg: rawFlag))
      }

      expectVariant = false
      hasByteRange = false
    }

    return outLines.joined(separator: "\n") + "\n"
  }

  private static func resolveReference(_ rawRef: String, baseURL: URL) -> URL? {
    let trimmed = rawRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let lower = trimmed.lowercased()
    if lower.hasPrefix("data:") || lower.hasPrefix("skd:") {
      return nil
    }
    let sanitized = IosUrlSanitizer.sanitizePercentEncoding(trimmed)
    return URL(string: sanitized, relativeTo: baseURL)?.absoluteURL
  }

  fileprivate static func buildProxyUrlString(
    port: UInt16,
    token: String,
    targetURL: URL,
    kind: String,
    fileName: String,
    rawSeg: Bool
  ) -> String {
    let encoded = IosUrlSanitizer.base64UrlEncode(targetURL.absoluteString)
    let extra = rawSeg ? "&rawseg=1" : ""
    return "http://127.0.0.1:\(port)/proxy/\(token)/\(fileName)?u=\(encoded)&kind=\(kind)\(extra)"
  }
}

/// Local `127.0.0.1` HTTP/1.1 streaming & HLS proxy solving iOS `AVPlayer` and `MobileVLCKit` compatibility:
/// 1. Injects `Cookie`, `Referer`, `User-Agent`, `Origin`, and custom headers reliably across cross-host HTTP redirects.
/// 2. Accepts VOD slice CDN servers with incomplete/self-signed TLS chains when standard validation fails.
/// 3. Sniffs magic bytes (`#EXTM3U`, `ftyp`, `EBML`/MKV, `FLV`, `AVI`, raw `TS`) to fix `application/octet-stream` `-11828` failures.
/// 4. Rewrites HLS playlists and strips disguised PNG/JPEG/GIF/BMP segment prefixes before `0x47` MPEG-TS packets.
final class IosStreamProxy: NSObject, URLSessionDataDelegate {
  static let shared = IosStreamProxy()

  private struct CachedPlaylist {
    let data: Data
    let finalURL: URL
    let cachedAt: TimeInterval
    let isStatic: Bool
  }

  private final class ProxySession {
    let token: String
    let rootURL: URL
    let headers: [String: String]
    let createdAt: TimeInterval

    var redirectCookies: [String: String] = [:]
    var cachedRootPlaylist: CachedPlaylist?
    var lastStatusCode: Int?
    var lastContentType: String?
    var lastError: String?
    var detectedContainer: IosStreamContainer = .unknown
    var lastFinalHost: String?

    init(token: String, rootURL: URL, headers: [String: String]) {
      self.token = token
      self.rootURL = rootURL
      var effective = headers
      let hasUA = effective.keys.contains { $0.lowercased() == "user-agent" }
      if !hasUA {
        effective["User-Agent"] = IosUrlSanitizer.defaultSafariUserAgent
      }
      self.headers = effective
      self.createdAt = ProcessInfo.processInfo.systemUptime
    }
  }

  private struct TaskCallbacks {
    let session: ProxySession
    let originalRange: String?
    let binaryIdentityEncoding: Bool
    let onResponse: (HTTPURLResponse) -> Void
    let onData: (Data) -> Void
    let onComplete: (Error?) -> Void
  }

  private let lock = NSLock()
  private var serverFd: Int32 = -1
  private var boundPort: UInt16 = 0
  private var sessions: [String: ProxySession] = [:]
  private var sessionOrder: [String] = []
  private var taskCallbacks: [Int: TaskCallbacks] = [:]
  private var totalBytesReceived: Int64 = 0

  private let delegateQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "app.novaplay.streamproxy.urlsession"
    q.maxConcurrentOperationCount = 16
    q.qualityOfService = .userInitiated
    return q
  }()
  private var urlSession: URLSession!

  private override init() {
    super.init()
    let cfg = URLSessionConfiguration.ephemeral
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    cfg.urlCache = nil
    cfg.httpShouldSetCookies = false
    cfg.httpCookieAcceptPolicy = .never
    cfg.httpMaximumConnectionsPerHost = 16
    cfg.timeoutIntervalForRequest = 20
    cfg.timeoutIntervalForResource = 7200
    urlSession = URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
  }

  /// True only for URLs served by this `IosStreamProxy` listener (`127.0.0.1:<boundPort>/proxy/...`),
  /// NOT for CatPaw's own local Node proxy (`127.0.0.1:2333/...`).
  func isOwnProxyURL(_ url: URL) -> Bool {
    guard url.host == "127.0.0.1", url.path.hasPrefix("/proxy/") else { return false }
    let p = Int(currentBoundPort)
    return p > 0 && url.port == p
  }

  static func isLikelyVlcOnlyExtension(_ rawExt: String) -> Bool {
    let ext = rawExt.lowercased()
    return ["mkv", "webm", "flv", "avi", "rmvb", "rm", "wmv", "asf", "ogv", "ogg", "divx", "mpg", "mpeg", "vob"].contains(ext)
  }

  static func inferredKind(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if ext == "m3u8" || ext == "m3u" { return "hls" }
    if ["mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "ts", "mp3", "m4a", "aac", "flac"].contains(ext) {
      return "bin"
    }
    return "auto"
  }

  static func inferredFileName(for url: URL) -> String {
    let ext = url.pathExtension.lowercased()
    if ext == "m3u8" || ext == "m3u" { return "index.m3u8" }
    if ["mp4", "m4v", "mov", "mkv", "webm", "flv", "avi", "ts", "mp3", "m4a", "aac", "flac"].contains(ext) {
      return "stream.\(ext)"
    }
    return "stream"
  }

  func totalUpstreamBytesRead() -> Int64 {
    lock.lock()
    let val = totalBytesReceived
    lock.unlock()
    return val
  }

  func ensureStarted() -> UInt16? {
    lock.lock()
    if boundPort > 0 && serverFd >= 0 {
      let p = boundPort
      lock.unlock()
      return p
    }
    guard let (fd, port) = openLoopbackListener() else {
      lock.unlock()
      return nil
    }
    serverFd = fd
    boundPort = port
    lock.unlock()
    proxyUsbLog.notice("[NovaPlay][Proxy] listening on 127.0.0.1:\(port, privacy: .public)")

    Thread.detachNewThread { [weak self] in
      self?.acceptLoop(srvFd: fd)
    }
    return port
  }

  func registerSession(rootURL: URL, headers: [String: String]) -> String {
    var rnd = [UInt8](repeating: 0, count: 8)
    _ = SecRandomCopyBytes(kSecRandomDefault, rnd.count, &rnd)
    let token = rnd.map { String(format: "%02x", $0) }.joined()

    let session = ProxySession(token: token, rootURL: rootURL, headers: headers)
    lock.lock()
    sessions[token] = session
    sessionOrder.append(token)
    while sessionOrder.count > 12 {
      let evicted = sessionOrder.removeFirst()
      sessions.removeValue(forKey: evicted)
    }
    lock.unlock()
    return token
  }

  func buildProxyURL(
    targetURL: URL,
    token: String,
    kind: String,
    fileName: String
  ) -> URL? {
    guard let port = ensureStarted() else { return nil }
    let str = IosHlsRewriter.buildProxyUrlString(
      port: port,
      token: token,
      targetURL: targetURL,
      kind: kind,
      fileName: fileName,
      rawSeg: false
    )
    return URL(string: str)
  }

  func diagnosticsSummary(for token: String?) -> String? {
    guard let token = token else { return nil }
    lock.lock()
    guard let s = sessions[token] else {
      lock.unlock()
      return nil
    }
    let status = s.lastStatusCode
    let ct = s.lastContentType
    let err = s.lastError
    let container = s.detectedContainer
    let host = s.lastFinalHost ?? s.rootURL.host
    lock.unlock()

    var parts: [String] = []
    if let status = status {
      parts.append("HTTP \(status)")
    }
    if let ct = ct, !ct.isEmpty {
      parts.append("MIME=\(ct)")
    }
    if container != .unknown {
      parts.append("container=\(container.rawValue)")
    }
    if let host = host, !host.isEmpty {
      parts.append("host=\(host)")
    }
    if let err = err, !err.isEmpty {
      parts.append("net=\(err)")
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
  }

  // MARK: - Fast Container Probe (<= 1 KB)

  @discardableResult
  func probe(
    token: String,
    completion: @escaping (IosStreamProbeResult) -> Void
  ) -> (() -> Void) {
    guard let session = getSession(token) else {
      let res = IosStreamProbeResult(container: .unknown, statusCode: nil, contentType: nil, finalURL: nil, errorDescription: "missing session")
      DispatchQueue.main.async { completion(res) }
      return {}
    }

    let ext = session.rootURL.pathExtension.lowercased()
    let rawLower = session.rootURL.absoluteString.lowercased()
    let sendRange = (ext != "m3u8" && ext != "m3u" && !rawLower.contains("m3u8"))
    return performSingleProbe(session: session, useRangeHeader: sendRange, allowRetryWithoutRange: sendRange, completion: completion)
  }

  private func performSingleProbe(
    session: ProxySession,
    useRangeHeader: Bool,
    allowRetryWithoutRange: Bool,
    completion: @escaping (IosStreamProbeResult) -> Void
  ) -> (() -> Void) {
    let stateLock = NSLock()
    var finished = false
    var capturedResponse: HTTPURLResponse?
    var capturedData = Data()
    var isLikelyHlsResponse = false
    var activeTask: URLSessionDataTask?
    var cancelChild: (() -> Void)?

    func finishOnce(_ result: IosStreamProbeResult) {
      stateLock.lock()
      if finished {
        stateLock.unlock()
        return
      }
      finished = true
      stateLock.unlock()
      let host = result.finalURL?.host ?? session.rootURL.host ?? "-"
      let ext = (result.finalURL?.pathExtension.isEmpty == false
        ? result.finalURL?.pathExtension
        : session.rootURL.pathExtension) ?? ""
      let codeStr = result.statusCode.map(String.init) ?? "nil"
      let mimeStr = result.contentType ?? "-"
      let containerStr = result.container.rawValue
      let errStr = result.errorDescription ?? "-"
      proxyUsbLog.notice(
        "[NovaPlay][Proxy] probe host=\(host, privacy: .public) ext=\(ext, privacy: .public) status=\(codeStr, privacy: .public) mime=\(mimeStr, privacy: .public) container=\(containerStr, privacy: .public) err=\(errStr, privacy: .public)"
      )
      DispatchQueue.main.async {
        completion(result)
      }
    }

    var req = URLRequest(url: session.rootURL)
    req.httpMethod = "GET"
    req.timeoutInterval = 5.5
    applyEffectiveHeaders(for: session, into: &req)
    let rangeValue: String? = useRangeHeader ? "bytes=0-1023" : nil
    if let r = rangeValue {
      req.setValue(r, forHTTPHeaderField: "Range")
      req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    let task = urlSession.dataTask(with: req)
    activeTask = task

    let callbacks = TaskCallbacks(
      session: session,
      originalRange: rangeValue,
      binaryIdentityEncoding: useRangeHeader,
      onResponse: { [weak self] resp in
        let ctLower = (resp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let respUrlLower = (resp.url?.pathExtension ?? "").lowercased()
        stateLock.lock()
        capturedResponse = resp
        if ctLower.contains("mpegurl") || respUrlLower == "m3u8" || respUrlLower == "m3u" {
          isLikelyHlsResponse = true
        }
        stateLock.unlock()
        if !(allowRetryWithoutRange && resp.statusCode >= 400) {
          self?.recordSessionResponse(session: session, response: resp)
        }
      },
      onData: { [weak self, weak task] chunk in
        self?.addReceivedBytes(chunk.count)
        var shouldStopNow = false
        stateLock.lock()
        if !finished {
          if capturedData.isEmpty && IosHlsRewriter.looksLikeHlsPlaylist(chunk) {
            isLikelyHlsResponse = true
          }
          let capBytes = isLikelyHlsResponse ? (1024 * 1024) : 1024
          let needed = max(0, capBytes - capturedData.count)
          if needed > 0 {
            capturedData.append(chunk.prefix(needed))
          }
          if !isLikelyHlsResponse && capturedData.count >= 1024 {
            shouldStopNow = true
          } else if isLikelyHlsResponse && capturedData.count >= capBytes {
            shouldStopNow = true
          }
        }
        stateLock.unlock()
        if shouldStopNow {
          task?.cancel()
        }
      },
      onComplete: { [weak self] err in
        guard let self = self else { return }
        stateLock.lock()
        let alreadyDone = finished
        let resp = capturedResponse
        let sample = capturedData
        stateLock.unlock()
        guard !alreadyDone else { return }

        let status = resp?.statusCode
        if allowRetryWithoutRange, let code = status, code >= 400 {
          let retryCancel = self.performSingleProbe(
            session: session,
            useRangeHeader: false,
            allowRetryWithoutRange: false,
            completion: completion
          )
          stateLock.lock()
          cancelChild = retryCancel
          stateLock.unlock()
          return
        }

        let nsErr = err as NSError?
        let isCancelledByCap = (nsErr?.domain == NSURLErrorDomain && nsErr?.code == NSURLErrorCancelled && !sample.isEmpty)
        let errText: String? = (err != nil && !isCancelledByCap) ? err?.localizedDescription : nil
        if let errText = errText {
          self.recordSessionError(session: session, errorText: errText)
        }

        let finalURL = resp?.url ?? session.rootURL
        let ct = resp?.value(forHTTPHeaderField: "Content-Type")
        let sniffed = Self.sniffContainer(firstBytes: sample, contentType: ct, finalURL: finalURL)
        self.recordSessionContainer(session: session, container: sniffed)

        if sniffed == .hls,
           err == nil,
           (status ?? 200) == 200,
           !useRangeHeader,
           IosHlsRewriter.looksLikeHlsPlaylist(sample) {
          self.storeCachedRootPlaylist(session: session, data: sample, finalURL: finalURL)
        }

        finishOnce(IosStreamProbeResult(
          container: sniffed,
          statusCode: status,
          contentType: ct,
          finalURL: finalURL,
          errorDescription: errText
        ))
      }
    )

    registerTask(task, callbacks: callbacks)
    task.resume()

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 4.5) { [weak self] in
      guard let self = self else { return }
      stateLock.lock()
      let done = finished
      let resp = capturedResponse
      let sample = capturedData
      stateLock.unlock()
      guard !done else { return }
      activeTask?.cancel()
      let finalURL = resp?.url ?? session.rootURL
      let ct = resp?.value(forHTTPHeaderField: "Content-Type")
      let sniffed = Self.sniffContainer(firstBytes: sample, contentType: ct, finalURL: finalURL)
      self.recordSessionContainer(session: session, container: sniffed)
      finishOnce(IosStreamProbeResult(
        container: sniffed,
        statusCode: resp?.statusCode,
        contentType: ct,
        finalURL: finalURL,
        errorDescription: nil
      ))
    }

    return {
      stateLock.lock()
      finished = true
      let child = cancelChild
      stateLock.unlock()
      activeTask?.cancel()
      child?()
    }
  }

  static func sniffContainer(firstBytes: Data, contentType: String?, finalURL: URL) -> IosStreamContainer {
    if IosHlsRewriter.looksLikeHlsPlaylist(firstBytes) {
      return .hls
    }

    let ctLower = (contentType ?? "").lowercased()
    if !firstBytes.isEmpty {
      let asciiPrefix = String(bytes: firstBytes.prefix(min(firstBytes.count, 128)), encoding: .isoLatin1)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
      if (asciiPrefix.hasPrefix("<!doctype html") || asciiPrefix.hasPrefix("<html")) &&
          (ctLower.contains("text/html") || finalURL.pathExtension.isEmpty || finalURL.pathExtension.lowercased() == "m3u8") {
        return .html
      }

      let bytes = Array(firstBytes.prefix(min(firstBytes.count, 16)))
      if bytes.count >= 4 && bytes[0] == 0x1A && bytes[1] == 0x45 && bytes[2] == 0xDF && bytes[3] == 0xA3 {
        return .mkv
      }
      if bytes.count >= 4 && bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53 {
        // Ogg/Opus/Theora -> VLC
        return .mkv
      }
      if bytes.count >= 4 && bytes[0] == 0x46 && bytes[1] == 0x4C && bytes[2] == 0x56 && bytes[3] < 0x05 {
        return .flv
      }
      if bytes.count >= 12,
         String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
         String(bytes: bytes[8..<12], encoding: .ascii) == "AVI " {
        return .avi
      }
      if bytes.count >= 8, let box = String(bytes: bytes[4..<8], encoding: .ascii) {
        if ["ftyp", "moof", "mdat", "wide", "free", "skip", "styp", "pnot"].contains(box) {
          return .mp4
        }
      }
      if bytes.count >= 4, let head4 = String(bytes: bytes[0..<4], encoding: .ascii), head4 == "fLaC" {
        return .audio
      }
      if bytes.count >= 3, let head3 = String(bytes: bytes[0..<3], encoding: .ascii), head3 == "ID3" {
        return .audio
      }
      if firstBytes.count >= 377, IosMpegTsSanitizer.findSyncOffset(in: firstBytes) != nil {
        return .rawTs
      }
    }

    let ext = finalURL.pathExtension.lowercased()
    if ctLower.contains("mpegurl") || ext == "m3u8" || ext == "m3u" {
      return .hls
    }
    if ctLower.contains("matroska") || ctLower.contains("webm") || isLikelyVlcOnlyExtension(ext) {
      return .mkv
    }
    if ctLower.contains("x-flv") || ext == "flv" {
      return .flv
    }
    if ctLower.contains("msvideo") || ext == "avi" {
      return .avi
    }
    if ctLower.contains("video/mp4") || ctLower.contains("quicktime") || ["mp4", "m4v", "mov"].contains(ext) {
      return .mp4
    }
    if ["mp3", "m4a", "aac", "flac", "wav"].contains(ext) {
      return .audio
    }
    return .unknown
  }

  // MARK: - Loopback POSIX Socket Server

  private func openLoopbackListener() -> (Int32, UInt16)? {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

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
    guard bindRc == 0, Darwin.listen(fd, 64) == 0 else {
      Darwin.close(fd)
      return nil
    }

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameRc = withUnsafeMutablePointer(to: &bound) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        Darwin.getsockname(fd, saPtr, &len)
      }
    }
    guard nameRc == 0 else {
      Darwin.close(fd)
      return nil
    }
    return (fd, UInt16(bigEndian: bound.sin_port))
  }

  private func acceptLoop(srvFd: Int32) {
    while true {
      let connFd = Darwin.accept(srvFd, nil, nil)
      if connFd < 0 {
        let err = errno
        if err == EINTR || err == EAGAIN {
          continue
        }
        break
      }
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        self?.handleClientConnection(fd: connFd)
      }
    }
  }

  private func handleClientConnection(fd: Int32) {
    var yes: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    var rcvTimeout = timeval(tv_sec: 10, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcvTimeout, socklen_t(MemoryLayout<timeval>.size))
    var sndTimeout = timeval(tv_sec: 20, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sndTimeout, socklen_t(MemoryLayout<timeval>.size))

    guard let requestHead = readHttpHeaderBlock(fd: fd) else {
      Darwin.close(fd)
      return
    }
    let lines = requestHead.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      Darwin.close(fd)
      return
    }
    let reqParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
    guard reqParts.count >= 2 else {
      Darwin.close(fd)
      return
    }
    let method = reqParts[0].uppercased()
    let rawTarget = reqParts[1]
    guard method == "GET" || method == "HEAD" else {
      _ = writeAll(fd: fd, data: Data("HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
      Darwin.close(fd)
      return
    }
    let isHead = (method == "HEAD")

    var incomingHeaders: [String: String] = [:]
    for headerLine in lines.dropFirst() {
      guard let colon = headerLine.firstIndex(of: ":") else { continue }
      let k = String(headerLine[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
      let v = String(headerLine[headerLine.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
      if !k.isEmpty {
        incomingHeaders[k] = v
      }
    }
    let incomingRange = incomingHeaders["range"]

    let fullTarget = rawTarget.lowercased().hasPrefix("http://") ? rawTarget : ("http://127.0.0.1" + rawTarget)
    guard let comps = URLComponents(string: fullTarget) else {
      _ = writeAll(fd: fd, data: Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
      Darwin.close(fd)
      return
    }

    // Path shape: `/proxy/<token>/<fileName>`
    let pathParts = comps.path.split(separator: "/").map(String.init)
    guard pathParts.count >= 2, pathParts[0] == "proxy" else {
      _ = writeAll(fd: fd, data: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
      Darwin.close(fd)
      return
    }
    let token = pathParts[1]
    let pathFileName = pathParts.count >= 3 ? pathParts[2] : "stream"

    var queryMap: [String: String] = [:]
    for item in comps.queryItems ?? [] {
      if let val = item.value {
        queryMap[item.name] = val
      }
    }

    guard let session = getSession(token),
          let uEncoded = queryMap["u"],
          let targetStr = IosUrlSanitizer.base64UrlDecode(uEncoded),
          let targetURL = URL(string: targetStr) ?? URL(string: IosUrlSanitizer.sanitizePercentEncoding(targetStr)) else {
      _ = writeAll(fd: fd, data: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
      Darwin.close(fd)
      return
    }

    let kind = (queryMap["kind"] ?? "auto").lowercased()
    let isRawSeg = (queryMap["rawseg"] == "1")

    if kind == "hls" {
      serveHlsPlaylist(fd: fd, isHead: isHead, targetURL: targetURL, session: session)
    } else if kind == "key" {
      serveHlsKey(fd: fd, isHead: isHead, targetURL: targetURL, session: session)
    } else if kind == "ts" && !isRawSeg && incomingRange == nil && !isHead {
      serveSanitizedTsSegment(fd: fd, targetURL: targetURL, session: session)
    } else {
      serveStreamingResource(
        fd: fd,
        isHead: isHead,
        targetURL: targetURL,
        session: session,
        kind: kind,
        pathFileName: pathFileName,
        incomingRange: incomingRange
      )
    }
  }

  // MARK: - Playlist & Key Handlers (`kind == "hls"` / `kind == "key"`)

  private func serveHlsPlaylist(
    fd: Int32,
    isHead: Bool,
    targetURL: URL,
    session: ProxySession
  ) {
    let proxyPortNow = currentBoundPort
    if proxyPortNow > 0,
       let cached = takeCachedRootPlaylistIfFresh(session: session, targetURL: targetURL),
       let playlistText = String(data: cached.data, encoding: .utf8) ?? String(data: cached.data, encoding: .isoLatin1) {
      defer { Darwin.close(fd) }
      let rewritten = IosHlsRewriter.rewrite(
        playlist: playlistText,
        baseURL: cached.finalURL,
        proxyPort: proxyPortNow,
        sessionToken: session.token
      )
      let outBytes = Data(rewritten.utf8)
      let headStr =
        "HTTP/1.1 200 OK\r\n" +
        "Content-Type: application/vnd.apple.mpegurl; charset=utf-8\r\n" +
        "Content-Length: \(outBytes.count)\r\n" +
        "Cache-Control: no-cache\r\n" +
        "Connection: close\r\n\r\n"
      if writeAll(fd: fd, data: Data(headStr.utf8)), !isHead {
        _ = writeAll(fd: fd, data: outBytes)
      }
      return
    }

    var req = URLRequest(url: targetURL)
    req.httpMethod = "GET"
    applyEffectiveHeaders(for: session, into: &req)

    let stateLock = NSLock()
    var upstreamResp: HTTPURLResponse?
    var body = Data()
    var exceededCap = false

    let task = urlSession.dataTask(with: req)
    let callbacks = TaskCallbacks(
      session: session,
      originalRange: nil,
      binaryIdentityEncoding: false,
      onResponse: { [weak self] resp in
        stateLock.lock()
        upstreamResp = resp
        stateLock.unlock()
        self?.recordSessionResponse(session: session, response: resp)
      },
      onData: { [weak self, weak task] chunk in
        self?.addReceivedBytes(chunk.count)
        var shouldAbort = false
        stateLock.lock()
        if body.count + chunk.count <= 8 * 1024 * 1024 {
          body.append(chunk)
        } else {
          exceededCap = true
          shouldAbort = true
        }
        stateLock.unlock()
        if shouldAbort { task?.cancel() }
      },
      onComplete: { [weak self] err in
        defer { Darwin.close(fd) }
        guard let self = self else { return }
        stateLock.lock()
        let resp = upstreamResp
        let data = body
        let capped = exceededCap
        stateLock.unlock()

        if let err = err, !capped {
          self.recordSessionError(session: session, errorText: err.localizedDescription)
          _ = self.writeAll(fd: fd, data: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
          return
        }
        let status = resp?.statusCode ?? 200
        if status >= 400 {
          let header = "HTTP/1.1 \(status) Upstream Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          _ = self.writeAll(fd: fd, data: Data(header.utf8))
          return
        }

        let finalURL = resp?.url ?? targetURL
        let proxyPort = self.currentBoundPort
        if proxyPort > 0,
           IosHlsRewriter.looksLikeHlsPlaylist(data),
           let playlistText = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
          self.recordSessionContainer(session: session, container: .hls)
          let rewritten = IosHlsRewriter.rewrite(
            playlist: playlistText,
            baseURL: finalURL,
            proxyPort: proxyPort,
            sessionToken: session.token
          )
          let outBytes = Data(rewritten.utf8)
          let headStr =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/vnd.apple.mpegurl; charset=utf-8\r\n" +
            "Content-Length: \(outBytes.count)\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: close\r\n\r\n"
          if self.writeAll(fd: fd, data: Data(headStr.utf8)), !isHead {
            _ = self.writeAll(fd: fd, data: outBytes)
          }
          return
        }

        let ct = resp?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        let headStr =
          "HTTP/1.1 \(status) OK\r\n" +
          "Content-Type: \(ct)\r\n" +
          "Content-Length: \(data.count)\r\n" +
          "Connection: close\r\n\r\n"
        if self.writeAll(fd: fd, data: Data(headStr.utf8)), !isHead {
          _ = self.writeAll(fd: fd, data: data)
        }
      }
    )

    registerTask(task, callbacks: callbacks)
    task.resume()
  }

  private func serveHlsKey(
    fd: Int32,
    isHead: Bool,
    targetURL: URL,
    session: ProxySession
  ) {
    var req = URLRequest(url: targetURL)
    req.httpMethod = "GET"
    applyEffectiveHeaders(for: session, into: &req)

    let stateLock = NSLock()
    var upstreamResp: HTTPURLResponse?
    var body = Data()
    var exceededCap = false

    let task = urlSession.dataTask(with: req)
    let callbacks = TaskCallbacks(
      session: session,
      originalRange: nil,
      binaryIdentityEncoding: false,
      onResponse: { [weak self] resp in
        stateLock.lock()
        upstreamResp = resp
        stateLock.unlock()
        self?.recordSessionResponse(session: session, response: resp)
      },
      onData: { [weak self, weak task] chunk in
        self?.addReceivedBytes(chunk.count)
        var shouldAbort = false
        stateLock.lock()
        if body.count + chunk.count <= 65536 {
          body.append(chunk)
        } else {
          exceededCap = true
          shouldAbort = true
        }
        stateLock.unlock()
        if shouldAbort { task?.cancel() }
      },
      onComplete: { [weak self] err in
        defer { Darwin.close(fd) }
        guard let self = self else { return }
        stateLock.lock()
        let resp = upstreamResp
        let data = body
        let capped = exceededCap
        stateLock.unlock()

        if let err = err, !capped {
          self.recordSessionError(session: session, errorText: err.localizedDescription)
          _ = self.writeAll(fd: fd, data: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
          return
        }
        let status = resp?.statusCode ?? 200
        if status >= 400 {
          let header = "HTTP/1.1 \(status) Upstream Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          _ = self.writeAll(fd: fd, data: Data(header.utf8))
          return
        }
        let headStr =
          "HTTP/1.1 200 OK\r\n" +
          "Content-Type: application/octet-stream\r\n" +
          "Content-Length: \(data.count)\r\n" +
          "Connection: close\r\n\r\n"
        if self.writeAll(fd: fd, data: Data(headStr.utf8)), !isHead {
          _ = self.writeAll(fd: fd, data: data)
        }
      }
    )

    registerTask(task, callbacks: callbacks)
    task.resume()
  }

  // MARK: - Disguised MPEG-TS Segment Handler (`kind == "ts"`)

  private func serveSanitizedTsSegment(
    fd: Int32,
    targetURL: URL,
    session: ProxySession
  ) {
    let writeQueue = DispatchQueue(label: "app.novaplay.proxy.tswrite")
    let stateLock = NSLock()
    var upstreamResp: HTTPURLResponse?
    var prefixBuf = Data()
    var headerFlushed = false
    var socketDead = false
    var queuedBytes = 0
    var suspended = false

    var req = URLRequest(url: targetURL)
    req.httpMethod = "GET"
    applyEffectiveHeaders(for: session, into: &req)
    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

    let task = urlSession.dataTask(with: req)

    func flushPrefixAndHeader(_ initialData: Data, resp: HTTPURLResponse?) -> Bool {
      let status = resp?.statusCode ?? 200
      if status >= 400 {
        let h = "HTTP/1.1 \(status) Upstream Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = self.writeAll(fd: fd, data: Data(h.utf8))
        return false
      }

      let isFmp4 = IosMpegTsSanitizer.looksLikeFmp4Segment(initialData)
      let stripOffset = isFmp4 ? 0 : (IosMpegTsSanitizer.findSyncOffset(in: initialData) ?? 0)
      let outMime = isFmp4 ? "video/mp4" : "video/mp2t"

      var headers = "HTTP/1.1 200 OK\r\nContent-Type: \(outMime)\r\n"
      if let clRaw = resp?.value(forHTTPHeaderField: "Content-Length"),
         let clVal = Int64(clRaw.trimmingCharacters(in: .whitespaces)),
         clVal > Int64(stripOffset),
         Self.isIdentityContentEncoding(resp) {
        headers += "Content-Length: \(clVal - Int64(stripOffset))\r\n"
      }
      headers += "Connection: close\r\n\r\n"

      guard self.writeAll(fd: fd, data: Data(headers.utf8)) else {
        return false
      }
      if stripOffset < initialData.count {
        let slice = stripOffset > 0 ? initialData.subdata(in: stripOffset..<initialData.count) : initialData
        if !self.writeAll(fd: fd, data: slice) {
          return false
        }
      }
      return true
    }

    let callbacks = TaskCallbacks(
      session: session,
      originalRange: nil,
      binaryIdentityEncoding: true,
      onResponse: { [weak self] resp in
        stateLock.lock()
        upstreamResp = resp
        stateLock.unlock()
        self?.recordSessionResponse(session: session, response: resp)
      },
      onData: { [weak self, weak task] chunk in
        guard let self = self else { return }
        self.addReceivedBytes(chunk.count)

        var chunkToStream: Data?
        var prefixToFlush: Data?
        var respSnap: HTTPURLResponse?
        var shouldSuspend = false
        var shouldCancel = false

        var shouldResumeBeforeCancel = false
        stateLock.lock()
        if socketDead {
          shouldCancel = true
          if suspended {
            suspended = false
            shouldResumeBeforeCancel = true
          }
        } else if !headerFlushed {
          prefixBuf.append(chunk)
          if prefixBuf.count >= 8192 {
            headerFlushed = true
            prefixToFlush = prefixBuf
            prefixBuf.removeAll(keepingCapacity: false)
            respSnap = upstreamResp
            queuedBytes += (prefixToFlush?.count ?? 0)
          }
        } else {
          chunkToStream = chunk
          queuedBytes += chunk.count
          if queuedBytes > 2 * 1024 * 1024 && !suspended {
            suspended = true
            shouldSuspend = true
          }
        }
        stateLock.unlock()

        if shouldCancel {
          if shouldResumeBeforeCancel { task?.resume() }
          task?.cancel()
          return
        }
        if shouldSuspend {
          task?.suspend()
        }

        if let firstBlock = prefixToFlush {
          writeQueue.async { [weak task] in
            let flushedOk = flushPrefixAndHeader(firstBlock, resp: respSnap)
            var resumeNow = false
            var deadNow = false
            var resumeForDead = false
            stateLock.lock()
            if !flushedOk { socketDead = true }
            queuedBytes = max(0, queuedBytes - firstBlock.count)
            deadNow = socketDead
            if suspended && (queuedBytes < 512 * 1024 || deadNow) {
              suspended = false
              if deadNow { resumeForDead = true } else { resumeNow = true }
            }
            stateLock.unlock()
            if deadNow {
              if resumeForDead { task?.resume() }
              task?.cancel()
            } else if resumeNow {
              task?.resume()
            }
          }
        } else if let streamChunk = chunkToStream {
          writeQueue.async { [weak self, weak task] in
            guard let self = self else { return }
            stateLock.lock()
            let alreadyDead = socketDead
            stateLock.unlock()
            var ok = !alreadyDead
            if ok {
              ok = self.writeAll(fd: fd, data: streamChunk)
            }
            var resumeNow = false
            stateLock.lock()
            if !ok { socketDead = true }
            queuedBytes = max(0, queuedBytes - streamChunk.count)
            if suspended && (queuedBytes < 512 * 1024 || !ok) {
              suspended = false
              resumeNow = true
            }
            stateLock.unlock()
            if resumeNow { task?.resume() }
            if !ok { task?.cancel() }
          }
        }
      },
      onComplete: { [weak self, weak task] err in
        guard let self = self else {
          writeQueue.async { Darwin.close(fd) }
          return
        }
        stateLock.lock()
        let wasFlushed = headerFlushed
        headerFlushed = true
        let remainingPrefix = prefixBuf
        prefixBuf.removeAll(keepingCapacity: false)
        let respSnap = upstreamResp
        let wasSuspended = suspended
        suspended = false
        stateLock.unlock()

        if wasSuspended {
          task?.resume()
        }

        writeQueue.async {
          defer { Darwin.close(fd) }
          if !wasFlushed {
            if err != nil && remainingPrefix.isEmpty && respSnap == nil {
              if let err = err {
                self.recordSessionError(session: session, errorText: err.localizedDescription)
              }
              _ = self.writeAll(fd: fd, data: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
              return
            }
            _ = flushPrefixAndHeader(remainingPrefix, resp: respSnap)
          }
        }
      }
    )

    registerTask(task, callbacks: callbacks)
    task.resume()
  }

  // MARK: - Byte-Range & Generic Streaming Handler (`mp4` / `mkv` / `raw` / `auto`)

  private func serveStreamingResource(
    fd: Int32,
    isHead: Bool,
    targetURL: URL,
    session: ProxySession,
    kind: String,
    pathFileName: String,
    incomingRange: String?
  ) {
    let writeQueue = DispatchQueue(label: "app.novaplay.proxy.streamwrite")
    let stateLock = NSLock()
    var upstreamResp: HTTPURLResponse?
    var headerFlushed = false
    var socketDead = false
    var queuedBytes = 0
    var suspended = false
    var autoHlsBuffer: Data?

    var req = URLRequest(url: targetURL)
    req.httpMethod = isHead ? "HEAD" : "GET"
    applyEffectiveHeaders(for: session, into: &req)
    if let incomingRange = incomingRange, !incomingRange.isEmpty {
      req.setValue(incomingRange, forHTTPHeaderField: "Range")
    }
    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

    let task = urlSession.dataTask(with: req)

    func resolveMimeType(resp: HTTPURLResponse?, firstChunk: Data?) -> String {
      if kind == "ts" {
        return "video/mp2t"
      }
      let upstreamCt = resp?.value(forHTTPHeaderField: "Content-Type") ?? ""
      let lowerCt = upstreamCt.lowercased()
      let ext = (pathFileName as NSString).pathExtension.lowercased()
      let isDisguisedImageCt = lowerCt.hasPrefix("image/") && ["ts", "mp4", "m4v", "m4s", "mkv", "flv", "avi"].contains(ext)
      let isGenericCt = lowerCt.isEmpty ||
        lowerCt.contains("octet-stream") ||
        lowerCt.contains("text/plain") ||
        isDisguisedImageCt

      if let firstChunk = firstChunk, !firstChunk.isEmpty, isGenericCt {
        let sniffed = Self.sniffContainer(firstBytes: firstChunk, contentType: upstreamCt, finalURL: resp?.url ?? targetURL)
        if let mime = sniffed.defaultMimeType {
          return mime
        }
      }
      if isGenericCt {
        switch ext {
        case "mp4", "m4v", "m4s": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "flv": return "video/x-flv"
        case "avi": return "video/x-msvideo"
        case "ts": return "video/mp2t"
        case "vtt": return "text/vtt"
        default: break
        }
        if let sessionMime = self.detectedContainer(for: session).defaultMimeType {
          return sessionMime
        }
      }
      return upstreamCt.isEmpty ? "application/octet-stream" : upstreamCt
    }

    func buildResponseHeaders(resp: HTTPURLResponse?, firstChunk: Data?) -> Data {
      let status = resp?.statusCode ?? 200
      let reason: String
      switch status {
      case 200: reason = "OK"
      case 206: reason = "Partial Content"
      case 416: reason = "Range Not Satisfiable"
      default: reason = "Status"
      }
      var h = "HTTP/1.1 \(status) \(reason)\r\n"
      h += "Content-Type: \(resolveMimeType(resp: resp, firstChunk: firstChunk))\r\n"
      if let cl = resp?.value(forHTTPHeaderField: "Content-Length"),
         !cl.isEmpty,
         Self.isIdentityContentEncoding(resp) {
        h += "Content-Length: \(cl)\r\n"
      }
      if let cr = resp?.value(forHTTPHeaderField: "Content-Range"), !cr.isEmpty {
        h += "Content-Range: \(cr)\r\n"
      }
      if let ar = resp?.value(forHTTPHeaderField: "Accept-Ranges"), !ar.isEmpty {
        h += "Accept-Ranges: \(ar)\r\n"
      } else if status == 206 || resp?.value(forHTTPHeaderField: "Content-Range") != nil {
        h += "Accept-Ranges: bytes\r\n"
      }
      h += "Connection: close\r\n\r\n"
      return Data(h.utf8)
    }

    let callbacks = TaskCallbacks(
      session: session,
      originalRange: incomingRange,
      binaryIdentityEncoding: true,
      onResponse: { [weak self] resp in
        stateLock.lock()
        upstreamResp = resp
        stateLock.unlock()
        self?.recordSessionResponse(session: session, response: resp)
      },
      onData: { [weak self, weak task] chunk in
        guard let self = self else { return }
        self.addReceivedBytes(chunk.count)

        var headerDataToWrite: Data?
        var bodyDataToWrite: Data?
        var shouldSuspend = false
        var shouldCancel = false

        var shouldResumeBeforeCancel = false
        stateLock.lock()
        if socketDead {
          shouldCancel = true
          if suspended {
            suspended = false
            shouldResumeBeforeCancel = true
          }
        } else if let buf = autoHlsBuffer {
          if buf.count + chunk.count <= 4 * 1024 * 1024 {
            autoHlsBuffer = buf + chunk
          } else {
            shouldCancel = true
            if suspended {
              suspended = false
              shouldResumeBeforeCancel = true
            }
          }
        } else if !headerFlushed {
          let canRewriteAutoHls = (kind == "auto") &&
            (incomingRange == nil || incomingRange == "bytes=0-") &&
            (upstreamResp?.statusCode ?? 200) < 400 &&
            IosHlsRewriter.looksLikeHlsPlaylist(chunk)
          if canRewriteAutoHls {
            autoHlsBuffer = chunk
          } else {
            headerFlushed = true
            headerDataToWrite = buildResponseHeaders(resp: upstreamResp, firstChunk: chunk)
            bodyDataToWrite = isHead ? nil : chunk
            queuedBytes += chunk.count
          }
        } else {
          bodyDataToWrite = isHead ? nil : chunk
          queuedBytes += chunk.count
          if queuedBytes > 2 * 1024 * 1024 && !suspended {
            suspended = true
            shouldSuspend = true
          }
        }
        stateLock.unlock()

        if shouldCancel {
          if shouldResumeBeforeCancel { task?.resume() }
          task?.cancel()
          return
        }
        if shouldSuspend {
          task?.suspend()
        }

        if headerDataToWrite != nil || bodyDataToWrite != nil {
          let hdr = headerDataToWrite
          let bdy = bodyDataToWrite
          let byteDelta = chunk.count
          writeQueue.async { [weak self, weak task] in
            guard let self = self else { return }
            stateLock.lock()
            let deadBefore = socketDead
            stateLock.unlock()
            var ok = !deadBefore
            if ok, let hdr = hdr {
              ok = self.writeAll(fd: fd, data: hdr)
            }
            if ok, let bdy = bdy {
              ok = self.writeAll(fd: fd, data: bdy)
            }
            var resumeNow = false
            stateLock.lock()
            if !ok { socketDead = true }
            queuedBytes = max(0, queuedBytes - byteDelta)
            if suspended && (queuedBytes < 512 * 1024 || !ok) {
              suspended = false
              resumeNow = true
            }
            stateLock.unlock()
            if resumeNow { task?.resume() }
            if !ok { task?.cancel() }
          }
        }
      },
      onComplete: { [weak self, weak task] err in
        guard let self = self else {
          writeQueue.async { Darwin.close(fd) }
          return
        }
        stateLock.lock()
        let wasFlushed = headerFlushed
        headerFlushed = true
        let hlsBuf = autoHlsBuffer
        autoHlsBuffer = nil
        let respSnap = upstreamResp
        let wasSuspended = suspended
        suspended = false
        stateLock.unlock()

        if wasSuspended {
          task?.resume()
        }

        writeQueue.async {
          defer { Darwin.close(fd) }
          if let hlsData = hlsBuf {
            let finalURL = respSnap?.url ?? targetURL
            let portNow = self.currentBoundPort
            if portNow > 0,
               let text = String(data: hlsData, encoding: .utf8) ?? String(data: hlsData, encoding: .isoLatin1) {
              self.recordSessionContainer(session: session, container: .hls)
              let rewritten = IosHlsRewriter.rewrite(
                playlist: text,
                baseURL: finalURL,
                proxyPort: portNow,
                sessionToken: session.token
              )
              let outBytes = Data(rewritten.utf8)
              let h =
                "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/vnd.apple.mpegurl; charset=utf-8\r\n" +
                "Content-Length: \(outBytes.count)\r\n" +
                "Cache-Control: no-cache\r\n" +
                "Connection: close\r\n\r\n"
              if self.writeAll(fd: fd, data: Data(h.utf8)), !isHead {
                _ = self.writeAll(fd: fd, data: outBytes)
              }
              return
            }
          }

          if !wasFlushed {
            if let err = err, respSnap == nil {
              self.recordSessionError(session: session, errorText: err.localizedDescription)
              _ = self.writeAll(fd: fd, data: Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
              return
            }
            let hdr = buildResponseHeaders(resp: respSnap, firstChunk: nil)
            _ = self.writeAll(fd: fd, data: hdr)
          }
        }
      }
    )

    registerTask(task, callbacks: callbacks)
    task.resume()
  }

  // MARK: - Socket I/O Helpers

  private func readHttpHeaderBlock(fd: Int32) -> String? {
    var buffer = Data()
    var temp = [UInt8](repeating: 0, count: 2048)
    let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A])

    while buffer.count < 32768 {
      let n = Darwin.read(fd, &temp, temp.count)
      if n <= 0 {
        break
      }
      buffer.append(temp, count: n)
      if let range = buffer.range(of: delimiter) {
        let headData = buffer.subdata(in: 0..<range.lowerBound)
        return String(data: headData, encoding: .utf8) ?? String(data: headData, encoding: .isoLatin1)
      }
    }
    return nil
  }

  private func writeAll(fd: Int32, data: Data) -> Bool {
    guard !data.isEmpty else { return true }
    return data.withUnsafeBytes { rawBuf -> Bool in
      guard let base = rawBuf.baseAddress else { return true }
      var written = 0
      while written < rawBuf.count {
        let n = Darwin.write(fd, base.advanced(by: written), rawBuf.count - written)
        if n <= 0 {
          if n < 0 && errno == EINTR {
            continue
          }
          return false
        }
        written += n
      }
      return true
    }
  }

  private static func isIdentityContentEncoding(_ resp: HTTPURLResponse?) -> Bool {
    guard let enc = resp?.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespacesAndNewlines),
          !enc.isEmpty else {
      return true
    }
    return enc.lowercased() == "identity"
  }

  // MARK: - Session & Task Registry

  private var currentBoundPort: UInt16 {
    lock.lock()
    let p = boundPort
    lock.unlock()
    return p
  }

  private func getSession(_ token: String) -> ProxySession? {
    lock.lock()
    let s = sessions[token]
    lock.unlock()
    return s
  }

  private func detectedContainer(for session: ProxySession) -> IosStreamContainer {
    lock.lock()
    let c = session.detectedContainer
    lock.unlock()
    return c
  }

  private func storeCachedRootPlaylist(session: ProxySession, data: Data, finalURL: URL) {
    let text = (String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "").uppercased()
    let isStatic = text.contains("#EXT-X-ENDLIST") || text.contains("#EXT-X-STREAM-INF")
    let entry = CachedPlaylist(
      data: data,
      finalURL: finalURL,
      cachedAt: ProcessInfo.processInfo.systemUptime,
      isStatic: isStatic
    )
    lock.lock()
    session.cachedRootPlaylist = entry
    lock.unlock()
  }

  private func takeCachedRootPlaylistIfFresh(session: ProxySession, targetURL: URL) -> CachedPlaylist? {
    guard targetURL.absoluteString == session.rootURL.absoluteString else { return nil }
    let now = ProcessInfo.processInfo.systemUptime
    lock.lock()
    defer { lock.unlock() }
    guard let entry = session.cachedRootPlaylist else { return nil }
    let maxAge: TimeInterval = entry.isStatic ? 15.0 : 3.0
    guard now - entry.cachedAt <= maxAge else {
      session.cachedRootPlaylist = nil
      return nil
    }
    if !entry.isStatic {
      session.cachedRootPlaylist = nil
    }
    return entry
  }

  private func recordRedirectCookies(session: ProxySession, cookies: [HTTPCookie]) {
    guard !cookies.isEmpty else { return }
    lock.lock()
    for c in cookies where !c.name.isEmpty && !c.value.isEmpty {
      session.redirectCookies[c.name] = c.value
    }
    lock.unlock()
  }

  private func effectiveHeadersSnapshot(for session: ProxySession) -> [String: String] {
    lock.lock()
    let base = session.headers
    let learned = session.redirectCookies
    lock.unlock()
    guard !learned.isEmpty else { return base }

    var out = base
    let existingCookieKey = out.keys.first { $0.lowercased() == "cookie" }
    let existingCookieVal = existingCookieKey.flatMap { out[$0] } ?? ""

    var existingNames = Set<String>()
    for part in existingCookieVal.components(separatedBy: ";") {
      if let eq = part.firstIndex(of: "=") {
        let name = String(part[..<eq]).trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { existingNames.insert(name) }
      }
    }

    var extraPairs: [String] = []
    for (name, val) in learned where !existingNames.contains(name) {
      extraPairs.append("\(name)=\(val)")
    }
    guard !extraPairs.isEmpty else { return out }

    let keyToSet = existingCookieKey ?? "Cookie"
    if existingCookieVal.isEmpty {
      out[keyToSet] = extraPairs.joined(separator: "; ")
    } else {
      out[keyToSet] = existingCookieVal + "; " + extraPairs.joined(separator: "; ")
    }
    return out
  }

  private func applyEffectiveHeaders(for session: ProxySession, into request: inout URLRequest) {
    let hdrs = effectiveHeadersSnapshot(for: session)
    for (k, v) in hdrs {
      request.setValue(v, forHTTPHeaderField: k)
    }
  }

  private func addReceivedBytes(_ n: Int) {
    guard n > 0 else { return }
    lock.lock()
    totalBytesReceived += Int64(n)
    lock.unlock()
  }

  private func recordSessionResponse(session: ProxySession, response: HTTPURLResponse) {
    lock.lock()
    session.lastStatusCode = response.statusCode
    session.lastContentType = response.value(forHTTPHeaderField: "Content-Type")
    session.lastFinalHost = response.url?.host
    lock.unlock()
  }

  private func recordSessionError(session: ProxySession, errorText: String) {
    lock.lock()
    session.lastError = errorText
    lock.unlock()
  }

  private func recordSessionContainer(session: ProxySession, container: IosStreamContainer) {
    guard container != .unknown else { return }
    lock.lock()
    session.detectedContainer = container
    lock.unlock()
  }

  private func registerTask(_ task: URLSessionTask, callbacks: TaskCallbacks) {
    lock.lock()
    taskCallbacks[task.taskIdentifier] = callbacks
    lock.unlock()
  }

  private func callbacksForTask(_ task: URLSessionTask) -> TaskCallbacks? {
    lock.lock()
    let cb = taskCallbacks[task.taskIdentifier]
    lock.unlock()
    return cb
  }

  private func takeCallbacksForTask(_ task: URLSessionTask) -> TaskCallbacks? {
    lock.lock()
    let cb = taskCallbacks.removeValue(forKey: task.taskIdentifier)
    lock.unlock()
    return cb
  }

  // MARK: - URLSessionDataDelegate & URLSessionTaskDelegate

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
       let trust = challenge.protectionSpace.serverTrust {
      if SecTrustEvaluateWithError(trust, nil) {
        completionHandler(.performDefaultHandling, nil)
      } else {
        completionHandler(.useCredential, URLCredential(trust: trust))
      }
      return
    }
    completionHandler(.performDefaultHandling, nil)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let cb = callbacksForTask(task) else {
      completionHandler(request)
      return
    }
    var stringHeaders: [String: String] = [:]
    for (k, v) in response.allHeaderFields {
      if let ks = k as? String, let vs = v as? String {
        stringHeaders[ks] = vs
      }
    }
    if let respURL = response.url ?? request.url, !stringHeaders.isEmpty {
      let cookies = HTTPCookie.cookies(withResponseHeaderFields: stringHeaders, for: respURL)
      recordRedirectCookies(session: cb.session, cookies: cookies)
    }

    var redirected = request
    let queryLower = (request.url?.query ?? "").lowercased()
    let isPresignedObjectUrl =
      queryLower.contains("x-amz-signature=") ||
      queryLower.contains("ossaccesskeyid=") ||
      queryLower.contains("q-signature=")

    let mergedHeaders = effectiveHeadersSnapshot(for: cb.session)
    for (k, v) in mergedHeaders {
      let lower = k.lowercased()
      if lower == "host" { continue }
      if lower == "authorization" && isPresignedObjectUrl { continue }
      redirected.setValue(v, forHTTPHeaderField: k)
    }
    if let origRange = cb.originalRange, !origRange.isEmpty {
      redirected.setValue(origRange, forHTTPHeaderField: "Range")
    }
    if cb.binaryIdentityEncoding {
      redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }
    completionHandler(redirected)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    if let httpResp = response as? HTTPURLResponse,
       let cb = callbacksForTask(dataTask) {
      cb.onResponse(httpResp)
    }
    completionHandler(.allow)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard let cb = callbacksForTask(dataTask) else { return }
    cb.onData(data)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let cb = takeCallbacksForTask(task) else { return }
    cb.onComplete(error)
  }
}
