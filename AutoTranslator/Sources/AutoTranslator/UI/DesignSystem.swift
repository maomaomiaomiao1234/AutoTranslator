import AppKit

// MARK: - Layout Constants

let WINDOW_WIDTH: CGFloat = 464
let WINDOW_MIN_HEIGHT: CGFloat = 424
let MIN_WINDOW_WIDTH: CGFloat = 360
let MAX_WINDOW_WIDTH: CGFloat = 720
let RESIZE_GRIP_SIZE: CGFloat = 14
let RESIZE_EDGE_THICKNESS: CGFloat = 8
let RESIZE_CORNER_HIT_SIZE: CGFloat = 22
let OUTER_PADDING: CGFloat = 16
let SECTION_GAP: CGFloat = 12
let HEADER_HEIGHT: CGFloat = 44
let TOOLBAR_BUTTON_SIZE: CGFloat = 32
let BACKEND_BTN_WIDTH: CGFloat = 52
let CARD_RADIUS: CGFloat = 8
let PANEL_RADIUS: CGFloat = 20
let CONTROL_RADIUS: CGFloat = 8
let CARD_INSET_X: CGFloat = 16
let MAX_CARD_TEXT_HEIGHT: CGFloat = 252
let SRC_MAX_CARD_HEIGHT: CGFloat = 290
let DEST_MAX_CARD_HEIGHT: CGFloat = 380
let MAX_WINDOW_HEIGHT: CGFloat = 760
let LANG_BAR_HEIGHT: CGFloat = 44
let SOURCE_FONT_SIZE: CGFloat = 13.5
let BODY_FONT_SIZE: CGFloat = 16

// MARK: - Theme Detection

private var _cachedIsDarkMode: Bool = {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}()

var isDarkMode: Bool {
    _cachedIsDarkMode
}

func refreshThemeCache() {
    _cachedIsDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
}

// MARK: - Color Helpers

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func blendWithWhite(_ color: NSColor, amount: CGFloat, alpha: CGFloat = 1.0) -> NSColor {
    let baseR = Int(color.redComponent * 255)
    let baseG = Int(color.greenComponent * 255)
    let baseB = Int(color.blueComponent * 255)
    let r = CGFloat(baseR) + (255 - CGFloat(baseR)) * amount
    let g = CGFloat(baseG) + (255 - CGFloat(baseG)) * amount
    let b = CGFloat(baseB) + (255 - CGFloat(baseB)) * amount
    return rgb(r, g, b, alpha)
}

func blendWithBlack(_ color: NSColor, amount: CGFloat, alpha: CGFloat = 1.0) -> NSColor {
    let r = color.redComponent * (1 - amount)
    let g = color.greenComponent * (1 - amount)
    let b = color.blueComponent * (1 - amount)
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha)
}

// MARK: - Color Palette (Theme-aware)

var WINDOW_BG: NSColor { rgb(0, 0, 0, 0) }

var PANEL_TOP: NSColor {
    isDarkMode ? rgb(32, 31, 29, 0.97) : rgb(253, 251, 248, 0.98)
}
var PANEL_BOTTOM: NSColor {
    isDarkMode ? rgb(24, 24, 23, 0.96) : rgb(246, 242, 236, 0.97)
}
var PANEL_BORDER: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.13) : rgb(86, 70, 58, 0.14)
}
var SOURCE_CARD_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.055) : rgb(255, 255, 255, 0.70)
}
var LANG_BAR_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.050) : rgb(255, 255, 255, 0.66)
}
var DEST_CARD_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.078) : rgb(255, 255, 255, 0.92)
}
var SURFACE_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.085) : rgb(255, 255, 255, 0.82)
}
var SURFACE_BG_SOFT: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.045) : rgb(247, 244, 239, 0.74)
}
var TOOLBAR_GHOST_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.060) : rgb(255, 255, 255, 0.58)
}
var CARD_BORDER: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.10) : rgb(87, 71, 58, 0.11)
}
var BUTTON_BORDER: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.12) : rgb(87, 71, 58, 0.13)
}
var TEXT_PRIMARY: NSColor {
    isDarkMode ? rgb(240, 239, 236) : rgb(31, 29, 27)
}
var TEXT_SECONDARY: NSColor {
    isDarkMode ? rgb(177, 172, 164) : rgb(101, 91, 82)
}
var TEXT_MUTED: NSColor {
    isDarkMode ? rgb(126, 121, 114) : rgb(143, 132, 121)
}
var BLUE_ACCENT: NSColor {
    isDarkMode ? rgb(112, 145, 176) : rgb(46, 89, 126)
}
var TEAL_ACCENT: NSColor {
    isDarkMode ? rgb(78, 183, 160) : rgb(16, 132, 116)
}
var AMBER_ACCENT: NSColor {
    isDarkMode ? rgb(231, 164, 76) : rgb(177, 103, 28)
}
var CORAL_ACCENT: NSColor {
    isDarkMode ? rgb(238, 121, 92) : rgb(194, 75, 48)
}
var PANEL_HAIRLINE: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.075) : rgb(255, 255, 255, 0.72)
}
var TOOLBAR_BUTTON_BORDER: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.10) : rgb(87, 71, 58, 0.12)
}
var TOOLBAR_ACTIVE_BG: NSColor {
    isDarkMode
        ? blendWithBlack(CORAL_ACCENT, amount: 0.55, alpha: 0.58)
        : blendWithWhite(CORAL_ACCENT, amount: 0.84, alpha: 0.78)
}
var TOOLBAR_ACTIVE_BORDER: NSColor {
    isDarkMode
        ? blendWithBlack(CORAL_ACCENT, amount: 0.30, alpha: 0.78)
        : blendWithWhite(CORAL_ACCENT, amount: 0.54, alpha: 0.86)
}
var CHIP_BG: NSColor {
    isDarkMode ? rgb(33, 43, 52, 0.92) : rgb(230, 239, 244, 0.94)
}
var CHIP_BG_ALT: NSColor {
    isDarkMode ? rgb(28, 48, 42, 0.92) : rgb(226, 242, 236, 0.94)
}
var CHIP_BG_WARM: NSColor {
    isDarkMode ? rgb(50, 42, 31, 0.92) : rgb(251, 236, 211, 0.94)
}

// MARK: - View Styling Helpers

func styleSurface(_ view: NSView, background: NSColor, radius: CGFloat,
                  border: NSColor? = nil, shadow: Bool = false) {
    view.wantsLayer = true
    guard let layer = view.layer else { return }
    layer.cornerRadius = radius
    if shadow {
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 5)
        layer.shadowRadius = 14
        layer.shadowOpacity = isDarkMode ? 0.22 : 0.065
    } else {
        layer.masksToBounds = true
        layer.shadowOpacity = 0
    }
    layer.backgroundColor = background.cgColor
    if let border = border {
        layer.borderWidth = 1
        layer.borderColor = border.cgColor
    } else {
        layer.borderWidth = 0
    }
}

func stylePill(_ label: NSTextField, textColor: NSColor, background: NSColor,
               border: NSColor? = nil) {
    label.textColor = textColor
    styleSurface(label, background: background, radius: 11, border: border)
}

func createLabel(fontSize: CGFloat, color: NSColor = TEXT_PRIMARY, bold: Bool = false,
                 selectable: Bool = false, wraps: Bool = true) -> NSTextField {
    let label = NSTextField()
    label.isEditable = false
    label.isSelectable = selectable
    label.isBordered = false
    label.isBezeled = false
    label.drawsBackground = false
    label.textColor = color
    label.font = bold ? NSFont.boldSystemFont(ofSize: fontSize)
                      : NSFont.systemFont(ofSize: fontSize)
    label.cell?.wraps = wraps
    label.cell?.isScrollable = false
    label.cell?.lineBreakMode = wraps ? .byWordWrapping : .byClipping
    label.cell?.usesSingleLineMode = !wraps
    return label
}

func createTextView(fontSize: CGFloat, color: NSColor = TEXT_PRIMARY,
                    selectable: Bool = true) -> NSTextView {
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = selectable
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
    textView.textColor = color
    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = false
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.textContainerInset = .zero
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.lineBreakMode = .byWordWrapping
    return textView
}

func createPillLabel(fontSize: CGFloat = 11, color: NSColor = TEXT_SECONDARY,
                     background: NSColor = CHIP_BG) -> NSTextField {
    let label = createLabel(fontSize: fontSize, color: color, bold: true,
                            selectable: false, wraps: false)
    label.alignment = .center
    stylePill(label, textColor: color, background: background)
    return label
}

func applySymbol(_ button: NSButton, symbolName: String, fallback: String,
                 pointSize: CGFloat = 16, tint: NSColor = TEXT_SECONDARY) {
    if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        button.image = image.withSymbolConfiguration(config)
        button.imageScaling = .scaleProportionallyUpOrDown
        button.imagePosition = .imageOnly
        button.title = ""
        button.contentTintColor = tint
    } else {
        button.image = nil
        button.imagePosition = .noImage
        button.title = fallback
        button.font = NSFont.systemFont(ofSize: pointSize)
    }
}

func createIconButton(symbolName: String, fallback: String, pointSize: CGFloat = 16,
                      tint: NSColor = TEXT_SECONDARY, background: NSColor = SURFACE_BG,
                      size: CGFloat = TOOLBAR_BUTTON_SIZE,
                      border: NSColor = BUTTON_BORDER) -> NSButton {
    let button = NSButton()
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.focusRingType = .none
    styleSurface(button, background: background, radius: size / 2, border: border)
    applySymbol(button, symbolName: symbolName, fallback: fallback,
                pointSize: pointSize, tint: tint)
    return button
}

func createToolbarIconButton(symbolName: String, fallback: String,
                             pointSize: CGFloat = 12,
                             tint: NSColor = TEXT_SECONDARY) -> NSButton {
    return createIconButton(symbolName: symbolName, fallback: fallback,
                            pointSize: pointSize, tint: tint,
                            background: TOOLBAR_GHOST_BG, size: TOOLBAR_BUTTON_SIZE,
                            border: TOOLBAR_BUTTON_BORDER)
}

func measureTextHeight(_ text: String, width: CGFloat, fontSize: CGFloat,
                       bold: Bool = false, minimum: CGFloat = 0) -> CGFloat {
    let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    let rect = attributedString.boundingRect(
        with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    return max(minimum, ceil(rect.height) + 2)
}

func measureTextWidth(_ text: String, fontSize: CGFloat, bold: Bool = false) -> CGFloat {
    let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
    let attributes: [NSAttributedString.Key: Any] = [.font: font]
    let attributedString = NSAttributedString(string: text, attributes: attributes)
    return ceil(attributedString.size().width)
}
