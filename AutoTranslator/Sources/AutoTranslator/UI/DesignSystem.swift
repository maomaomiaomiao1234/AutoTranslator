import AppKit

// MARK: - Layout Constants

let WINDOW_WIDTH: CGFloat = 464
let WINDOW_MIN_HEIGHT: CGFloat = 424
let MIN_WINDOW_WIDTH: CGFloat = 360
let MAX_WINDOW_WIDTH: CGFloat = 720
let MINIMAL_WINDOW_MIN_WIDTH: CGFloat = 280
let MINIMAL_WINDOW_MAX_WIDTH: CGFloat = 420
let MINIMAL_WINDOW_MIN_HEIGHT: CGFloat = 88
let MINIMAL_WINDOW_MAX_HEIGHT: CGFloat = 320
let MINIMAL_WINDOW_PADDING_X: CGFloat = 20
let MINIMAL_WINDOW_PADDING_Y: CGFloat = 16
let MINIMAL_WINDOW_CURSOR_OFFSET_X: CGFloat = 16
let MINIMAL_WINDOW_CURSOR_OFFSET_Y: CGFloat = 18
let MINIMAL_WINDOW_SCREEN_MARGIN: CGFloat = 10
let MINIMAL_TEXT_MIN_HEIGHT: CGFloat = 48
let MINIMAL_PANEL_RADIUS: CGFloat = 16
let MINIMAL_TOOLBAR_HEIGHT: CGFloat = 28
let MINIMAL_TOOLBAR_BUTTON_SIZE: CGFloat = 28
let MINIMAL_TOOLBAR_GAP: CGFloat = 8
let MINIMAL_DICTIONARY_EXTRA_HEIGHT: CGFloat = 44
let RESIZE_GRIP_SIZE: CGFloat = 14
let RESIZE_EDGE_THICKNESS: CGFloat = 8
let RESIZE_CORNER_HIT_SIZE: CGFloat = 22
let OUTER_PADDING: CGFloat = 16
let SECTION_GAP: CGFloat = 12
let HEADER_HEIGHT: CGFloat = 44
let TOOLBAR_BUTTON_SIZE: CGFloat = 32
let CARD_RADIUS: CGFloat = 8
let PANEL_RADIUS: CGFloat = 20
let CONTROL_RADIUS: CGFloat = 8
let CARD_INSET_X: CGFloat = 16
let MAX_CARD_TEXT_HEIGHT: CGFloat = 252
let SRC_MAX_CARD_HEIGHT: CGFloat = 304
let SOURCE_CARD_MIN_HEIGHT: CGFloat = 136
let SOURCE_RESIZE_HANDLE_HEIGHT: CGFloat = 40
let SOURCE_CARD_CHROME_HEIGHT: CGFloat = 104
let SOURCE_TEXT_MIN_HEIGHT: CGFloat = 32
let SOURCE_TEXT_MAX_HEIGHT: CGFloat = SRC_MAX_CARD_HEIGHT - SOURCE_CARD_CHROME_HEIGHT
let SOURCE_TEXT_LINE_HEIGHT: CGFloat = 20
let DEST_CARD_MIN_HEIGHT: CGFloat = 132
let DEST_TEXT_MIN_HEIGHT: CGFloat = 40
let DICTIONARY_DEST_CARD_MIN_HEIGHT: CGFloat = 176
let DICTIONARY_TEXT_MIN_HEIGHT: CGFloat = 88
let DEST_CARD_CHROME_HEIGHT: CGFloat = 92
let DICTIONARY_DEST_CARD_CHROME_HEIGHT: CGFloat = 116
let DEST_MAX_CARD_HEIGHT: CGFloat = 380
let MAX_WINDOW_HEIGHT: CGFloat = 760
let LANG_BAR_HEIGHT: CGFloat = 44
let SOURCE_FONT_SIZE: CGFloat = 13   // = AppUI.FontSize.base；与 measureTextHeight 测量耦合，二者须一致
let BODY_FONT_SIZE: CGFloat = 16     // = AppUI.FontSize.body；同上
let DICTIONARY_TITLE_FONT_SIZE: CGFloat = 20
let DICTIONARY_PRONUNCIATION_FONT_SIZE: CGFloat = 12
let DICTIONARY_BODY_FONT_SIZE: CGFloat = 14
let STREAM_RENDER_INTERVAL: TimeInterval = 0.05
let STREAM_RENDER_TIMER_TOLERANCE: TimeInterval = 0.015
/// 流式渲染期间，译文每增长这么多字符才重新测量+尝试增高窗口一次。
/// 避免每 50ms 都对不断变长的整段译文做一次全量文本布局（近似 O(n²)）。
/// 增高滞后至多一行左右，流结束时 finishStream 会做一次精确布局兜底。
let STREAM_GROW_MEASURE_CHAR_DELTA = 20

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
var MINIMAL_PANEL_BG: NSColor {
    // 低不透明度的暖色薄膜，叠在 .regularMaterial 之上：让磨砂玻璃透出背景模糊，
    // 同时保留品牌暖调。过去的 ~0.8 会盖住材质，导致面板看起来是实心暖卡而非毛玻璃。
    isDarkMode ? rgb(30, 29, 27, 0.36) : rgb(255, 253, 249, 0.34)
}
var MINIMAL_PANEL_TOP: NSColor {
    isDarkMode ? rgb(42, 39, 35, 0.34) : rgb(255, 255, 255, 0.42)
}
var MINIMAL_PANEL_BOTTOM: NSColor {
    isDarkMode ? rgb(19, 18, 17, 0.22) : rgb(232, 225, 215, 0.18)
}
var MINIMAL_PANEL_BORDER: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.22) : rgb(86, 70, 58, 0.22)
}
var MINIMAL_PANEL_HIGHLIGHT: NSColor {
    isDarkMode ? rgb(255, 255, 255, 0.16) : rgb(255, 255, 255, 0.68)
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

// MARK: - Text Measurement

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
