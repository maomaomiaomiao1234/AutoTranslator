import Cocoa
import CoreGraphics

let LANGUAGES: [(String, String)] = [
    ("自动检测", "auto"),
    ("中文简体", "zh-CN"),
    ("英语", "en"),
    ("日语", "ja"),
    ("韩语", "ko"),
    ("法语", "fr"),
    ("德语", "de"),
    ("俄语", "ru"),
]

let LANG_DICT: [String: String] = Dictionary(uniqueKeysWithValues: LANGUAGES)

final class AppController: NSObject {

    // MARK: - State

    private var srcLang = "auto"
    private var destLang = "zh-CN"
    private var lastText = ""

    private var translatorBackend: String
    private var translator: TranslatorProtocol!

    private let window: FloatingWindow
    private let textSelector = TextSelector()
    private let mouseMonitor = MouseMonitor()

    private var translateVersion = 0
    private var translateTask: Task<Void, Never>?

    // MARK: - Init

    override init() {
        translatorBackend = ProcessInfo.processInfo.environment["TRANSLATOR_BACKEND"] ?? "llm"
        window = FloatingWindow()

        super.init()

        translator = createTranslator()
        window.delegate = self
        window.setLanguages(LANG_DICT, source: srcLang, target: destLang)
        window.setBackendLabel(translatorBackend)
        mouseMonitor.delegate = self
    }

    // MARK: - Start / Stop

    func start() {
        mouseMonitor.start()
    }

    func stop() {
        mouseMonitor.stop()
        translateTask?.cancel()
    }

    // MARK: - Translator management

    private func createTranslator() -> TranslatorProtocol {
        if translatorBackend == "llm" {
            do {
                fputs("[AutoTranslator] 使用大模型翻译 (LLM)\n", stderr)
                return try LLMTranslator(source: srcLang, target: destLang)
            } catch {
                fputs("[AutoTranslator] 大模型翻译初始化失败，回退到谷歌翻译: \(error)\n", stderr)
                translatorBackend = "google"
                DispatchQueue.main.async { [weak self] in
                    self?.window.setBackendLabel("google")
                }
            }
        }
        fputs("[AutoTranslator] 使用谷歌翻译 (Google)\n", stderr)
        return GoogleTranslator(source: srcLang, target: destLang)
    }

    private func switchTranslatorBackend() {
        translateTask?.cancel()
        translatorBackend = translatorBackend == "llm" ? "google" : "llm"
        translator = createTranslator()
        DispatchQueue.main.async { [weak self] in
            self?.window.setBackendLabel(self?.translatorBackend ?? "google")
        }
        fputs("[AutoTranslator] 翻译后端切换为: \(translatorBackend)\n", stderr)
        retranslateLast()
    }

    private func retranslateLast() {
        guard !lastText.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.window.show(srcText: self?.lastText ?? "", destText: nil)
        }
        dispatchTranslate(lastText)
    }

    // MARK: - Translation dispatch

    private func dispatchTranslate(_ text: String) {
        translateVersion += 1
        let version = translateVersion
        translateTask?.cancel()

        translateTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                if self.translator is LLMTranslator {
                    var buffer = ""
                    let stream = self.translator.translateStream(text)
                    for try await token in stream {
                        if version != self.translateVersion { return }
                        buffer += token
                        let current = buffer
                        if version == self.translateVersion {
                            await MainActor.run { [weak self] in
                                if version == self?.translateVersion {
                                    self?.window.streamFeed(current)
                                }
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
                    let translated = try await self.translator.translate(text)
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
        let text = textSelector.getSelectedText(allowClipboardFallback: allowClipboardFallback,
                                                 previousText: lastText)
        guard let text = text, !text.isEmpty, text != lastText else { return }

        lastText = text
        DispatchQueue.main.async { [weak self] in
            self?.window.show(srcText: text, destText: nil)
        }
        dispatchTranslate(text)
    }
}

// MARK: - FloatingWindowDelegate

extension AppController: FloatingWindowDelegate {
    func languageChanged(srcName: String, destName: String) {
        srcLang = LANG_DICT[srcName] ?? "auto"
        destLang = LANG_DICT[destName] ?? "zh-CN"
        fputs("[AutoTranslator] 语言切换: \(srcName)(\(srcLang)) -> \(destName)(\(destLang))\n", stderr)
        translateTask?.cancel()
        translator.source = srcLang
        translator.target = destLang
        retranslateLast()
    }

    func swapLanguages() {
        guard srcLang != "auto" else {
            fputs("[AutoTranslator] 源语言为自动检测，跳过语言互换\n", stderr)
            return
        }
        swap(&srcLang, &destLang)
        window.setLanguages(LANG_DICT, source: srcLang, target: destLang)
        translateTask?.cancel()
        translator.source = srcLang
        translator.target = destLang
        fputs("[AutoTranslator] 语言互换完成: \(srcLang) -> \(destLang)\n", stderr)
        retranslateLast()
    }

    func toggleTranslator() {
        switchTranslatorBackend()
    }

    func retranslateCurrent() {
        retranslateLast()
    }

    func copySource() {
        let text = lastText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.declareTypes([.string], owner: nil)
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyDest() {
        // Handled by FloatingWindow directly
    }

    func hideWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.window.hide()
        }
    }
}
