import Cocoa
import Combine
import CoreGraphics
import ApplicationServices
import ImageIO

private actor SelectionFocusLookupGate {
    func perform(_ operation: @Sendable () -> Bool) -> Bool {
        operation()
    }
}

final class AppController: NSObject {
    private enum TranslationMode {
        case translation
        case dictionary(word: String)

        var floatingPresentation: FloatingPresentation {
            switch self {
            case .translation:
                return .translation
            case .dictionary:
                return .dictionary
            }
        }

        var dictionaryWord: String? {
            switch self {
            case .translation:
                return nil
            case .dictionary(let word):
                return word
            }
        }
    }

    private struct TranslationRequest {
        let version: Int
        let text: String
        let mode: TranslationMode
        let backend: String
        let sourceLanguage: String
        let targetLanguage: String
        let cacheKey: String
        let translator: TranslatorProtocol?
    }

    // MARK: - State

    private var srcLang = Languages.defaultSourceCode
    private var destLang = Languages.defaultTargetCode
    private var lastText = ""
    private var lastTranslationMode: TranslationMode = .translation

    private var translatorBackend: String
    private var translator: TranslatorProtocol!

    private let window: FloatingWindow
    private let textSelector = TextSelector()
    private let mouseMonitor = MouseMonitor()
    private let selectionFocusLookupGate = SelectionFocusLookupGate()
    private let ocrService = OCRService()
    private let speechService = SpeechService()

    private var translateVersion = 0
    private var translateTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var screenshotTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var speechStatusResetTask: Task<Void, Never>?
    private var speechGeneration = 0
    private var currentHistoryEntryID: UUID?
    private var historyObservation: AnyCancellable?

    // MARK: 贴图翻译状态

    private var overlayWindow: OverlayTranslationController?
    private var overlayTask: Task<Void, Never>?
    private var overlayVersion = 0
    /// 贴图翻译的重试上下文：块、配色与语言在初次流程确定后保持不变。
    private struct OverlayContext {
        let blocks: [TextBlock]
        let styles: [PatchStyle]
        let scale: CGFloat
        let sourceLanguage: String
        let targetLanguage: String
        let backend: String
    }
    private var overlayContext: OverlayContext?

    /// 翻译/词典结果缓存：避免重复划选同一文本时重复请求后端。
    /// key 含后端与源/目标语言，故切换它们天然命中不同条目；模型/BaseURL 变更时由 reloadFromConfig 清空。
    private let translationCache = LRUCache<String, String>(capacity: 200)

    private(set) var isMonitoringPaused = false
    private(set) var currentTheme: Theme = .default
    private(set) var currentFloatingWindowMode: FloatingWindowMode = .standard

    var currentBackend: String { translatorBackend }

    private static let ignoredSelectionBundleIdentifiers: Set<String> = [
        // Finder 同时承载桌面和文件列表。它会把被选中的文件/文件夹名称暴露为
        // AXSelectedText；这不是用户划选的正文。跳过整个鼠标序列也能避免在
        // 拖拽选择文件时触发 TextSelector 的模拟 ⌘C 回退。
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
    ]

    // MARK: - Init

    override init() {
        translatorBackend = ProcessInfo.processInfo.environment["TRANSLATOR_BACKEND"] ?? "llm"
        // 恢复保存的语言偏好（如不合法则使用默认值）
        let savedSrc = ConfigStore.shared.get(.srcLang)
        let savedDest = ConfigStore.shared.get(.destLang)
        if let savedSrc, Languages.nameByCode[savedSrc] != nil {
            srcLang = savedSrc
        }
        if let savedDest, Languages.nameByCode[savedDest] != nil, savedDest != "auto" {
            destLang = savedDest
        }
        currentFloatingWindowMode = FloatingWindowMode.from(rawValue: ConfigStore.shared.get(.floatingWindowMode))
        window = FloatingWindow()

        super.init()

        translator = createTranslator()
        window.delegate = self
        window.setLanguages(Languages.codeByName, source: srcLang, target: destLang)
        window.setBackendLabel(translatorBackend)
        window.setWindowMode(currentFloatingWindowMode)
        mouseMonitor.delegate = self
        mouseMonitor.shouldIgnoreMouseSequenceStartingAt = { [weak self] point in
            self?.shouldIgnoreSelectionSequence(startingAt: point) ?? false
        }
        historyObservation = TranslationHistoryStore.shared.$revision.sink { [weak self] _ in
            guard let self, let id = self.currentHistoryEntryID else { return }
            if let entry = TranslationHistoryStore.shared.entry(id: id) {
                self.window.setHistoryFavorite(entry.isFavorite, available: true)
            } else {
                self.currentHistoryEntryID = nil
                self.window.setHistoryFavorite(false, available: false)
            }
        }

        // 恢复保存的主题（必须在 NSApp 创建之后才有效，此处只是记录；
        // 实际应用由 start() 调用，那时 NSApplication.shared 已就绪）
        currentTheme = Theme.from(rawValue: ConfigStore.shared.get(.theme))
    }

    // MARK: - Start / Stop

    /// 与权限无关的启动准备（应用主题等）；无论辅助功能是否授权都应在启动时执行。
    func prepare() {
        currentTheme.apply()
    }

    /// 启动划词监听。事件 tap 在辅助功能授权前创建会失败，须在授权后调用。
    func start() {
        mouseMonitor.start()
    }

    @MainActor
    func stop() {
        mouseMonitor.stop()
        selectionTask?.cancel()
        translateTask?.cancel()
        screenshotTask?.cancel()
        overlayTask?.cancel()
        speechTask?.cancel()
        speechService.stop()
    }

    // MARK: - Public control surface (供菜单栏/偏好设置调用)

    func pauseMonitoring() {
        guard !isMonitoringPaused else { return }
        isMonitoringPaused = true
        mouseMonitor.stop()
        selectionTask?.cancel()
        NotificationManager.shared.post(title: "AutoTranslator", body: "已暂停划词监听")
    }

    func resumeMonitoring() {
        guard isMonitoringPaused else { return }
        isMonitoringPaused = false
        mouseMonitor.start()
        NotificationManager.shared.post(title: "AutoTranslator", body: "已恢复划词监听")
    }

    func toggleMonitoring() {
        if isMonitoringPaused { resumeMonitoring() } else { pauseMonitoring() }
    }

    @MainActor
    func startScreenshotTranslation() {
        selectionTask?.cancel()
        screenshotTask?.cancel()
        speechTask?.cancel()

        screenshotTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            guard ScreenCaptureService.ensurePermission() else {
                NotificationManager.shared.post(
                    title: "需要屏幕录制权限",
                    body: "请在 系统设置 > 隐私与安全性 > 屏幕与系统音频录制 中允许 AutoTranslator，然后重新点击 OCR。"
                )
                self.window.showError(
                    srcText: "截图翻译需要屏幕录制权限",
                    message: "授权后请重新点击 OCR 按钮",
                    status: "需要授权"
                )
                return
            }

            let shouldResumeMonitoring = !self.isMonitoringPaused
            if shouldResumeMonitoring {
                self.mouseMonitor.stop()
            }
            defer {
                if shouldResumeMonitoring {
                    self.mouseMonitor.start()
                }
            }

            do {
                self.window.hideImmediately()
                let capture = try await ScreenCaptureService.captureInteractively()
                defer { ScreenCaptureService.removeCapturedImage(at: capture.imageURL) }
                self.window.show(srcText: "正在识别截图文字...", destText: nil)
                let recognizedText = try await self.ocrService.recognizeText(
                    inFileAt: capture.imageURL,
                    imageWidth: capture.width,
                    imageHeight: capture.height,
                    sourceLanguage: self.srcLang
                )
                let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else {
                    self.window.showError(
                        srcText: "截图中未识别到文字",
                        message: "请重新框选更清晰的文字区域",
                        status: "未识别"
                    )
                    return
                }

                self.lastText = text
                self.lastTranslationMode = .translation
                self.window.show(srcText: text, destText: nil)
                self.dispatchTranslate(text, mode: .translation)
            } catch ScreenCaptureError.cancelled {
                return
            } catch is CancellationError {
                return
            } catch {
                let errMsg = Self.userFacingErrorMessage(
                    from: error,
                    fallback: "截图翻译失败，请重新框选更清晰的文字区域",
                    maxLength: 80
                )
                self.window.showError(srcText: "截图翻译失败", message: errMsg, status: "截图失败")
                NotificationManager.shared.post(title: "截图翻译失败", body: errMsg)
            }
        }
    }

    // MARK: - 贴图翻译（原位替换文字）

    /// 贴图翻译入口：自绘框选 → 定点截屏 → 原位钉图 → 结构化 OCR →
    /// 分块并发翻译 → 译文色块逐个淡入。与「截图翻译」互不影响。
    @MainActor
    func startOverlayTranslation() {
        selectionTask?.cancel()
        screenshotTask?.cancel()
        overlayTask?.cancel()
        speechTask?.cancel()

        // 旧贴图先关闭（其 delegate 清理只影响旧任务），再开新版本。
        let overlay = ensureOverlayWindow()
        overlay.close()
        overlayContext = nil
        overlayVersion += 1
        let version = overlayVersion

        overlayTask = Task { @MainActor [weak self] in
            guard let self else { return }

            guard ScreenCaptureService.ensurePermission() else {
                NotificationManager.shared.post(
                    title: "需要屏幕录制权限",
                    body: "请在 系统设置 > 隐私与安全性 > 屏幕与系统音频录制 中允许 AutoTranslator，然后重新点击贴图翻译。"
                )
                return
            }

            let shouldResumeMonitoring = !self.isMonitoringPaused
            if shouldResumeMonitoring {
                self.mouseMonitor.stop()
            }
            defer {
                if shouldResumeMonitoring {
                    self.mouseMonitor.start()
                }
            }

            // 浮窗与蒙层不同框：隐藏浮窗避免它挡住/进入取景。
            self.window.hideImmediately()

            guard let rect = await RegionSelectionController.selectRegion() else { return }
            guard self.isCurrentOverlay(version) else { return }
            guard let primaryScreenFrame = NSScreen.screens.first?.frame else { return }

            do {
                let capture = try await ScreenCaptureService.captureRect(
                    rect,
                    primaryScreenFrame: primaryScreenFrame
                )
                defer { ScreenCaptureService.removeCapturedImage(at: capture.imageURL) }

                guard let baseImage = Self.loadCGImage(at: capture.imageURL) else {
                    throw ScreenCaptureError.failed("无法读取截图图像")
                }
                guard self.isCurrentOverlay(version) else { return }

                // 立即钉出原图（识别中），随后阶段逐步补内容。
                overlay.present(baseImage: baseImage, imageScreenRect: rect)

                let structured = try await self.ocrService.recognizeTextLines(
                    inFileAt: capture.imageURL,
                    imageWidth: capture.width,
                    imageHeight: capture.height,
                    sourceLanguage: self.srcLang
                )
                guard self.isCurrentOverlay(version) else { return }

                let blocks = TextBlockGrouper.group(lines: structured.lines)
                guard !blocks.isEmpty else {
                    overlay.finishNoText()
                    return
                }

                let scale = CGFloat(capture.width) / max(rect.width, 1)
                let joinedSource = blocks.map(\.text).joined(separator: "\n")
                let backend = self.translatorBackend
                let sourceLanguage = self.srcLang
                let targetLanguage = Self.effectiveTargetLanguage(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: self.destLang,
                    text: joinedSource
                )
                overlay.setLanguageChip(Self.overlayLanguageChipText(
                    source: sourceLanguage,
                    target: targetLanguage,
                    backend: backend
                ))

                // 逐块取色。只读各块外沿+块内的有界像素区域（非整图），块数通常 <10，
                // 直接在主 actor 上算，避免把 CGImage 送进 detached 任务引发 Sendable 警告。
                let styles = blocks.map { PatchStyleSampler.style(for: $0.pxRect, in: baseImage) }
                guard self.isCurrentOverlay(version) else { return }

                let skeletons = zip(blocks, styles).map { block, style in
                    (
                        ptRect: CGRect(
                            x: block.pxRect.minX / scale,
                            y: block.pxRect.minY / scale,
                            width: block.pxRect.width / scale,
                            height: block.pxRect.height / scale
                        ),
                        style: style
                    )
                }
                overlay.showSkeleton(skeletons)

                let context = OverlayContext(
                    blocks: blocks,
                    styles: styles,
                    scale: scale,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    backend: backend
                )
                self.overlayContext = context

                let translated = await self.translateOverlayBlocks(
                    indices: Array(blocks.indices),
                    context: context,
                    version: version,
                    overlay: overlay
                )
                guard self.isCurrentOverlay(version) else { return }
                overlay.finishTranslating()

                if !translated.isEmpty {
                    let translatedJoined = translated
                        .sorted { $0.index < $1.index }
                        .map(\.text)
                        .joined(separator: "\n")
                    TranslationHistoryStore.shared.record(
                        sourceText: joinedSource,
                        translatedText: translatedJoined,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage,
                        backend: backend,
                        kind: .translation
                    )
                }
            } catch ScreenCaptureError.cancelled {
                return
            } catch is CancellationError {
                return
            } catch {
                guard self.isCurrentOverlay(version) else { return }
                let message = Self.userFacingErrorMessage(
                    from: error,
                    fallback: "贴图翻译失败，请重新框选",
                    maxLength: 60
                )
                // 截屏/OCR 阶段的失败没有可重试的块：收起贴图并通知。
                overlay.close()
                NotificationManager.shared.post(title: "贴图翻译失败", body: message)
            }
        }
    }

    /// 有界并发（≤4）逐块翻译；命中缓存的块也走同一 reveal 路径。
    /// 返回成功翻译的 (块下标, 译文)。
    /// 本项目默认 actor 隔离为 MainActor：用 MainActor 继承的 `Task` 值维持有界并发，
    /// 翻译器留在主 actor（其耗时在 async 网络 I/O，不阻塞主线程），避免把非 Sendable
    /// 的 translator 送进 `@Sendable` 任务组闭包。
    @MainActor
    private func translateOverlayBlocks(indices: [Int],
                                        context: OverlayContext,
                                        version: Int,
                                        overlay: OverlayTranslationController) async -> [(index: Int, text: String)] {
        guard let translator = translator(
            sourceLanguage: context.sourceLanguage,
            targetLanguage: context.targetLanguage
        ) else { return [] }

        var translated: [(index: Int, text: String)] = []
        let maxConcurrent = 4

        // 按下标切成每批 ≤4，批内并发、批间串行；块数通常 <10，足够。
        for batchStart in stride(from: 0, to: indices.count, by: maxConcurrent) {
            guard isCurrentOverlay(version) else { break }
            let batch = Array(indices[batchStart..<min(batchStart + maxConcurrent, indices.count)])

            var tasks: [(index: Int, task: Task<String?, Never>)] = []
            for index in batch {
                let text = context.blocks[index].text
                let cacheKey = Self.translationCacheKey(
                    backend: context.backend,
                    src: context.sourceLanguage,
                    dest: context.targetLanguage,
                    mode: .translation,
                    text: text
                )
                if let cached = translationCache.value(forKey: cacheKey) {
                    tasks.append((index, Task { cached as String? }))
                } else {
                    tasks.append((index, Task { try? await translator.translate(text) }))
                }
            }

            for (index, task) in tasks {
                let result = await task.value
                guard isCurrentOverlay(version) else { break }
                let block = context.blocks[index]
                if let result = result?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !result.isEmpty {
                    let cacheKey = Self.translationCacheKey(
                        backend: context.backend,
                        src: context.sourceLanguage,
                        dest: context.targetLanguage,
                        mode: .translation,
                        text: block.text
                    )
                    translationCache.setValue(result, forKey: cacheKey)
                    let layout = OverlayComposer.layout(
                        blockIndex: index,
                        block: block,
                        translatedText: result,
                        style: context.styles[index],
                        scale: context.scale
                    )
                    overlay.revealBlock(index, layout: layout)
                    translated.append((index, result))
                } else {
                    overlay.markBlockFailed(index)
                }
            }
        }
        return translated
    }

    @MainActor
    private func ensureOverlayWindow() -> OverlayTranslationController {
        if let overlayWindow {
            return overlayWindow
        }
        let controller = OverlayTranslationController()
        controller.delegate = self
        overlayWindow = controller
        return controller
    }

    private func isCurrentOverlay(_ version: Int) -> Bool {
        version == overlayVersion
    }

    private static func overlayLanguageChipText(source: String,
                                                target: String,
                                                backend: String) -> String {
        "\(Languages.name(for: source)) → \(Languages.name(for: target)) · \(TranslationBackend.shortName(backend))"
    }

    private static func loadCGImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// 来自「翻译输入」入口：对手动输入/编辑的文本发起翻译。
    /// 复用划词的同一套流水线（单词→词典、整句→翻译，含缓存/流式/历史/朗读/错误处理），
    /// 仅把"取到文本"的来源从划词换成手动输入。
    func translateText(_ rawText: String) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        selectionTask?.cancel()
        lastText = text
        let mode = Self.translationMode(for: text)
        lastTranslationMode = mode
        window.show(srcText: text, destText: nil, presentation: mode.floatingPresentation)
        dispatchTranslate(text, mode: mode)
    }

    /// 来自菜单「翻译输入…」：弹出空白浮窗并聚焦原文框，供用户直接输入翻译。
    func presentManualInput() {
        window.presentForManualInput()
    }

    /// 切换到指定后端；若与当前一致则无操作。
    func setBackend(_ backend: String) {
        guard TranslationBackend.isValid(backend) else { return }
        guard backend != translatorBackend else { return }
        translateTask?.cancel()
        speechTask?.cancel()
        translatorBackend = backend
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        let label = TranslationBackend.displayName(translatorBackend)
        NotificationManager.shared.post(title: "翻译后端已切换", body: "当前使用：\(label)")
        retranslateLast()
    }

    /// 偏好设置保存后调用：重新读取配置并重建翻译器。
    func reloadFromConfig() {
        ConfigStore.shared.reload()
        ConfigStore.shared.applyToEnvironment()
        let newBackend = ConfigStore.shared.get(.backend) ?? translatorBackend
        let newFloatingWindowMode = FloatingWindowMode.from(rawValue: ConfigStore.shared.get(.floatingWindowMode))
        translateTask?.cancel()
        speechTask?.cancel()
        translationCache.removeAll()
        translatorBackend = newBackend
        currentFloatingWindowMode = newFloatingWindowMode
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        window.setWindowMode(currentFloatingWindowMode)
        retranslateLast()
    }

    /// 来自偏好设置：设定源/目标语言代码并刷新 UI、翻译器。
    func setLanguages(source: String, target: String) {
        let validSource = Languages.nameByCode[source] != nil ? source : Languages.defaultSourceCode
        let validTarget = (target != "auto" && Languages.nameByCode[target] != nil) ? target : Languages.defaultTargetCode
        guard validSource != srcLang || validTarget != destLang else { return }
        srcLang = validSource
        destLang = validTarget
        window.setLanguages(Languages.codeByName, source: srcLang, target: destLang)
        translateTask?.cancel()
        speechTask?.cancel()
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        ConfigStore.shared.update([.srcLang: srcLang, .destLang: destLang])
        retranslateLast()
    }

    var currentSourceLang: String { srcLang }
    var currentDestLang: String { destLang }

    /// 设置主题外观（浅色/深色/跟随系统）。立即应用并持久化。
    func setTheme(_ theme: Theme) {
        guard theme != currentTheme else { return }
        currentTheme = theme
        theme.apply()
        ConfigStore.shared.update([.theme: theme.rawValue])
    }

    func setFloatingWindowMode(_ mode: FloatingWindowMode) {
        guard mode != currentFloatingWindowMode else { return }
        currentFloatingWindowMode = mode
        window.setWindowMode(mode)
        ConfigStore.shared.update([.floatingWindowMode: mode.rawValue])
    }

    // MARK: - Translator management

    private func createTranslator(source: String? = nil, target: String? = nil) -> TranslatorProtocol {
        let sourceLanguage = source ?? srcLang
        let targetLanguage = target ?? destLang

        switch translatorBackend {
        case TranslationBackend.llm:
            do {
                AppLog.debug("使用大模型翻译 (LLM)")
                return try LLMTranslator(source: sourceLanguage, target: targetLanguage)
            } catch {
                // 不再静默把文本改发到用户没有选择的云服务（旧行为：回退谷歌）。
                // macOS 15+ 回退到本机系统翻译并通知；更早系统保持 llm 后端标签，
                // 由占位翻译器在使用时给出配置引导错误。
                if #available(macOS 15.0, *) {
                    AppLog.error("大模型未配置 API Key，已回退到系统翻译（本机）: \(error)")
                    NotificationManager.shared.post(
                        title: "大模型不可用，已改用系统翻译",
                        body: "系统翻译在本机完成，不会发送文本到第三方。可在偏好设置中配置 API Key 后切回大模型。"
                    )
                    translatorBackend = TranslationBackend.apple
                    window.setBackendLabel(TranslationBackend.apple)
                    return AppleTranslator(source: sourceLanguage, target: targetLanguage)
                }
                AppLog.error("大模型未配置 API Key: \(error)")
                return UnconfiguredTranslator(
                    source: sourceLanguage,
                    target: targetLanguage,
                    message: "未配置大模型 API Key。请在偏好设置中填写，或切换其他翻译后端。"
                )
            }
        case TranslationBackend.apple:
            if #available(macOS 15.0, *) {
                AppLog.debug("使用系统翻译 (Apple Translation)")
                return AppleTranslator(source: sourceLanguage, target: targetLanguage)
            }
            AppLog.error("系统翻译需要 macOS 15 及以上")
            return UnconfiguredTranslator(
                source: sourceLanguage,
                target: targetLanguage,
                message: "系统翻译需要 macOS 15 及以上。请在偏好设置中选择其他后端。"
            )
        default:
            AppLog.debug("使用谷歌翻译 (Google)")
            return GoogleTranslator(source: sourceLanguage, target: targetLanguage)
        }
    }

    private func switchTranslatorBackend() {
        translateTask?.cancel()
        speechTask?.cancel()
        translatorBackend = Self.nextBackend(after: translatorBackend)
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        AppLog.debug("翻译后端切换为: \(translatorBackend)")
        retranslateLast()
    }

    /// 浮窗 chevron 循环切换后端：llm → google → apple →（回到 llm）。
    /// 低于 macOS 15 时跳过 apple。
    private static func nextBackend(after current: String) -> String {
        var order = ["llm", "google", "apple"]
        if !TranslationBackend.isAppleAvailable {
            order.removeAll { $0 == "apple" }
        }
        guard let index = order.firstIndex(of: current) else { return order.first ?? "google" }
        return order[(index + 1) % order.count]
    }

    private static func userFacingErrorMessage(from error: Error,
                                               fallback: String,
                                               maxLength: Int) -> String {
        let raw = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return fallback }

        let cleaned = raw
            .replacingOccurrences(of: "[AutoTranslator]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let normalized = cleaned.lowercased()
        let message: String
        if normalized.contains("llm api http 401") || normalized.contains("llm api http 403") {
            message = "大模型认证失败，请检查 API Key"
        } else if normalized.contains("tts api http 401") || normalized.contains("tts api http 403") {
            message = "发音认证失败，请检查 API Key"
        } else if normalized.contains("llm api http") {
            message = "大模型服务返回错误，请检查 API Key、模型或网络"
        } else if normalized.contains("tts api http") {
            message = "发音服务返回错误，请检查 TTS 模型、Base URL 或网络"
        } else if normalized.contains("google translate http") {
            message = "Google 翻译服务返回错误，请稍后重试"
        } else if normalized.contains("timed out")
                    || normalized.contains("offline")
                    || normalized.contains("network connection") {
            message = "网络请求失败，请检查网络连接"
        } else if normalized.contains("ocr 子进程") || normalized.contains("vision") {
            message = "OCR 识别失败，请重新框选更清晰的文字区域"
        } else {
            message = cleaned
        }

        return String(message.prefix(maxLength))
    }

    private func retranslateLast() {
        guard !lastText.isEmpty else { return }
        window.show(srcText: lastText, destText: nil, presentation: lastTranslationMode.floatingPresentation)
        dispatchTranslate(lastText, mode: lastTranslationMode)
    }

    private func shouldIgnoreSelectionSequence(startingAt point: CGPoint) -> Bool {
        if let reason = selectionIgnoreReason(startingAt: point) {
            AppLog.debug("Selection sequence ignored: reason=\(reason) point=\(Self.pointDescription(point))")
            return true
        }
        return false
    }

    private func selectionIgnoreReason(startingAt point: CGPoint) -> String? {
        if isMonitoringPaused { return "monitoringPaused" }
        if window.containsScreenPoint(point) { return "insideFloatingWindow" }
        if Self.isSystemChromePoint(point) { return "systemChrome" }
        // 注意：这里只做廉价的几何/前台应用判断。聚焦元素是否为文本输入框需要一次
        // 同步 AX 跨进程查询（最坏阻塞 0.2s），而本方法运行在 CGEventTap 回调（主 run loop）
        // 的 mouseDown 阶段——对系统中每一次左键点击都执行会拖慢 tap 甚至触发系统禁用。
        // 该判断改由 mouseUp 后的 onSelectionEvent 统一执行（见 isFocusedElementTextInput 调用处）。
        return Self.ignoredFrontmostApplicationReason()
    }

    private static func isSystemChromePoint(_ point: CGPoint) -> Bool {
        let nsPoint = NSPoint(x: point.x, y: point.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(nsPoint) }) else {
            return false
        }
        return !screen.visibleFrame.contains(nsPoint)
    }

    private static func ignoredFrontmostApplicationReason() -> String? {
        if NSApp.isActive { return "appActive" }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier else {
            return nil
        }
        if bundleIdentifier == Bundle.main.bundleIdentifier {
            return "frontmostSelf bundle=\(bundleIdentifier)"
        }
        if ignoredSelectionBundleIdentifiers.contains(bundleIdentifier) {
            return "ignoredBundle bundle=\(bundleIdentifier)"
        }
        return nil
    }

    /// 检查指定进程中聚焦的 UI 元素是否为可编辑的文本输入框。
    /// 若为真，说明用户正在输入框（网址栏、聊天输入框、搜索框等）中编辑文本，
    /// 应跳过划词翻译，避免干扰正常的文本编辑操作。
    /// 只做跨进程 AX 查询、不触碰 AppKit 主线程状态，可在后台线程执行——
    /// 系统里每次左键点击都会触发本检查，同步跑在主线程会造成可感知卡顿。
    nonisolated private static func isFocusedElementTextInput(pid: pid_t,
                                                              bundleIdentifier: String?) -> Bool {
        guard !Task.isCancelled else { return false }
        let appRef = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appRef, 0.2)

        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let focusedElement = focused else {
            return false
        }
        guard !Task.isCancelled else { return false }

        let element = focusedElement as! AXUIElement

        var roleVal: CFTypeRef?
        let roleErr = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleVal)
        guard roleErr == .success, let role = roleVal as? String else {
            return false
        }

        // 单行文本输入框 —— 包括浏览器网址栏、搜索框、表单输入框等。
        // 用户在这些地方几乎不会需要划词翻译，而是做编辑操作。
        let singleLineInputRoles: Set<String> = [
            "AXTextField",
            "AXSearchField",
            "AXComboBox",
        ]

        if singleLineInputRoles.contains(role) {
            return true
        }

        // 对于多行文本区（AXTextArea），只在已知的聊天/即时通讯应用中跳过，
        // 避免影响笔记、文档编辑器等 App 里的正常划词翻译体验。
        if role == "AXTextArea" {
            guard let bundleID = bundleIdentifier else { return false }
            let chatBundleIDs: Set<String> = [
                "com.tencent.xinWeChat",     // 微信
                "com.tencent.qq",            // QQ
                "com.apple.iChat",           // Messages（iMessage）
                "com.apple.MobileSMS",       // Messages（短信）
                "com.apple.messages",        // Messages（macOS Ventura+）
                "com.tinyspeck.slackmacgap", // Slack
                "com.microsoft.teams",       // Microsoft Teams（经典版）
                "com.microsoft.teams2",      // Microsoft Teams（新版，2023+ 默认）
            ]
            return chatBundleIDs.contains(bundleID)
        }

        return false
    }

    private static func pointDescription(_ point: CGPoint) -> String {
        "(\(String(format: "%.1f", point.x)),\(String(format: "%.1f", point.y)))"
    }

    /// 词典与普通翻译一律使用用户当前选择的后端。
    /// 曾经的实现会在词典模式下优先尝试 LLM(即使用户选了系统翻译/谷歌),
    /// 导致文本被发送到用户未选择的云服务;知情同意优先于释义质量,
    /// 非 LLM 后端的词典释义由 TranslatorProtocol 的 define 默认实现(直接翻译该词)承担。
    private func translator(sourceLanguage: String,
                            targetLanguage: String) -> TranslatorProtocol? {
        if translator.source == sourceLanguage, translator.target == targetLanguage {
            return translator
        }
        return createTranslator(source: sourceLanguage, target: targetLanguage)
    }

    private static func translationMode(for text: String) -> TranslationMode {
        if let word = dictionaryWord(from: text) {
            let hasSystemDefinition = SystemDictionary.definition(for: word) != nil
            if LanguageHeuristics.shouldUseDictionaryMode(
                for: word,
                systemDefinitionAvailable: hasSystemDefinition
            ) {
                return .dictionary(word: word)
            }
        }
        return .translation
    }

    private static func translationCacheKey(backend: String,
                                            src: String,
                                            dest: String,
                                            mode: TranslationMode,
                                            text: String) -> String {
        let kind: String
        switch mode {
        case .translation: kind = "t"
        case .dictionary: kind = "d"
        }
        return "\(backend)|\(src)|\(dest)|\(kind)|\(text)"
    }

    private static func effectiveTargetLanguage(sourceLanguage: String,
                                                targetLanguage: String,
                                                text: String) -> String {
        LanguageHeuristics.effectiveTargetLanguage(
            sourceLanguage: sourceLanguage,
            configuredTargetLanguage: targetLanguage,
            text: text
        )
    }

    private static func dictionaryWord(from text: String) -> String? {
        let boundaryPunctuation = CharacterSet(charactersIn: "\"“”‘’()[]{}<>.,;:!?，。？！；：")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(boundaryPunctuation))
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "'-’"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        guard trimmed.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    // MARK: - Translation dispatch

    /// 单次翻译输入上限：超长 GET URL 会被谷歌接口拒绝、大模型会静默截断输出，
    /// 与其让用户看到晦涩失败/残缺译文，不如直接明确提示。
    private static let maxTranslationInputLength = 5000

    private func dispatchTranslate(
        _ text: String,
        mode: TranslationMode
    ) {
        guard text.count <= Self.maxTranslationInputLength else {
            AppLog.debug("Translate rejected: input too long length=\(text.count)")
            window.showError(
                srcText: text,
                message: "文本过长（\(text.count) 字符），单次最多 \(Self.maxTranslationInputLength) 字符",
                status: "文本过长",
                presentation: mode.floatingPresentation
            )
            return
        }
        translateVersion += 1
        let version = translateVersion
        if translateTask != nil {
            AppLog.debug("Translate cancel previous task before version=\(version)")
        }
        translateTask?.cancel()
        // 任何新的（重）翻译开始前，先停止仍在播放的上一段朗读。
        // speak() 返回后音频仍在缓冲区播放、朗读 Task 已结束，单纯 cancel Task 不会停声，
        // 必须显式停止播放。新划词、切换后端/语言、刷新配置等入口都经 dispatchTranslate，
        // 故在此一处覆盖（原先仅词典模式停，翻译模式下划新词时旧音频会继续播放）。
        stopSpeech()
        currentHistoryEntryID = nil
        window.setHistoryFavorite(false, available: false)

        let request = makeTranslationRequest(
            version: version,
            text: text,
            mode: mode
        )
        window.setLanguages(
            Languages.codeByName,
            source: request.sourceLanguage,
            target: request.targetLanguage
        )
        AppLog.debug(
            "Translate dispatch version=\(request.version) mode=\(Self.modeDescription(request.mode)) length=\(request.text.count) backend=\(request.backend)"
        )

        if presentImmediateResultIfAvailable(for: request) {
            return
        }

        translateTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runTranslation(request)
        }
    }

    /// 同步快速路径:命中系统词典或翻译缓存时,在让出 runloop 前直接展示结果。
    /// 与调用方刚设置的「正在翻译」处于同一 runloop turn,SwiftUI 只渲染最终态,
    /// 从而消除缓存命中时先闪一帧 loading 再替换的问题。返回 true 表示已处理,无需发起网络翻译。
    /// 顺序与 runTranslation 一致:系统词典优先于翻译缓存。
    private func presentImmediateResultIfAvailable(for request: TranslationRequest) -> Bool {
        if case .dictionary(let word) = request.mode,
           let definition = SystemDictionary.definition(for: word) {
            if LanguageHeuristics.isLikelyChinese(word) {
                if let cached = translationCache.value(forKey: request.cacheKey) {
                    AppLog.debug("Translate version=\(request.version) resolved synchronously by augmented dictionary cache")
                    recordHistory(cached, for: request, kind: .systemDictionary)
                    window.show(srcText: request.text, destText: cached, presentation: .systemDictionary)
                    playPronunciationIfNeeded(for: request.text, mode: request.mode)
                    return true
                }

                AppLog.debug("Translate version=\(request.version) showing system dictionary while requesting English translation")
                recordHistory(definition, for: request, kind: .systemDictionary)
                window.show(srcText: request.text, destText: definition, presentation: .systemDictionary)
                playPronunciationIfNeeded(for: request.text, mode: request.mode)
                return false
            }

            AppLog.debug("Translate version=\(request.version) resolved synchronously by system dictionary")
            recordHistory(definition, for: request, kind: .systemDictionary)
            window.show(srcText: request.text, destText: definition, presentation: .systemDictionary)
            playPronunciationIfNeeded(for: request.text, mode: request.mode)
            return true
        }

        if let cached = translationCache.value(forKey: request.cacheKey) {
            AppLog.debug("Translate version=\(request.version) resolved synchronously by cache")
            recordHistory(cached, for: request, kind: Self.historyKind(for: request.mode))
            window.show(srcText: request.text, destText: cached, presentation: request.mode.floatingPresentation)
            playPronunciationIfNeeded(for: request.text, mode: request.mode)
            return true
        }

        return false
    }

    private func makeTranslationRequest(
        version: Int,
        text: String,
        mode: TranslationMode
    ) -> TranslationRequest {
        let backend = translatorBackend
        let sourceLanguage = srcLang
        let targetLanguage: String
        if case .dictionary(let word) = mode {
            targetLanguage = LanguageHeuristics.effectiveDictionaryTargetLanguage(
                sourceLanguage: sourceLanguage,
                configuredTargetLanguage: destLang,
                word: word
            )
        } else {
            targetLanguage = Self.effectiveTargetLanguage(
                sourceLanguage: sourceLanguage,
                targetLanguage: destLang,
                text: text
            )
        }
        let cacheKey = Self.translationCacheKey(
            backend: backend,
            src: sourceLanguage,
            dest: targetLanguage,
            mode: mode,
            text: text
        )
        return TranslationRequest(
            version: version,
            text: text,
            mode: mode,
            backend: backend,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            cacheKey: cacheKey,
            translator: translator(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        )
    }

    private func runTranslation(_ request: TranslationRequest) async {
        do {
            if await augmentChineseSystemDictionaryIfNeeded(for: request) {
                return
            }
            if await presentSystemDictionaryResultIfAvailable(for: request) {
                return
            }
            if await presentCachedTranslationIfAvailable(for: request) {
                return
            }

            guard let translator = request.translator else { return }
            guard let result = try await requestTranslation(for: request, using: translator) else {
                return
            }

            if !result.isEmpty {
                translationCache.setValue(result, forKey: request.cacheKey)
            }
            await presentFinalTranslation(result, for: request)
        } catch {
            await presentTranslationError(error, for: request)
        }
    }

    /// 中文单词先即时展示本地词典，再用当前翻译后端补充纯英文翻译。
    /// 补充请求失败时保留已经展示的本地结果，不把可用内容替换成错误页。
    private func augmentChineseSystemDictionaryIfNeeded(for request: TranslationRequest) async -> Bool {
        guard case .dictionary(let word) = request.mode,
              LanguageHeuristics.isLikelyChinese(word),
              let localDefinition = SystemDictionary.definition(for: word) else {
            return false
        }

        if let cached = translationCache.value(forKey: request.cacheKey) {
            await presentAugmentedSystemDictionary(cached, for: request)
            return true
        }

        guard let translator = request.translator else { return true }
        do {
            AppLog.debug("Translate version=\(request.version) requesting English translation for Chinese system dictionary entry")
            let englishTranslation = try await translator.translate(word)
            guard !Task.isCancelled, isCurrentTranslation(request.version) else { return true }
            let combined = SystemDictionary.definition(
                localDefinition,
                addingEnglishTranslation: englishTranslation
            )
            translationCache.setValue(combined, forKey: request.cacheKey)
            await presentAugmentedSystemDictionary(combined, for: request)
        } catch {
            guard !Task.isCancelled, isCurrentTranslation(request.version) else { return true }
            AppLog.debug(
                "Translate version=\(request.version) English dictionary augmentation failed; keeping system dictionary: \(Self.userFacingErrorMessage(from: error, fallback: "翻译服务暂时不可用", maxLength: 80))"
            )
        }
        return true
    }

    private func presentAugmentedSystemDictionary(_ definition: String,
                                                  for request: TranslationRequest) async {
        await MainActor.run { [weak self] in
            guard let self, self.isCurrentTranslation(request.version) else { return }
            self.recordHistory(definition, for: request, kind: .systemDictionary)
            self.window.show(
                srcText: request.text,
                destText: definition,
                presentation: .systemDictionary
            )
        }
    }

    private func presentSystemDictionaryResultIfAvailable(for request: TranslationRequest) async -> Bool {
        guard case .dictionary(let word) = request.mode,
              let definition = SystemDictionary.definition(for: word) else {
            return false
        }

        AppLog.debug("Translate version=\(request.version) resolved by system dictionary wordLength=\(word.count)")
        await MainActor.run { [weak self] in
            guard let self, self.isCurrentTranslation(request.version) else { return }
            self.recordHistory(
                definition,
                for: request,
                kind: .systemDictionary
            )
            self.window.show(
                srcText: request.text,
                destText: definition,
                presentation: .systemDictionary
            )
            self.playPronunciationIfNeeded(for: request.text, mode: request.mode)
        }
        return true
    }

    private func presentCachedTranslationIfAvailable(for request: TranslationRequest) async -> Bool {
        guard let cached = translationCache.value(forKey: request.cacheKey) else {
            return false
        }

        AppLog.debug("Translate version=\(request.version) cache hit")
        await MainActor.run { [weak self] in
            guard let self, self.isCurrentTranslation(request.version) else { return }
            self.recordHistory(
                cached,
                for: request,
                kind: Self.historyKind(for: request.mode)
            )
            self.window.show(
                srcText: request.text,
                destText: cached,
                presentation: request.mode.floatingPresentation
            )
            self.playPronunciationIfNeeded(for: request.text, mode: request.mode)
        }
        return true
    }

    private func requestTranslation(for request: TranslationRequest,
                                    using translator: TranslatorProtocol) async throws -> String? {
        if translator.supportsStreaming {
            AppLog.debug("Translate version=\(request.version) request started streaming=true")
            return try await requestStreamingTranslation(for: request, using: translator)
        }

        AppLog.debug("Translate version=\(request.version) request started streaming=false")
        switch request.mode {
        case .translation:
            return try await translator.translate(request.text)
        case .dictionary(let word):
            return try await translator.define(word)
        }
    }

    private func requestStreamingTranslation(for request: TranslationRequest,
                                             using translator: TranslatorProtocol) async throws -> String? {
        var buffer = ""
        var pendingDisplayChunk = ""
        var lastDisplayFlush = ProcessInfo.processInfo.systemUptime
        let stream: AsyncThrowingStream<String, Error>
        switch request.mode {
        case .translation:
            stream = translator.translateStream(request.text)
        case .dictionary(let word):
            stream = translator.defineStream(word)
        }

        for try await token in stream {
            guard isCurrentTranslation(request.version) else { return nil }
            guard !token.isEmpty else { continue }
            buffer += token
            pendingDisplayChunk += token

            let now = ProcessInfo.processInfo.systemUptime
            guard pendingDisplayChunk.count >= 12 || now - lastDisplayFlush >= 0.05 else {
                continue
            }

            let chunk = pendingDisplayChunk
            pendingDisplayChunk = ""
            lastDisplayFlush = now
            await appendTranslationStreamChunk(chunk, for: request)
        }

        if !pendingDisplayChunk.isEmpty, isCurrentTranslation(request.version) {
            await appendTranslationStreamChunk(pendingDisplayChunk, for: request)
        }

        return isCurrentTranslation(request.version) ? buffer : nil
    }

    private func appendTranslationStreamChunk(_ chunk: String, for request: TranslationRequest) async {
        await MainActor.run { [weak self] in
            guard let self, self.isCurrentTranslation(request.version) else { return }
            self.window.streamAppend(chunk)
        }
    }

    private func presentFinalTranslation(_ result: String, for request: TranslationRequest) async {
        await MainActor.run { [weak self] in
            guard let self, self.isCurrentTranslation(request.version) else { return }
            if result.isEmpty {
                self.window.showError(
                    srcText: request.text,
                    message: "翻译结果为空",
                    status: "无结果",
                    presentation: request.mode.floatingPresentation
                )
            } else if request.translator?.supportsStreaming == true {
                self.recordHistory(
                    result,
                    for: request,
                    kind: Self.historyKind(for: request.mode)
                )
                self.window.streamFinish(result)
                self.playPronunciationIfNeeded(for: request.text, mode: request.mode)
            } else {
                self.recordHistory(
                    result,
                    for: request,
                    kind: Self.historyKind(for: request.mode)
                )
                self.window.show(
                    srcText: request.text,
                    destText: result,
                    presentation: request.mode.floatingPresentation
                )
                self.playPronunciationIfNeeded(for: request.text, mode: request.mode)
            }
        }
    }

    @MainActor
    private func recordHistory(_ translatedText: String,
                               for request: TranslationRequest,
                               kind: TranslationHistoryKind) {
        currentHistoryEntryID = TranslationHistoryStore.shared.record(
            sourceText: request.text,
            translatedText: translatedText,
            sourceLanguage: request.sourceLanguage,
            targetLanguage: request.targetLanguage,
            backend: request.backend,
            kind: kind
        )
        if let currentHistoryEntryID,
           let entry = TranslationHistoryStore.shared.entry(id: currentHistoryEntryID) {
            window.setHistoryFavorite(entry.isFavorite, available: true)
        } else {
            window.setHistoryFavorite(false, available: false)
        }
    }

    private static func historyKind(for mode: TranslationMode) -> TranslationHistoryKind {
        switch mode {
        case .translation:
            return .translation
        case .dictionary:
            return .dictionary
        }
    }

    private func presentTranslationError(_ error: Error, for request: TranslationRequest) async {
        guard !Task.isCancelled, isCurrentTranslation(request.version) else { return }

        AppLog.debug("Translate version=\(request.version) failed error=\(Self.userFacingErrorMessage(from: error, fallback: "翻译服务暂时不可用", maxLength: 80))")
        let errMsg = Self.userFacingErrorMessage(
            from: error,
            fallback: "翻译服务暂时不可用",
            maxLength: 50
        )
        await MainActor.run { [weak self] in
            guard let self, self.isCurrentTranslation(request.version) else { return }
            self.window.showError(
                srcText: request.text,
                message: errMsg,
                presentation: request.mode.floatingPresentation
            )
        }
    }

    private func isCurrentTranslation(_ version: Int) -> Bool {
        version == translateVersion
    }

    private static func modeDescription(_ mode: TranslationMode) -> String {
        switch mode {
        case .translation:
            return "translation"
        case .dictionary:
            return "dictionary"
        }
    }

    private func playPronunciationIfNeeded(for text: String, mode: TranslationMode) {
        guard case .dictionary = mode else { return }
        guard Self.isAutoSpeakEnabled() else { return }
        playPronunciation(for: mode.dictionaryWord ?? text, isAutomatic: true)
    }

    private func playPronunciation(for text: String, isAutomatic: Bool) {
        let input = Self.pronunciationInput(from: text)
        guard !input.isEmpty else { return }

        speechGeneration += 1
        let generation = speechGeneration
        speechStatusResetTask?.cancel()
        speechTask?.cancel()
        window.setSpeechState(.preparing)
        // 音频真正开始播放时即翻为「播放中」，使长句在整段播放期间都显示播放态。
        speechService.onPlaybackStarted = { [weak self] in
            guard let self, self.speechGeneration == generation else { return }
            self.window.setSpeechState(.playing)
        }
        speechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await speechService.speak(input, languageHint: srcLang)
                guard !Task.isCancelled, self.speechGeneration == generation else { return }
                self.window.setSpeechState(.playing)
                // 按真实剩余播放时长安排回到空闲态；取不到时退回粗略估时。
                let remaining = self.speechService.currentPlaybackRemainingDuration()
                    ?? Self.estimatedPlaybackStatusDuration(for: input)
                self.scheduleSpeechStatusReset(for: generation, after: remaining + 0.3)
            } catch is CancellationError {
                guard self.speechGeneration == generation else { return }
                self.window.setSpeechState(.idle)
                return
            } catch {
                guard self.speechGeneration == generation else { return }
                let message = Self.userFacingErrorMessage(
                    from: error,
                    fallback: "发音生成失败，请检查 TTS 配置",
                    maxLength: 80
                )
                self.window.setSpeechState(.failed)
                self.scheduleSpeechStatusReset(for: generation, after: 2.2)
                if isAutomatic {
                    AppLog.error("自动发音失败: \(message)")
                } else {
                    NotificationManager.shared.post(title: "发音失败", body: message)
                }
            }
        }
    }

    private func scheduleSpeechStatusReset(for generation: Int, after delay: TimeInterval) {
        speechStatusResetTask?.cancel()
        speechStatusResetTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.speechGeneration == generation else { return }
            self.window.setSpeechState(.idle)
        }
    }

    private static func estimatedPlaybackStatusDuration(for text: String) -> TimeInterval {
        min(8.0, max(1.6, Double(text.count) * 0.16))
    }

    private static func pronunciationInput(from text: String) -> String {
        text
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isAutoSpeakEnabled() -> Bool {
        let value = ConfigStore.shared.get(.ttsAutoPlay)
            ?? ProcessInfo.processInfo.environment["TTS_AUTO_PLAY"]
            ?? ""
        return ["1", "true", "yes", "on"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// 剪贴板回退开关（默认开启）。关闭后仅通过 Accessibility 取词，
    /// 不再模拟 ⌘C，也不会读取/恢复用户剪贴板；部分不支持 AX 选区的应用将无法划词。
    private static func isClipboardFallbackEnabled() -> Bool {
        let value = ConfigStore.shared.get(.clipboardFallback)
            ?? ProcessInfo.processInfo.environment["CLIPBOARD_FALLBACK"]
            ?? ""
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return !["0", "false", "no", "off"].contains(normalized)
    }
}

// MARK: - MouseMonitorDelegate

extension AppController: MouseMonitorDelegate {
    func onSelectionEvent(allowClipboardFallback: Bool,
                          allowDeepAccessibilitySearch: Bool,
                          selectionPoint: CGPoint) {
        if selectionTask != nil {
            AppLog.debug("Selection event cancels previous selectionTask")
        }
        selectionTask?.cancel()
        // 手势层面的回退许可还要过用户开关：关闭后绝不模拟 ⌘C、不触碰剪贴板。
        let clipboardFallbackPermitted = allowClipboardFallback && Self.isClipboardFallbackEnabled()
        selectionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            AppLog.debug("Selection event handling begin allowClipboardFallback=\(clipboardFallbackPermitted) allowDeepAX=\(allowDeepAccessibilitySearch) point=\(Self.pointDescription(selectionPoint))")
            if let reason = Self.ignoredFrontmostApplicationReason() {
                AppLog.debug("Selection event dropped before text lookup: reason=\(reason)")
                return
            }
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                AppLog.debug("Selection event dropped: no frontmost application")
                return
            }
            let pid = frontApp.processIdentifier
            let bundleID = frontApp.bundleIdentifier
            // AX 跨进程查询会阻塞调用线程（最坏 0.2s，见 messaging timeout）。放到后台线程执行，
            // 避免每次划选/单击探测都占用主 run loop。
            let isTextInput = await self.selectionFocusLookupGate.perform {
                Self.isFocusedElementTextInput(pid: pid, bundleIdentifier: bundleID)
            }
            guard !Task.isCancelled else {
                AppLog.debug("Selection event cancelled during focus check")
                return
            }
            if isTextInput {
                AppLog.debug("Selection event dropped: focused text input")
                return
            }
            let text = await self.textSelector.getSelectedText(
                allowClipboardFallback: clipboardFallbackPermitted,
                allowDeepAccessibilitySearch: allowDeepAccessibilitySearch,
                selectionPoint: selectionPoint
            )
            guard !Task.isCancelled else {
                AppLog.debug("Selection event cancelled after text lookup")
                return
            }
            guard let text = text, !text.isEmpty else {
                AppLog.debug("Selection event dropped: no selected text")
                return
            }
            // 去重看「是否明确划选手势」（allowClipboardFallback 原始语义），与用户回退开关无关：
            // 即使回退被关闭，明确划选同一段文字也应再次弹窗。
            guard allowClipboardFallback || text != self.lastText else {
                AppLog.debug("Selection event dropped: duplicate text length=\(text.count)")
                return
            }

            self.lastText = text
            let mode = Self.translationMode(for: text)
            self.lastTranslationMode = mode
            AppLog.debug("Selection event accepted length=\(text.count) mode=\(Self.modeDescription(mode))")
            self.window.show(srcText: text, destText: nil, presentation: mode.floatingPresentation)
            self.dispatchTranslate(text, mode: mode)
        }
    }
}

// MARK: - FloatingWindowDelegate

extension AppController: FloatingWindowDelegate {
    func languageChanged(srcName: String, destName: String) {
        srcLang = Languages.code(for: srcName) ?? Languages.defaultSourceCode
        destLang = Languages.code(for: destName) ?? Languages.defaultTargetCode
        AppLog.debug("语言切换: \(srcName)(\(srcLang)) -> \(destName)(\(destLang))")
        translateTask?.cancel()
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        ConfigStore.shared.update([.srcLang: srcLang, .destLang: destLang])
        retranslateLast()
    }

    func swapLanguages() {
        guard srcLang != "auto" else {
            AppLog.debug("源语言为自动检测，跳过语言互换")
            return
        }
        swap(&srcLang, &destLang)
        window.setLanguages(Languages.codeByName, source: srcLang, target: destLang)
        translateTask?.cancel()
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        ConfigStore.shared.update([.srcLang: srcLang, .destLang: destLang])
        AppLog.debug("语言互换完成: \(srcLang) -> \(destLang)")
        retranslateLast()
    }

    func toggleTranslator() {
        switchTranslatorBackend()
    }

    func speakCurrentSource() {
        playPronunciation(for: window.currentSourceText, isAutomatic: false)
    }

    func screenshotTranslation() {
        Task { @MainActor [weak self] in
            self?.startScreenshotTranslation()
        }
    }

    func overlayTranslation() {
        Task { @MainActor [weak self] in
            self?.startOverlayTranslation()
        }
    }

    func retranslateCurrent() {
        retranslateLast()
    }

    func submitEditedSource(_ text: String) {
        translateText(text)
    }

    func toggleFavoriteCurrentResult() {
        guard let currentHistoryEntryID,
              TranslationHistoryStore.shared.entry(id: currentHistoryEntryID) != nil else {
            window.setHistoryFavorite(false, available: false)
            return
        }
        TranslationHistoryStore.shared.toggleFavorite(id: currentHistoryEntryID)
        let isFavorite = TranslationHistoryStore.shared.entry(id: currentHistoryEntryID)?.isFavorite ?? false
        window.setHistoryFavorite(isFavorite, available: true)
    }

    func toggleFloatingWindowMode() {
        let nextMode: FloatingWindowMode = currentFloatingWindowMode == .minimal ? .standard : .minimal
        setFloatingWindowMode(nextMode)
    }

    func hideWindow() {
        window.hide()
    }

    func stopSpeech() {
        // 让所有在途的朗读任务/状态重置失效：自增 generation 后，已排队的 speak 续延
        // 与状态重置都会因 generation 不匹配而成为 no-op，不会再把状态翻回 .playing。
        speechGeneration += 1
        speechStatusResetTask?.cancel()
        speechStatusResetTask = nil
        speechTask?.cancel()
        speechTask = nil
        speechService.stop()
        window.setSpeechState(.idle)
    }
}

// MARK: - OverlayTranslationControllerDelegate

extension AppController: OverlayTranslationControllerDelegate {
    func overlayRequestedOpenInFloatingWindow() {
        guard let context = overlayContext else { return }
        let source = context.blocks.map(\.text).joined(separator: "\n")
        guard !source.isEmpty else { return }
        // 复用手动输入管线：整段联合上下文重新翻译，浮窗里可复制/朗读/收藏。
        translateText(source)
    }

    func overlayRequestedRetry() {
        guard let context = overlayContext else { return }
        let overlay = ensureOverlayWindow()
        let indices = overlay.resetFailedBlocksToPending()
        guard !indices.isEmpty else { return }

        overlayTask?.cancel()
        overlayVersion += 1
        let version = overlayVersion
        overlayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.translateOverlayBlocks(
                indices: indices,
                context: context,
                version: version,
                overlay: overlay
            )
            guard self.isCurrentOverlay(version) else { return }
            overlay.finishTranslating()
        }
    }

    func overlayDidClose() {
        overlayTask?.cancel()
        overlayContext = nil
    }
}
