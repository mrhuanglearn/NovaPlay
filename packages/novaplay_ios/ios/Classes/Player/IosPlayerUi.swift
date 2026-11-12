import CoreGraphics
import CoreText
import UIKit

/// Material icon codepoints matching Android's `Ic` (`player_icons.otf`).
enum IosPlayerIcon {
  static let BACK = 0xf572
  static let CAMERA = 0xf29b
  static let REFRESH = 0xf00e9
  static let ROTATE = 0xf342
  static let PIP = 0xf2a5
  static let SUBTITLES = 0xf3fd
  static let SETTINGS = 0xf36e
  static let LOCK_OPEN = 0xf196
  static let LOCK = 0xf197
  static let REWIND = 0xf048
  static let FORWARD = 0xf047
  static let PLAY = 0xf00a0
  static let PAUSE = 0xe47c
  static let PREV = 0xf3a1
  static let NEXT = 0xf3a0
  static let SKIP_NEXT = 0xe5bd
  static let FORUM = 0xf0b0
  static let MENU = 0xe3dc
  static let UNFOLD = 0xe68e
  static let MORE = 0xe402
  static let LOCATE = 0xe2dc
  static let MEMORY = 0xe3db
  static let ASPECT = 0xe0a3
  static let FIT = 0xf079
  static let HEIGHT = 0xe308
  static let VOLUME_UP = 0xf4a8
  static let VOLUME_DOWN = 0xf4a5
  static let VOLUME_MUTE = 0xf4a6
  static let BRIGHTNESS = 0xeef9
  static let CHECK = 0xe156
  static let TUNE = 0xe683
  static let CLOCK = 0xe556
  static let BOLT = 0xe0ee
  static let DOUBLE_RIGHT = 0xf0531
  static let DOUBLE_LEFT = 0xf0530
  static let INFO = 0xe33d
  static let TEXT_FORMAT = 0xe64a
  static let CONTRAST = 0xf04d8
  static let COLUMNS = 0xf492
  static let BRUSH = 0xef02
  static let CANCEL = 0xef28
  static let CHEVRON = 0xe15f
  static let ADD = 0xe047
  static let REMOVE = 0xe516
  static let MUSIC = 0xf1fb
  static let CLOSE = 0xe16a
  static let MOVIE = 0xf1f5
  static let SEARCH = 0xe567
  static let SWAP_VERT = 0xe627
  static let AUTO_AWESOME = 0xe0b7
  static let CHECK_CIRCLE = 0xe159
  static let GRID_VIEW = 0xe2ea
  static let FILTER_LIST = 0xe280
  static let AIRPLAY = -1001

  private static let loadedCGFont: CGFont? = {
    let pluginBundle = Bundle(for: NovaPlayIosPlugin.self)
    var urls: [URL] = []
    if let resBundleUrl = pluginBundle.url(forResource: "novaplay_ios_resources", withExtension: "bundle"),
       let resBundle = Bundle(url: resBundleUrl),
       let u = resBundle.url(forResource: "player_icons", withExtension: "otf") {
      urls.append(u)
    }
    if let resBundleUrl = Bundle.main.url(forResource: "novaplay_ios_resources", withExtension: "bundle"),
       let resBundle = Bundle(url: resBundleUrl),
       let u = resBundle.url(forResource: "player_icons", withExtension: "otf") {
      urls.append(u)
    }
    if let u = pluginBundle.url(forResource: "player_icons", withExtension: "otf") {
      urls.append(u)
    }
    if let u = Bundle.main.url(forResource: "player_icons", withExtension: "otf") {
      urls.append(u)
    }
    for url in urls {
      if let provider = CGDataProvider(url: url as CFURL),
         let cgFont = CGFont(provider) {
        return cgFont
      }
    }
    return nil
  }()

  static func font(size: CGFloat) -> UIFont? {
    guard let cg = loadedCGFont else { return nil }
    return CTFontCreateWithGraphicsFont(cg, size, nil, nil) as UIFont
  }

  static func glyphString(_ code: Int) -> String? {
    guard code > 0, let scalar = UnicodeScalar(code) else { return nil }
    return String(scalar)
  }

  static func sfSymbolFallback(_ code: Int) -> String {
    switch code {
    case BACK: return "chevron.left"
    case CAMERA: return "camera"
    case REFRESH: return "arrow.clockwise"
    case ROTATE: return "rotate.right"
    case PIP: return "pip.enter"
    case SUBTITLES: return "captions.bubble"
    case SETTINGS: return "gearshape"
    case LOCK_OPEN: return "lock.open"
    case LOCK: return "lock.fill"
    case REWIND: return "gobackward.10"
    case FORWARD: return "goforward.10"
    case PLAY: return "play.fill"
    case PAUSE: return "pause.fill"
    case PREV: return "backward.end.fill"
    case NEXT: return "forward.end.fill"
    case SKIP_NEXT: return "forward.frame.fill"
    case FORUM: return "bubble.left.and.bubble.right"
    case MENU: return "list.bullet"
    case UNFOLD: return "chevron.up.chevron.down"
    case MORE: return "ellipsis"
    case LOCATE: return "scope"
    case MEMORY: return "cpu"
    case ASPECT: return "aspectratio"
    case FIT: return "arrow.up.left.and.arrow.down.right"
    case HEIGHT: return "arrow.up.and.down"
    case VOLUME_UP: return "speaker.wave.3.fill"
    case VOLUME_DOWN: return "speaker.wave.1.fill"
    case VOLUME_MUTE: return "speaker.slash.fill"
    case BRIGHTNESS: return "sun.max.fill"
    case CHECK: return "checkmark"
    case TUNE: return "slider.horizontal.3"
    case CLOCK: return "clock"
    case BOLT: return "bolt.fill"
    case DOUBLE_RIGHT: return "chevron.forward.2"
    case DOUBLE_LEFT: return "chevron.backward.2"
    case INFO: return "info.circle"
    case TEXT_FORMAT: return "textformat"
    case CONTRAST: return "circle.lefthalf.filled"
    case COLUMNS: return "rectangle.split.3x1"
    case BRUSH: return "paintbrush"
    case CANCEL: return "nosign"
    case CHEVRON: return "chevron.right"
    case ADD: return "plus"
    case REMOVE: return "minus"
    case MUSIC: return "waveform"
    case CLOSE: return "xmark"
    case MOVIE: return "film"
    case SEARCH: return "magnifyingglass"
    case SWAP_VERT: return "arrow.up.arrow.down"
    case AUTO_AWESOME: return "sparkles"
    case CHECK_CIRCLE: return "checkmark.circle.fill"
    case GRID_VIEW: return "square.grid.2x2"
    case FILTER_LIST: return "line.3.horizontal.decrease"
    case AIRPLAY: return "airplayvideo"
    default: return "circle"
    }
  }
}

/// View factory & color system matching Android's `PlayerUi.kt` 1:1.
final class IosPlayerUi {
  static let accentDefault = argb(0xFF00_7AFF)
  static let btnFill = argb(0x7311_1114)
  static let btnStroke = argb(0x1FFF_FFFF)
  static let textDim = argb(0x99FF_FFFF)
  static let cardFill = argb(0x14FF_FFFF)
  static let cardStroke = argb(0x12FF_FFFF)
  static let panelFill = argb(0xAC15_1515)
  static let menuFill = argb(0xFF19_191E)

  var accent: UIColor

  init(accentHex: String? = nil) {
    self.accent = IosPlayerUiText.accentColor(hex: accentHex)
  }

  static func argb(_ value: UInt32) -> UIColor {
    let a = CGFloat((value >> 24) & 0xFF) / 255.0
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }

  static func withAlpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
    color.withAlphaComponent(max(0, min(1, alpha)))
  }

  func applyRounded(_ view: UIView, fill: UIColor, radius: CGFloat, stroke: UIColor? = nil, strokeWidth: CGFloat = 1.0) {
    view.backgroundColor = fill
    view.layer.cornerRadius = radius
    view.layer.cornerCurve = .continuous
    if let stroke = stroke {
      view.layer.borderColor = stroke.cgColor
      view.layer.borderWidth = strokeWidth
    } else {
      view.layer.borderWidth = 0
      view.layer.borderColor = nil
    }
  }

  func icon(_ code: Int, size: CGFloat, color: UIColor = .white) -> PlayerIconView {
    PlayerIconView(code: code, size: size, color: color)
  }

  func text(
    _ string: String,
    size: CGFloat,
    color: UIColor = .white,
    bold: Bool = false,
    medium: Bool = false,
    mono: Bool = false
  ) -> UILabel {
    let lbl = UILabel()
    lbl.translatesAutoresizingMaskIntoConstraints = false
    lbl.text = string
    lbl.textColor = color
    if mono {
      lbl.font = UIFont.monospacedDigitSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    } else if bold {
      lbl.font = UIFont.systemFont(ofSize: size, weight: .semibold)
    } else if medium {
      lbl.font = UIFont.systemFont(ofSize: size, weight: .medium)
    } else {
      lbl.font = UIFont.systemFont(ofSize: size, weight: .regular)
    }
    return lbl
  }

  /// Round translucent icon button (`38pt` Back, `34pt` TopBar actions, `32pt` Prev/Next, `26pt` Stepper).
  func circleButton(
    _ code: Int,
    size: CGFloat,
    iconSize: CGFloat,
    fill: UIColor = IosPlayerUi.btnFill,
    stroke: UIColor? = IosPlayerUi.btnStroke,
    iconColor: UIColor = .white,
    onTap: (() -> Void)? = nil
  ) -> PlayerCircleButton {
    let btn = PlayerCircleButton(code: code, size: size, iconSize: iconSize, fill: fill, stroke: stroke, iconColor: iconColor)
    btn.onTap = onTap
    return btn
  }

  /// Bottom-bar 32pt pill (`弹`, `选集`/`频道`, `节目单`, `代理 ⌄`, `1.0x`).
  func pill(
    _ label: String,
    leading: Int? = nil,
    trailing: Int? = nil,
    mono: Bool = false,
    onTap: (() -> Void)? = nil
  ) -> PlayerPillView {
    let p = PlayerPillView(ui: self, label: label, leading: leading, trailing: trailing, mono: mono)
    p.onTap = onTap
    return p
  }

  /// Small translucent chip under title (`1920x800`, `第1集`) or bottom `statsLine`.
  func chip(maxWidth: CGFloat? = nil) -> PlayerInsetLabel {
    let lbl = PlayerInsetLabel(insets: UIEdgeInsets(top: 2.5, left: 7, bottom: 2.5, right: 7))
    lbl.translatesAutoresizingMaskIntoConstraints = false
    lbl.font = UIFont.systemFont(ofSize: 11.5, weight: .regular)
    lbl.textColor = Self.argb(0xE6FF_FFFF)
    lbl.numberOfLines = 1
    lbl.lineBreakMode = .byTruncatingMiddle
    lbl.clipsToBounds = true
    applyRounded(lbl, fill: Self.argb(0x24FF_FFFF), radius: 9)
    lbl.isHidden = true
    if let mw = maxWidth {
      lbl.widthAnchor.constraint(lessThanOrEqualToConstant: mw).isActive = true
    }
    return lbl
  }

  func sectionLabel(_ title: String) -> UIView {
    let wrap = UIView()
    wrap.translatesAutoresizingMaskIntoConstraints = false
    let lbl = text(title, size: 12.5, color: Self.textDim)
    wrap.addSubview(lbl)
    NSLayoutConstraint.activate([
      lbl.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 2),
      lbl.trailingAnchor.constraint(lessThanOrEqualTo: wrap.trailingAnchor),
      lbl.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 18),
      lbl.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -8)
    ])
    return wrap
  }

  func card() -> PlayerCardView {
    PlayerCardView(ui: self)
  }

  func addRow(_ card: PlayerCardView, _ row: UIView) {
    card.addRow(row)
  }

  func row(
    iconCode: Int?,
    title: String,
    subtitle: String? = nil,
    trailing: UIView? = nil,
    rotateIcon: Bool = false,
    minHeight: CGFloat? = nil,
    onTap: (() -> Void)? = nil
  ) -> PlayerRowView {
    let r = PlayerRowView(
      ui: self,
      iconCode: iconCode,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      rotateIcon: rotateIcon,
      minHeight: minHeight
    )
    r.onTap = onTap
    return r
  }

  func valueBadge(_ value: String) -> PlayerInsetLabel {
    let lbl = PlayerInsetLabel(insets: UIEdgeInsets(top: 3, left: 8, bottom: 3, right: 8))
    lbl.translatesAutoresizingMaskIntoConstraints = false
    lbl.font = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    lbl.textColor = Self.argb(0xD9FF_FFFF)
    lbl.clipsToBounds = true
    applyRounded(lbl, fill: Self.argb(0x1FFF_FFFF), radius: 10)
    lbl.text = value
    lbl.setContentHuggingPriority(.required, for: .horizontal)
    lbl.setContentCompressionResistancePriority(.required, for: .horizontal)
    return lbl
  }

  func textField(text initial: String, placeholder: String, numeric: Bool = false) -> PlayerTextField {
    let tf = PlayerTextField()
    tf.translatesAutoresizingMaskIntoConstraints = false
    tf.text = initial
    tf.textColor = .white
    tf.tintColor = accent
    tf.font = UIFont.systemFont(ofSize: 14)
    tf.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: Self.argb(0x66FF_FFFF)]
    )
    tf.keyboardAppearance = .dark
    tf.returnKeyType = .done
    tf.autocorrectionType = .no
    tf.autocapitalizationType = .none
    if numeric {
      tf.keyboardType = .numberPad
    }
    applyRounded(tf, fill: Self.cardFill, radius: 10, stroke: Self.cardStroke, strokeWidth: 0.6)
    return tf
  }
}

// MARK: - Reusable Primitives & Custom Drawn Controls

final class PlayerGradientView: UIView {
  override static var layerClass: AnyClass { CAGradientLayer.self }
  var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

  init(topColor: UIColor, bottomColor: UIColor) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isUserInteractionEnabled = true
    gradientLayer.colors = [topColor.cgColor, bottomColor.cgColor]
    gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    gradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class PlayerInsetLabel: UILabel {
  var insets: UIEdgeInsets {
    didSet { invalidateIntrinsicContentSize(); setNeedsDisplay() }
  }

  init(insets: UIEdgeInsets) {
    self.insets = insets
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: insets))
  }

  override var intrinsicContentSize: CGSize {
    let s = super.intrinsicContentSize
    guard s.width > 0 && s.height > 0 else { return s }
    return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let inner = CGSize(
      width: max(0, size.width - insets.left - insets.right),
      height: max(0, size.height - insets.top - insets.bottom)
    )
    let fit = super.sizeThatFits(inner)
    guard fit.width > 0 && fit.height > 0 else { return fit }
    return CGSize(width: fit.width + insets.left + insets.right, height: fit.height + insets.top + insets.bottom)
  }
}

final class PlayerTextField: UITextField, UITextFieldDelegate {
  private let pad = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
  var onTextChanged: ((String) -> Void)?
  var onSubmit: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    delegate = self
    addTarget(self, action: #selector(editingChanged), for: .editingChanged)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: pad) }
  override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: pad) }
  override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: pad) }

  @objc private func editingChanged() {
    onTextChanged?(text ?? "")
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    onSubmit?()
    return true
  }
}

/// Renders an icon from `player_icons.otf` directly via CoreText `CGFont`, with automatic SF Symbols fallback.
final class PlayerIconView: UIView {
  private let label = UILabel()
  private let imageView = UIImageView()

  var code: Int {
    didSet { applyGlyph() }
  }
  var iconSize: CGFloat {
    didSet { applyGlyph(); invalidateIntrinsicContentSize() }
  }
  var iconColor: UIColor {
    didSet {
      label.textColor = iconColor
      imageView.tintColor = iconColor
    }
  }

  init(code: Int, size: CGFloat, color: UIColor = .white) {
    self.code = code
    self.iconSize = size
    self.iconColor = color
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isUserInteractionEnabled = false

    label.translatesAutoresizingMaskIntoConstraints = false
    label.textAlignment = .center
    label.textColor = color
    addSubview(label)

    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFit
    imageView.tintColor = color
    addSubview(imageView)

    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: centerXAnchor),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.widthAnchor.constraint(lessThanOrEqualToConstant: size + 2),
      imageView.heightAnchor.constraint(lessThanOrEqualToConstant: size + 2)
    ])
    setContentHuggingPriority(.required, for: .horizontal)
    setContentHuggingPriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .vertical)
    applyGlyph()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: ceil(iconSize), height: ceil(iconSize))
  }

  private func applyGlyph() {
    if code > 0, let font = IosPlayerIcon.font(size: iconSize), let glyph = IosPlayerIcon.glyphString(code) {
      label.font = font
      label.text = glyph
      label.isHidden = false
      imageView.isHidden = true
    } else {
      label.isHidden = true
      imageView.isHidden = false
      let cfg = UIImage.SymbolConfiguration(pointSize: iconSize * 0.82, weight: .medium)
      imageView.image = UIImage(systemName: IosPlayerIcon.sfSymbolFallback(code), withConfiguration: cfg)
    }
  }
}

class PlayerTappableView: UIControl {
  var onTap: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @objc private func handleTap() {
    onTap?()
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.1) {
        self.alpha = self.isHighlighted ? 0.72 : (self.isEnabled ? 1.0 : 0.45)
      }
    }
  }
}

final class PlayerCircleButton: PlayerTappableView {
  let iconView: PlayerIconView
  private let diameter: CGFloat

  init(
    code: Int,
    size: CGFloat,
    iconSize: CGFloat,
    fill: UIColor = IosPlayerUi.btnFill,
    stroke: UIColor? = IosPlayerUi.btnStroke,
    iconColor: UIColor = .white
  ) {
    self.diameter = size
    self.iconView = PlayerIconView(code: code, size: iconSize, color: iconColor)
    super.init(frame: .zero)
    backgroundColor = fill
    layer.cornerRadius = size * 0.5
    if let stroke = stroke {
      layer.borderColor = stroke.cgColor
      layer.borderWidth = 0.6
    }
    addSubview(iconView)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),
      iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: diameter, height: diameter)
  }
}

final class PlayerPillView: PlayerTappableView {
  let labelView: UILabel
  let leadingIcon: PlayerIconView?
  let trailingIcon: PlayerIconView?

  init(ui: IosPlayerUi, label: String, leading: Int?, trailing: Int?, mono: Bool) {
    self.labelView = ui.text(label, size: 13.5, mono: mono)
    self.leadingIcon = leading.map { ui.icon($0, size: 17) }
    self.trailingIcon = trailing.map { ui.icon($0, size: 13, color: IosPlayerUi.argb(0xCCFF_FFFF)) }
    super.init(frame: .zero)

    ui.applyRounded(self, fill: IosPlayerUi.btnFill, radius: 16, stroke: IosPlayerUi.btnStroke, strokeWidth: 0.6)
    labelView.numberOfLines = 1
    labelView.isUserInteractionEnabled = false

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.alignment = .center
    stack.spacing = 0
    stack.isUserInteractionEnabled = false
    if let l = leadingIcon {
      stack.addArrangedSubview(l)
      stack.setCustomSpacing(8, after: l)
    }
    stack.addArrangedSubview(labelView)
    if let t = trailingIcon {
      stack.setCustomSpacing(6, after: labelView)
      stack.addArrangedSubview(t)
    }
    addSubview(stack)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor)
    ])
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class PlayerCardView: UIView {
  private let stack = UIStackView()

  init(ui: IosPlayerUi) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    clipsToBounds = true
    ui.applyRounded(self, fill: IosPlayerUi.cardFill, radius: 16, stroke: IosPlayerUi.cardStroke, strokeWidth: 0.5)

    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 0
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var rowCount: Int { stack.arrangedSubviews.count }

  func addRow(_ row: UIView) {
    if !stack.arrangedSubviews.isEmpty {
      let sep = UIView()
      sep.translatesAutoresizingMaskIntoConstraints = false
      sep.backgroundColor = IosPlayerUi.cardStroke
      sep.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
      stack.addArrangedSubview(sep)
    }
    stack.addArrangedSubview(row)
  }
}

final class PlayerRowView: PlayerTappableView {
  let iconView: PlayerIconView?
  let titleLabel: UILabel
  let subtitleLabel: UILabel?

  init(
    ui: IosPlayerUi,
    iconCode: Int?,
    title: String,
    subtitle: String?,
    trailing: UIView?,
    rotateIcon: Bool,
    minHeight: CGFloat?
  ) {
    self.iconView = iconCode.map { ui.icon($0, size: 18, color: IosPlayerUi.argb(0xD9FF_FFFF)) }
    self.titleLabel = ui.text(title, size: 14.5)
    self.subtitleLabel = subtitle.map { ui.text($0, size: 10.5, color: IosPlayerUi.textDim) }
    super.init(frame: .zero)

    titleLabel.numberOfLines = 2
    subtitleLabel?.numberOfLines = 3

    let textCol = UIStackView()
    textCol.translatesAutoresizingMaskIntoConstraints = false
    textCol.axis = .vertical
    textCol.alignment = .fill
    textCol.spacing = 3
    textCol.isUserInteractionEnabled = false
    textCol.addArrangedSubview(titleLabel)
    if let sub = subtitleLabel {
      textCol.addArrangedSubview(sub)
    }

    let hStack = UIStackView()
    hStack.translatesAutoresizingMaskIntoConstraints = false
    hStack.axis = .horizontal
    hStack.alignment = .center
    hStack.spacing = 12

    if let ic = iconView {
      let icWrap = UIView()
      icWrap.translatesAutoresizingMaskIntoConstraints = false
      icWrap.isUserInteractionEnabled = false
      icWrap.addSubview(ic)
      if rotateIcon {
        ic.transform = CGAffineTransform(rotationAngle: .pi * 0.5)
      }
      NSLayoutConstraint.activate([
        icWrap.widthAnchor.constraint(equalToConstant: 20),
        icWrap.heightAnchor.constraint(equalToConstant: 20),
        ic.centerXAnchor.constraint(equalTo: icWrap.centerXAnchor),
        ic.centerYAnchor.constraint(equalTo: icWrap.centerYAnchor)
      ])
      hStack.addArrangedSubview(icWrap)
      hStack.setCustomSpacing(14, after: icWrap)
    }

    hStack.addArrangedSubview(textCol)
    if let tr = trailing {
      hStack.addArrangedSubview(tr)
    }

    // Allow sub-controls (like SwitchControlView or stepper buttons) inside `trailing` to receive direct touches,
    // while tapping anywhere else on the row invokes `onTap`.
    hStack.isUserInteractionEnabled = (trailing != nil)
    addSubview(hStack)

    let targetMinH = minHeight ?? (subtitle == nil ? 44 : 49)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: targetMinH),
      hStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      hStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      hStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      hStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    if let ctrl = hit as? UIControl, ctrl !== self {
      return ctrl
    }
    return self.point(inside: point, with: event) ? self : nil
  }
}

/// Two hollow rounded bars: exact counterpart of Android's `PauseBars`.
final class PauseBarsView: UIView {
  var barColor: UIColor {
    didSet { setNeedsDisplay() }
  }

  init(color: UIColor = .black) {
    self.barColor = color
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ rect: CGRect) {
    guard let ctx = UIGraphicsGetCurrentContext() else { return }
    let w = bounds.width
    let h = bounds.height
    guard w > 0, h > 0 else { return }
    let sw = w * 0.115
    let bw = w * 0.2
    let top = h * 0.2
    let bottom = h * 0.8
    let r = bw * 0.38

    ctx.setStrokeColor(barColor.cgColor)
    ctx.setLineWidth(sw)
    let leftRect = CGRect(x: w * 0.22, y: top, width: bw, height: bottom - top)
    let rightRect = CGRect(x: w * 0.78 - bw, y: top, width: bw, height: bottom - top)
    UIBezierPath(roundedRect: leftRect, cornerRadius: r).stroke()
    UIBezierPath(roundedRect: rightRect, cornerRadius: r).stroke()
  }
}

/// Outlined battery icon (`19x10pt`) next to the clock in the Landscape top bar: exact counterpart of Android's `BatteryView`.
final class BatteryView: UIView {
  var level: CGFloat = 1.0 {
    didSet {
      level = max(0, min(1, level))
      setNeedsDisplay()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: 19, height: 10)
  }

  override func draw(_ rect: CGRect) {
    let w = bounds.width
    let h = bounds.height
    guard w > 0, h > 0 else { return }
    let sw = h * 0.12
    UIColor.white.setStroke()
    UIColor.white.setFill()

    let body = CGRect(x: sw * 0.5, y: sw * 0.5, width: w - sw * 2.1, height: h - sw)
    let bodyPath = UIBezierPath(roundedRect: body, cornerRadius: h * 0.22)
    bodyPath.lineWidth = sw
    bodyPath.stroke()

    let nub = CGRect(x: w - sw * 1.2, y: h * 0.3, width: sw * 1.2, height: h * 0.4)
    UIBezierPath(roundedRect: nub, cornerRadius: sw * 0.5).fill()

    let inset = sw * 1.6
    let full = max(0, body.width - inset * 2 + sw)
    let fillW = full * level
    if fillW > 0.2 {
      let fillRect = CGRect(
        x: body.minX + inset - sw * 0.5,
        y: body.minY + inset - sw * 0.5,
        width: fillW,
        height: max(0, body.height - inset * 2 + sw)
      )
      UIBezierPath(roundedRect: fillRect, cornerRadius: sw * 0.5).fill()
    }
  }
}

/// Turning white arc on a grey ring (`30x30pt`) inside the center loading box: exact counterpart of Android's `RingSpinner`.
final class RingSpinnerView: UIView {
  private let ringLayer = CAShapeLayer()
  private let arcLayer = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    isOpaque = false
    backgroundColor = .clear
    isUserInteractionEnabled = false

    ringLayer.fillColor = UIColor.clear.cgColor
    ringLayer.strokeColor = IosPlayerUi.argb(0x40FF_FFFF).cgColor

    arcLayer.fillColor = UIColor.clear.cgColor
    arcLayer.strokeColor = UIColor.white.cgColor
    arcLayer.lineCap = .round

    layer.addSublayer(ringLayer)
    layer.addSublayer(arcLayer)
    startSpinning()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: 30, height: 30)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    let h = bounds.height
    guard w > 0, h > 0 else { return }
    let sw = w * 0.14
    ringLayer.frame = bounds
    arcLayer.frame = bounds
    ringLayer.lineWidth = sw
    arcLayer.lineWidth = sw

    let radius = min(w, h) * 0.5 - sw * 0.5
    let center = CGPoint(x: w * 0.5, y: h * 0.5)
    ringLayer.path = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath
    let startA = -CGFloat.pi * 0.5
    let endA = startA + (80.0 * .pi / 180.0)
    arcLayer.path = UIBezierPath(arcCenter: center, radius: radius, startAngle: startA, endAngle: endA, clockwise: true).cgPath
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      startSpinning()
    } else {
      arcLayer.removeAnimation(forKey: "spin")
    }
  }

  private func startSpinning() {
    guard arcLayer.animation(forKey: "spin") == nil else { return }
    let anim = CABasicAnimation(keyPath: "transform.rotation.z")
    anim.fromValue = 0.0
    anim.toValue = Double.pi * 2.0
    anim.duration = 0.9
    anim.repeatCount = .infinity
    anim.isRemovedOnCompletion = false
    arcLayer.add(anim, forKey: "spin")
  }
}

/// Compact `39x22pt` pill switch (`#5B5B5F` off -> `accent` on, white circular thumb): exact counterpart of Android's `SwitchView`.
final class SwitchControlView: UIControl {
  private(set) var isOn: Bool
  private let accent: UIColor
  private let onChange: (Bool) -> Void
  private let trackView = UIView()
  private let thumbView = UIView()
  private var thumbLeadingConstraint: NSLayoutConstraint!

  init(accent: UIColor, isOn: Bool, onChange: @escaping (Bool) -> Void) {
    self.accent = accent
    self.isOn = isOn
    self.onChange = onChange
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    trackView.translatesAutoresizingMaskIntoConstraints = false
    trackView.isUserInteractionEnabled = false
    trackView.layer.cornerRadius = 11
    addSubview(trackView)

    thumbView.translatesAutoresizingMaskIntoConstraints = false
    thumbView.isUserInteractionEnabled = false
    thumbView.backgroundColor = .white
    thumbView.layer.cornerRadius = 8
    trackView.addSubview(thumbView)

    thumbLeadingConstraint = thumbView.leadingAnchor.constraint(equalTo: trackView.leadingAnchor, constant: isOn ? 20 : 3)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 39),
      heightAnchor.constraint(equalToConstant: 22),
      trackView.leadingAnchor.constraint(equalTo: leadingAnchor),
      trackView.trailingAnchor.constraint(equalTo: trailingAnchor),
      trackView.topAnchor.constraint(equalTo: topAnchor),
      trackView.bottomAnchor.constraint(equalTo: bottomAnchor),
      thumbView.widthAnchor.constraint(equalToConstant: 16),
      thumbView.heightAnchor.constraint(equalToConstant: 16),
      thumbView.centerYAnchor.constraint(equalTo: trackView.centerYAnchor),
      thumbLeadingConstraint
    ])
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
    applyVisualState(animated: false)
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: 39, height: 22)
  }

  @objc private func handleTap() {
    toggle()
  }

  func toggle() {
    setOn(!isOn, notify: true)
  }

  func setOn(_ next: Bool, notify: Bool = false) {
    guard next != isOn else { return }
    isOn = next
    applyVisualState(animated: true)
    if notify {
      onChange(next)
    }
  }

  private func applyVisualState(animated: Bool) {
    let targetColor = isOn ? accent : IosPlayerUi.argb(0xFF5B_5B5F)
    let targetConstant: CGFloat = isOn ? 20 : 3
    thumbLeadingConstraint.constant = targetConstant
    if animated {
      UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
        self.trackView.backgroundColor = targetColor
        self.layoutIfNeeded()
      }
    } else {
      trackView.backgroundColor = targetColor
    }
  }
}

/// Thin horizontal slider (`fraction` `0..1`, `secondary` buffer `0..1`) used by progress bar, HUDs, EPG, and danmaku style sliders.
final class ThinSliderView: UIControl {
  var fraction: CGFloat = 0 {
    didSet {
      fraction = max(0, min(1, fraction))
      setNeedsDisplay()
    }
  }
  var secondary: CGFloat = 0 {
    didSet {
      secondary = max(0, min(1, secondary))
      setNeedsDisplay()
    }
  }
  var fillColor: UIColor {
    didSet { setNeedsDisplay() }
  }
  var trackColor: UIColor {
    didSet { setNeedsDisplay() }
  }
  let thumbSize: CGFloat
  let trackHeight: CGFloat
  private(set) var isDraggingSlider: Bool = false
  var onChange: ((CGFloat, Bool) -> Void)?

  init(
    fillColor: UIColor,
    trackColor: UIColor = IosPlayerUi.argb(0x40FF_FFFF),
    thumbSize: CGFloat = 11,
    trackHeight: CGFloat = 3,
    onChange: ((CGFloat, Bool) -> Void)? = nil
  ) {
    self.fillColor = fillColor
    self.trackColor = trackColor
    self.thumbSize = thumbSize
    self.trackHeight = trackHeight
    self.onChange = onChange
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    let h = thumbSize > 0 ? (thumbSize + 14) : max(6, trackHeight + 4)
    return CGSize(width: UIView.noIntrinsicMetric, height: h)
  }

  private func fractionAt(x: CGFloat) -> CGFloat {
    let pad = thumbSize * 0.5
    let usable = max(1, bounds.width - pad * 2)
    return max(0, min(1, (x - pad) / usable))
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    guard isEnabled && isUserInteractionEnabled else { return false }
    isDraggingSlider = true
    fraction = fractionAt(x: touch.location(in: self).x)
    onChange?(fraction, false)
    return true
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    guard isDraggingSlider else { return false }
    fraction = fractionAt(x: touch.location(in: self).x)
    onChange?(fraction, false)
    return true
  }

  override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
    if let t = touch {
      fraction = fractionAt(x: t.location(in: self).x)
    }
    isDraggingSlider = false
    onChange?(fraction, true)
  }

  override func cancelTracking(with event: UIEvent?) {
    isDraggingSlider = false
    onChange?(fraction, true)
  }

  override func draw(_ rect: CGRect) {
    let pad = thumbSize * 0.5
    let cy = bounds.height * 0.5
    let th = trackHeight
    let left = pad
    let right = max(left, bounds.width - pad)
    let totalW = right - left
    guard totalW > 0 else { return }

    trackColor.setFill()
    UIBezierPath(roundedRect: CGRect(x: left, y: cy - th * 0.5, width: totalW, height: th), cornerRadius: th * 0.5).fill()

    if secondary > 0 {
      IosPlayerUi.argb(0x66FF_FFFF).setFill()
      UIBezierPath(
        roundedRect: CGRect(x: left, y: cy - th * 0.5, width: totalW * secondary, height: th),
        cornerRadius: th * 0.5
      ).fill()
    }

    let fillW = totalW * fraction
    if fillW > 0 {
      fillColor.setFill()
      UIBezierPath(
        roundedRect: CGRect(x: left, y: cy - th * 0.5, width: fillW, height: th),
        cornerRadius: th * 0.5
      ).fill()
    }

    if thumbSize > 0 {
      let cx = left + fillW
      UIColor.white.setFill()
      UIBezierPath(
        ovalIn: CGRect(x: cx - thumbSize * 0.5, y: cy - thumbSize * 0.5, width: thumbSize, height: thumbSize)
      ).fill()
    }
  }
}

/// Tall `34x254pt` vertical fill slider on the left side of the 2-column Speed Menu: exact counterpart of Android's `VerticalFillSlider`.
final class VerticalFillSliderView: UIControl {
  var fraction: CGFloat = 0 {
    didSet {
      fraction = max(0, min(1, fraction))
      setNeedsDisplay()
    }
  }
  var topLabel: String = "" {
    didSet { setNeedsDisplay() }
  }
  var bottomLabel: String = "0.5" {
    didSet { setNeedsDisplay() }
  }
  private let accent: UIColor
  private let onChange: (CGFloat, Bool) -> Void

  init(accent: UIColor, onChange: @escaping (CGFloat, Bool) -> Void) {
    self.accent = accent
    self.onChange = onChange
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isOpaque = false
    backgroundColor = .clear
    contentMode = .redraw
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: 34, height: 254)
  }

  private func fractionAt(y: CGFloat) -> CGFloat {
    let w = bounds.width
    let h = bounds.height
    let span = max(1, h - w)
    return max(0, min(1, 1.0 - (y - w * 0.5) / span))
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    fraction = fractionAt(y: touch.location(in: self).y)
    onChange(fraction, false)
    return true
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    fraction = fractionAt(y: touch.location(in: self).y)
    onChange(fraction, false)
    return true
  }

  override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
    if let t = touch {
      fraction = fractionAt(y: t.location(in: self).y)
    }
    onChange(fraction, true)
  }

  override func cancelTracking(with event: UIEvent?) {
    onChange(fraction, true)
  }

  override func draw(_ rect: CGRect) {
    let w = bounds.width
    let h = bounds.height
    guard w > 0, h > 0 else { return }
    let r = w * 0.5

    let trackPath = UIBezierPath(roundedRect: bounds, cornerRadius: r)
    IosPlayerUi.argb(0x1FFF_FFFF).setFill()
    trackPath.fill()

    if let ctx = UIGraphicsGetCurrentContext() {
      ctx.saveGState()
      trackPath.addClip()
      let fillTop = h - w - (h - w * 2) * fraction
      accent.setFill()
      UIBezierPath(roundedRect: CGRect(x: 0, y: fillTop, width: w, height: h - fillTop), cornerRadius: r).fill()
      ctx.restoreGState()
    }

    let font = UIFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    let para = NSMutableParagraphStyle()
    para.alignment = .center

    if !topLabel.isEmpty {
      let topAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: UIColor.white,
        .paragraphStyle: para
      ]
      let sz = (topLabel as NSString).size(withAttributes: topAttrs)
      (topLabel as NSString).draw(in: CGRect(x: 0, y: 10, width: w, height: sz.height + 2), withAttributes: topAttrs)
    }
    if !bottomLabel.isEmpty {
      let botAttrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: IosPlayerUi.argb(0x99FF_FFFF),
        .paragraphStyle: para
      ]
      let sz = (bottomLabel as NSString).size(withAttributes: botAttrs)
      (bottomLabel as NSString).draw(
        in: CGRect(x: 0, y: h - sz.height - 10, width: w, height: sz.height + 2),
        withAttributes: botAttrs
      )
    }
  }
}
