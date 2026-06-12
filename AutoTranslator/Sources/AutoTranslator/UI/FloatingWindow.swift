import AppKit
import SwiftUI

// MARK: - Borderless Window

final class BorderlessWindow: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    var onAnyMouseDown: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
    }

    override func mouseDown(with event: NSEvent) {
        // Window background dragging is handled by isMovableByWindowBackground.
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { /* Esc is handled via key monitor. */ }
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

private final class ThemeAwareView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override var isOpaque: Bool { false }

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
        resizeEdges(at: point).isEmpty ? nil : self
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
    private let hostingView: NSHostingView<FloatingWindowView>
    private let resizeView: WindowResizeView
    private let viewModel = FloatingWindowViewModel()

    private(set) var currentSourceText = ""
    private(set) var currentDestText = ""
    private var backend = "google"
    private var isPinned = false
    private var savedOrigin: NSPoint?
    private var savedHeight: CGFloat?
    private var suppressAutoPin = false
    private var activeResizeEdges: ResizeEdges = []
    private var hasManualHeight = false
    private var currentState: TranslationState = .idle

    private var streamTimer: Timer?
    private var streamBuffer = ""
    private var streamBufferCount = 0
    private var streamPos = 0
    private var streamFinal: String?

    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var globalClickMonitor: Any?
    private var pendingSinkWorkItem: DispatchWorkItem?

    private var srcLang = "auto"
    private var destLang = "zh-CN"

    override init() {
        window = BorderlessWindow()
        rootView = ThemeAwareView(frame: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT))
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = PANEL_RADIUS
        rootView.layer?.masksToBounds = true
        rootView.autoresizingMask = [.width, .height]

        hostingView = NSHostingView(rootView: FloatingWindowView(model: viewModel))
        hostingView.frame = rootView.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        resizeView = WindowResizeView(frame: rootView.bounds)
        resizeView.autoresizingMask = [.width, .height]

        super.init()

        window.contentView = rootView
        rootView.addSubview(hostingView)
        rootView.addSubview(resizeView)

        rootView.onAppearanceChanged = { [weak self] in
            refreshThemeCache()
            self?.viewModel.appearanceVersion += 1
            self?.resizeView.needsDisplay = true
        }

        window.onAnyMouseDown = { [weak self] in
            self?.raiseToTop()
        }

        wireViewModel()
        setupMenu()
        setupKeyMonitor()

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidMove),
                                               name: NSWindow.didMoveNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize),
                                               name: NSWindow.didResizeNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey),
                                               name: NSWindow.didBecomeKeyNotification,
                                               object: window)

        resizeView.onResize = { [weak self] edges, startFrame, delta in
            self?.handleResize(edges: edges, startFrame: startFrame, delta: delta)
        }
        resizeView.onResizeEnd = { [weak self] in
            self?.activeResizeEdges = []
        }

        viewModel.state = .idle
        setBackendLabel("google")
    }

    deinit {
        stopStream()
        NotificationCenter.default.removeObserver(self)
        if let m = localKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m) }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m) }
        pendingSinkWorkItem?.cancel()
    }

    // MARK: - Window Level Management

    private func raiseToTop() {
        pendingSinkWorkItem?.cancel()
        pendingSinkWorkItem = nil
        window.level = .floating
        window.orderFrontRegardless()
    }

    private func sinkBelowOtherWindows() {
        guard window.isVisible, !isPinned else { return }
        window.level = .normal
        window.orderBack(nil)
    }

    private func installGlobalClickMonitorIfNeeded() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self,
                  self.window.isVisible,
                  !self.isPinned,
                  self.window.level == .floating else { return }
            let work = DispatchWorkItem { [weak self] in self?.sinkBelowOtherWindows() }
            self.pendingSinkWorkItem?.cancel()
            self.pendingSinkWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350), execute: work)
        }
    }

    @objc private func windowDidBecomeKey() {
        pendingSinkWorkItem?.cancel()
        pendingSinkWorkItem = nil
        window.level = .floating
        window.orderFrontRegardless()
    }

    // MARK: - Public API

    func setBackendLabel(_ backend: String) {
        self.backend = backend
        viewModel.backend = backend
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard window.isVisible else { return false }
        return window.frame.contains(NSPoint(x: point.x, y: point.y))
    }

    func setLanguages(_ languages: [String: String], source: String, target: String) {
        srcLang = source
        destLang = target

        let sourceTitles = Languages.sourceOptions.map(\.name).filter { languages[$0] != nil }
        let targetTitles = Languages.targetOptions.map(\.name).filter { languages[$0] != nil }

        viewModel.sourceOptions = sourceTitles
        viewModel.targetOptions = targetTitles
        viewModel.selectedSource = Languages.name(for: source)
        viewModel.selectedTarget = Languages.name(for: target)
    }

    func show(srcText: String, destText: String?) {
        pendingSinkWorkItem?.cancel()
        pendingSinkWorkItem = nil
        stopStream()
        let wasVisible = window.isVisible

        currentSourceText = srcText
        currentDestText = destText ?? ""
        viewModel.sourceText = srcText

        if let destText {
            setDestText(destText)
            setTranslationState(.done)
        } else {
            setDestText("正在翻译...")
            setTranslationState(.loading)
        }

        let currentHeight = clampedWindowHeight(window.frame.height)
        let targetHeight: CGFloat
        if usesManualHeightForLayout {
            targetHeight = currentHeight
        } else if wasVisible {
            targetHeight = max(currentHeight, desiredAutomaticWindowHeight(for: window.frame.width))
        } else if let restored = savedHeight {
            targetHeight = max(clampedWindowHeight(restored), desiredAutomaticWindowHeight(for: window.frame.width))
        } else {
            targetHeight = WINDOW_MIN_HEIGHT
        }
        layoutWindow(forcedHeight: targetHeight)

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
            window.level = .floating
            window.orderFrontRegardless()
        } else {
            let (x, y): (CGFloat, CGFloat)
            if let saved = savedOrigin {
                x = saved.x
                y = saved.y
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
        setTranslationState(.loading)
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

    private func handlePin() {
        isPinned.toggle()
        viewModel.isPinned = isPinned
    }

    private func handleCopySource() {
        copyToClipboard(currentSourceText)
    }

    private func handleCopyDest() {
        copyToClipboard(currentDestText)
    }

    private func handleBackendToggle() {
        delegate?.toggleTranslator()
    }

    private func handleHide() {
        hide()
    }

    private func handleRefresh() {
        delegate?.retranslateCurrent()
    }

    private func handleLangChange(srcName: String, destName: String) {
        delegate?.languageChanged(srcName: srcName, destName: destName)
    }

    private func handleSwapLanguages() {
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
        let windowWidth = clampedWindowWidth(window.frame.width)
        let totalHeight: CGFloat
        if let forcedHeight {
            totalHeight = clampedWindowHeight(forcedHeight)
        } else if usesManualHeightForLayout {
            totalHeight = clampedWindowHeight(window.frame.height)
        } else {
            totalHeight = desiredAutomaticWindowHeight(for: windowWidth)
        }

        rootView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight)
        hostingView.frame = rootView.bounds
        resizeView.frame = rootView.bounds
        window.invalidateCursorRects(for: resizeView)
    }

    private func desiredAutomaticWindowHeight(for width: CGFloat) -> CGFloat {
        let contentWidth = width - (OUTER_PADDING * 2)
        let cardInnerWidth = contentWidth - (CARD_INSET_X * 2)
        let destDisplayText = currentDestText.isEmpty ? "正在翻译..." : currentDestText
        let destTextHeight = measureTextHeight(destDisplayText, width: cardInnerWidth,
                                               fontSize: BODY_FONT_SIZE, minimum: 64)

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

        suppressAutoPin = true
        window.setFrame(NSRect(x: originX, y: originY, width: width, height: height), display: true)
        suppressAutoPin = false
        layoutWindow()
    }

    private func clampedWindowWidth(_ width: CGFloat) -> CGFloat {
        max(MIN_WINDOW_WIDTH, min(MAX_WINDOW_WIDTH, width))
    }

    private func clampedWindowHeight(_ height: CGFloat) -> CGFloat {
        max(WINDOW_MIN_HEIGHT, min(MAX_WINDOW_HEIGHT, height))
    }

    // MARK: - Private Helpers

    private func wireViewModel() {
        viewModel.onPin = { [weak self] in self?.handlePin() }
        viewModel.onCopySource = { [weak self] in self?.handleCopySource() }
        viewModel.onCopyDest = { [weak self] in self?.handleCopyDest() }
        viewModel.onToggleBackend = { [weak self] in self?.handleBackendToggle() }
        viewModel.onHide = { [weak self] in self?.handleHide() }
        viewModel.onRefresh = { [weak self] in self?.handleRefresh() }
        viewModel.onSwapLanguages = { [weak self] in self?.handleSwapLanguages() }
        viewModel.onLanguageChanged = { [weak self] src, dest in
            self?.handleLangChange(srcName: src, destName: dest)
        }
    }

    private func setupKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            if self.window.isVisible, NSPointInRect(NSEvent.mouseLocation, self.window.frame) {
                self.hide()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return }
            if self.window.isVisible, NSPointInRect(NSEvent.mouseLocation, self.window.frame) {
                self.hide()
            }
        }
    }

    private func setupMenu() {
        let menu = NSMenu(title: "Options")
        let closeItem = NSMenuItem(title: "隐藏窗口", action: #selector(handleMenuHide), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
        rootView.menu = menu
    }

    @objc private func handleMenuHide() {
        hide()
    }

    private func autoPin() {
        guard !isPinned else { return }
        isPinned = true
        viewModel.isPinned = true
    }

    private func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        pb.setString(text, forType: .string)
    }

    private func setDestText(_ text: String) {
        currentDestText = text
        viewModel.destText = text
    }

    private func setTranslationState(_ state: TranslationState) {
        currentState = state
        viewModel.state = state
    }
}
