import AppKit

/// 自绘屏幕区域框选。贴图翻译要把结果钉回框选位置，必须知道所选矩形的
/// 屏幕坐标，而系统 `screencapture -i` 不回报矩形，故用全屏蒙层自绘实现。
/// 蒙层窗口 `sharingType = .none`，即使与后续定点截屏竞态也不会入镜。
@MainActor
final class RegionSelectionController: NSObject {

    /// 弹出框选蒙层并等待用户拖选。返回 AppKit 全局屏幕坐标的整数矩形；
    /// Esc / 右键 / 未拖拽的单击取消时返回 nil。
    static func selectRegion() async -> NSRect? {
        await withCheckedContinuation { continuation in
            let controller = RegionSelectionController()
            controller.begin { rect in
                continuation.resume(returning: rect)
            }
        }
    }

    /// 框选期间保活当前实例（窗口/监视器均由它持有）。
    private static var activeController: RegionSelectionController?

    private var windows: [SelectionWindow] = []
    private var completion: ((NSRect?) -> Void)?
    private var keyMonitor: Any?
    private var didFinish = false

    private func begin(completion: @escaping (NSRect?) -> Void) {
        self.completion = completion

        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            finish(with: nil)
            return
        }

        // 结束上一次仍在等待的框选（如用户在框选中再次点击「贴图翻译」）：
        // 恢复其 continuation（返回 nil），旧任务凭版本守卫自行退出，避免悬挂。
        Self.activeController?.finish(with: nil)
        Self.activeController = self

        for screen in screens {
            let window = SelectionWindow(screen: screen, controller: self)
            windows.append(window)
            window.orderFrontRegardless()
        }

        // 应用需处于激活状态才能收到 Esc 键；蒙层窗口本身可成为 key。
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        NSCursor.crosshair.push()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            self.finish(with: nil)
            return nil
        }
    }

    fileprivate func finish(with rect: NSRect?) {
        guard !didFinish else { return }
        didFinish = true

        NSCursor.pop()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()

        let completion = self.completion
        self.completion = nil
        if Self.activeController === self {
            Self.activeController = nil
        }
        completion?(rect)
    }
}

// MARK: - 蒙层窗口

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, controller: RegionSelectionController) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        // 关键：自身不参与屏幕捕捉，蒙层永远不会污染定点截屏。
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size),
                                           controller: controller)
    }
}

// MARK: - 蒙层视图（暗化 + 框选矩形 + 尺寸角标）

private final class SelectionOverlayView: NSView {

    private weak var controller: RegionSelectionController?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    init(frame: NSRect, controller: RegionSelectionController) {
        self.controller = controller
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    private var selectionRect: NSRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return NSRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragStart.x - dragCurrent.x),
            height: abs(dragStart.y - dragCurrent.y)
        )
    }

    // MARK: 交互

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragCurrent = nil
        }
        guard let rect = selectionRect, rect.width >= 8, rect.height >= 8 else {
            // 单击或过小的拖拽视为取消。
            controller?.finish(with: nil)
            return
        }
        guard let window else {
            controller?.finish(with: nil)
            return
        }
        // contentView 铺满 borderless 窗口：视图坐标 == 窗口坐标。
        let screenRect = window.convertToScreen(rect).integral
        controller?.finish(with: screenRect)
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.finish(with: nil)
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.22)

        guard let selection = selectionRect, selection.width > 0, selection.height > 0 else {
            dim.setFill()
            bounds.fill()
            return
        }

        // 框选区外的四条暗化带（避免混合模式技巧，普通填充即可）。
        dim.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: selection.minY).fill()
        NSRect(x: 0, y: selection.maxY,
               width: bounds.width, height: bounds.height - selection.maxY).fill()
        NSRect(x: 0, y: selection.minY,
               width: selection.minX, height: selection.height).fill()
        NSRect(x: selection.maxX, y: selection.minY,
               width: bounds.width - selection.maxX, height: selection.height).fill()

        // 品牌色选框 + 外圈半透明白描边（深色背景上仍可辨识）。
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let outer = NSBezierPath(rect: selection.insetBy(dx: -1.25, dy: -1.25))
        outer.lineWidth = 1
        outer.stroke()

        CORAL_ACCENT.setStroke()
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1.5
        border.stroke()

        drawSizeBadge(for: selection)
    }

    private func drawSizeBadge(for selection: NSRect) {
        let label = "\(Int(selection.width)) × \(Int(selection.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let textSize = label.size(withAttributes: attributes)
        let padding: CGFloat = 6
        let badgeSize = NSSize(width: textSize.width + padding * 2, height: textSize.height + 6)

        // 优先放在选区右下角下方；贴近屏幕底部时移到选区内侧。
        var origin = NSPoint(
            x: selection.maxX - badgeSize.width,
            y: selection.minY - badgeSize.height - 6
        )
        if origin.y < 0 {
            origin.y = selection.minY + 6
            origin.x = selection.maxX - badgeSize.width - 6
        }
        origin.x = max(0, min(origin.x, bounds.width - badgeSize.width))

        let badgeRect = NSRect(origin: origin, size: badgeSize)
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: badgeSize.height / 2, yRadius: badgeSize.height / 2).fill()
        label.draw(
            at: NSPoint(x: badgeRect.minX + padding, y: badgeRect.minY + 3),
            withAttributes: attributes
        )
    }
}
