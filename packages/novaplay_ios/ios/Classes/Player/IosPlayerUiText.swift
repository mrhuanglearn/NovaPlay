import UIKit

enum IosPlayerUiText {
  static var chinese: Bool = {
    let preferred = Locale.preferredLanguages.first ?? "zh"
    return preferred.lowercased().hasPrefix("zh")
  }()

  static func applyLocale(_ uiLocale: String?) {
    if let loc = uiLocale, !loc.isEmpty {
      chinese = loc.lowercased().hasPrefix("zh")
    } else {
      let preferred = Locale.preferredLanguages.first ?? "zh"
      chinese = preferred.lowercased().hasPrefix("zh")
    }
  }

  static func t(_ zh: String, _ en: String) -> String {
    chinese ? zh : en
  }

  static func clock(_ ms: Int64) -> String {
    let s = max(0, ms / 1000)
    let h = s / 3600
    if h > 0 {
      return String(format: "%d:%02d:%02d", h, (s % 3600) / 60, s % 60)
    } else {
      return String(format: "%02d:%02d", s / 60, s % 60)
    }
  }

  static func rightTime(positionMs: Int64, durationMs: Int64, showTotal: Bool) -> String {
    if showTotal || durationMs <= 0 {
      return clock(durationMs)
    }
    return "-" + clock(max(0, durationMs - positionMs))
  }

  static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0]

  static func speed(_ v: Double) -> String {
    let r = (v * 100.0).rounded() / 100.0
    if Int((r * 10.0).rounded()) * 10 == Int((r * 100.0).rounded()) {
      return String(format: "%.1fx", r)
    }
    return String(format: "%.2fx", r)
  }

  static func speedOption(_ v: Double) -> String {
    abs(v - 1.0) < 0.001 ? t("1.0x 常速", "1.0x Normal") : speed(v)
  }

  static func speedMenuLabel(_ v: Double) -> String {
    if abs(v - 1.0) < 0.001 {
      return t("1.0x 常速", "1.0x Normal")
    }
    if v.truncatingRemainder(dividingBy: 1.0) == 0 {
      return "\(Int(v))x"
    }
    return speed(v)
  }

  static func num(_ v: Double) -> String {
    if v == floor(v) {
      return String(format: "%.1f", v)
    }
    let r = (v * 100.0).rounded() / 100.0
    if Int((r * 10.0).rounded()) * 10 == Int((r * 100.0).rounded()) {
      return String(format: "%.1f", r)
    }
    return String(format: "%.2f", r)
  }

  static func danmakuDelay(_ seconds: Double) -> String {
    let v = (seconds * 10.0).rounded() / 10.0
    let n = (v.truncatingRemainder(dividingBy: 1.0) == 0) ? "\(Int(v))" : String(format: "%.1f", v)
    return (v >= 0 ? "+" : "") + n + t(" 秒", " s")
  }

  static func codecName(_ raw: String?) -> String? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
    if raw.contains("hevc") || raw.contains("h265") || raw.contains("hvc1") || raw.contains("hev1") { return "HEVC" }
    if raw.contains("avc") || raw.contains("h264") { return "H.264" }
    if raw.contains("av01") || raw.contains("av1") { return "AV1" }
    if raw.contains("vp9") { return "VP9" }
    if raw.contains("vp8") { return "VP8" }
    let stripped = raw.hasPrefix("video/") ? String(raw.dropFirst("video/".count)) : raw
    return stripped.uppercased()
  }

  static func fps(_ v: Double?) -> String? {
    guard let v = v, v > 0 else { return nil }
    if v.truncatingRemainder(dividingBy: 1.0) == 0 {
      return "\(Int(v)) FPS"
    }
    return String(format: "%.1f FPS", v)
  }

  static func longPressSlideSpeed(base: Double, upPt: CGFloat, ptPerStep: CGFloat, enabled: Bool?) -> Double {
    if enabled == false || ptPerStep <= 0 {
      return base
    }
    let raw = min(8.0, max(0.5, base + Double(upPt / ptPerStep)))
    return (raw * 100.0).rounded() / 100.0
  }

  static func netSpeed(_ bytesPerSecond: Double) -> String {
    let bps = max(0.0, bytesPerSecond)
    if bps >= 1_048_576.0 {
      return String(format: "%.1f MB/s", bps / 1_048_576.0)
    }
    return String(format: "%.0f KB/s", bps / 1024.0)
  }

  static func bufferingSpeed(_ bytesPerSecond: Double) -> String {
    bytesPerSecond > 0 ? netSpeed(bytesPerSecond) : "0.0 KB/s"
  }

  static func markButton(positionMs: Int64, durationMs: Int64, allowed: Bool) -> Bool? {
    guard allowed, durationMs > 0 else { return nil }
    let window = min(Int64(300_000), durationMs / 3)
    if positionMs < window { return true }
    if durationMs - positionMs < window { return false }
    return nil
  }

  static func switchingTo(_ episodeName: String) -> String {
    t("正在切换至 \(episodeName)", "Switching to \(episodeName)")
  }

  static func introMarked(_ ms: Int64) -> String {
    t("已记录片头 \(clock(ms))", "Intro ends at \(clock(ms))")
  }

  static func outroMarked(_ beforeEndMs: Int64) -> String {
    t("已记录片尾（结束前 \(clock(beforeEndMs))）", "Outro starts \(clock(beforeEndMs)) before the end")
  }

  private static let linkFailedPrefix = "获取播放链接失败"

  static func sourceFailed(_ detail: String?) -> String {
    let trimmed = (detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = trimmed.isEmpty ? t("解析失败", "Parse failed") : trimmed
    if fallback.hasPrefix(linkFailedPrefix) {
      return fallback
    }
    return "\(linkFailedPrefix)：\(fallback)"
  }

  static func errorTitle(_ message: String) -> String {
    if message.hasPrefix(linkFailedPrefix) {
      return "⚠️ " + t("获取播放链接失败", "Failed to Resolve Stream")
    }
    if message.contains("播放失败") {
      return "⚠️ " + t("视频播放失败", "Video Playback Failed")
    }
    return "⚠️ " + t("播放失败", "Playback Failed")
  }

  static func errorDetail(_ message: String) -> String {
    if message.hasPrefix("\(linkFailedPrefix)：") {
      return String(message.dropFirst("\(linkFailedPrefix)：".count))
    }
    if message.hasPrefix("\(linkFailedPrefix): ") {
      return String(message.dropFirst("\(linkFailedPrefix): ".count))
    }
    return message
  }

  static func swipeSeekMs(dx: CGFloat, width: CGFloat) -> Int64 {
    guard width > 0 else { return 0 }
    return Int64((dx / width) * 120_000.0)
  }

  // Canonical fitMode IDs shared with Flutter PlaybackConfig (`fit`, `zoom`, `fill`).
  static let fitModes: [(String, String, String)] = [
    ("fit", "原比例", "Original"),
    ("zoom", "裁剪铺满", "Crop"),
    ("fill", "拉伸铺满", "Stretch")
  ]

  static func fitModeLabel(_ mode: String) -> String {
    switch mode {
    case "zoom": return t("裁剪铺满", "Crop")
    case "fill": return t("拉伸铺满", "Stretch")
    default: return t("原比例", "Original")
    }
  }

  static func fitModePanelLabel(_ mode: String) -> String {
    switch mode {
    case "zoom": return t("裁剪填充", "Crop")
    case "fill": return t("拉伸填充", "Stretch")
    default: return t("适应（留黑边）", "Fit (letterbox)")
    }
  }

  static func nextFitMode(_ mode: String) -> String {
    let ids = fitModes.map { $0.0 }
    let idx = ids.firstIndex(of: mode) ?? 0
    return ids[(idx + 1) % ids.count]
  }

  // iOS-supported playback kernels (`avplayer`, `mpv`, `vlc`), normalizing cross-platform configs (`exo`->`avplayer`, `mdk`->`vlc`).
  static let iosKernels: [String] = ["avplayer", "mpv", "vlc"]

  static func normalizeIosKernel(_ raw: String) -> String {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "mpv":
      return "mpv"
    case "vlc", "mdk":
      return "vlc"
    default:
      return "avplayer"
    }
  }

  static func kernelShortName(_ raw: String) -> String {
    switch normalizeIosKernel(raw) {
    case "mpv": return "MPV"
    case "vlc": return "VLC"
    default: return "AVPlayer"
    }
  }

  static func kernelOptionName(_ raw: String) -> String {
    switch normalizeIosKernel(raw) {
    case "mpv": return "MPV (MPV)"
    case "vlc": return "VLC (FFmpeg)"
    default: return "AVPlayer (SYSTEM)"
    }
  }

  static let danmakuColorModes = ["random_Mix", "white", "original", "gradient", "random"]

  static func danmakuColorModeLabel(_ mode: String) -> String {
    switch mode {
    case "random_Mix", "0": return t("随机（混渐变）", "Random (Mix Gradient)")
    case "white", "1": return t("白色", "White")
    case "original", "2": return t("自带颜色", "Original")
    case "gradient", "3": return t("全部渐变", "All Gradient")
    case "random", "random_Color", "4": return t("随机彩色", "Random Color")
    default: return t("自带颜色", "Original")
    }
  }

  static let danmakuGradientColors: [(UIColor, UIColor)] = [
    (uiColor(0xFF6B9D), uiColor(0xC44DFF)),
    (uiColor(0xFFD700), uiColor(0xFF6B35)),
    (uiColor(0x00D2FF), uiColor(0x3AFFA3)),
    (uiColor(0xA78BFA), uiColor(0xF472B6)),
    (uiColor(0x38BDF8), uiColor(0x34D399)),
    (uiColor(0xFB7185), uiColor(0xA855F7)),
    (uiColor(0xFB923C), uiColor(0xFACC15)),
    (uiColor(0x2DD4BF), uiColor(0x60A5FA))
  ]

  static let danmakuRandomColors: [UIColor] = [
    uiColor(0xFF6B9D), uiColor(0x70A1FF), uiColor(0x7BED9F), uiColor(0xFFA502), uiColor(0xA29BFE),
    uiColor(0xFF7675), uiColor(0x55EFC4), uiColor(0xFD79A8), uiColor(0x74B9FF), uiColor(0xFFEAA7),
    uiColor(0xDFE6E9), uiColor(0x81ECEC), uiColor(0xFAB1A0), uiColor(0xE17055), uiColor(0x00CEC9)
  ]

  static func parseGradientPreset(_ gradientStyle: String) -> Int {
    let head = gradientStyle.components(separatedBy: ":").first ?? ""
    if let val = Int(head), (0...7).contains(val) {
      return val
    }
    return -1
  }

  static func parseFontWeight(_ gradientStyle: String) -> Int {
    guard let range = gradientStyle.range(of: ":w=") else { return 4 }
    let tail = String(gradientStyle[range.upperBound...])
    if let val = Int(tail) {
      return min(8, max(0, val))
    }
    return 4
  }

  static func uiFontWeight(from index: Int) -> UIFont.Weight {
    switch min(8, max(0, index)) {
    case 0: return .ultraLight
    case 1: return .thin
    case 2: return .light
    case 3: return .regular
    case 4: return .medium
    case 5: return .semibold
    case 6: return .bold
    case 7: return .heavy
    default: return .black
    }
  }

  static func uiColor(_ rgb: Int, alpha: CGFloat = 1.0) -> UIColor {
    let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
    let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
    let b = CGFloat(rgb & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: alpha)
  }

  static var danmakuGradientPresets: [(Int, String)] {
    [
      (-1, t("随机风格", "Random Style")),
      (0, t("粉→蓝", "Pink → Purple")),
      (1, t("金→橙红", "Gold → Orange")),
      (2, t("青→薄荷绿", "Cyan → Mint")),
      (3, t("紫→粉", "Violet → Pink")),
      (4, t("天蓝→青", "Sky → Emerald")),
      (5, t("玫红→深紫", "Rose → Purple")),
      (6, t("橙→柠檬黄", "Orange → Yellow")),
      (7, t("薄荷→蓝绿", "Teal → Blue"))
    ]
  }

  static func encodeGradientAndWeight(preset: Int, weight: Int) -> String {
    let g = (0...7).contains(preset) ? "\(preset)" : "none"
    let w = min(8, max(0, weight))
    return w == 4 ? g : "\(g):w=\(w)"
  }

  static func danmakuGradientLabel(_ gradientStyle: String) -> String {
    let p = parseGradientPreset(gradientStyle)
    return danmakuGradientPresets.first(where: { $0.0 == p })?.1 ?? t("随机风格", "Random Style")
  }

  static func danmakuFontWeightLabel(_ weight: Int) -> String {
    let w = min(8, max(0, weight))
    let zh = ["最细", "特细", "细", "偏细", "适中", "半粗", "粗", "特粗", "最粗"]
    let en = ["Thin", "Extra Light", "Light", "Normal-", "Medium", "Semi Bold", "Bold", "Extra Bold", "Black"]
    return chinese ? zh[w] : en[w]
  }

  static func accentColor(hex: String?) -> UIColor {
    guard let raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return uiColor(0x007AFF)
    }
    let cleaned = raw.hasPrefix("#") ? String(raw.dropFirst()) : (raw.lowercased().hasPrefix("0x") ? String(raw.dropFirst(2)) : raw)
    guard let val = UInt64(cleaned, radix: 16) else {
      return uiColor(0x007AFF)
    }
    let rgb = Int(val & 0xFFFFFF)
    return uiColor(rgb)
  }
}
