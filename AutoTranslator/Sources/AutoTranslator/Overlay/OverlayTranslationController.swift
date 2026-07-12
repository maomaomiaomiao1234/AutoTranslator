import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 贴图面板

/// 钉在屏幕上的贴图窗口：无边框、不抢焦点、可拖动、跨空间常驻。
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

/// 主题切换时通知 SwiftUI 重新解析自适应 NSColor（同 FloatingWindow 的做法）。
private final class OverlayRootView: NSView {
    var onAppearanceChanged: (() -> Void)?

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }
}

// MARK: - 控制器

@MainActor
protocol OverlayTranslationControllerDelegate: AnyObject {
    /// 用户点击"浮窗查看"：在标准浮窗中展示原文与译文。
    func overlayRequestedOpenInFloatingWindow()
    /// 用户点击"重试"：重新翻译失败的块。
    func overlayRequestedRetry()
    /// 贴图已关闭（Esc/关闭按钮/被新贴图替换）。
    func overlayDidClose()
}

/// 贴图翻译结果窗口的生命周期与交互：钉图、进度状态、复制/保存导出。
@MainActor
final class OverlayTranslationController: NSObject {

    weak var delegate: OverlayTranslationControllerDelegate?

    private let panel = OverlayPanel()
    private let viewModel = OverlayTranslationViewModel()
    private let rootView: OverlayRootView
    private let hostingView: NSHostingView<OverlayTranslationView>

    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    private var baseImage: CGImage?
    private var imagePtSize: CGSize = .zero
    /// 交错淡入：短时间内连续到达的块依次加一点延迟（缓存命中成批到达时仍有层次）。
    private var lastRevealUptime: TimeInterval = 0
    private var burstRevealCount = 0

    override init() {
        rootView = OverlayRootView(frame: .zero)
        rootView.autoresizingMask = [.width, .height]
        hostingView = NSHostingView(rootView: OverlayTranslationView(model: viewModel))
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        super.init()

        panel.contentView = rootView
        rootView.addSubview(hostingView)
        rootView.onAppearanceChanged = { [weak self] in
            self?.viewModel.appearanceVersion += 1
        }

        viewModel.onCopyImage = { [weak self] in self?.copyCompositedImage() }
        viewModel.onSave = { [weak self] in self?.saveCompositedImage() }
        viewModel.onOpenInWindow = { [weak self] in
            self?.delegate?.overlayRequestedOpenInFloatingWindow()
        }
        viewModel.onClose = { [weak self] in self?.close() }
        viewModel.onRetry = { [weak self] in self?.delegate?.overlayRequestedRetry() }
        viewModel.onCopyBlockText = { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    deinit {
        // 监视器随控制器一起消失；panel 由 AppController 持有同生命周期。
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: - 呈现流水线（由 AppController 依阶段调用）

    /// 立即把原始截图钉到框选位置（识别中状态），给用户瞬时反馈。
    func present(baseImage: CGImage, imageScreenRect: NSRect) {
        self.baseImage = baseImage
        imagePtSize = imageScreenRect.size

        let geometry = Self.pinGeometry(
            imageRect: imageScreenRect,
            visibleFrame: Self.visibleFrame(for: imageScreenRect)
        )

        viewModel.image = NSImage(cgImage: baseImage, size: imageScreenRect.size)
        viewModel.imagePtSize = imageScreenRect.size
        viewModel.blocks = []
        viewModel.phase = .recognizing
        viewModel.doneCount = 0
        viewModel.totalCount = 0
        viewModel.langChipText = ""
        viewModel.stripPlacement = geometry.placement
        viewModel.alignsTrailing = geometry.alignsTrailing
        viewModel.stripWidth = geometry.stripWidth

        rootView.frame = NSRect(origin: .zero, size: geometry.windowFrame.size)
        hostingView.frame = rootView.bounds
        panel.setFrame(geometry.windowFrame, display: true)
        panel.orderFrontRegardless()
        installKeyMonitorsIfNeeded()
    }

    func setLanguageChip(_ text: String) {
        viewModel.langChipText = text
    }

    /// OCR 完成、翻译开始：铺骨架色块。
    func showSkeleton(_ skeletons: [(ptRect: CGRect, style: PatchStyle)]) {
        viewModel.blocks = skeletons.enumerated().map { index, skeleton in
            OverlayTranslationViewModel.BlockItem(
                id: index,
                ptRect: skeleton.ptRect,
                style: skeleton.style
            )
        }
        viewModel.totalCount = skeletons.count
        viewModel.doneCount = 0
        viewModel.phase = .translating
    }

    /// 单块译文到达：交错淡入。
    func revealBlock(_ index: Int, layout: BlockLayout) {
        guard viewModel.blocks.indices.contains(index) else { return }
        let delay = nextRevealDelay()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85).delay(delay)) {
            viewModel.blocks[index].layout = layout
            viewModel.blocks[index].state = .translated
        }
        viewModel.doneCount += 1
    }

    func markBlockFailed(_ index: Int) {
        guard viewModel.blocks.indices.contains(index) else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            viewModel.blocks[index].state = .failed
        }
        viewModel.doneCount += 1
    }

    /// 把失败块重置回骨架态（重试开始时调用）。返回这些块的下标。
    func resetFailedBlocksToPending() -> [Int] {
        var indices: [Int] = []
        for index in viewModel.blocks.indices where viewModel.blocks[index].state == .failed {
            viewModel.blocks[index].state = .pending
            indices.append(index)
        }
        guard !indices.isEmpty else { return [] }
        viewModel.doneCount = viewModel.blocks.count - indices.count
        viewModel.totalCount = viewModel.blocks.count
        viewModel.phase = .translating
        return indices
    }

    func finishTranslating() {
        viewModel.phase = .done
    }

    func finishNoText() {
        viewModel.phase = .noText
    }

    func finishFailed(_ message: String) {
        viewModel.phase = .failed(message)
    }

    func close() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        removeKeyMonitors()
        baseImage = nil
        viewModel.image = nil
        viewModel.blocks = []
        delegate?.overlayDidClose()
    }

    // MARK: - 导出

    private func compositedImage() -> NSImage? {
        guard let baseImage else { return nil }
        let layouts = viewModel.blocks.compactMap { block -> BlockLayout? in
            guard block.state == .translated else { return nil }
            return block.layout
        }
        return OverlayComposer.renderFlat(
            baseImage: baseImage,
            imagePtSize: imagePtSize,
            layouts: layouts
        )
    }

    private func copyCompositedImage() {
        guard let image = compositedImage() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var wrotePNG = false
        if let png = OverlayComposer.pngData(from: image) {
            pasteboard.declareTypes([.png, .tiff], owner: nil)
            wrotePNG = pasteboard.setData(png, forType: .png)
            if let tiff = image.tiffRepresentation {
                pasteboard.setData(tiff, forType: .tiff)
            }
        }
        if !wrotePNG {
            pasteboard.writeObjects([image])
        }
        NotificationManager.shared.post(title: "已复制贴图", body: "翻译后的截图已复制到剪贴板")
    }

    private func saveCompositedImage() {
        guard let image = compositedImage(),
              let png = OverlayComposer.pngData(from: image) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "贴图翻译-\(formatter.string(from: Date())).png"
        savePanel.canCreateDirectories = true

        NSApp.activate(ignoringOtherApps: true)
        guard savePanel.runModal() == .OK, let url = savePanel.url else { return }
        do {
            try png.write(to: url, options: [.atomic])
        } catch {
            AppLog.error("保存贴图失败: \(error.localizedDescription)")
            NotificationManager.shared.post(title: "保存失败", body: error.localizedDescription)
        }
    }

    // MARK: - Esc 关闭（与 FloatingWindow 同约定：鼠标在窗口内时生效）

    private func installKeyMonitorsIfNeeded() {
        guard localKeyMonitor == nil, globalKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            if self.panel.isVisible, NSPointInRect(NSEvent.mouseLocation, self.panel.frame) {
                self.close()
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return }
            if self.panel.isVisible, NSPointInRect(NSEvent.mouseLocation, self.panel.frame) {
                self.close()
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

    private func nextRevealDelay() -> TimeInterval {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastRevealUptime < 0.08 {
            burstRevealCount += 1
        } else {
            burstRevealCount = 0
        }
        lastRevealUptime = now
        return min(0.25, Double(burstRevealCount) * 0.045)
    }

    // MARK: - 钉图几何（纯函数，便于推理与测试）

    struct PinGeometry: Equatable {
        let windowFrame: NSRect
        let placement: OverlayTranslationViewModel.StripPlacement
        let alignsTrailing: Bool
        let stripWidth: CGFloat

        static func == (lhs: PinGeometry, rhs: PinGeometry) -> Bool {
            lhs.windowFrame == rhs.windowFrame
                && lhs.placement == rhs.placement
                && lhs.alignsTrailing == rhs.alignsTrailing
                && lhs.stripWidth == rhs.stripWidth
        }
    }

    /// 计算贴图窗口 frame：图像区严格钉在捕获位置，控制条优先放图像下方、
    /// 其次上方、都放不下则叠在图像内右下角。
    static func pinGeometry(imageRect: NSRect, visibleFrame: NSRect) -> PinGeometry {
        let stripWidth = min(max(imageRect.width, 240), 420)
        let contentWidth = max(imageRect.width, stripWidth)
        let stripZoneHeight = OVERLAY_STRIP_GAP + OVERLAY_STRIP_HEIGHT

        var alignsTrailing = true
        var x = imageRect.maxX - contentWidth
        if x < visibleFrame.minX {
            alignsTrailing = false
            x = imageRect.minX
        }

        if imageRect.minY - stripZoneHeight >= visibleFrame.minY {
            return PinGeometry(
                windowFrame: NSRect(
                    x: x,
                    y: imageRect.minY - stripZoneHeight,
                    width: contentWidth,
                    height: imageRect.height + stripZoneHeight
                ),
                placement: .below,
                alignsTrailing: alignsTrailing,
                stripWidth: stripWidth
            )
        }

        if imageRect.maxY + stripZoneHeight <= visibleFrame.maxY {
            return PinGeometry(
                windowFrame: NSRect(
                    x: x,
                    y: imageRect.minY,
                    width: contentWidth,
                    height: imageRect.height + stripZoneHeight
                ),
                placement: .above,
                alignsTrailing: alignsTrailing,
                stripWidth: stripWidth
            )
        }

        return PinGeometry(
            windowFrame: imageRect,
            placement: .inside,
            alignsTrailing: alignsTrailing,
            // 极小贴图（宽不足容纳完整控制条）时也不产生非法负宽度。
            stripWidth: max(120, min(stripWidth, imageRect.width - AppUI.Space.s * 2))
        )
    }

    private static func visibleFrame(for rect: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) }
            ?? NSScreen.main
        return screen?.visibleFrame ?? rect.insetBy(dx: -100, dy: -100)
    }
}
