import AppKit

// MARK: - Layout Constants

let WINDOW_WIDTH: CGFloat = 448
let WINDOW_MIN_HEIGHT: CGFloat = 400
let MIN_WINDOW_WIDTH: CGFloat = 360
let MAX_WINDOW_WIDTH: CGFloat = 720
let RESIZE_GRIP_SIZE: CGFloat = 14
let RESIZE_EDGE_THICKNESS: CGFloat = 8
let RESIZE_CORNER_HIT_SIZE: CGFloat = 22
let OUTER_PADDING: CGFloat = 14
let SECTION_GAP: CGFloat = 11
let HEADER_HEIGHT: CGFloat = 38
let TOOLBAR_BUTTON_SIZE: CGFloat = 28
let BACKEND_BTN_WIDTH: CGFloat = 48
let CARD_RADIUS: CGFloat = 20
let PANEL_RADIUS: CGFloat = 28
let CARD_INSET_X: CGFloat = 16
let MAX_CARD_TEXT_HEIGHT: CGFloat = 220
let SRC_MAX_CARD_HEIGHT: CGFloat = 290
let DEST_MAX_CARD_HEIGHT: CGFloat = 340
let MAX_WINDOW_HEIGHT: CGFloat = 760
let LANG_BAR_HEIGHT: CGFloat = 42
let BODY_FONT_SIZE: CGFloat = 15

// MARK: - Theme Detection

var isDarkMode: Bool {
    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
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
    isDarkMode ? rgb(40, 40, 44, 0.96) : rgb(248, 242, 232, 0.96)
}
var PANEL_BOTTOM: NSColor {
    isDarkMode ? rgb(32, 32, 36, 0.94) : rgb(231, 240, 248, 0.94)
}
var PANEL_BORDER: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.10) : rgb(255, 255, 255, 0.62)
}
var SOURCE_CARD_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.06) : rgb(255, 255, 255, 0.72)
}
var LANG_BAR_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.05) : rgb(255, 255, 255, 0.58)
}
var DEST_CARD_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.05) : rgb(251, 253, 255, 0.76)
}
var SURFACE_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.08) : rgb(255, 255, 255, 0.74)
}
var SURFACE_BG_SOFT: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.04) : rgb(255, 255, 255, 0.56)
}
var TOOLBAR_GHOST_BG: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.06) : rgb(255, 255, 255, 0.08)
}
var CARD_BORDER: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.08) : rgb(255, 255, 255, 0.58)
}
var BUTTON_BORDER: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.10) : rgb(255, 255, 255, 0.78)
}
var TEXT_PRIMARY: NSColor {
    isDarkMode ? rgb(235, 237, 243) : rgb(31, 35, 42)
}
var TEXT_SECONDARY: NSColor {
    isDarkMode ? rgb(166, 172, 184) : rgb(103, 111, 123)
}
var TEXT_MUTED: NSColor {
    isDarkMode ? rgb(116, 120, 130) : rgb(144, 150, 159)
}
var BLUE_ACCENT: NSColor {
    isDarkMode ? rgb(108, 147, 242) : rgb(53, 97, 214)
}
var TEAL_ACCENT: NSColor {
    isDarkMode ? rgb(56, 185, 168) : rgb(20, 151, 135)
}
var AMBER_ACCENT: NSColor {
    isDarkMode ? rgb(234, 165, 52) : rgb(194, 121, 28)
}
var TOOLBAR_BUTTON_BORDER: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.12) : rgb(255, 255, 255, 0.34)
}
var TOOLBAR_ACTIVE_BG: NSColor {
    isDarkMode
        ? blendWithBlack(BLUE_ACCENT, amount: 0.55, alpha: 0.55)
        : blendWithWhite(BLUE_ACCENT, amount: 0.82, alpha: 0.78)
}
var TOOLBAR_ACTIVE_BORDER: NSColor {
    isDarkMode
        ? blendWithBlack(BLUE_ACCENT, amount: 0.35, alpha: 0.75)
        : blendWithWhite(BLUE_ACCENT, amount: 0.56, alpha: 0.84)
}
var CHIP_BG: NSColor {
    isDarkMode ? rgb(30, 38, 58, 0.96) : rgb(235, 242, 255, 0.96)
}
var CHIP_BG_ALT: NSColor {
    isDarkMode ? rgb(28, 48, 42, 0.96) : rgb(231, 247, 242, 0.96)
}
var CHIP_BG_WARM: NSColor {
    isDarkMode ? rgb(50, 42, 28, 0.96) : rgb(255, 238, 209, 0.97)
}
var GLOW_WARM: NSColor {
    isDarkMode ? rgb(246, 198, 111, 0.05) : rgb(246, 198, 111, 0.22)
}
var GLOW_COOL: NSColor {
    isDarkMode ? rgb(80, 128, 234, 0.04) : rgb(80, 128, 234, 0.16)
}
var GLOW_MINT: NSColor {
    isDarkMode ? rgb(89, 183, 159, 0.03) : rgb(89, 183, 159, 0.12)
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
        layer.shadowOffset = CGSize(width: 0, height: 8)
        layer.shadowRadius = 20
        layer.shadowOpacity = isDarkMode ? 0.18 : 0.08
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
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .light)
        button.image = image.withSymbolConfiguration(config)
        button.imageScaling = .scaleProportionallyUpOrDown
        button.title = ""
        button.contentTintColor = tint
    } else {
        button.image = nil
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
    let probe = createLabel(fontSize: fontSize, bold: bold, wraps: true)
    probe.stringValue = text
    let size = probe.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10000))
    return max(minimum, ceil(size.height) + 2)
}

func measureTextWidth(_ text: String, fontSize: CGFloat, bold: Bool = false) -> CGFloat {
    let probe = createLabel(fontSize: fontSize, bold: bold, wraps: false)
    probe.stringValue = text
    return ceil(probe.cell!.cellSize.width)
}
