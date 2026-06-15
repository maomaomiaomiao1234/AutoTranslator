import Cocoa
import CoreGraphics

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
    private let ocrService = OCRService()
    private let speechService = SpeechService()

    private var translateVersion = 0
    private var translateTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var screenshotTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?

    private(set) var isMonitoringPaused = false
    private(set) var currentTheme: Theme = .default

    var currentBackend: String { translatorBackend }

    private static let ignoredSelectionBundleIdentifiers: Set<String> = [
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
        window = FloatingWindow()

        super.init()

        translator = createTranslator()
        window.delegate = self
        window.setLanguages(Languages.codeByName, source: srcLang, target: destLang)
        window.setBackendLabel(translatorBackend)
        mouseMonitor.delegate = self
        mouseMonitor.shouldIgnoreMouseSequenceStartingAt = { [weak self] point in
            self?.shouldIgnoreSelectionSequence(startingAt: point) ?? false
        }

        // 恢复保存的主题（必须在 NSApp 创建之后才有效，此处只是记录；
        // 实际应用由 start() 调用，那时 NSApplication.shared 已就绪）
        currentTheme = Theme.from(rawValue: ConfigStore.shared.get(.theme))
    }

    // MARK: - Start / Stop

    func start() {
        currentTheme.apply()
        mouseMonitor.start()
    }

    @MainActor
    func stop() {
        mouseMonitor.stop()
        selectionTask?.cancel()
        translateTask?.cancel()
        screenshotTask?.cancel()
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

    /// 切换到指定后端；若与当前一致则无操作。
    func setBackend(_ backend: String) {
        guard backend == "llm" || backend == "google" else { return }
        guard backend != translatorBackend else { return }
        translateTask?.cancel()
        speechTask?.cancel()
        translatorBackend = backend
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        let label = translatorBackend == "llm" ? "大模型" : "谷歌翻译"
        NotificationManager.shared.post(title: "翻译后端已切换", body: "当前使用：\(label)")
        retranslateLast()
    }

    /// 偏好设置保存后调用：重新读取配置并重建翻译器。
    func reloadFromConfig() {
        ConfigStore.shared.reload()
        ConfigStore.shared.applyToEnvironment()
        let newBackend = ConfigStore.shared.get(.backend) ?? translatorBackend
        translateTask?.cancel()
        speechTask?.cancel()
        translatorBackend = newBackend
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
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

    // MARK: - Translator management

    private func createTranslator() -> TranslatorProtocol {
        if translatorBackend == "llm" {
            do {
                AppLog.debug("使用大模型翻译 (LLM)")
                return try LLMTranslator(source: srcLang, target: destLang)
            } catch {
                AppLog.error("大模型翻译初始化失败，回退到谷歌翻译: \(error)")
                NotificationManager.shared.post(
                    title: "大模型不可用，已回退到谷歌翻译",
                    body: "请在偏好设置中配置 API Key。"
                )
                translatorBackend = "google"
                window.setBackendLabel("google")
            }
        }
        AppLog.debug("使用谷歌翻译 (Google)")
        return GoogleTranslator(source: srcLang, target: destLang)
    }

    private func switchTranslatorBackend() {
        translateTask?.cancel()
        speechTask?.cancel()
        translatorBackend = translatorBackend == "llm" ? "google" : "llm"
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        AppLog.debug("翻译后端切换为: \(translatorBackend)")
        retranslateLast()
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
        if isMonitoringPaused { return true }
        if window.containsScreenPoint(point) { return true }
        if Self.isSystemChromePoint(point) { return true }
        if Self.isIgnoredFrontmostApplication() { return true }
        return false
    }

    private static func isSystemChromePoint(_ point: CGPoint) -> Bool {
        let nsPoint = NSPoint(x: point.x, y: point.y)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(nsPoint) }) else {
            return false
        }
        return !screen.visibleFrame.contains(nsPoint)
    }

    private static func isIgnoredFrontmostApplication() -> Bool {
        if NSApp.isActive { return true }
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier else {
            return false
        }
        if bundleIdentifier == Bundle.main.bundleIdentifier {
            return true
        }
        return ignoredSelectionBundleIdentifiers.contains(bundleIdentifier)
    }

    private func translator(for mode: TranslationMode) -> TranslatorProtocol? {
        switch mode {
        case .translation:
            return translator
        case .dictionary:
            if let llmTranslator = translator as? LLMTranslator {
                return llmTranslator
            }
            if let llmTranslator = try? LLMTranslator(source: srcLang, target: destLang) {
                return llmTranslator
            }
            return translator
        }
    }

    private static func translationMode(for text: String) -> TranslationMode {
        if let word = dictionaryWord(from: text) {
            return .dictionary(word: word)
        }
        return .translation
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

    private func dispatchTranslate(_ text: String, mode: TranslationMode) {
        translateVersion += 1
        let version = translateVersion
        translateTask?.cancel()
        if case .dictionary = mode {
            speechTask?.cancel()
            speechService.stop()
        }

        translateTask = Task { [weak self, mode] in
            guard let self = self else { return }

            do {
                if case .dictionary(let word) = mode,
                   let definition = SystemDictionary.definition(for: word) {
                    await MainActor.run { [weak self] in
                        if version == self?.translateVersion {
                            self?.window.show(
                                srcText: text,
                                destText: definition,
                                presentation: .systemDictionary
                            )
                            self?.playPronunciationIfNeeded(for: text, mode: mode)
                        }
                    }
                    return
                }

                guard let requestTranslator = self.translator(for: mode) else { return }
                if requestTranslator.supportsStreaming {
                    var buffer = ""
                    var pendingDisplayChunk = ""
                    var lastDisplayFlush = ProcessInfo.processInfo.systemUptime
                    let stream: AsyncThrowingStream<String, Error>
                    switch mode {
                    case .translation:
                        stream = requestTranslator.translateStream(text)
                    case .dictionary(let word):
                        stream = requestTranslator.defineStream(word)
                    }
                    for try await token in stream {
                        if version != self.translateVersion { return }
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

                        if version == self.translateVersion {
                            await MainActor.run { [weak self] in
                                if version == self?.translateVersion {
                                    self?.window.streamAppend(chunk)
                                }
                            }
                        }
                    }
                    if !pendingDisplayChunk.isEmpty, version == self.translateVersion {
                        let chunk = pendingDisplayChunk
                        await MainActor.run { [weak self] in
                            if version == self?.translateVersion {
                                self?.window.streamAppend(chunk)
                            }
                        }
                    }
                    let finalBuffer = buffer
                    if version == self.translateVersion {
                        await MainActor.run { [weak self] in
                            if version == self?.translateVersion {
                                if finalBuffer.isEmpty {
                                    self?.window.showError(
                                        srcText: text,
                                        message: "翻译结果为空",
                                        status: "无结果",
                                        presentation: mode.floatingPresentation
                                    )
                                } else {
                                    self?.window.streamFinish(finalBuffer)
                                    self?.playPronunciationIfNeeded(for: text, mode: mode)
                                }
                            }
                        }
                    }
                } else {
                    let result: String
                    switch mode {
                    case .translation:
                        result = try await requestTranslator.translate(text)
                    case .dictionary(let word):
                        result = try await requestTranslator.define(word)
                    }
                    if version == self.translateVersion {
                        await MainActor.run { [weak self] in
                            if version == self?.translateVersion {
                                if result.isEmpty {
                                    self?.window.showError(
                                        srcText: text,
                                        message: "翻译结果为空",
                                        status: "无结果",
                                        presentation: mode.floatingPresentation
                                    )
                                } else {
                                    self?.window.show(
                                        srcText: text,
                                        destText: result,
                                        presentation: mode.floatingPresentation
                                    )
                                    self?.playPronunciationIfNeeded(for: text, mode: mode)
                                }
                            }
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                if version == self.translateVersion {
                    let errMsg = Self.userFacingErrorMessage(
                        from: error,
                        fallback: "翻译服务暂时不可用",
                        maxLength: 50
                    )
                    await MainActor.run { [weak self] in
                        if version == self?.translateVersion {
                            self?.window.showError(
                                srcText: text,
                                message: errMsg,
                                presentation: mode.floatingPresentation
                            )
                        }
                    }
                }
            }
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

        speechTask?.cancel()
        speechTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await speechService.speak(input, languageHint: srcLang)
            } catch is CancellationError {
                return
            } catch {
                let message = Self.userFacingErrorMessage(
                    from: error,
                    fallback: "发音生成失败，请检查 TTS 配置",
                    maxLength: 80
                )
                if isAutomatic {
                    AppLog.error("自动发音失败: \(message)")
                } else {
                    NotificationManager.shared.post(title: "发音失败", body: message)
                }
            }
        }
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
}

// MARK: - MouseMonitorDelegate

extension AppController: MouseMonitorDelegate {
    func onSelectionEvent(allowClipboardFallback: Bool) {
        selectionTask?.cancel()
        selectionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard !Self.isIgnoredFrontmostApplication() else { return }
            let text = await self.textSelector.getSelectedText(
                allowClipboardFallback: allowClipboardFallback
            )
            guard !Task.isCancelled else { return }
            guard let text = text, !text.isEmpty else { return }
            guard allowClipboardFallback || text != self.lastText else { return }

            self.lastText = text
            let mode = Self.translationMode(for: text)
            self.lastTranslationMode = mode
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

    func retranslateCurrent() {
        retranslateLast()
    }

    func hideWindow() {
        window.hide()
    }
}
