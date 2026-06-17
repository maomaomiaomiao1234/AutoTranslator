import SwiftUI

enum AppUI {
    static var panelTop: Color { Color(nsColor: PANEL_TOP) }
    static var panelBottom: Color { Color(nsColor: PANEL_BOTTOM) }
    static var panelBorder: Color { Color(nsColor: PANEL_BORDER) }
    static var minimalPanel: Color { Color(nsColor: MINIMAL_PANEL_BG) }
    static var minimalPanelTop: Color { Color(nsColor: MINIMAL_PANEL_TOP) }
    static var minimalPanelBottom: Color { Color(nsColor: MINIMAL_PANEL_BOTTOM) }
    static var minimalPanelBorder: Color { Color(nsColor: MINIMAL_PANEL_BORDER) }
    static var minimalPanelHighlight: Color { Color(nsColor: MINIMAL_PANEL_HIGHLIGHT) }
    static var surface: Color { Color(nsColor: SURFACE_BG) }
    static var surfaceSoft: Color { Color(nsColor: SURFACE_BG_SOFT) }
    static var toolbarGhost: Color { Color(nsColor: TOOLBAR_GHOST_BG) }
    static var cardBorder: Color { Color(nsColor: CARD_BORDER) }
    static var buttonBorder: Color { Color(nsColor: BUTTON_BORDER) }
    static var textPrimary: Color { Color(nsColor: TEXT_PRIMARY) }
    static var textSecondary: Color { Color(nsColor: TEXT_SECONDARY) }
    static var textMuted: Color { Color(nsColor: TEXT_MUTED) }
    static var accent: Color { Color(nsColor: CORAL_ACCENT) }
    static var blue: Color { Color(nsColor: BLUE_ACCENT) }
    static var teal: Color { Color(nsColor: TEAL_ACCENT) }
    static var amber: Color { Color(nsColor: AMBER_ACCENT) }
    static var chipBlue: Color { Color(nsColor: CHIP_BG) }
    static var chipTeal: Color { Color(nsColor: CHIP_BG_ALT) }
    static var chipWarm: Color { Color(nsColor: CHIP_BG_WARM) }
    static var activeToolbar: Color { Color(nsColor: TOOLBAR_ACTIVE_BG) }
    static var activeToolbarBorder: Color { Color(nsColor: TOOLBAR_ACTIVE_BORDER) }

    static let radius: CGFloat = CARD_RADIUS
    static let panelRadius: CGFloat = PANEL_RADIUS
    static let controlRadius: CGFloat = CONTROL_RADIUS
    static let outerPadding: CGFloat = OUTER_PADDING
    static let sectionGap: CGFloat = SECTION_GAP

    // MARK: - Design Tokens

    /// 字号标度（pt）。原文 / 译文正文另由 DesignSystem 的 `SOURCE_FONT_SIZE` /
    /// `BODY_FONT_SIZE` 提供（与文本高度测量耦合），取值分别与 `base` / `body` 一致。
    enum FontSize {
        static let micro: CGFloat = 10    // 徽标 / 计数 / 路径等最小文字
        static let mini: CGFloat = 11     // 次级粗体小标题
        static let small: CGFloat = 12    // 辅助说明 / 等宽输入 / 状态
        static let base: CGFloat = 13     // 行标题 / 项值 / 原文正文
        static let section: CGFloat = 15  // 设置分区标题
        static let body: CGFloat = 16     // 译文正文
        static let title: CGFloat = 18    // 浮窗标题
        static let display: CGFloat = 24  // 偏好页标题
    }

    /// 4pt 间距栅格。`xxs`(2) 为发丝级光学微调，其余为标准档。
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    /// 圆角标度。
    enum Radius {
        static let chip: CGFloat = CARD_RADIUS   // 8 · 小徽标 / 输入
        static let card: CGFloat = CARD_RADIUS   // 8
        static let panel: CGFloat = PANEL_RADIUS // 20
    }
}

extension View {
    func appSurface(
        background: Color = AppUI.surface,
        radius: CGFloat = AppUI.radius,
        border: Color = AppUI.cardBorder,
        shadow: Bool = false
    ) -> some View {
        self
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
            .shadow(
                color: shadow ? Color.black.opacity(isDarkMode ? 0.22 : 0.065) : .clear,
                radius: shadow ? 14 : 0,
                x: 0,
                y: shadow ? 5 : 0
            )
    }
}

struct IconButtonStyle: ButtonStyle {
    var tint: Color = AppUI.textSecondary
    var background: Color = AppUI.toolbarGhost
    var border: Color = AppUI.buttonBorder
    var size: CGFloat = TOOLBAR_BUTTON_SIZE
    var pillWidth: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: max(11, size * 0.42), weight: .medium))
            .foregroundStyle(tint)
            .frame(width: pillWidth ?? size, height: size)
            .background(background.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(Capsule())
            .overlay {
                Capsule().stroke(border, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

struct Chip: View {
    let text: String
    var foreground: Color = AppUI.textSecondary
    var background: Color = AppUI.surfaceSoft

    var body: some View {
        Text(text)
            .font(.system(size: AppUI.FontSize.micro, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, AppUI.Space.s)
            .frame(height: 20)
            .background(background)
            .clipShape(Capsule())
    }
}

struct SymbolBadge: View {
    let symbol: String
    var tint: Color = AppUI.textSecondary
    var background: Color = AppUI.surfaceSoft
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: max(12, size * 0.44), weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: AppUI.Radius.chip, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: AppUI.Radius.chip, style: .continuous)
                    .stroke(AppUI.buttonBorder, lineWidth: 1)
            }
    }
}

struct ResizeGrip: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            gripLine(offset: 0, length: 4)
            gripLine(offset: 5, length: 9)
            gripLine(offset: 10, length: 14)
        }
        .frame(width: RESIZE_GRIP_SIZE, height: RESIZE_GRIP_SIZE)
        .opacity(isDarkMode ? 0.52 : 0.44)
        .accessibilityHidden(true)
    }

    private func gripLine(offset: CGFloat, length: CGFloat) -> some View {
        Capsule()
            .fill(AppUI.textMuted)
            .frame(width: 1, height: length)
            .rotationEffect(.degrees(45))
            .offset(x: -offset, y: -offset)
    }
}
