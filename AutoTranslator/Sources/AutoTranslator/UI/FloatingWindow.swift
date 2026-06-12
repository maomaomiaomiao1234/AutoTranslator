import AppKit
import Quartz

// MARK: - Borderless Window

final class BorderlessWindow: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 在窗口或其任意子视图收到任何鼠标按下事件时调用；
    /// FloatingWindow 借此在窗口被其它窗口遮挡时把它重新提到最前。
    var onAnyMouseDown: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // 浮动层级：翻译弹出时始终可见；
        // 用户点击其它窗口后由 FloatingWindow 的全局监听把 level 降回 .normal。
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
    }

    override func mouseDown(with event: NSEvent) {
        // Window background dragging is handled by isMovableByWindowBackground
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { /* Esc — handled via key monitor */ }
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onAnyMouseDown?()
        default:
            break
        }
        super.sendEvent(event)
    }
}

// MARK: - Panel Background View

final class PanelBackgroundView: NSView {
    override var isOpaque: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Window dragging is handled by isMovableByWindowBackground
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: b, xRadius: PANEL_RADIUS, yRadius: PANEL_RADIUS)

        if let gradient = NSGradient(starting: PANEL_TOP, ending: PANEL_BOTTOM) {
            gradient.draw(in: path, angle: -90)
        }

        NSGraphicsContext.saveGraphicsState()
        path.addClip()

        let accentWidth = min(116, max(72, b.width * 0.28))
        let accentPath = NSBezierPath(roundedRect: NSRect(x: b.minX + 16,
                                                          y: b.maxY - 5,
                                                          width: accentWidth,
                                                          height: 3),
                                      xRadius: 1.5,
                                      yRadius: 1.5)
        CORAL_ACCENT.withAlphaComponent(isDarkMode ? 0.72 : 0.84).setFill()
        accentPath.fill()

        PANEL_HAIRLINE.setStroke()
        let hairline = NSBezierPath()
        hairline.move(to: NSPoint(x: b.minX + 16, y: b.maxY - 52))
        hairline.line(to: NSPoint(x: b.maxX - 16, y: b.maxY - 52))
        hairline.lineWidth = 1
        hairline.lineCapStyle = .round
        hairline.stroke()

        NSGraphicsContext.restoreGraphicsState()

        PANEL_BORDER.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

private final class TopAlignedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private final class FlippedContentView: NSView {
    override var isFlipped: Bool { true }
}

private final class ThemeAwareView: NSView {
    var onAppearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}

// MARK: - Window Resize View

private struct ResizeEdges: OptionSet {
    let rawValue: Int

    static let left = ResizeEdges(rawValue: 1 << 0)
    static let right = ResizeEdges(rawValue: 1 << 1)
    static let top = ResizeEdges(rawValue: 1 << 2)
    static let bottom = ResizeEdges(rawValue: 1 << 3)

    var hasHorizontal: Bool { contains(.left) || contains(.right) }
    var hasVertical: Bool { contains(.top) || contains(.bottom) }
}

private final class WindowResizeView: NSView {
    var onResize: ((ResizeEdges, NSRect, NSSize) -> Void)?
    var onResizeEnd: (() -> Void)?

    private var activeEdges: ResizeEdges = []
    private var startScreenPoint: NSPoint = .zero
    private var startFrame: NSRect = .zero

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return resizeEdges(at: point).isEmpty ? nil : self
    }

    override func resetCursorRects() {
        let w = bounds.width
        let h = bounds.height
        let edge = RESIZE_EDGE_THICKNESS
        let corner = RESIZE_CORNER_HIT_SIZE

        addCursorRect(NSRect(x: 0, y: 0, width: corner, height: corner),
                      cursor: resizeCursor(for: [.left, .bottom]))
        addCursorRect(NSRect(x: w - corner, y: 0, width: corner, height: corner),
                      cursor: resizeCursor(for: [.right, .bottom]))
        addCursorRect(NSRect(x: 0, y: h - corner, width: corner, height: corner),
                      cursor: resizeCursor(for: [.left, .top]))
        addCursorRect(NSRect(x: w - corner, y: h - corner, width: corner, height: corner),
                      cursor: resizeCursor(for: [.right, .top]))

        addCursorRect(NSRect(x: corner, y: 0, width: max(0, w - corner * 2), height: edge),
                      cursor: resizeCursor(for: [.bottom]))
        addCursorRect(NSRect(x: corner, y: h - edge, width: max(0, w - corner * 2), height: edge),
                      cursor: resizeCursor(for: [.top]))
        addCursorRect(NSRect(x: 0, y: corner, width: edge, height: max(0, h - corner * 2)),
                      cursor: resizeCursor(for: [.left]))
        addCursorRect(NSRect(x: w - edge, y: corner, width: edge, height: max(0, h - corner * 2)),
                      cursor: resizeCursor(for: [.right]))
    }

    override func mouseDown(with event: NSEvent) {
        startFrame = window?.frame ?? .zero
        activeEdges = resizeEdges(at: convert(event.locationInWindow, from: nil))
        startScreenPoint = screenPoint(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !activeEdges.isEmpty else { return }
        let point = screenPoint(for: event)
        let delta = NSSize(width: point.x - startScreenPoint.x,
                           height: point.y - startScreenPoint.y)
        onResize?(activeEdges, startFrame, delta)
    }

    override func mouseUp(with event: NSEvent) {
        activeEdges = []
        onResizeEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(TEXT_MUTED.cgColor)
        ctx.setLineWidth(1.0)
        ctx.setLineCap(.round)

        let step: CGFloat = 4.5
        let margin: CGFloat = 7
        for i in 0..<3 {
            let offset = CGFloat(i) * step
            let x = bounds.maxX - margin - offset
            let y = bounds.minY + margin
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: bounds.maxX - margin, y: y + offset))
        }
        ctx.strokePath()
    }

    private func resizeEdges(at point: NSPoint) -> ResizeEdges {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0, point.x >= 0, point.y >= 0, point.x <= w, point.y <= h else {
            return []
        }

        let edge = RESIZE_EDGE_THICKNESS
        let corner = RESIZE_CORNER_HIT_SIZE

        if point.x <= corner, point.y <= corner { return [.left, .bottom] }
        if point.x >= w - corner, point.y <= corner { return [.right, .bottom] }
        if point.x <= corner, point.y >= h - corner { return [.left, .top] }
        if point.x >= w - corner, point.y >= h - corner { return [.right, .top] }

        var edges: ResizeEdges = []
        if point.x <= edge { edges.insert(.left) }
        if point.x >= w - edge { edges.insert(.right) }
        if point.y <= edge { edges.insert(.bottom) }
        if point.y >= h - edge { edges.insert(.top) }
        return edges
    }

    private func resizeCursor(for edges: ResizeEdges) -> NSCursor {
        if edges.hasHorizontal { return .resizeLeftRight }
        if edges.hasVertical { return .resizeUpDown }
        return .arrow
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        guard let window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}

// MARK: - Floating Window Delegate Protocol

protocol FloatingWindowDelegate: AnyObject {
    func languageChanged(srcName: String, destName: String)
    func swapLanguages()
    func toggleTranslator()
    func retranslateCurrent()
    func hideWindow()
}

// MARK: - Floating Window Controller

final class FloatingWindow: NSObject {

    weak var delegate: FloatingWindowDelegate?

    let window: BorderlessWindow
    private let rootView: ThemeAwareView
    private let backgroundView: PanelBackgroundView

    private(set) var currentSourceText = ""
    private(set) var currentDestText = ""
    private var backend: String = "google"
    private var isPinned = false
    private var savedOrigin: NSPoint?
    private var savedHeight: CGFloat?
    private var suppressAutoPin = false
    private var activeResizeEdges: ResizeEdges = []
    private var hasManualHeight = false
    private var currentState: TranslationState = .idle

    // Resize hit area
    private let resizeView: WindowResizeView

    // Stream state
    private var streamTimer: Timer?
    private var streamBuffer = ""
    private var streamBufferCount = 0
    private var streamPos = 0
    private var streamFinal: String?

    // Event monitors
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var pendingSinkWorkItem: DispatchWorkItem?

    private var languages: [String: String] = [:]
    private var srcLang = "auto"
    private var destLang = "zh-CN"

    // MARK: Subviews — Toolbar

    private let pinBtn: NSButton
    private let headerTitleLabel: NSTextField
    private let headerSubtitleLabel: NSTextField
    private let quickSourceCopyBtn: NSButton
    private let quickDestCopyBtn: NSButton
    private let backendBtn: NSButton
    private let hideBtn: NSButton

    // MARK: Subviews — Source Card

    private let srcCard: NSView
    private let srcTitleLabel: NSTextField
    private let srcMetaChip: NSTextField
    private let srcScroll: NSScrollView
    private let srcTextContainer: FlippedContentView
    private let srcLabel: NSTextField
    private let srcCopyBtn: NSButton
    private let srcLangChip: NSTextField

    // MARK: Subviews — Language Bar

    private let langBar: NSView
    private let srcLangPop: NSPopUpButton
    private let swapBtn: NSButton
    private let destLangPop: NSPopUpButton

    // MARK: Subviews — Dest Card

    private let destCard: NSView
    private let backendBadge: NSView
    private let backendBadgeLabel: NSTextField
    private let backendNameLabel: NSTextField
    private let destStateChip: NSTextField
    private let backendToggleBtn: NSButton
    private let destScroll: NSScrollView
    private let destTextContainer: FlippedContentView
    private let destLabel: NSTextView
    private let destCopyBtn: NSButton
    private let destRefreshBtn: NSButton

    // MARK: - Init

    override init() {
        window = BorderlessWindow()

        rootView = ThemeAwareView(frame: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT))
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = PANEL_RADIUS
        rootView.layer?.masksToBounds = true
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView

        backgroundView = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT))
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = PANEL_RADIUS
        backgroundView.layer?.masksToBounds = true
        backgroundView.autoresizingMask = [.width, .height]
        rootView.addSubview(backgroundView)

        resizeView = WindowResizeView(frame: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT))
        resizeView.autoresizingMask = [.width, .height]

        // Toolbar
        pinBtn = createToolbarIconButton(symbolName: "pin.fill", fallback: "P")
        quickSourceCopyBtn = createToolbarIconButton(symbolName: "text.quote", fallback: "S")
        quickDestCopyBtn = createToolbarIconButton(symbolName: "doc.on.doc", fallback: "C")
        hideBtn = createToolbarIconButton(symbolName: "xmark", fallback: "X")
        pinBtn.toolTip = "固定窗口"
        quickSourceCopyBtn.toolTip = "复制原文"
        quickDestCopyBtn.toolTip = "复制译文"
        hideBtn.toolTip = "隐藏窗口"

        headerTitleLabel = createLabel(fontSize: 18, color: TEXT_PRIMARY, bold: true, wraps: false)
        headerTitleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        headerTitleLabel.stringValue = "划词翻译"

        headerSubtitleLabel = createLabel(fontSize: 11.5, color: TEXT_SECONDARY, wraps: false)
        headerSubtitleLabel.stringValue = "自动检测 → 中文简体 · Google"

        backendBtn = NSButton()
        backendBtn.isBordered = false
        backendBtn.bezelStyle = .regularSquare
        backendBtn.focusRingType = .none
        backendBtn.title = "LLM"
        backendBtn.font = NSFont.boldSystemFont(ofSize: 11)
        backendBtn.toolTip = "切换翻译后端"
        styleSurface(backendBtn, background: TOOLBAR_GHOST_BG, radius: BACKEND_BTN_WIDTH / 2,
                     border: TOOLBAR_BUTTON_BORDER)

        for v in [pinBtn, headerTitleLabel, headerSubtitleLabel,
                  quickSourceCopyBtn, quickDestCopyBtn, backendBtn, hideBtn] {
            rootView.addSubview(v)
        }

        // Source card
        srcCard = NSView()
        styleSurface(srcCard, background: SOURCE_CARD_BG, radius: CARD_RADIUS,
                     border: CARD_BORDER, shadow: true)

        srcTitleLabel = createLabel(fontSize: 10.5, color: TEXT_SECONDARY, bold: true, wraps: false)
        srcTitleLabel.stringValue = "原文"

        srcMetaChip = createPillLabel(fontSize: 9.5, color: TEXT_SECONDARY, background: SURFACE_BG_SOFT)

        srcScroll = NSScrollView()
        srcScroll.hasVerticalScroller = true
        srcScroll.autohidesScrollers = true
        srcScroll.borderType = .noBorder
        srcScroll.drawsBackground = false
        srcScroll.contentView = TopAlignedClipView()
        srcScroll.wantsLayer = true
        srcScroll.layer?.cornerRadius = CONTROL_RADIUS
        srcScroll.layer?.masksToBounds = true

        srcTextContainer = FlippedContentView()
        srcLabel = createLabel(fontSize: SOURCE_FONT_SIZE, color: TEXT_SECONDARY, selectable: true, wraps: true)
        srcTextContainer.addSubview(srcLabel)
        srcScroll.documentView = srcTextContainer

        srcCopyBtn = createIconButton(symbolName: "doc.on.doc", fallback: "C",
                                      pointSize: 10, tint: TEXT_SECONDARY, size: 22)
        srcCopyBtn.toolTip = "复制原文"

        srcLangChip = createPillLabel(fontSize: 9.5, color: BLUE_ACCENT, background: CHIP_BG)

        for v in [srcTitleLabel, srcMetaChip, srcScroll, srcCopyBtn, srcLangChip] {
            srcCard.addSubview(v)
        }
        rootView.addSubview(srcCard)

        // Language bar
        langBar = NSView()
        styleSurface(langBar, background: LANG_BAR_BG, radius: CARD_RADIUS,
                     border: CARD_BORDER)

        srcLangPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 80, height: 26), pullsDown: false)

        swapBtn = createIconButton(symbolName: "arrow.left.arrow.right", fallback: "<>",
                                   pointSize: 12, tint: TEXT_PRIMARY, size: 24)
        swapBtn.toolTip = "互换语言"

        destLangPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 80, height: 26), pullsDown: false)

        for v in [srcLangPop, swapBtn, destLangPop] { langBar.addSubview(v) }
        rootView.addSubview(langBar)

        // Dest card
        destCard = NSView()
        styleSurface(destCard, background: DEST_CARD_BG, radius: CARD_RADIUS,
                     border: CARD_BORDER, shadow: true)

        backendBadge = NSView()
        styleSurface(backendBadge, background: BLUE_ACCENT, radius: 8)

        backendBadgeLabel = createLabel(fontSize: 10, color: .white, bold: true, wraps: false)
        backendBadgeLabel.alignment = .center
        backendBadge.addSubview(backendBadgeLabel)

        backendNameLabel = createLabel(fontSize: 13, color: TEXT_PRIMARY, bold: true, wraps: false)

        destStateChip = createPillLabel(fontSize: 10, color: TEXT_SECONDARY, background: SURFACE_BG_SOFT)

        backendToggleBtn = createIconButton(symbolName: "chevron.down", fallback: "v",
                                            pointSize: 9, tint: TEXT_SECONDARY, size: 24)
        backendToggleBtn.toolTip = "切换翻译后端"

        destScroll = NSScrollView()
        destScroll.hasVerticalScroller = true
        destScroll.autohidesScrollers = true
        destScroll.borderType = .noBorder
        destScroll.drawsBackground = false
        destScroll.contentView = TopAlignedClipView()
        destScroll.wantsLayer = true
        destScroll.layer?.cornerRadius = CONTROL_RADIUS
        destScroll.layer?.masksToBounds = true

        destTextContainer = FlippedContentView()
        destLabel = createTextView(fontSize: BODY_FONT_SIZE, color: TEXT_PRIMARY, selectable: true)
        destTextContainer.addSubview(destLabel)
        destScroll.documentView = destTextContainer

        destCopyBtn = createIconButton(symbolName: "doc.on.doc", fallback: "C",
                                       pointSize: 11, tint: TEXT_PRIMARY, size: 24)
        destRefreshBtn = createIconButton(symbolName: "arrow.clockwise", fallback: "R",
                                          pointSize: 11, tint: TEXT_PRIMARY, size: 24)
        destCopyBtn.toolTip = "复制译文"
        destRefreshBtn.toolTip = "重新翻译"

        for v in [backendBadge, backendBadgeLabel, backendNameLabel, destStateChip,
                  backendToggleBtn, destScroll, destCopyBtn, destRefreshBtn] {
            destCard.addSubview(v)
        }
        rootView.addSubview(destCard)

        rootView.addSubview(resizeView)

        super.init()

        rootView.onAppearanceChanged = { [weak self] in
            refreshThemeCache()
            self?.refreshAppearance()
        }

        // 当窗口被其它窗口遮挡后，用户点击翻译窗任意位置时把它重新提到最前。
        window.onAnyMouseDown = { [weak self] in
            self?.raiseToTop()
        }

        configurePopup(srcLangPop)
        configurePopup(destLangPop)

        // Wire targets
        pinBtn.target = self
        pinBtn.action = #selector(handlePin)

        quickSourceCopyBtn.target = self
        quickSourceCopyBtn.action = #selector(handleCopySource)

        quickDestCopyBtn.target = self
        quickDestCopyBtn.action = #selector(handleCopyDest)

        backendBtn.target = self
        backendBtn.action = #selector(handleBackendToggle)

        hideBtn.target = self
        hideBtn.action = #selector(handleHide)

        srcCopyBtn.target = self
        srcCopyBtn.action = #selector(handleCopySource)

        destCopyBtn.target = self
        destCopyBtn.action = #selector(handleCopyDest)

        destRefreshBtn.target = self
        destRefreshBtn.action = #selector(handleRefresh)

        swapBtn.target = self
        swapBtn.action = #selector(handleSwapLanguages)

        backendToggleBtn.target = self
        backendToggleBtn.action = #selector(handleBackendToggle)

        srcLangPop.target = self
        srcLangPop.action = #selector(handleLangChange)

        destLangPop.target = self
        destLangPop.action = #selector(handleLangChange)

        setupMenu()
        setupKeyMonitor()

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidMove),
                                               name: NSWindow.didMoveNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize),
                                               name: NSWindow.didResizeNotification,
                                               object: window)
        // Mission Control / Stage Manager 选中本窗口后会触发 didBecomeKey；
        // 借此取消任何挂起的降级任务，消除"闪一下后被放到下层"的竞态。
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
                                               name: NSWindow.didBecomeKeyNotification,
                                               object: window)

        resizeView.onResize = { [weak self] edges, startFrame, delta in
            self?.handleResize(edges: edges, startFrame: startFrame, delta: delta)
        }
        resizeView.onResizeEnd = { [weak self] in
            self?.activeResizeEdges = []
        }

        refreshPinStyle()
        refreshActionState()
        refreshSourceMeta()
        setTranslationState(.idle)
        setBackendLabel("google")
    }

    deinit {
        stopStream()
        NotificationCenter.default.removeObserver(self)
        if let m = localKeyMonitor  { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        pendingSinkWorkItem?.cancel()
    }

    // MARK: - Window level management

    /// 提到浮动层并置前；同时取消任何挂起的降级任务。
    private func raiseToTop() {
        pendingSinkWorkItem?.cancel()
        pendingSinkWorkItem = nil
        window.level = .floating
        window.orderFrontRegardless()
    }

    /// 降到普通层级，让其它 App 窗口能自然盖过它。
    private func sinkBelowOtherWindows() {
        guard window.isVisible, !isPinned else { return }
        window.level = .normal
        window.orderBack(nil)
    }

    /// 全局点击监听：点击翻译窗以外时延迟 350ms 下沉。
    /// 固定窗口时保持浮动层，不因外部点击后置。
    /// 窗口自身的 sendEvent（raiseToTop）或 didBecomeKey（Mission Control 回调）
    /// 会在这段时间内取消该任务，消除闪动竞态。
    private func installGlobalClickMonitorIfNeeded() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self = self,
                  self.window.isVisible,
                  !self.isPinned,
                  self.window.level == .floating else { return }
            let work = DispatchWorkItem { [weak self] in self?.sinkBelowOtherWindows() }
            self.pendingSinkWorkItem?.cancel()
            self.pendingSinkWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350), execute: work)
        }
    }

    /// Mission Control / Stage Manager 选中本窗口后系统会把它设为 Key；
    /// 此时取消任何挂起的降级，确保窗口留在浮动层。
    @objc private func windowDidBecomeKey() {
        pendingSinkWorkItem?.cancel()
        pendingSinkWorkItem = nil
        window.level = .floating
        window.orderFrontRegardless()
    }

    // MARK: - Public API

    func setBackendLabel(_ backend: String) {
        self.backend = backend
        if backend == "llm" {
            styleSurface(backendBadge, background: TEAL_ACCENT, radius: 12)
            backendBadgeLabel.stringValue = "AI"
            backendNameLabel.stringValue = "大模型翻译"
            backendBtn.contentTintColor = TEAL_ACCENT
            if isDarkMode {
                styleSurface(backendBtn,
                             background: blendWithBlack(TEAL_ACCENT, amount: 0.50, alpha: 0.65),
                             radius: BACKEND_BTN_WIDTH / 2,
                             border: blendWithBlack(TEAL_ACCENT, amount: 0.30, alpha: 0.75))
            } else {
                styleSurface(backendBtn,
                             background: blendWithWhite(TEAL_ACCENT, amount: 0.84, alpha: 0.72),
                             radius: BACKEND_BTN_WIDTH / 2,
                             border: blendWithWhite(TEAL_ACCENT, amount: 0.56, alpha: 0.84))
            }
        } else {
            styleSurface(backendBadge, background: BLUE_ACCENT, radius: 12)
            backendBadgeLabel.stringValue = "G"
            backendNameLabel.stringValue = "Google 翻译"
            backendBtn.contentTintColor = TEXT_SECONDARY
            styleSurface(backendBtn, background: TOOLBAR_GHOST_BG,
                         radius: BACKEND_BTN_WIDTH / 2, border: TOOLBAR_BUTTON_BORDER)
        }
        backendNameLabel.textColor = TEXT_PRIMARY
        backendBtn.title = backend == "llm" ? "AI" : "G"
        refreshHeaderStatus()
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard window.isVisible else { return false }
        return window.frame.contains(NSPoint(x: point.x, y: point.y))
    }

    func setLanguages(_ languages: [String: String], source: String, target: String) {
        self.languages = languages
        srcLang = source
        destLang = target

        srcLangPop.removeAllItems()
        destLangPop.removeAllItems()

        let sourceTitles = Array(languages.keys)
        let targetTitles = languages.keys.filter { languages[$0] != "auto" }

        srcLangPop.addItems(withTitles: sourceTitles)
        destLangPop.addItems(withTitles: targetTitles)

        for (name, code) in languages {
            if code == source { srcLangPop.selectItem(withTitle: name) }
            if code == target, code != "auto" { destLangPop.selectItem(withTitle: name) }
        }
        if destLangPop.indexOfSelectedItem < 0, let first = targetTitles.first {
            destLangPop.selectItem(withTitle: first)
        }

        refreshLanguageUI()
    }

    func show(srcText: String, destText: String?) {
        pendingSinkWorkItem?.cancel()
        pendingSinkWorkItem = nil
        stopStream()
        let wasVisible = window.isVisible

        currentSourceText = srcText
        currentDestText = destText ?? ""

        srcLabel.stringValue = currentSourceText
        if let dest = destText {
            setDestText(dest)
            destLabel.textColor = TEXT_PRIMARY
            setTranslationState(.done)
        } else {
            setDestText("正在翻译...")
            destLabel.textColor = TEXT_MUTED
            setTranslationState(.loading)
        }

        refreshSourceMeta()
        refreshLanguageUI()
        refreshActionState()
        let currentHeight = clampedWindowHeight(window.frame.height)
        let targetHeight: CGFloat
        if usesManualHeightForLayout {
            targetHeight = currentHeight
        } else if wasVisible {
            // Grow to fit content (e.g. Google's one-shot result); never shrink.
            targetHeight = max(currentHeight, desiredAutomaticWindowHeight(for: window.frame.width))
        } else if let restored = savedHeight {
            // Reopen at last height, but grow if new content needs more room.
            let restoredClamped = clampedWindowHeight(restored)
            targetHeight = max(restoredClamped, desiredAutomaticWindowHeight(for: window.frame.width))
        } else {
            targetHeight = WINDOW_MIN_HEIGHT
        }
        layoutWindow(forcedHeight: targetHeight)
        scrollToTop(srcScroll)
        scrollToTop(destScroll)

        let newHeight = rootView.frame.height
        suppressAutoPin = true
        defer { suppressAutoPin = false }

        if wasVisible {
            let frame = window.frame
            if abs(frame.height - newHeight) > 0.5 {
                window.setFrame(
                    NSRect(x: frame.origin.x, y: frame.maxY - newHeight,
                           width: frame.width, height: newHeight),
                    display: true
                )
            } else {
                window.displayIfNeeded()
            }
            // 之前可能被压到了普通层级；重新置顶到当前活动 App 之上
            window.level = .floating
            window.orderFrontRegardless()
        } else {
            let (x, y): (CGFloat, CGFloat)
            if let saved = savedOrigin {
                x = saved.x; y = saved.y
            } else {
                let screen = NSScreen.main?.frame ?? .zero
                x = (screen.width - window.frame.width) / 2 + screen.origin.x
                y = (screen.height - newHeight) / 2 + screen.origin.y
            }

            window.setFrame(NSRect(x: x, y: y, width: window.frame.width, height: newHeight), display: true)
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                window.animator().alphaValue = 1
            }
        }

        // 安装全局点击监听：点击翻译窗以外时延迟下沉
        installGlobalClickMonitorIfNeeded()
    }

    // MARK: - Stream

    func streamFeed(_ text: String) {
        if streamTimer == nil { startStream() }
        streamBuffer = text
        streamBufferCount = text.count
    }

    func streamFinish(_ finalText: String) {
        streamFinal = finalText
        streamBuffer = finalText
        streamBufferCount = finalText.count
        if streamPos >= streamBufferCount { finishStream() }
    }

    private func startStream() {
        stopStream()
        streamBuffer = ""
        streamBufferCount = 0
        streamPos = 0
        streamFinal = nil
        currentDestText = ""
        setDestText("正在翻译...")
        destLabel.textColor = TEXT_PRIMARY
        setTranslationState(.loading)
        refreshActionState()
        scrollToTop(destScroll)
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.streamTick()
        }
    }

    private func streamTick() {
        let backlog = streamBufferCount - streamPos
        if backlog <= 0 {
            if streamFinal != nil { finishStream() }
            return
        }

        // Adaptive reveal rate:
        //  - API finished: catch up fast (≈4 ticks ≈ 120ms regardless of backlog)
        //  - Buffer is well ahead: speed up to ~200 chars/sec
        //  - Default: ~100 chars/sec
        let charsPerTick: Int
        if streamFinal != nil {
            charsPerTick = max(12, (backlog + 3) / 4)
        } else if backlog > 24 {
            charsPerTick = 6
        } else {
            charsPerTick = 3
        }

        streamPos = min(streamPos + charsPerTick, streamBufferCount)
        let displayed = String(streamBuffer.prefix(streamPos))

        if displayed == currentDestText {
            if streamFinal != nil, streamPos >= streamBufferCount { finishStream() }
            return
        }

        currentDestText = displayed
        setDestText(displayed)
        refreshActionState()

        let cardInnerWidth = window.frame.width - (OUTER_PADDING * 2) - (CARD_INSET_X * 2)
        let fullTextHeight = measureTextHeight(displayed, width: cardInnerWidth,
                                               fontSize: BODY_FONT_SIZE, minimum: 40)
        let visibleHeight = max(0, destScroll.contentView.bounds.height)
        updateDestTextLayout(width: cardInnerWidth, visibleHeight: visibleHeight, textHeight: fullTextHeight)
        growWindowForStreamingIfNeeded()

        if streamFinal != nil, streamPos >= streamBufferCount { finishStream() }
    }

    private func stopStream() {
        streamTimer?.invalidate()
        streamTimer = nil
        streamFinal = nil
    }

    private func finishStream() {
        stopStream()
        currentDestText = streamBuffer
        setDestText(streamBuffer)
        setTranslationState(.done)
        refreshActionState()
        let frame = window.frame
        let desiredHeight = usesManualHeightForLayout
            ? clampedWindowHeight(frame.height)
            : max(clampedWindowHeight(frame.height), desiredAutomaticWindowHeight(for: frame.width))
        layoutWindow(forcedHeight: desiredHeight)

        guard window.isVisible else { return }
        let newHeight = rootView.frame.height
        guard abs(frame.height - newHeight) > 0.5 else { return }
        suppressAutoPin = true
        window.setFrame(
            NSRect(x: frame.origin.x, y: frame.maxY - newHeight, width: frame.width, height: newHeight),
            display: true
        )
        suppressAutoPin = false
    }

    func hide() {
        stopStream()
        if !isPinned { savedOrigin = window.frame.origin }
        savedHeight = window.frame.height

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        } completionHandler: {
            self.window.orderOut(nil)
            self.window.alphaValue = 1
        }
    }

    // MARK: - Actions

    @objc private func handlePin() {
        isPinned.toggle()
        refreshPinStyle()
    }

    @objc private func handleCopySource() {
        copyToClipboard(currentSourceText)
    }

    @objc private func handleCopyDest() {
        copyToClipboard(currentDestText)
    }

    @objc private func handleBackendToggle() {
        delegate?.toggleTranslator()
    }

    @objc private func handleHide() {
        hide()
    }

    @objc private func handleRefresh() {
        delegate?.retranslateCurrent()
    }

    @objc private func handleLangChange() {
        refreshLanguageUI()
        let srcName = srcLangPop.titleOfSelectedItem ?? "自动检测"
        let destName = destLangPop.titleOfSelectedItem ?? "中文简体"
        delegate?.languageChanged(srcName: srcName, destName: destName)
    }

    @objc private func handleSwapLanguages() {
        delegate?.swapLanguages()
    }

    @objc private func windowDidMove(_ notification: Notification) {
        guard !suppressAutoPin else { return }
        autoPin()
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard !suppressAutoPin else { return }
        layoutWindow()
    }

    // MARK: - Layout

    private func layoutWindow(forcedHeight: CGFloat? = nil) {
        let windowWidth = window.frame.width
        let contentWidth = windowWidth - (OUTER_PADDING * 2)
        let cardInnerWidth = contentWidth - (CARD_INSET_X * 2)

        let srcTextHeight = measureTextHeight(currentSourceText.isEmpty ? " " : currentSourceText,
                                              width: cardInnerWidth, fontSize: SOURCE_FONT_SIZE, minimum: 44)
        let destDisplayText = currentDestText.isEmpty ? "正在翻译..." : currentDestText
        let destTextHeight = measureTextHeight(destDisplayText, width: cardInnerWidth,
                                               fontSize: BODY_FONT_SIZE, minimum: 40)
        let totalHeight: CGFloat
        if let forcedHeight {
            totalHeight = clampedWindowHeight(forcedHeight)
        } else if usesManualHeightForLayout {
            totalHeight = clampedWindowHeight(window.frame.height)
        } else {
            totalHeight = desiredAutomaticWindowHeight(for: windowWidth)
        }
        let cardHeights = stableCardHeights(for: totalHeight)
        let srcCardHeight = cardHeights.src
        let destCardHeight = cardHeights.dest

        rootView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight)
        backgroundView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight)
        backgroundView.needsDisplay = true
        resizeView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight)
        resizeView.needsDisplay = true
        window.invalidateCursorRects(for: resizeView)

        // Toolbar
        let headerY = totalHeight - OUTER_PADDING - HEADER_HEIGHT
        let toolbarY = headerY + (HEADER_HEIGHT - TOOLBAR_BUTTON_SIZE) / 2

        pinBtn.frame = NSRect(x: OUTER_PADDING, y: toolbarY,
                              width: TOOLBAR_BUTTON_SIZE, height: TOOLBAR_BUTTON_SIZE)

        let titleX = OUTER_PADDING + TOOLBAR_BUTTON_SIZE + 12
        let titleWidth = max(124, contentWidth - 232)
        headerTitleLabel.frame = NSRect(x: titleX, y: headerY + 22, width: titleWidth, height: 20)
        headerSubtitleLabel.frame = NSRect(x: titleX, y: headerY + 5, width: titleWidth + 24, height: 15)

        var rightX = windowWidth - OUTER_PADDING
        for button in [hideBtn, backendBtn, quickDestCopyBtn, quickSourceCopyBtn] {
            let btnW = (button === backendBtn) ? BACKEND_BTN_WIDTH : TOOLBAR_BUTTON_SIZE
            button.frame = NSRect(x: rightX - btnW, y: toolbarY, width: btnW, height: TOOLBAR_BUTTON_SIZE)
            rightX -= btnW + 8
        }

        // Source card
        let srcY = headerY - SECTION_GAP - srcCardHeight
        srcCard.frame = NSRect(x: OUTER_PADDING, y: srcY, width: contentWidth, height: srcCardHeight)
        let srcVisibleH = srcCardHeight - 62
        srcScroll.frame = NSRect(x: CARD_INSET_X, y: 34, width: cardInnerWidth,
                                 height: srcVisibleH)
        srcTextContainer.frame = NSRect(x: 0, y: 0, width: cardInnerWidth,
                                        height: max(srcTextHeight, srcVisibleH))
        srcLabel.frame = NSRect(x: 0, y: 0, width: cardInnerWidth, height: srcTextHeight)
        srcTitleLabel.frame = NSRect(x: CARD_INSET_X, y: srcCardHeight - 26, width: 52, height: 14)
        srcCopyBtn.frame = NSRect(x: CARD_INSET_X, y: 8, width: 22, height: 22)

        let mt = srcMetaChip.stringValue.isEmpty ? "等待选中" : srcMetaChip.stringValue
        let mw = min(max(measureTextWidth(mt, fontSize: 9.5, bold: true) + 18, 68), 112)
        srcMetaChip.frame = NSRect(x: contentWidth - CARD_INSET_X - mw, y: srcCardHeight - 28,
                                   width: mw, height: 20)

        let ct = srcLangChip.stringValue.isEmpty ? "自动检测" : srcLangChip.stringValue
        let cw = min(max(measureTextWidth(ct, fontSize: 9.5, bold: true) + 18, 68), 128)
        srcLangChip.frame = NSRect(x: contentWidth - CARD_INSET_X - cw, y: 9,
                                   width: cw, height: 20)

        // Language bar
        let langY = srcY - SECTION_GAP - LANG_BAR_HEIGHT
        langBar.frame = NSRect(x: OUTER_PADDING, y: langY, width: contentWidth, height: LANG_BAR_HEIGHT)
        let swapSize: CGFloat = 28
        let popupWidth = max(112, (contentWidth - CARD_INSET_X * 2 - swapSize - 16) / 2)
        srcLangPop.frame = NSRect(x: CARD_INSET_X, y: 8, width: popupWidth, height: 28)
        swapBtn.frame = NSRect(x: (contentWidth - swapSize) / 2, y: 8, width: swapSize, height: swapSize)
        destLangPop.frame = NSRect(x: contentWidth - CARD_INSET_X - popupWidth, y: 8,
                                   width: popupWidth, height: 28)

        // Dest card
        let destY = langY - SECTION_GAP - destCardHeight
        destCard.frame = NSRect(x: OUTER_PADDING, y: destY, width: contentWidth, height: destCardHeight)

        let destVisibleH = destCardHeight - 92
        let destTextScrollY: CGFloat = 48
        destScroll.frame = NSRect(x: CARD_INSET_X, y: destTextScrollY,
                                  width: cardInnerWidth, height: destVisibleH)
        updateDestTextLayout(width: cardInnerWidth, visibleHeight: destVisibleH, textHeight: destTextHeight)

        let providerY = destTextScrollY + destVisibleH + 10
        let toggleX = contentWidth - CARD_INSET_X - 24
        let st = destStateChip.stringValue.isEmpty ? "待翻译" : destStateChip.stringValue
        let sw = min(max(measureTextWidth(st, fontSize: 10, bold: true) + 18, 60), 78)
        let stateX = toggleX - 8 - sw

        backendBadge.frame = NSRect(x: CARD_INSET_X, y: providerY, width: 24, height: 24)
        backendBadgeLabel.frame = NSRect(x: 0, y: 4, width: 24, height: 14)
        backendNameLabel.frame = NSRect(x: CARD_INSET_X + 34, y: providerY + 3,
                                        width: max(80, stateX - 60), height: 18)
        destStateChip.frame = NSRect(x: stateX, y: providerY + 2, width: sw, height: 20)
        backendToggleBtn.frame = NSRect(x: toggleX, y: providerY, width: 24, height: 24)
        destCopyBtn.frame = NSRect(x: CARD_INSET_X, y: 12, width: 24, height: 24)
        destRefreshBtn.frame = NSRect(x: CARD_INSET_X + 32, y: 12, width: 24, height: 24)
        rootView.needsLayout = true
        rootView.layoutSubtreeIfNeeded()
        rootView.needsDisplay = true
    }

    // MARK: - Appearance

    private func refreshAppearance() {
        styleSurface(srcCard, background: SOURCE_CARD_BG, radius: CARD_RADIUS,
                     border: CARD_BORDER, shadow: true)
        styleSurface(langBar, background: LANG_BAR_BG, radius: CARD_RADIUS,
                     border: CARD_BORDER)
        styleSurface(destCard, background: DEST_CARD_BG, radius: CARD_RADIUS,
                     border: CARD_BORDER, shadow: true)

        // 文本颜色随主题刷新
        headerTitleLabel.textColor = TEXT_PRIMARY
        headerSubtitleLabel.textColor = TEXT_SECONDARY
        srcTitleLabel.textColor = TEXT_SECONDARY
        srcLabel.textColor = TEXT_SECONDARY
        // destLabel 是 NSTextView：直接改 textColor 即可；翻译中的"灰色 placeholder"由 setTranslationState 重设
        destLabel.textColor = (currentState == .loading) ? TEXT_MUTED : TEXT_PRIMARY

        restyleToolbarButton(quickSourceCopyBtn)
        restyleToolbarButton(quickDestCopyBtn)
        restyleToolbarButton(hideBtn)

        restyleIconButton(srcCopyBtn, tint: TEXT_SECONDARY, size: 22)
        restyleIconButton(swapBtn, tint: TEXT_PRIMARY, size: 28)
        restyleIconButton(backendToggleBtn, tint: TEXT_SECONDARY, size: 24)
        restyleIconButton(destCopyBtn, tint: TEXT_PRIMARY, size: 24)
        restyleIconButton(destRefreshBtn, tint: TEXT_PRIMARY, size: 24)

        srcLangPop.contentTintColor = TEXT_PRIMARY
        destLangPop.contentTintColor = TEXT_PRIMARY
        restylePopup(srcLangPop)
        restylePopup(destLangPop)

        refreshPinStyle()
        setBackendLabel(backend)
        setTranslationState(currentState)
        refreshSourceMeta()
        refreshLanguageUI()

        backgroundView.needsDisplay = true
        resizeView.needsDisplay = true
    }

    private func restyleToolbarButton(_ button: NSButton, tint: NSColor = TEXT_SECONDARY) {
        styleSurface(button, background: TOOLBAR_GHOST_BG, radius: TOOLBAR_BUTTON_SIZE / 2,
                     border: TOOLBAR_BUTTON_BORDER)
        button.contentTintColor = tint
    }

    private func restyleIconButton(_ button: NSButton, tint: NSColor, size: CGFloat) {
        styleSurface(button, background: SURFACE_BG, radius: size / 2, border: BUTTON_BORDER)
        button.contentTintColor = tint
    }

    private func restylePopup(_ popup: NSPopUpButton) {
        styleSurface(popup, background: SURFACE_BG_SOFT, radius: CONTROL_RADIUS, border: BUTTON_BORDER)
        popup.contentTintColor = TEXT_PRIMARY
    }

    // MARK: - Private Helpers

    private func configurePopup(_ popup: NSPopUpButton) {
        popup.isBordered = false
        popup.bezelStyle = .rounded
        popup.font = NSFont.boldSystemFont(ofSize: 12)
        popup.contentTintColor = TEXT_PRIMARY
        popup.wantsLayer = true
        popup.layer?.masksToBounds = true
        restylePopup(popup)
    }

    private func setupKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.keyCode == 53 else { return event }
            if self.window.isVisible, NSPointInRect(NSEvent.mouseLocation, self.window.frame) {
                self.hide()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.keyCode == 53 else { return }
            if self.window.isVisible, NSPointInRect(NSEvent.mouseLocation, self.window.frame) {
                self.hide()
            }
        }
    }

    private func setupMenu() {
        let menu = NSMenu(title: "Options")
        let closeItem = NSMenuItem(title: "隐藏窗口", action: #selector(handleHide), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
        rootView.menu = menu
    }

    private func setButtonEnabled(_ button: NSButton, _ enabled: Bool) {
        button.isEnabled = enabled
        button.alphaValue = enabled ? 1.0 : 0.36
    }

    private func refreshPinStyle() {
        let accent = isPinned ? CORAL_ACCENT : TEXT_SECONDARY
        let bg = isPinned ? TOOLBAR_ACTIVE_BG : TOOLBAR_GHOST_BG
        let bd = isPinned ? TOOLBAR_ACTIVE_BORDER : TOOLBAR_BUTTON_BORDER
        styleSurface(pinBtn, background: bg, radius: TOOLBAR_BUTTON_SIZE / 2, border: bd)
        applySymbol(pinBtn, symbolName: "pin.fill", fallback: "P", pointSize: 12, tint: accent)
    }

    private func refreshActionState() {
        let hs = !currentSourceText.isEmpty
        let hd = !currentDestText.isEmpty
        setButtonEnabled(quickSourceCopyBtn, hs)
        setButtonEnabled(srcCopyBtn, hs)
        setButtonEnabled(quickDestCopyBtn, hd)
        setButtonEnabled(destCopyBtn, hd)
        setButtonEnabled(destRefreshBtn, hs)
    }

    private func refreshSourceMeta() {
        let trimmed = currentSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            srcMetaChip.stringValue = "\(trimmed.count) 字符"
            stylePill(srcMetaChip, textColor: TEXT_SECONDARY, background: SURFACE_BG)
        } else {
            srcMetaChip.stringValue = "等待选中"
            stylePill(srcMetaChip, textColor: TEXT_MUTED, background: SURFACE_BG_SOFT)
        }
    }

    private func refreshHeaderStatus() {
        let srcTitle = srcLangPop.titleOfSelectedItem ?? "自动检测"
        let destTitle = destLangPop.titleOfSelectedItem ?? "中文简体"
        let provider = backend == "llm" ? "大模型" : "Google"
        headerSubtitleLabel.stringValue = "\(srcTitle) → \(destTitle) · \(provider)"
    }

    private func setTranslationState(_ state: TranslationState) {
        currentState = state
        switch state {
        case .done:
            destStateChip.stringValue = "已完成"
            stylePill(destStateChip, textColor: TEAL_ACCENT, background: CHIP_BG_ALT)
        case .loading:
            destStateChip.stringValue = "翻译中"
            stylePill(destStateChip, textColor: AMBER_ACCENT, background: CHIP_BG_WARM)
        case .idle:
            destStateChip.stringValue = "待翻译"
            stylePill(destStateChip, textColor: TEXT_MUTED, background: SURFACE_BG_SOFT)
        }
    }

    private func refreshLanguageUI() {
        let srcTitle = srcLangPop.titleOfSelectedItem ?? "自动检测"
        if srcTitle == "自动检测" {
            srcLangChip.stringValue = "自动检测"
            setButtonEnabled(swapBtn, false)
            stylePill(srcLangChip, textColor: TEXT_SECONDARY, background: SURFACE_BG)
        } else {
            srcLangChip.stringValue = srcTitle
            setButtonEnabled(swapBtn, true)
            stylePill(srcLangChip, textColor: BLUE_ACCENT, background: CHIP_BG)
        }
        refreshHeaderStatus()
    }

    private func autoPin() {
        guard !isPinned else { return }
        isPinned = true
        refreshPinStyle()
    }

    private func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    private func scrollToTop(_ scrollView: NSScrollView) {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func setDestText(_ text: String) {
        destLabel.string = text
    }

    private func updateDestTextLayout(width: CGFloat, visibleHeight: CGFloat, textHeight: CGFloat) {
        let contentHeight = max(40, ceil(textHeight))
        destTextContainer.frame = NSRect(x: 0, y: 0, width: width,
                                         height: max(contentHeight, visibleHeight))
        destLabel.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
    }

    private func stableCardHeights(for totalHeight: CGFloat) -> (src: CGFloat, dest: CGFloat) {
        let overhead = OUTER_PADDING + HEADER_HEIGHT + SECTION_GAP + SECTION_GAP
            + LANG_BAR_HEIGHT + SECTION_GAP + OUTER_PADDING
        let available = max(0, clampedWindowHeight(totalHeight) - overhead)
        let baseSrcCardHeight: CGFloat = 112
        let baseDestCardHeight = max(CGFloat(164), WINDOW_MIN_HEIGHT - overhead - baseSrcCardHeight)

        var src = min(baseSrcCardHeight, available)
        var dest = max(baseDestCardHeight, available - src)

        if dest > DEST_MAX_CARD_HEIGHT {
            let overflow = dest - DEST_MAX_CARD_HEIGHT
            dest = DEST_MAX_CARD_HEIGHT
            src = min(SRC_MAX_CARD_HEIGHT, src + overflow)
        }

        if src + dest < available {
            let remaining = available - src - dest
            src = min(SRC_MAX_CARD_HEIGHT, src + remaining)
        }

        if src + dest > available {
            dest = max(CGFloat(164), available - src)
        }

        return (src: src, dest: dest)
    }

    private func desiredAutomaticWindowHeight(for width: CGFloat) -> CGFloat {
        let contentWidth = width - (OUTER_PADDING * 2)
        let cardInnerWidth = contentWidth - (CARD_INSET_X * 2)
        let destDisplayText = currentDestText.isEmpty ? "正在翻译..." : currentDestText
        let destTextHeight = measureTextHeight(destDisplayText, width: cardInnerWidth,
                                               fontSize: BODY_FONT_SIZE, minimum: 40)

        let overhead = OUTER_PADDING + HEADER_HEIGHT + SECTION_GAP + SECTION_GAP
            + LANG_BAR_HEIGHT + SECTION_GAP + OUTER_PADDING
        let baseSrcCardHeight: CGFloat = 112
        let baseDestCardHeight = max(CGFloat(164), WINDOW_MIN_HEIGHT - overhead - baseSrcCardHeight)
        let neededDestCardHeight = min(DEST_MAX_CARD_HEIGHT,
                                       max(baseDestCardHeight, min(destTextHeight, MAX_CARD_TEXT_HEIGHT) + 92))
        return min(MAX_WINDOW_HEIGHT,
                   max(WINDOW_MIN_HEIGHT, overhead + baseSrcCardHeight + neededDestCardHeight))
    }

    private func growWindowForStreamingIfNeeded() {
        guard !usesManualHeightForLayout, window.isVisible else { return }

        let frame = window.frame
        let targetHeight = desiredAutomaticWindowHeight(for: frame.width)
        let growthThreshold: CGFloat = 18
        guard targetHeight > frame.height + growthThreshold else { return }

        layoutWindow(forcedHeight: targetHeight)
        let top = frame.maxY
        suppressAutoPin = true
        window.setFrame(
            NSRect(x: frame.origin.x, y: top - targetHeight, width: frame.width, height: targetHeight),
            display: true
        )
        suppressAutoPin = false
    }

    private var usesManualHeightForLayout: Bool {
        hasManualHeight || activeResizeEdges.hasVertical
    }

    private func handleResize(edges: ResizeEdges, startFrame: NSRect, delta: NSSize) {
        activeResizeEdges = edges
        if edges.hasVertical {
            hasManualHeight = true
        }

        let width: CGFloat
        let originX: CGFloat
        if edges.contains(.left) {
            width = clampedWindowWidth(startFrame.width - delta.width)
            originX = startFrame.maxX - width
        } else if edges.contains(.right) {
            width = clampedWindowWidth(startFrame.width + delta.width)
            originX = startFrame.origin.x
        } else {
            width = startFrame.width
            originX = startFrame.origin.x
        }

        let height: CGFloat
        let originY: CGFloat
        if edges.contains(.bottom) {
            height = clampedWindowHeight(startFrame.height - delta.height)
            originY = startFrame.maxY - height
        } else if edges.contains(.top) {
            height = clampedWindowHeight(startFrame.height + delta.height)
            originY = startFrame.origin.y
        } else {
            height = startFrame.height
            originY = startFrame.origin.y
        }

        let newFrame = NSRect(x: originX, y: originY, width: width, height: height)
        suppressAutoPin = true
        window.setFrame(newFrame, display: true)
        suppressAutoPin = false
        layoutWindow()
    }

    private func clampedWindowWidth(_ width: CGFloat) -> CGFloat {
        return max(MIN_WINDOW_WIDTH, min(MAX_WINDOW_WIDTH, width))
    }

    private func clampedWindowHeight(_ height: CGFloat) -> CGFloat {
        return max(WINDOW_MIN_HEIGHT, min(MAX_WINDOW_HEIGHT, height))
    }
}

// MARK: - Translation State Enum

private enum TranslationState {
    case idle, loading, done
}
