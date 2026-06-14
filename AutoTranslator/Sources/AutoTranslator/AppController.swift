import Cocoa
import CoreGraphics

final class AppController: NSObject {

    // MARK: - State

    private var srcLang = Languages.defaultSourceCode
    private var destLang = Languages.defaultTargetCode
    private var lastText = ""

    private var translatorBackend: String
    private var translator: TranslatorProtocol!

    private let window: FloatingWindow
    private let textSelector = TextSelector()
    private let mouseMonitor = MouseMonitor()
    private let ocrService = OCRService()

    private var translateVersion = 0
    private var translateTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var screenshotTask: Task<Void, Never>?

    private(set) var isMonitoringPaused = false
    private(set) var currentTheme: Theme = .default

    var currentBackend: String { translatorBackend }

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
        mouseMonitor.shouldIgnoreMouseSequenceStartingAt = { [weak window] point in
            window?.containsScreenPoint(point) ?? false
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

        screenshotTask = Task { @MainActor [weak self] in
            guard let self = self else { return }

            guard ScreenCaptureService.ensurePermission() else {
                NotificationManager.shared.post(
                    title: "需要屏幕录制权限",
                    body: "请在 系统设置 > 隐私与安全性 > 屏幕与系统音频录制 中允许 AutoTranslator，然后重新点击 OCR。"
                )
                self.window.show(
                    srcText: "截图翻译需要屏幕录制权限",
                    destText: "授权后请重新点击 OCR 按钮"
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
                    self.window.show(
                        srcText: "截图中未识别到文字",
                        destText: "请重新框选更清晰的文字区域"
                    )
                    return
                }

                self.lastText = text
                self.window.show(srcText: text, destText: nil)
                self.dispatchTranslate(text)
            } catch ScreenCaptureError.cancelled {
                return
            } catch is CancellationError {
                return
            } catch {
                let errMsg = String(error.localizedDescription.prefix(80))
                self.window.show(srcText: "截图翻译失败", destText: "错误: \(errMsg)")
                NotificationManager.shared.post(title: "截图翻译失败", body: errMsg)
            }
        }
    }

    /// 切换到指定后端；若与当前一致则无操作。
    func setBackend(_ backend: String) {
        guard backend == "llm" || backend == "google" else { return }
        guard backend != translatorBackend else { return }
        translateTask?.cancel()
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
                fputs("[AutoTranslator] 使用大模型翻译 (LLM)\n", stderr)
                return try LLMTranslator(source: srcLang, target: destLang)
            } catch {
                fputs("[AutoTranslator] 大模型翻译初始化失败，回退到谷歌翻译: \(error)\n", stderr)
                NotificationManager.shared.post(
                    title: "大模型不可用，已回退到谷歌翻译",
                    body: "请在偏好设置中配置 API Key。"
                )
                translatorBackend = "google"
                window.setBackendLabel("google")
            }
        }
        fputs("[AutoTranslator] 使用谷歌翻译 (Google)\n", stderr)
        return GoogleTranslator(source: srcLang, target: destLang)
    }

    private func switchTranslatorBackend() {
        translateTask?.cancel()
        translatorBackend = translatorBackend == "llm" ? "google" : "llm"
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        fputs("[AutoTranslator] 翻译后端切换为: \(translatorBackend)\n", stderr)
        retranslateLast()
    }

    private func retranslateLast() {
        guard !lastText.isEmpty else { return }
        window.show(srcText: lastText, destText: nil)
        dispatchTranslate(lastText)
    }

    // MARK: - Translation dispatch

    private func dispatchTranslate(_ text: String) {
        guard let requestTranslator = translator else { return }
        translateVersion += 1
        let version = translateVersion
        translateTask?.cancel()

        translateTask = Task { [weak self, requestTranslator] in
            guard let self = self else { return }

            do {
                if requestTranslator.supportsStreaming {
                    var buffer = ""
                    var pendingDisplayChunk = ""
                    var lastDisplayFlush = ProcessInfo.processInfo.systemUptime
                    let stream = requestTranslator.translateStream(text)
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
                                self?.window.streamFinish(finalBuffer.isEmpty ? "翻译结果为空" : finalBuffer)
                            }
                        }
                    }
                } else {
                    let translated = try await requestTranslator.translate(text)
                    let result = translated.isEmpty ? "翻译结果为空" : translated
                    if version == self.translateVersion {
                        await MainActor.run { [weak self] in
                            if version == self?.translateVersion {
                                self?.window.show(srcText: text, destText: result)
                            }
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                if version == self.translateVersion {
                    let errMsg = String(error.localizedDescription.prefix(50))
                    await MainActor.run { [weak self] in
                        self?.window.show(srcText: text, destText: "错误: \(errMsg)")
                    }
                }
            }
        }
    }
}

// MARK: - MouseMonitorDelegate

extension AppController: MouseMonitorDelegate {
    func onSelectionEvent(allowClipboardFallback: Bool) {
        selectionTask?.cancel()
        selectionTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            let text = await self.textSelector.getSelectedText(
                allowClipboardFallback: allowClipboardFallback
            )
            guard !Task.isCancelled else { return }
            guard let text = text, !text.isEmpty else { return }
            guard allowClipboardFallback || text != self.lastText else { return }

            self.lastText = text
            self.window.show(srcText: text, destText: nil)
            self.dispatchTranslate(text)
        }
    }
}

// MARK: - FloatingWindowDelegate

extension AppController: FloatingWindowDelegate {
    func languageChanged(srcName: String, destName: String) {
        srcLang = Languages.code(for: srcName) ?? Languages.defaultSourceCode
        destLang = Languages.code(for: destName) ?? Languages.defaultTargetCode
        fputs("[AutoTranslator] 语言切换: \(srcName)(\(srcLang)) -> \(destName)(\(destLang))\n", stderr)
        translateTask?.cancel()
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        ConfigStore.shared.update([.srcLang: srcLang, .destLang: destLang])
        retranslateLast()
    }

    func swapLanguages() {
        guard srcLang != "auto" else {
            fputs("[AutoTranslator] 源语言为自动检测，跳过语言互换\n", stderr)
            return
        }
        swap(&srcLang, &destLang)
        window.setLanguages(Languages.codeByName, source: srcLang, target: destLang)
        translateTask?.cancel()
        translator = createTranslator()
        window.setBackendLabel(translatorBackend)
        ConfigStore.shared.update([.srcLang: srcLang, .destLang: destLang])
        fputs("[AutoTranslator] 语言互换完成: \(srcLang) -> \(destLang)\n", stderr)
        retranslateLast()
    }

    func toggleTranslator() {
        switchTranslatorBackend()
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
