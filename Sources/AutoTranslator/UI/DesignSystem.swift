import AppKit

// MARK: - Layout Constants

let WINDOW_WIDTH: CGFloat = 448
let WINDOW_MIN_HEIGHT: CGFloat = 400
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

// MARK: - Color Palette

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

let WINDOW_BG = rgb(0, 0, 0, 0)
let PANEL_TOP = rgb(248, 242, 232, 0.96)
let PANEL_BOTTOM = rgb(231, 240, 248, 0.94)
let PANEL_BORDER = rgb(255, 255, 255, 0.62)
let SOURCE_CARD_BG = rgb(255, 255, 255, 0.72)
let LANG_BAR_BG = rgb(255, 255, 255, 0.58)
let DEST_CARD_BG = rgb(251, 253, 255, 0.76)
let SURFACE_BG = rgb(255, 255, 255, 0.74)
let SURFACE_BG_SOFT = rgb(255, 255, 255, 0.56)
let TOOLBAR_GHOST_BG = rgb(255, 255, 255, 0.08)
let CARD_BORDER = rgb(255, 255, 255, 0.58)
let BUTTON_BORDER = rgb(255, 255, 255, 0.78)
let TEXT_PRIMARY = rgb(31, 35, 42)
let TEXT_SECONDARY = rgb(103, 111, 123)
let TEXT_MUTED = rgb(144, 150, 159)
let BLUE_ACCENT = rgb(53, 97, 214)
let TEAL_ACCENT = rgb(20, 151, 135)
let AMBER_ACCENT = rgb(194, 121, 28)
let TOOLBAR_BUTTON_BORDER = rgb(255, 255, 255, 0.34)
let TOOLBAR_ACTIVE_BG = blendWithWhite(BLUE_ACCENT, amount: 0.82, alpha: 0.78)
let TOOLBAR_ACTIVE_BORDER = blendWithWhite(BLUE_ACCENT, amount: 0.56, alpha: 0.84)
let CHIP_BG = rgb(235, 242, 255, 0.96)
let CHIP_BG_ALT = rgb(231, 247, 242, 0.96)
let CHIP_BG_WARM = rgb(255, 238, 209, 0.97)
let GLOW_WARM = rgb(246, 198, 111, 0.22)
let GLOW_COOL = rgb(80, 128, 234, 0.16)
let GLOW_MINT = rgb(89, 183, 159, 0.12)

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
        layer.shadowOpacity = 0.08
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
