import AppKit
import Quartz

// MARK: - Borderless Window

final class BorderlessWindow: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
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

        let glows: [(NSRect, NSColor)] = [
            (NSRect(x: b.minX - 18, y: b.maxY - 126, width: 190, height: 190), GLOW_WARM),
            (NSRect(x: b.maxX - 204, y: b.minY - 26, width: 230, height: 230), GLOW_COOL),
            (NSRect(x: b.maxX - 152, y: b.maxY - 178, width: 176, height: 176), GLOW_MINT),
        ]
        for (rect, color) in glows {
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }

        NSGraphicsContext.restoreGraphicsState()

        PANEL_BORDER.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - Floating Window Delegate Protocol

protocol FloatingWindowDelegate: AnyObject {
    func languageChanged(srcName: String, destName: String)
    func swapLanguages()
    func toggleTranslator()
    func retranslateCurrent()
    func copySource()
    func copyDest()
    func hideWindow()
}

// MARK: - Floating Window Controller

final class FloatingWindow: NSObject {

    weak var delegate: FloatingWindowDelegate?

    let window: BorderlessWindow
    private let vibrancyView: NSVisualEffectView
    private let rootView: NSView
    private let backgroundView: PanelBackgroundView

    private(set) var currentSourceText = ""
    private(set) var currentDestText = ""
    private var backend: String = "google"
    private var isPinned = false
    private var savedOrigin: NSPoint?
    private var suppressAutoPin = false

    // Stream state
    private var streamTimer: Timer?
    private var streamBuffer = ""
    private var streamPos = 0
    private var streamFinal: String?

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
    private let srcLabel: NSTextField
    private let srcAudioBtn: NSButton
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
    private let destLabel: NSTextField
    private let destCopyBtn: NSButton
    private let destRefreshBtn: NSButton

    // MARK: - Init

    override init() {
        window = BorderlessWindow()

        vibrancyView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT))
        vibrancyView.blendingMode = .behindWindow
        vibrancyView.material = .menu
        vibrancyView.state = .active
        vibrancyView.wantsLayer = true
        window.contentView = vibrancyView

        rootView = NSView(frame: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT))
        vibrancyView.addSubview(rootView)

        backgroundView = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: WINDOW_MIN_HEIGHT))
        rootView.addSubview(backgroundView)

        // Toolbar
        pinBtn = createToolbarIconButton(symbolName: "pin.fill", fallback: "\u{1F4CC}")
        quickSourceCopyBtn = createToolbarIconButton(symbolName: "scissors", fallback: "\u{2702}")
        quickDestCopyBtn = createToolbarIconButton(symbolName: "doc.on.doc", fallback: "\u{29C9}")
        hideBtn = createToolbarIconButton(symbolName: "xmark", fallback: "\u{2715}")

        headerTitleLabel = createLabel(fontSize: 16, color: TEXT_PRIMARY, bold: true, wraps: false)
        headerTitleLabel.stringValue = "划词翻译"

        headerSubtitleLabel = createLabel(fontSize: 11, color: TEXT_SECONDARY, wraps: false)
        headerSubtitleLabel.stringValue = "自动检测 → 中文简体 · Google"

        backendBtn = NSButton()
        backendBtn.isBordered = false
        backendBtn.bezelStyle = .regularSquare
        backendBtn.title = "LLM"
        backendBtn.font = NSFont.boldSystemFont(ofSize: 11)
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

        srcTitleLabel = createLabel(fontSize: 9, color: TEXT_SECONDARY, bold: true, wraps: false)
        srcTitleLabel.stringValue = "原文"

        srcMetaChip = createPillLabel(fontSize: 9, color: TEXT_SECONDARY, background: SURFACE_BG_SOFT)

        srcScroll = NSScrollView()
        srcScroll.hasVerticalScroller = true
        srcScroll.autohidesScrollers = true
        srcScroll.borderType = .noBorder
        srcScroll.drawsBackground = false

        srcLabel = createLabel(fontSize: BODY_FONT_SIZE, color: TEXT_PRIMARY, selectable: true, wraps: true)
        srcScroll.documentView = srcLabel

        srcAudioBtn = createIconButton(symbolName: "speaker.wave.2", fallback: "\u{1F50A}",
                                       pointSize: 10, tint: TEXT_MUTED, size: 20)
        srcAudioBtn.isEnabled = false
        srcAudioBtn.alphaValue = 0.45

        srcCopyBtn = createIconButton(symbolName: "doc.on.doc", fallback: "\u{29C9}",
                                      pointSize: 10, tint: TEXT_PRIMARY, size: 20)

        srcLangChip = createPillLabel(fontSize: 9, color: BLUE_ACCENT, background: CHIP_BG)

        for v in [srcTitleLabel, srcMetaChip, srcScroll, srcAudioBtn, srcCopyBtn, srcLangChip] {
            srcCard.addSubview(v)
        }
        rootView.addSubview(srcCard)

        // Language bar
        langBar = NSView()
        styleSurface(langBar, background: LANG_BAR_BG, radius: CARD_RADIUS,
                     border: CARD_BORDER, shadow: true)

        srcLangPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 80, height: 26), pullsDown: false)

        swapBtn = createIconButton(symbolName: "arrow.left.arrow.right", fallback: "\u{21C4}",
                                   pointSize: 12, tint: TEXT_PRIMARY, size: 24)

        destLangPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 80, height: 26), pullsDown: false)

        for v in [srcLangPop, swapBtn, destLangPop] { langBar.addSubview(v) }
        rootView.addSubview(langBar)

        // Dest card
        destCard = NSView()
        styleSurface(destCard, background: DEST_CARD_BG, radius: CARD_RADIUS,
                     border: CARD_BORDER, shadow: true)

        backendBadge = NSView()
        styleSurface(backendBadge, background: BLUE_ACCENT, radius: 12)

        backendBadgeLabel = createLabel(fontSize: 10, color: .white, bold: true, wraps: false)
        backendBadgeLabel.alignment = .center
        backendBadge.addSubview(backendBadgeLabel)

        backendNameLabel = createLabel(fontSize: 12, color: TEXT_PRIMARY, bold: true, wraps: false)

        destStateChip = createPillLabel(fontSize: 10, color: TEXT_SECONDARY, background: SURFACE_BG_SOFT)

        backendToggleBtn = createIconButton(symbolName: "chevron.down", fallback: "\u{2304}",
                                            pointSize: 9, tint: TEXT_SECONDARY, size: 24)

        destScroll = NSScrollView()
        destScroll.hasVerticalScroller = true
        destScroll.autohidesScrollers = true
        destScroll.borderType = .noBorder
        destScroll.drawsBackground = false

        destLabel = createLabel(fontSize: BODY_FONT_SIZE, color: TEXT_PRIMARY, selectable: true, wraps: true)
        destScroll.documentView = destLabel

        destCopyBtn = createIconButton(symbolName: "doc.on.doc", fallback: "\u{29C9}",
                                       pointSize: 11, tint: TEXT_PRIMARY, size: 24)
        destRefreshBtn = createIconButton(symbolName: "arrow.clockwise", fallback: "\u{21BB}",
                                          pointSize: 11, tint: TEXT_PRIMARY, size: 24)

        for v in [backendBadge, backendBadgeLabel, backendNameLabel, destStateChip,
                  backendToggleBtn, destScroll, destCopyBtn, destRefreshBtn] {
            destCard.addSubview(v)
        }
        rootView.addSubview(destCard)

        super.init()

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

        refreshPinStyle()
        refreshActionState()
        refreshSourceMeta()
        setTranslationState(.idle)
        setBackendLabel("google")
    }

    deinit {
        stopStream()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public API

    func setBackendLabel(_ backend: String) {
        self.backend = backend
        if backend == "llm" {
            styleSurface(backendBadge, background: TEAL_ACCENT, radius: 12)
            backendBadgeLabel.stringValue = "AI"
            backendNameLabel.stringValue = "大模型翻译"
            backendBtn.contentTintColor = TEAL_ACCENT
            styleSurface(backendBtn,
                         background: blendWithWhite(TEAL_ACCENT, amount: 0.84, alpha: 0.72),
                         radius: BACKEND_BTN_WIDTH / 2,
                         border: blendWithWhite(TEAL_ACCENT, amount: 0.56, alpha: 0.84))
        } else {
            styleSurface(backendBadge, background: BLUE_ACCENT, radius: 12)
            backendBadgeLabel.stringValue = "G"
            backendNameLabel.stringValue = "Google 翻译"
            backendBtn.contentTintColor = TEXT_SECONDARY
            styleSurface(backendBtn, background: TOOLBAR_GHOST_BG,
                         radius: BACKEND_BTN_WIDTH / 2, border: TOOLBAR_BUTTON_BORDER)
        }
        backendNameLabel.textColor = TEXT_PRIMARY
        backendBtn.title = "LLM"
        refreshHeaderStatus()
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
        stopStream()
        let wasVisible = window.isVisible

        currentSourceText = srcText
        currentDestText = destText ?? ""

        srcLabel.stringValue = currentSourceText
        if let dest = destText {
            destLabel.stringValue = dest
            destLabel.textColor = TEXT_PRIMARY
            setTranslationState(.done)
        } else {
            destLabel.stringValue = "正在翻译..."
            destLabel.textColor = TEXT_MUTED
            setTranslationState(.loading)
        }

        refreshSourceMeta()
        refreshLanguageUI()
        refreshActionState()
        layoutWindow()

        let newHeight = rootView.frame.height
        suppressAutoPin = true
        defer { suppressAutoPin = false }

        if wasVisible {
            let frame = window.frame
            let top = frame.maxY
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().setFrame(
                    NSRect(x: frame.origin.x, y: top - newHeight, width: WINDOW_WIDTH, height: newHeight),
                    display: true)
            }
        } else {
            let (x, y): (CGFloat, CGFloat)
            if let saved = savedOrigin {
                x = saved.x; y = saved.y
            } else {
                let screen = NSScreen.main?.frame ?? .zero
                x = (screen.width - WINDOW_WIDTH) / 2 + screen.origin.x
                y = (screen.height - newHeight) / 2 + screen.origin.y
            }

            window.setFrame(NSRect(x: x, y: y, width: WINDOW_WIDTH, height: newHeight), display: true)
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                window.animator().alphaValue = 1
            }
        }
    }

    // MARK: - Stream

    func streamFeed(_ text: String) {
        if streamTimer == nil { startStream() }
        streamBuffer = text
    }

    func streamFinish(_ finalText: String) {
        streamFinal = finalText
        streamBuffer = finalText
        if streamPos >= finalText.count { finishStream() }
    }

    private func startStream() {
        stopStream()
        streamBuffer = ""
        streamPos = 0
        streamFinal = nil
        destLabel.stringValue = ""
        destLabel.textColor = TEXT_PRIMARY
        setTranslationState(.loading)
        streamTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            self?.streamTick()
        }
    }

    private func streamTick() {
        let charsPerTick = 2
        streamPos = min(streamPos + charsPerTick, streamBuffer.count)
        let displayed = String(streamBuffer.prefix(streamPos))

        if displayed == currentDestText {
            if streamFinal != nil, streamPos >= streamBuffer.count { finishStream() }
            return
        }

        currentDestText = displayed
        destLabel.stringValue = displayed
        refreshActionState()

        let cardInnerWidth = WINDOW_WIDTH - (OUTER_PADDING * 2) - (CARD_INSET_X * 2)
        let fullTextHeight = measureTextHeight(displayed, width: cardInnerWidth,
                                               fontSize: BODY_FONT_SIZE, minimum: 40)
        destLabel.frame = NSRect(x: 0, y: 0, width: cardInnerWidth, height: fullTextHeight)

        let needed = min(DEST_MAX_CARD_HEIGHT, max(132, fullTextHeight + 82))
        if Int(needed) > Int(destCard.frame.height) {
            layoutWindow()
            let newHeight = rootView.frame.height
            let frame = window.frame
            suppressAutoPin = true
            window.setFrame(NSRect(x: frame.origin.x, y: frame.maxY - newHeight,
                                   width: WINDOW_WIDTH, height: newHeight), display: true)
            suppressAutoPin = false
        }

        if streamFinal != nil, streamPos >= streamBuffer.count { finishStream() }
    }

    private func stopStream() {
        streamTimer?.invalidate()
        streamTimer = nil
        streamFinal = nil
    }

    private func finishStream() {
        stopStream()
        currentDestText = streamBuffer
        destLabel.stringValue = streamBuffer
        setTranslationState(.done)
        refreshActionState()
        layoutWindow()

        guard window.isVisible else { return }
        let newHeight = rootView.frame.height
        let frame = window.frame
        suppressAutoPin = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().setFrame(
                NSRect(x: frame.origin.x, y: frame.maxY - newHeight, width: WINDOW_WIDTH, height: newHeight),
                display: true)
        }
        suppressAutoPin = false
    }

    func hide() {
        stopStream()
        if !isPinned { savedOrigin = window.frame.origin }

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

    // MARK: - Layout

    private func layoutWindow() {
        let contentWidth = WINDOW_WIDTH - (OUTER_PADDING * 2)
        let cardInnerWidth = contentWidth - (CARD_INSET_X * 2)

        let srcTextHeight = measureTextHeight(currentSourceText.isEmpty ? " " : currentSourceText,
                                              width: cardInnerWidth, fontSize: BODY_FONT_SIZE, minimum: 48)
        let destDisplayText = currentDestText.isEmpty ? "正在翻译..." : currentDestText
        let destTextHeight = measureTextHeight(destDisplayText, width: cardInnerWidth,
                                               fontSize: BODY_FONT_SIZE, minimum: 40)

        let srcVisible = min(srcTextHeight, MAX_CARD_TEXT_HEIGHT)
        let destVisible = min(destTextHeight, MAX_CARD_TEXT_HEIGHT)

        var srcCardHeight = min(SRC_MAX_CARD_HEIGHT, max(106, srcVisible + 50))
        var destCardHeight = min(DEST_MAX_CARD_HEIGHT, max(132, destVisible + 82))

        let overhead = OUTER_PADDING + HEADER_HEIGHT + SECTION_GAP + SECTION_GAP
            + LANG_BAR_HEIGHT + SECTION_GAP + OUTER_PADDING
        let totalHeight = min(MAX_WINDOW_HEIGHT,
                              max(WINDOW_MIN_HEIGHT,
                                  OUTER_PADDING + HEADER_HEIGHT + SECTION_GAP + srcCardHeight
                                  + SECTION_GAP + LANG_BAR_HEIGHT + SECTION_GAP + destCardHeight
                                  + OUTER_PADDING))

        let available = totalHeight - overhead
        if srcCardHeight + destCardHeight > available {
            srcCardHeight = max(100, floor(available * 7 / 15))
            destCardHeight = max(124, available - srcCardHeight)
        }

        rootView.frame = NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: totalHeight)
        vibrancyView.frame = NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: totalHeight)
        backgroundView.frame = NSRect(x: 0, y: 0, width: WINDOW_WIDTH, height: totalHeight)
        backgroundView.needsDisplay = true

        // Toolbar
        let headerY = totalHeight - OUTER_PADDING - HEADER_HEIGHT
        let toolbarY = headerY + (HEADER_HEIGHT - TOOLBAR_BUTTON_SIZE) / 2

        pinBtn.frame = NSRect(x: OUTER_PADDING, y: toolbarY,
                              width: TOOLBAR_BUTTON_SIZE, height: TOOLBAR_BUTTON_SIZE)

        let titleX = OUTER_PADDING + TOOLBAR_BUTTON_SIZE + 10
        let titleWidth = max(120, contentWidth - 220)
        headerTitleLabel.frame = NSRect(x: titleX, y: headerY + 18, width: titleWidth, height: 16)
        headerSubtitleLabel.frame = NSRect(x: titleX, y: headerY + 2, width: titleWidth + 24, height: 14)

        var rightX = WINDOW_WIDTH - OUTER_PADDING
        for button in [hideBtn, backendBtn, quickDestCopyBtn, quickSourceCopyBtn] {
            let btnW = (button === backendBtn) ? BACKEND_BTN_WIDTH : TOOLBAR_BUTTON_SIZE
            button.frame = NSRect(x: rightX - btnW, y: toolbarY, width: btnW, height: TOOLBAR_BUTTON_SIZE)
            rightX -= btnW + 6
        }

        // Source card
        let srcY = headerY - SECTION_GAP - srcCardHeight
        srcCard.frame = NSRect(x: OUTER_PADDING, y: srcY, width: contentWidth, height: srcCardHeight)
        srcScroll.frame = NSRect(x: CARD_INSET_X, y: 32, width: cardInnerWidth,
                                 height: srcCardHeight - 58)
        srcLabel.frame = NSRect(x: 0, y: 0, width: cardInnerWidth, height: srcTextHeight)
        srcTitleLabel.frame = NSRect(x: CARD_INSET_X, y: srcCardHeight - 22, width: 40, height: 12)
        srcAudioBtn.frame = NSRect(x: CARD_INSET_X, y: 8, width: 20, height: 20)
        srcCopyBtn.frame = NSRect(x: CARD_INSET_X + 26, y: 8, width: 20, height: 20)

        let mt = srcMetaChip.stringValue.isEmpty ? "等待选中" : srcMetaChip.stringValue
        let mw = min(max(measureTextWidth(mt, fontSize: 9, bold: true) + 16, 64), 100)
        srcMetaChip.frame = NSRect(x: contentWidth - CARD_INSET_X - mw, y: srcCardHeight - 24,
                                   width: mw, height: 18)

        let ct = srcLangChip.stringValue.isEmpty ? "自动检测" : srcLangChip.stringValue
        let cw = min(max(measureTextWidth(ct, fontSize: 9, bold: true) + 16, 64), 120)
        srcLangChip.frame = NSRect(x: contentWidth - CARD_INSET_X - cw, y: 10,
                                   width: cw, height: 18)

        // Language bar
        let langY = srcY - SECTION_GAP - LANG_BAR_HEIGHT
        langBar.frame = NSRect(x: OUTER_PADDING, y: langY, width: contentWidth, height: LANG_BAR_HEIGHT)
        let popupWidth = (contentWidth - 72) / 2
        srcLangPop.frame = NSRect(x: CARD_INSET_X, y: 8, width: popupWidth, height: 24)
        swapBtn.frame = NSRect(x: (contentWidth - 24) / 2, y: 9, width: 24, height: 24)
        destLangPop.frame = NSRect(x: contentWidth - CARD_INSET_X - popupWidth, y: 8,
                                   width: popupWidth, height: 24)

        // Dest card
        let destY = langY - SECTION_GAP - destCardHeight
        destCard.frame = NSRect(x: OUTER_PADDING, y: destY, width: contentWidth, height: destCardHeight)

        let destVisibleH = destCardHeight - 84
        let destTextScrollY: CGFloat = 42
        destScroll.frame = NSRect(x: CARD_INSET_X, y: destTextScrollY,
                                  width: cardInnerWidth, height: destVisibleH)
        destLabel.frame = NSRect(x: 0, y: 0, width: cardInnerWidth, height: destTextHeight)

        let providerY = destTextScrollY + destVisibleH + 8
        let toggleX = contentWidth - CARD_INSET_X - 24
        let st = destStateChip.stringValue.isEmpty ? "待翻译" : destStateChip.stringValue
        let sw = min(max(measureTextWidth(st, fontSize: 10, bold: true) + 18, 60), 78)
        let stateX = toggleX - 8 - sw

        backendBadge.frame = NSRect(x: CARD_INSET_X, y: providerY, width: 24, height: 24)
        backendBadgeLabel.frame = NSRect(x: 0, y: 4, width: 24, height: 14)
        backendNameLabel.frame = NSRect(x: CARD_INSET_X + 32, y: providerY + 4,
                                        width: stateX - 58, height: 16)
        destStateChip.frame = NSRect(x: stateX, y: providerY + 2, width: sw, height: 20)
        backendToggleBtn.frame = NSRect(x: toggleX, y: providerY, width: 24, height: 24)
        destCopyBtn.frame = NSRect(x: CARD_INSET_X, y: 12, width: 24, height: 24)
        destRefreshBtn.frame = NSRect(x: CARD_INSET_X + 30, y: 12, width: 24, height: 24)
    }

    // MARK: - Private Helpers

    private func configurePopup(_ popup: NSPopUpButton) {
        popup.isBordered = false
        popup.font = NSFont.boldSystemFont(ofSize: 12)
        popup.contentTintColor = TEXT_PRIMARY
        popup.wantsLayer = true
        popup.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, event.keyCode == 53 else { return event }
            if self.window.isVisible, NSPointInRect(NSEvent.mouseLocation, self.window.frame) {
                self.hide()
                return nil
            }
            return event
        }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
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
        let accent = isPinned ? BLUE_ACCENT : TEXT_SECONDARY
        let bg = isPinned ? TOOLBAR_ACTIVE_BG : TOOLBAR_GHOST_BG
        let bd = isPinned ? TOOLBAR_ACTIVE_BORDER : TOOLBAR_BUTTON_BORDER
        styleSurface(pinBtn, background: bg, radius: TOOLBAR_BUTTON_SIZE / 2, border: bd)
        applySymbol(pinBtn, symbolName: "pin.fill", fallback: "\u{1F4CC}", pointSize: 12, tint: accent)
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
}

// MARK: - Translation State Enum

private enum TranslationState {
    case idle, loading, done
}
