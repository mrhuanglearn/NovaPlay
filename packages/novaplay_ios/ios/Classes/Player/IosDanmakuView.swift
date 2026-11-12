import CoreText
import UIKit

final class IosDanmakuView: UIView {
  struct Comment {
    let time: Double
    let mode: Int
    let color: Int
    let text: String
  }

  private struct ActiveComment {
    let comment: Comment
    let lane: Int
    let width: CGFloat
    let bornMs: Int64
  }

  private var comments: [Comment] = []
  var commentCount: Int { comments.count }

  private var config: DanmakuConfig?
  weak var kernel: IosPlayerKernel?
  var paused: Bool = false {
    didSet {
      syncDisplayLinkPaused()
    }
  }

  private var active: [ActiveComment] = []
  private var cursor: Int = 0
  private var lastPosMs: Int64 = 0
  private var displayLink: CADisplayLink?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
    contentMode = .redraw
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func startDisplayLink() {
    if displayLink == nil {
      let link = CADisplayLink(target: DisplayLinkProxy(target: self), selector: #selector(DisplayLinkProxy.tick))
      if #available(iOS 15.0, *) {
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
      }
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    syncDisplayLinkPaused()
  }

  func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  private func syncDisplayLinkPaused() {
    let shouldRun = (config?.enabled ?? false) && !comments.isEmpty && !paused
    displayLink?.isPaused = !shouldRun
  }

  func configure(_ cfg: DanmakuConfig) {
    config = cfg
    if !cfg.enabled && !active.isEmpty {
      active.removeAll()
    }
    syncDisplayLinkPaused()
    setNeedsDisplay()
  }

  func setComments(_ list: [Comment]) {
    comments = list.sorted { $0.time < $1.time }
    cursor = 0
    active.removeAll()
    syncDisplayLinkPaused()
    setNeedsDisplay()
  }

  fileprivate func onFrame() {
    guard let k = kernel, bounds.width > 0, bounds.height > 0 else { return }
    let pos = k.positionMs
    if pos < lastPosMs - 1500 {
      if let idx = comments.firstIndex(where: { Int64($0.time * 1000.0) >= pos }) {
        cursor = idx
      } else {
        cursor = comments.count
      }
      active.removeAll()
    }
    lastPosMs = pos

    guard let cfg = config, cfg.enabled else {
      if !active.isEmpty {
        active.removeAll()
        setNeedsDisplay()
      }
      return
    }

    let now = pos - Int64(cfg.delaySeconds * 1000.0)
    let weight = IosPlayerUiText.uiFontWeight(from: IosPlayerUiText.parseFontWeight(cfg.gradientStyle))
    let font = UIFont.systemFont(ofSize: CGFloat(max(10.0, cfg.fontSize)), weight: weight)
    let lineH = max(14.0, font.lineHeight * CGFloat(max(0.8, cfg.lineHeight)))
    let maxLanes = max(1, Int((bounds.height * CGFloat(max(0.1, min(1.0, cfg.area)))) / lineH))

    while cursor < comments.count && Int64(comments[cursor].time * 1000.0) <= now {
      let raw = comments[cursor]
      cursor += 1
      if cfg.blackList.contains(where: { !$0.isEmpty && raw.text.contains($0) }) {
        continue
      }
      var effectiveMode = raw.mode
      if (effectiveMode == 5 && !cfg.showTop) || (effectiveMode == 4 && !cfg.showBottom) {
        effectiveMode = 1
      }
      let adjusted = Comment(time: raw.time, mode: effectiveMode, color: raw.color, text: raw.text)
      let textWidth = ceil((adjusted.text as NSString).size(withAttributes: [.font: font]).width)
      guard let lane = (0..<maxLanes).first(where: { l in
        !active.contains(where: { $0.lane == l && $0.comment.mode == adjusted.mode && (now - $0.bornMs) < 3000 })
      }) else {
        continue
      }
      active.append(ActiveComment(comment: adjusted, lane: lane, width: textWidth, bornMs: now))
    }

    if !active.isEmpty {
      setNeedsDisplay()
    }
  }

  private func stableHash(_ c: Comment) -> Int {
    var h = 5381
    for byte in c.text.utf8 {
      h = ((h << 5) &+ h) ^ Int(byte)
    }
    h ^= Int(c.time * 1000.0)
    return h & 0x7FFFFFFF
  }

  override func draw(_ rect: CGRect) {
    guard let cfg = config, cfg.enabled, let ctx = UIGraphicsGetCurrentContext() else { return }
    let pos = (kernel?.positionMs ?? 0) - Int64(cfg.delaySeconds * 1000.0)
    let weight = IosPlayerUiText.uiFontWeight(from: IosPlayerUiText.parseFontWeight(cfg.gradientStyle))
    let font = UIFont.systemFont(ofSize: CGFloat(max(10.0, cfg.fontSize)), weight: weight)
    let alpha = CGFloat(min(1.0, max(0.0, cfg.opacity)))
    let lineH = max(14.0, font.lineHeight * CGFloat(max(0.8, cfg.lineHeight)))
    let travelMs = Int64(8000.0 / min(2.0, max(0.3, cfg.scrollSpeed)))
    let strokePt = CGFloat(max(0.0, cfg.strokeWidth))

    var kept: [ActiveComment] = []
    kept.reserveCapacity(active.count)

    for item in active {
      let age = pos - item.bornMs
      let life: Int64 = (item.comment.mode == 1) ? travelMs : 4000
      if age > life { continue }
      kept.append(item)
      if age < 0 { continue }

      let x: CGFloat
      if item.comment.mode == 1 {
        let progress = CGFloat(age) / CGFloat(max(1, travelMs))
        x = bounds.width - (bounds.width + item.width) * progress
      } else {
        x = (bounds.width - item.width) * 0.5
      }

      let topPadding: CGFloat = 8.0
      let y: CGFloat
      if item.comment.mode == 4 {
        y = bounds.height - lineH * CGFloat(item.lane + 1) - topPadding
      } else {
        y = topPadding + lineH * CGFloat(item.lane)
      }
      let pt = CGPoint(x: x, y: y)

      if strokePt > 0.05 {
        let strokeAttrs: [NSAttributedString.Key: Any] = [
          .font: font,
          .strokeColor: UIColor.black.withAlphaComponent(alpha),
          .strokeWidth: strokePt * 2.5
        ]
        (item.comment.text as NSString).draw(at: pt, withAttributes: strokeAttrs)
      }

      let h = stableHash(item.comment)
      let mode = cfg.colorMode
      let useGradient = (mode == "gradient" || mode == "3" || ((mode == "random_Mix" || mode == "0") && h % 5 == 0))

      if useGradient {
        let preset = IosPlayerUiText.parseGradientPreset(cfg.gradientStyle)
        let pairIdx = (0...7).contains(preset) ? preset : (h % IosPlayerUiText.danmakuGradientColors.count)
        let (c0, c1) = IosPlayerUiText.danmakuGradientColors[pairIdx]
        drawGradientText(item.comment.text, at: pt, width: max(1.0, item.width), font: font, c0: c0.withAlphaComponent(alpha), c1: c1.withAlphaComponent(alpha), in: ctx)
      } else {
        let fillColor: UIColor
        switch mode {
        case "white", "1":
          fillColor = .white
        case "random", "random_Color", "4", "random_Mix", "0":
          fillColor = IosPlayerUiText.danmakuRandomColors[h % IosPlayerUiText.danmakuRandomColors.count]
        default:
          fillColor = IosPlayerUiText.uiColor(item.comment.color & 0xFFFFFF)
        }
        let fillAttrs: [NSAttributedString.Key: Any] = [
          .font: font,
          .foregroundColor: fillColor.withAlphaComponent(alpha)
        ]
        (item.comment.text as NSString).draw(at: pt, withAttributes: fillAttrs)
      }
    }

    active = kept
  }

  private func drawGradientText(
    _ text: String,
    at point: CGPoint,
    width: CGFloat,
    font: UIFont,
    c0: UIColor,
    c1: UIColor,
    in ctx: CGContext
  ) {
    let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.white])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
    ctx.textPosition = CGPoint(x: point.x, y: point.y + font.ascender)
    ctx.setTextDrawingMode(.clip)
    CTLineDraw(line, ctx)
    if let grad = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(),
      colors: [c0.cgColor, c1.cgColor] as CFArray,
      locations: [0.0, 1.0]
    ) {
      ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: point.x, y: point.y),
        end: CGPoint(x: point.x + width, y: point.y),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
      )
    }
    ctx.restoreGState()
  }
}

private final class DisplayLinkProxy: NSObject {
  weak var target: IosDanmakuView?
  init(target: IosDanmakuView) {
    self.target = target
  }
  @objc func tick() {
    target?.onFrame()
  }
}
