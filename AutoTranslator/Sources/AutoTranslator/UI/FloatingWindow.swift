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
    var allowsScrollOnlyMouseInteraction = false

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard allowsScrollOnlyMouseInteraction else {
            return super.hitTest(point)
        }
        guard bounds.contains(point) else { return nil }

        let eventType = window?.currentEvent?.type ?? NSApp.currentEvent?.type
        guard eventType == .scrollWheel else { return nil }
        return super.hitTest(point)
    }

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
    func speakCurrentSource()
    func screenshotTranslation()
    func retranslateCurrent()
    func hideWindow()
    func stopSpeech()
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
    private var suppressAutoPin = false
    private var activeResizeEdges: ResizeEdges = []
    private var hasManualHeight = false
    private var sourceCardHeightOverride: CGFloat?
    private var isSourceResizeInteractionActive = false
    private var currentState: TranslationState = .idle
    private var minimalAnchorPoint: NSPoint?
    private var dismissedMinimalSourceText: String?

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
    private var currentPresentation: FloatingPresentation = .translation

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
        removeKeyMonitors()
        removeGlobalClickMonitor()
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
        guard isMinimalWindowMode || !isPinned else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self,
                  self.window.isVisible,
                  self.window.level == .floating else { return }
            if self.isMinimalWindowMode {
                self.hide()
                return
            }
            guard !self.isPinned else { return }
            let work = DispatchWorkItem { [weak self] in self?.sinkBelowOtherWindows() }
            self.pendingSinkWorkItem?.cancel()
            self.pendingSinkWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(350), execute: work)
        }
    }

    private func removeGlobalClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        pendingSinkWorkItem?.cancel()
        pendingSinkWorkItem = nil
    }

    @objc private func windowDidBecomeKey() {
        pendingSinkWorkItem?.cancel()
        pendingSinkWorkItem = nil
        window.level = .floating
        window.orderFrontRegardless()
    }

    // MARK: - Public API

    func setBackendLabel(_ backend: String) {
        guard self.backend != backend || viewModel.backend != backend else { return }
        self.backend = backend
        viewModel.backend = backend
    }

    func setWindowMode(_ mode: FloatingWindowMode) {
        guard viewModel.windowMode != mode else { return }
        viewModel.windowMode = mode
        if mode == .minimal, isPinned {
            isPinned = false
            viewModel.isPinned = false
        }
        hasManualHeight = false
        activeResizeEdges = []
        setSourceResizeInteractionActive(false)
        updateMouseEventPolicy()
        layoutWindow()
        if mode == .minimal {
            minimalAnchorPoint = NSEvent.mouseLocation
        } else {
            minimalAnchorPoint = nil
            dismissedMinimalSourceText = nil
        }

        let frame = window.frame
        let targetHeight = rootView.frame.height
        let targetFrame: NSRect
        if mode == .minimal, let point = minimalAnchorPoint {
            targetFrame = minimalWindowFrame(near: point, width: rootView.frame.width, height: targetHeight)
        } else {
            targetFrame = NSRect(
                x: frame.origin.x,
                y: window.isVisible ? frame.maxY - targetHeight : frame.origin.y,
                width: rootView.frame.width,
                height: targetHeight
            )
        }
        suppressAutoPin = true
        window.setFrame(targetFrame, display: window.isVisible)
        suppressAutoPin = false
        removeGlobalClickMonitor()
        if window.isVisible {
            installGlobalClickMonitorIfNeeded()
        }
    }

    func containsScreenPoint(_ point: CGPoint) -> Bool {
        guard window.isVisible, !isMinimalWindowMode, !window.ignoresMouseEvents else { return false }
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

    func show(
        srcText: String,
        destText: String?,
        presentation: FloatingPresentation = .translation
    ) {
        pendingSinkWorkItem?.cancel()
        pendingSinkWorkItem = nil
        stopStream()
        let wasVisible = window.isVisible
        let isNewSourceText = srcText != currentSourceText

        if isMinimalWindowMode,
           destText != nil,
           !wasVisible,
           !isNewSourceText,
           dismissedMinimalSourceText == srcText {
            return
        }

        if isMinimalWindowMode, destText == nil || isNewSourceText || minimalAnchorPoint == nil {
            dismissedMinimalSourceText = nil
            minimalAnchorPoint = NSEvent.mouseLocation
        }

        if isNewSourceText, !isSourceResizeInteractionActive {
            sourceCardHeightOverride = nil
        }

        currentSourceText = srcText
        currentDestText = destText ?? ""
        currentPresentation = presentation
        viewModel.sourceText = srcText
        viewModel.presentation = presentation
        if isNewSourceText {
            setSpeechState(.idle)
        }

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
        } else {
            targetHeight = desiredAutomaticWindowHeight(for: window.frame.width)
        }
        layoutWindow(forcedHeight: targetHeight)

        let newWidth = rootView.frame.width
        let newHeight = rootView.frame.height
        suppressAutoPin = true
        defer { suppressAutoPin = false }

        if isMinimalWindowMode {
            let point = minimalAnchorPoint ?? NSEvent.mouseLocation
            minimalAnchorPoint = point
            let targetFrame = minimalWindowFrame(near: point, width: newWidth, height: newHeight)
            if wasVisible {
                window.setFrame(targetFrame, display: true)
                window.level = .floating
                window.orderFrontRegardless()
            } else {
                window.setFrame(targetFrame, display: true)
                window.alphaValue = 0
                window.orderFrontRegardless()

                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    window.animator().alphaValue = 1
                }
            }
            window.invalidateShadow()
        } else if wasVisible {
            let frame = window.frame
            if abs(frame.width - newWidth) > 0.5 || abs(frame.height - newHeight) > 0.5 {
                window.setFrame(
                    NSRect(x: frame.origin.x, y: frame.maxY - newHeight,
                           width: newWidth, height: newHeight),
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
                x = (screen.width - newWidth) / 2 + screen.origin.x
                y = (screen.height - newHeight) / 2 + screen.origin.y
            }

            window.setFrame(NSRect(x: x, y: y, width: newWidth, height: newHeight), display: true)
            window.alphaValue = 0
            // 不调用 makeKeyAndOrderFront：让浮窗以“非激活”方式出现，避免抢走源程序的 key 焦点、
            // 把本应用置为 active。否则紧接着的划词会在鼠标按下时被 isIgnoredFrontmostApplication()
            // （NSApp.isActive 仍为 true）当成“在自己应用内操作”而整段忽略——表现为结果出来后
            // 马上划词没有任何反应、必须先点一下别处才恢复。窗口仍可在用户点击时按需成为 key。
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                window.animator().alphaValue = 1
            }
        }

        installKeyMonitorsIfNeeded()
        installGlobalClickMonitorIfNeeded()
    }

    /// 以错误态展示。复用 show() 的尺寸自适应、定位与出现动画，
    /// 仅在末尾把状态翻为 .error 并写入状态标签（驱动红色 chip 与珊瑚色文案）。
    func showError(
        srcText: String,
        message: String,
        status: String = "翻译失败",
        presentation: FloatingPresentation = .translation
    ) {
        viewModel.errorStatusText = status
        show(srcText: srcText, destText: message, presentation: presentation)
        setTranslationState(.error)
    }

    func setSpeechState(_ state: SpeechPlaybackState) {
        guard viewModel.speechState != state else { return }
        viewModel.speechState = state
    }

    // MARK: - Stream

    func streamAppend(_ token: String) {
        guard !token.isEmpty else { return }
        if streamTimer == nil { startStream() }
        streamBuffer += token
        streamBufferCount += token.count
    }

    func streamFeed(_ text: String) {
        if streamTimer == nil { startStream() }
        guard streamBuffer != text else { return }
        streamBuffer = text
        streamBufferCount = text.count
    }

    func streamFinish(_ finalText: String) {
        streamFinal = finalText
        if streamBuffer != finalText {
            streamBuffer = finalText
            streamBufferCount = finalText.count
        }
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
        let timer = Timer.scheduledTimer(withTimeInterval: STREAM_RENDER_INTERVAL, repeats: true) { [weak self] _ in
            self?.streamTick()
        }
        timer.tolerance = STREAM_RENDER_TIMER_TOLERANCE
        streamTimer = timer
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
            : desiredAutomaticWindowHeight(for: frame.width)
        layoutWindow(forcedHeight: desiredHeight)

        guard window.isVisible else { return }
        let newWidth = rootView.frame.width
        let newHeight = rootView.frame.height
        guard abs(frame.width - newWidth) > 0.5 || abs(frame.height - newHeight) > 0.5 else { return }
        suppressAutoPin = true
        if isMinimalWindowMode, let point = minimalAnchorPoint {
            window.setFrame(
                minimalWindowFrame(near: point, width: newWidth, height: newHeight),
                display: true
            )
        } else {
            window.setFrame(
                NSRect(x: frame.origin.x, y: frame.maxY - newHeight, width: newWidth, height: newHeight),
                display: true
            )
        }
        suppressAutoPin = false
        window.invalidateShadow()
    }

    func hide() {
        stopStream()
        delegate?.stopSpeech()
        setSourceResizeInteractionActive(false)
        if isMinimalWindowMode {
            dismissedMinimalSourceText = currentSourceText
            minimalAnchorPoint = nil
        } else if window.isVisible, !isPinned {
            savedOrigin = window.frame.origin
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        } completionHandler: {
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            self.removeGlobalClickMonitor()
            self.removeKeyMonitors()
        }
    }

    func hideImmediately() {
        stopStream()
        delegate?.stopSpeech()
        setSourceResizeInteractionActive(false)
        if isMinimalWindowMode {
            dismissedMinimalSourceText = currentSourceText
            minimalAnchorPoint = nil
        } else if window.isVisible, !isPinned {
            savedOrigin = window.frame.origin
        }
        window.alphaValue = 1
        window.orderOut(nil)
        removeGlobalClickMonitor()
        removeKeyMonitors()
    }

    // MARK: - Actions

    private func handlePin() {
        isPinned.toggle()
        viewModel.isPinned = isPinned
        if isPinned {
            removeGlobalClickMonitor()
        } else if window.isVisible {
            installGlobalClickMonitorIfNeeded()
        }
    }

    private func handleCopySource() {
        copyToClipboard(currentSourceText)
    }

    private func handleCopyDest() {
        let text = currentPresentation.isDictionary
            ? DictionaryDefinitionFormatter.measurementText(word: currentSourceText, definition: currentDestText)
            : currentDestText
        copyToClipboard(text)
    }

    private func handleBackendToggle() {
        delegate?.toggleTranslator()
    }

    private func handleSpeakSource() {
        delegate?.speakCurrentSource()
    }

    private func handleScreenshotTranslation() {
        delegate?.screenshotTranslation()
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

    private func handleSourceLineCountChange(_ lineCount: Int) {
        let nextHeight = sourceCardHeight(forLineCount: lineCount)
        guard abs((sourceCardHeightOverride ?? viewModel.sourceCardHeight) - nextHeight) > 0.5 else {
            return
        }
        sourceCardHeightOverride = nextHeight

        let frame = window.frame
        layoutWindow(forcedHeight: clampedWindowHeight(frame.height))
        if window.isVisible {
            window.displayIfNeeded()
        }
    }

    private func handleSourceResizeEnd() {
        guard !usesManualHeightForLayout, window.isVisible else { return }
        let frame = window.frame
        let targetHeight = desiredAutomaticWindowHeight(for: frame.width)
        guard abs(frame.height - targetHeight) > 0.5 else { return }

        layoutWindow(forcedHeight: targetHeight)
        suppressAutoPin = true
        window.setFrame(
            NSRect(x: frame.origin.x, y: frame.maxY - targetHeight, width: frame.width, height: targetHeight),
            display: true
        )
        suppressAutoPin = false
    }

    private func setSourceResizeInteractionActive(_ active: Bool) {
        guard active != isSourceResizeInteractionActive else { return }
        isSourceResizeInteractionActive = active
        updateMouseEventPolicy()
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

        if !isMinimalWindowMode {
            let preferredSourceHeight = preferredSourceCardHeight(for: windowWidth)
            let displayedSourceHeight = min(
                preferredSourceHeight,
                max(SOURCE_CARD_MIN_HEIGHT, totalHeight - minimumNonSourceHeight)
            )
            if abs(viewModel.sourceCardHeight - displayedSourceHeight) > 0.5 {
                viewModel.sourceCardHeight = displayedSourceHeight
            }
        }

        updateMouseEventPolicy()
        rootView.layer?.cornerRadius = isMinimalWindowMode ? MINIMAL_PANEL_RADIUS : PANEL_RADIUS
        resizeView.isHidden = isMinimalWindowMode
        rootView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight)
        hostingView.frame = rootView.bounds
        resizeView.frame = rootView.bounds
        window.invalidateCursorRects(for: resizeView)
    }

    private func desiredAutomaticWindowHeight(for width: CGFloat) -> CGFloat {
        if isMinimalWindowMode {
            return desiredMinimalWindowHeight(for: width)
        }

        let sourceCardHeight = preferredSourceCardHeight(for: width)
        let cardInnerWidth = textMeasureWidth(for: width)
        let destDisplayText = currentDestText.isEmpty ? "正在翻译..." : currentDestText
        let measuredDestText = destinationMeasurementText(for: destDisplayText)
        let measuredDestFontSize = currentPresentation.isDictionary
            ? DICTIONARY_BODY_FONT_SIZE
            : BODY_FONT_SIZE
        let destTextMinHeight = currentPresentation.isDictionary
            ? DICTIONARY_TEXT_MIN_HEIGHT
            : DEST_TEXT_MIN_HEIGHT
        let destTextHeight = measureTextHeight(measuredDestText, width: cardInnerWidth,
                                               fontSize: measuredDestFontSize, minimum: destTextMinHeight)

        let overhead = windowChromeHeight
        let destChromeHeight = currentPresentation.isDictionary
            ? DICTIONARY_DEST_CARD_CHROME_HEIGHT
            : DEST_CARD_CHROME_HEIGHT
        let baseDestCardHeight = max(destinationMinimumCardHeight, minimumWindowHeight - overhead - sourceCardHeight)
        let neededDestCardHeight = min(DEST_MAX_CARD_HEIGHT,
                                       max(baseDestCardHeight, min(destTextHeight, MAX_CARD_TEXT_HEIGHT) + destChromeHeight))
        return min(MAX_WINDOW_HEIGHT,
                   max(minimumWindowHeight, overhead + sourceCardHeight + neededDestCardHeight))
    }

    private func desiredMinimalWindowHeight(for width: CGFloat) -> CGFloat {
        let destDisplayText = currentDestText.isEmpty ? "正在翻译..." : currentDestText
        let measuredText = isMinimalDictionaryResult
            ? DictionaryDefinitionFormatter.measurementText(word: currentSourceText, definition: destDisplayText)
            : destDisplayText
        let measuredFontSize = isMinimalDictionaryResult ? DICTIONARY_BODY_FONT_SIZE : BODY_FONT_SIZE
        let extraHeight = isMinimalDictionaryResult ? MINIMAL_DICTIONARY_EXTRA_HEIGHT : 0
        let destTextHeight = measureTextHeight(
            measuredText,
            width: minimalTextMeasureWidth(for: width),
            fontSize: measuredFontSize,
            minimum: MINIMAL_TEXT_MIN_HEIGHT
        )
        let contentHeight = min(destTextHeight + extraHeight, MINIMAL_WINDOW_MAX_HEIGHT - minimalWindowChromeHeight)
        return min(maximumWindowHeight, max(minimumWindowHeight, contentHeight + minimalWindowChromeHeight))
    }

    private func destinationMeasurementText(for text: String) -> String {
        guard currentPresentation.isDictionary,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text != "正在翻译..." else {
            return text
        }
        return DictionaryDefinitionFormatter.measurementText(word: currentSourceText, definition: text)
    }

    private func desiredSourceCardHeight(for width: CGFloat) -> CGFloat {
        let sourceDisplayText = currentSourceText.isEmpty ? " " : currentSourceText
        let sourceTextHeight = measureTextHeight(sourceDisplayText,
                                                 width: textMeasureWidth(for: width),
                                                 fontSize: SOURCE_FONT_SIZE,
                                                 minimum: SOURCE_TEXT_MIN_HEIGHT)
        let neededTextHeight = min(sourceTextHeight, SOURCE_TEXT_MAX_HEIGHT)
        return min(SRC_MAX_CARD_HEIGHT,
                   max(SOURCE_CARD_MIN_HEIGHT, neededTextHeight + SOURCE_CARD_CHROME_HEIGHT))
    }

    private func preferredSourceCardHeight(for width: CGFloat) -> CGFloat {
        sourceCardHeightOverride ?? desiredSourceCardHeight(for: width)
    }

    private func sourceCardHeight(forLineCount lineCount: Int) -> CGFloat {
        let minLines = max(1, Int((SOURCE_TEXT_MIN_HEIGHT / SOURCE_TEXT_LINE_HEIGHT).rounded(.up)))
        let maxLines = max(minLines, Int((SOURCE_TEXT_MAX_HEIGHT / SOURCE_TEXT_LINE_HEIGHT).rounded(.down)))
        let clampedLineCount = min(maxLines, max(minLines, lineCount))
        let textHeight = CGFloat(clampedLineCount) * SOURCE_TEXT_LINE_HEIGHT
        return min(SRC_MAX_CARD_HEIGHT,
                   max(SOURCE_CARD_MIN_HEIGHT, textHeight + SOURCE_CARD_CHROME_HEIGHT))
    }

    private func textMeasureWidth(for width: CGFloat) -> CGFloat {
        let contentWidth = width - (OUTER_PADDING * 2)
        return max(120, contentWidth - (CARD_INSET_X * 2))
    }

    private func minimalTextMeasureWidth(for width: CGFloat) -> CGFloat {
        max(120, width - (MINIMAL_WINDOW_PADDING_X * 2))
    }

    private var windowChromeHeight: CGFloat {
        OUTER_PADDING + HEADER_HEIGHT + SECTION_GAP + SECTION_GAP
            + LANG_BAR_HEIGHT + SECTION_GAP + OUTER_PADDING
    }

    private var minimumNonSourceHeight: CGFloat {
        windowChromeHeight + destinationMinimumCardHeight
    }

    private var destinationMinimumCardHeight: CGFloat {
        currentPresentation.isDictionary ? DICTIONARY_DEST_CARD_MIN_HEIGHT : DEST_CARD_MIN_HEIGHT
    }

    private var minimumWindowHeight: CGFloat {
        if isMinimalWindowMode {
            return MINIMAL_WINDOW_MIN_HEIGHT
        }
        return max(WINDOW_MIN_HEIGHT, windowChromeHeight + SOURCE_CARD_MIN_HEIGHT + destinationMinimumCardHeight)
    }

    private var maximumWindowHeight: CGFloat {
        isMinimalWindowMode ? MINIMAL_WINDOW_MAX_HEIGHT : MAX_WINDOW_HEIGHT
    }

    private var minimalWindowChromeHeight: CGFloat {
        MINIMAL_WINDOW_PADDING_Y * 2
    }

    private func growWindowForStreamingIfNeeded() {
        guard !usesManualHeightForLayout, window.isVisible else { return }

        let frame = window.frame
        let targetHeight = desiredAutomaticWindowHeight(for: frame.width)
        let growthThreshold: CGFloat = 18
        guard targetHeight > frame.height + growthThreshold else { return }

        layoutWindow(forcedHeight: targetHeight)
        let top = frame.maxY
        let newWidth = rootView.frame.width
        let newHeight = rootView.frame.height
        suppressAutoPin = true
        if isMinimalWindowMode, let point = minimalAnchorPoint {
            window.setFrame(
                minimalWindowFrame(near: point, width: newWidth, height: newHeight),
                display: true
            )
        } else {
            window.setFrame(
                NSRect(x: frame.origin.x, y: top - newHeight, width: newWidth, height: newHeight),
                display: true
            )
        }
        suppressAutoPin = false
        window.invalidateShadow()
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
        if isMinimalWindowMode {
            return max(MINIMAL_WINDOW_MIN_WIDTH, min(MINIMAL_WINDOW_MAX_WIDTH, width))
        }
        return max(MIN_WINDOW_WIDTH, min(MAX_WINDOW_WIDTH, width))
    }

    private func clampedWindowHeight(_ height: CGFloat) -> CGFloat {
        max(minimumWindowHeight, min(maximumWindowHeight, height))
    }

    private func minimalWindowFrame(near point: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        let fallbackFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: width, height: height)
        let visibleFrame = (screen?.visibleFrame ?? fallbackFrame).insetBy(
            dx: MINIMAL_WINDOW_SCREEN_MARGIN,
            dy: MINIMAL_WINDOW_SCREEN_MARGIN
        )

        let minX = visibleFrame.minX
        let maxX = max(minX, visibleFrame.maxX - width)
        let preferredRightX = point.x + MINIMAL_WINDOW_CURSOR_OFFSET_X
        let preferredLeftX = point.x - width - MINIMAL_WINDOW_CURSOR_OFFSET_X
        let x: CGFloat
        if preferredRightX <= maxX {
            x = min(max(preferredRightX, minX), maxX)
        } else if preferredLeftX >= minX {
            x = min(max(preferredLeftX, minX), maxX)
        } else {
            x = min(max(preferredRightX, minX), maxX)
        }

        let minY = visibleFrame.minY
        let maxY = max(minY, visibleFrame.maxY - height)
        let preferredBelowY = point.y - height - MINIMAL_WINDOW_CURSOR_OFFSET_Y
        let preferredAboveY = point.y + MINIMAL_WINDOW_CURSOR_OFFSET_Y
        let y: CGFloat
        if preferredBelowY >= minY {
            y = min(max(preferredBelowY, minY), maxY)
        } else if preferredAboveY <= maxY {
            y = min(max(preferredAboveY, minY), maxY)
        } else {
            let availableBelow = point.y - MINIMAL_WINDOW_CURSOR_OFFSET_Y - minY
            let availableAbove = visibleFrame.maxY - point.y - MINIMAL_WINDOW_CURSOR_OFFSET_Y
            let preferredY = availableBelow >= availableAbove ? preferredBelowY : preferredAboveY
            y = min(max(preferredY, minY), maxY)
        }

        return NSRect(x: x, y: y, width: width, height: height)
    }

    private var isMinimalWindowMode: Bool {
        viewModel.windowMode == .minimal
    }

    private var isMinimalDictionaryResult: Bool {
        currentPresentation.isDictionary
            && currentState == .done
            && !currentDestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && currentDestText != "正在翻译..."
    }

    // MARK: - Private Helpers

    private func updateMouseEventPolicy() {
        // 极简模式只接收滚轮，让内容可滚动；点击和拖拽继续穿透到下面的网页。
        window.ignoresMouseEvents = false
        rootView.allowsScrollOnlyMouseInteraction = isMinimalWindowMode
        if isMinimalWindowMode {
            window.isMovableByWindowBackground = false
        } else {
            window.isMovableByWindowBackground = !isSourceResizeInteractionActive
        }
    }

    private func wireViewModel() {
        viewModel.onPin = { [weak self] in self?.handlePin() }
        viewModel.onCopySource = { [weak self] in self?.handleCopySource() }
        viewModel.onCopyDest = { [weak self] in self?.handleCopyDest() }
        viewModel.onSpeakSource = { [weak self] in self?.handleSpeakSource() }
        viewModel.onToggleBackend = { [weak self] in self?.handleBackendToggle() }
        viewModel.onScreenshotTranslation = { [weak self] in self?.handleScreenshotTranslation() }
        viewModel.onHide = { [weak self] in self?.handleHide() }
        viewModel.onRefresh = { [weak self] in self?.handleRefresh() }
        viewModel.onSwapLanguages = { [weak self] in self?.handleSwapLanguages() }
        viewModel.onSourceLineCountChanged = { [weak self] lineCount in
            self?.handleSourceLineCountChange(lineCount)
        }
        viewModel.onSourceResizeEnded = { [weak self] in
            self?.handleSourceResizeEnd()
        }
        viewModel.onSourceResizeInteractionChanged = { [weak self] active in
            self?.setSourceResizeInteractionActive(active)
        }
        viewModel.onLanguageChanged = { [weak self] src, dest in
            self?.handleLangChange(srcName: src, destName: dest)
        }
    }

    private func installKeyMonitorsIfNeeded() {
        guard localKeyMonitor == nil, globalKeyMonitor == nil else { return }
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

    private func removeKeyMonitors() {
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
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
        guard !isPinned, !isMinimalWindowMode else { return }
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
        guard currentDestText != text || viewModel.destText != text else { return }
        currentDestText = text
        viewModel.destText = text
    }

    private func setTranslationState(_ state: TranslationState) {
        guard currentState != state || viewModel.state != state else { return }
        currentState = state
        viewModel.state = state
    }
}
