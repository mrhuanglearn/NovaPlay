import Foundation

struct SubtitleCue {
  let startMs: Int64
  let endMs: Int64
  let text: String
}

/// Parses external sidecar subtitles (`.srt`, `.vtt`, `.ass`/`.ssa`) loaded via `SourcePayload.subtitles` or user URL/file.
enum SidecarSubtitleParser {
  static func parse(_ raw: String) -> [SubtitleCue] {
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    if normalized.contains("[Events]") && normalized.contains("Dialogue:") {
      return parseAss(normalized)
    }
    return parseSrtOrVtt(normalized)
  }

  private static func parseSrtOrVtt(_ content: String) -> [SubtitleCue] {
    var cues: [SubtitleCue] = []
    let blocks = content.components(separatedBy: "\n\n")
    for block in blocks {
      let lines = block
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("WEBVTT") && !$0.hasPrefix("NOTE") }
      guard let arrowIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
      let parts = lines[arrowIdx].components(separatedBy: "-->")
      guard parts.count >= 2,
            let startMs = parseTimestampMs(parts[0]),
            let endMs = parseTimestampMs(parts[1]),
            endMs > startMs else { continue }
      let bodyLines = lines[(arrowIdx + 1)...]
      let text = stripSubtitleTags(bodyLines.joined(separator: "\n"))
      if !text.isEmpty {
        cues.append(SubtitleCue(startMs: startMs, endMs: endMs, text: text))
      }
    }
    return cues.sorted { $0.startMs < $1.startMs }
  }

  private static func parseAss(_ content: String) -> [SubtitleCue] {
    var cues: [SubtitleCue] = []
    var inEvents = false
    var startCol = 1
    var endCol = 2
    var textCol = 9
    var totalCols = 10

    for rawLine in content.components(separatedBy: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("[") && line.hasSuffix("]") {
        inEvents = (line.caseInsensitiveCompare("[Events]") == .orderedSame)
        continue
      }
      guard inEvents else { continue }
      if line.lowercased().hasPrefix("format:") {
        let spec = line.dropFirst("format:".count)
        let cols = spec.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if !cols.isEmpty {
          totalCols = cols.count
          if let s = cols.firstIndex(of: "start") { startCol = s }
          if let e = cols.firstIndex(of: "end") { endCol = e }
          if let t = cols.firstIndex(of: "text") { textCol = t }
        }
        continue
      }
      guard line.lowercased().hasPrefix("dialogue:") else { continue }
      let rest = String(line.dropFirst("dialogue:".count))
      let fields = splitAssFields(rest, maxSplits: max(1, totalCols - 1))
      guard fields.count > max(startCol, max(endCol, textCol)),
            let startMs = parseTimestampMs(fields[startCol]),
            let endMs = parseTimestampMs(fields[endCol]),
            endMs > startMs else { continue }
      let cleaned = stripSubtitleTags(
        fields[textCol]
          .replacingOccurrences(of: "\\N", with: "\n")
          .replacingOccurrences(of: "\\n", with: "\n")
      )
      if !cleaned.isEmpty {
        cues.append(SubtitleCue(startMs: startMs, endMs: endMs, text: cleaned))
      }
    }
    return cues.sorted { $0.startMs < $1.startMs }
  }

  private static func splitAssFields(_ s: String, maxSplits: Int) -> [String] {
    var result: [String] = []
    var current = ""
    var splits = 0
    for ch in s {
      if ch == "," && splits < maxSplits {
        result.append(current.trimmingCharacters(in: .whitespaces))
        current = ""
        splits += 1
      } else {
        current.append(ch)
      }
    }
    result.append(current.trimmingCharacters(in: .whitespaces))
    return result
  }

  private static func parseTimestampMs(_ raw: String) -> Int64? {
    let token = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
    let normalized = token.replacingOccurrences(of: ",", with: ".")
    let colonParts = normalized.components(separatedBy: ":")
    guard colonParts.count == 2 || colonParts.count == 3 else { return nil }
    let hours: Double
    let minutes: Double
    let seconds: Double
    if colonParts.count == 3 {
      guard let h = Double(colonParts[0]),
            let m = Double(colonParts[1]),
            let s = Double(colonParts[2]) else { return nil }
      hours = h
      minutes = m
      seconds = s
    } else {
      guard let m = Double(colonParts[0]),
            let s = Double(colonParts[1]) else { return nil }
      hours = 0
      minutes = m
      seconds = s
    }
    return Int64(((hours * 3600.0) + (minutes * 60.0) + seconds) * 1000.0)
  }

  private static func stripSubtitleTags(_ text: String) -> String {
    var out = ""
    var inBrace = false
    var inAngle = false
    for ch in text {
      if ch == "{" { inBrace = true; continue }
      if ch == "}" && inBrace { inBrace = false; continue }
      if ch == "<" { inAngle = true; continue }
      if ch == ">" && inAngle { inAngle = false; continue }
      if !inBrace && !inAngle {
        out.append(ch)
      }
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
