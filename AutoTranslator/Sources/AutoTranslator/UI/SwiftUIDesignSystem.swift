import AppKit
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
        static let body: CGFloat = 15     // 译文正文
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

private struct AppSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    var background: Color
    var radius: CGFloat
    var border: Color
    var shadow: Bool

    func body(content: Content) -> some View {
        content
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            }
            .shadow(
                color: shadow ? Color.black.opacity(colorScheme == .dark ? 0.26 : 0.07) : .clear,
                radius: shadow ? 12 : 0,
                x: 0,
                y: shadow ? 4 : 0
            )
    }
}

extension View {
    func appSurface(
        background: Color = AppUI.surface,
        radius: CGFloat = AppUI.radius,
        border: Color = AppUI.cardBorder,
        shadow: Bool = false
    ) -> some View {
        modifier(AppSurfaceModifier(
            background: background,
            radius: radius,
            border: border,
            shadow: shadow
        ))
    }

    func hoverHighlight(radius: CGFloat = AppUI.controlRadius) -> some View {
        modifier(HoverHighlightModifier(cornerRadius: radius))
    }
}

struct IconButtonStyle: ButtonStyle {
    var tint: Color = AppUI.textSecondary
    var background: Color = AppUI.toolbarGhost
    var border: Color = AppUI.buttonBorder
    var size: CGFloat = TOOLBAR_BUTTON_SIZE
    var pillWidth: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(
            configuration: configuration,
            tint: tint,
            background: background,
            border: border,
            size: size,
            pillWidth: pillWidth
        )
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let tint: Color
        let background: Color
        let border: Color
        let size: CGFloat
        let pillWidth: CGFloat?

        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: max(11, size * 0.42), weight: .medium))
                .foregroundStyle(isHovered ? tint : tint.opacity(0.88))
                .frame(width: pillWidth ?? size, height: size)
                .background {
                    Capsule()
                        .fill(background)
                        .opacity(configuration.isPressed ? 0.72 : (isHovered ? 1.0 : 0.86))
                }
                .clipShape(Capsule())
                .overlay {
                    Capsule()
                        .stroke(isHovered ? border.opacity(0.85) : border.opacity(0.60), lineWidth: 1)
                }
                .scaleEffect(configuration.isPressed ? 0.94 : (isHovered ? 1.02 : 1.0))
                .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .onHover { isHovered = $0 }
        }
    }
}

struct HoverHighlightModifier: ViewModifier {
    @State private var isHovered = false
    var cornerRadius: CGFloat = AppUI.controlRadius

    func body(content: Content) -> some View {
        content
            .background {
                if isHovered {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// 无边框轻量图标按钮：静止时融入背景，悬停或激活时才显露柔润胶囊底色，用于划词浮窗的极简工具栏。
struct GhostIconButtonStyle: ButtonStyle {
    var tint: Color = AppUI.textSecondary
    var activeBackground: Color = .clear
    var size: CGFloat = TOOLBAR_BUTTON_SIZE
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        GhostIconButtonBody(
            configuration: configuration,
            tint: tint,
            activeBackground: activeBackground,
            size: size,
            isActive: isActive
        )
    }

    private struct GhostIconButtonBody: View {
        let configuration: Configuration
        let tint: Color
        let activeBackground: Color
        let size: CGFloat
        let isActive: Bool

        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: max(11, size * 0.48), weight: .medium))
                .foregroundStyle(isHovered || isActive ? tint : tint.opacity(0.82))
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(pillFill)
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
                .animation(.spring(response: 0.20, dampingFraction: 0.78), value: configuration.isPressed)
                .animation(.easeInOut(duration: 0.12), value: isHovered)
                .onHover { isHovered = $0 }
        }

        private var pillFill: Color {
            if isActive {
                return activeBackground
            }
            if configuration.isPressed {
                return Color.primary.opacity(0.10)
            }
            if isHovered {
                return Color.primary.opacity(0.065)
            }
            return .clear
        }
    }
}

struct CopyFeedbackButton: View {
    let textToCopy: () -> String
    var size: CGFloat = 24
    var helpText: String = "复制"
    var ghost: Bool = false

    @State private var hasCopied = false

    var body: some View {
        Button {
            let text = textToCopy()
            guard !text.isEmpty else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                hasCopied = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    hasCopied = false
                }
            }
        } label: {
            Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: max(10, size * 0.46), weight: hasCopied ? .semibold : .medium))
        }
        .modifier(CopyButtonStyleModifier(hasCopied: hasCopied, size: size, ghost: ghost))
        .help(hasCopied ? "已复制到剪贴板" : helpText)
        .accessibilityLabel(hasCopied ? "已复制到剪贴板" : helpText)
    }
}

private struct CopyButtonStyleModifier: ViewModifier {
    let hasCopied: Bool
    let size: CGFloat
    let ghost: Bool

    func body(content: Content) -> some View {
        if ghost {
            content.buttonStyle(GhostIconButtonStyle(
                tint: hasCopied ? AppUI.teal : AppUI.textSecondary,
                activeBackground: AppUI.chipTeal,
                size: size,
                isActive: hasCopied
            ))
        } else {
            content.buttonStyle(IconButtonStyle(
                tint: hasCopied ? AppUI.teal : AppUI.textSecondary,
                background: hasCopied ? AppUI.chipTeal : AppUI.toolbarGhost,
                border: hasCopied ? AppUI.teal.opacity(0.4) : AppUI.buttonBorder,
                size: size
            ))
        }
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

/// 窗口拖动热区：透明 NSView，按下即发起窗口拖动。
///
/// 浮窗是 .borderless 面板，本来指望 `isMovableByWindowBackground` 拖动，但那套逻辑在
/// `NSWindow.mouseDown(with:)` 里，而 NSHostingView 覆盖整个内容区并吞掉 mouseDown，
/// 事件到不了窗口——表现为窗口任何位置都拖不动。改用 `performDrag(with:)` 自己发起拖动。
///
/// 用法：`.background(WindowDragArea())`。放在内容之下，SwiftUI 的命中测试仍会让按钮、
/// 输入框、可选中文本优先拿到点击；只有它们不认领的留白才落到这里。纯装饰的文字/徽标
/// 默认也会认领点击，需要拖动的话给它们加 `.allowsHitTesting(false)`。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragSurface() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragSurface: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        /// 面板是 .nonactivatingPanel，本 App 不在前台时首次点击也要能直接拖动。
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

struct ResizeGrip: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            gripLine(offset: 0, length: 4)
            gripLine(offset: 5, length: 9)
            gripLine(offset: 10, length: 14)
        }
        .frame(width: RESIZE_GRIP_SIZE, height: RESIZE_GRIP_SIZE)
        .opacity(colorScheme == .dark ? 0.54 : 0.42)
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
