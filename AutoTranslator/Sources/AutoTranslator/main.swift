import Cocoa

// MARK: - OCR Helper Mode

func runOCRHelperIfRequested() -> Bool {
    let arguments = CommandLine.arguments
    guard arguments.contains("--autotranslator-ocr") else { return false }

    func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    guard let imagePath = value(after: "--image") else {
        AppLog.error("OCR 子进程缺少 --image 参数")
        exit(2)
    }

    let sourceLanguage = value(after: "--source-language") ?? Languages.defaultSourceCode
    do {
        let text = try OCRService.recognizeTextForCommandLine(
            inFileAt: URL(fileURLWithPath: imagePath),
            sourceLanguage: sourceLanguage
        )
        if let data = text.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
        return true
    } catch {
        AppLog.error("OCR 子进程失败: \(error.localizedDescription)")
        exit(2)
    }
}

// MARK: - Permission

func ensureAccessibilityPermission() -> Bool {
    if AXIsProcessTrusted() { return true }

    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(options) { return true }

    AppLog.error("需要辅助功能权限，请在 系统设置 > 隐私与安全性 > 辅助功能 中允许 AutoTranslator。")
    return false
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    let controller: AppController
    let statusBar: StatusBarController
    let preferences: PreferencesWindowController

    override init() {
        controller = AppController()
        statusBar = StatusBarController()
        preferences = PreferencesWindowController()
        super.init()
        statusBar.delegate = self
        preferences.prefDelegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
        statusBar.refresh()
        NotificationManager.shared.requestAuthorization()

        let backendName = controller.currentBackend == "google" ? "谷歌翻译" : "大模型"
        AppLog.debug("翻译器已启动（\(backendName)），支持语言切换")
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }
}

extension AppDelegate: StatusBarControllerDelegate {
    var currentBackend: String { controller.currentBackend }
    var isMonitoringPaused: Bool { controller.isMonitoringPaused }
    var currentTheme: Theme { controller.currentTheme }

    func statusBarRequestedScreenshotTranslation() {
        Task { @MainActor [controller] in
            controller.startScreenshotTranslation()
        }
    }

    func statusBarRequestedSwitchBackend(to backend: String) {
        controller.setBackend(backend)
        statusBar.refresh()
    }

    func statusBarRequestedTogglePause() {
        controller.toggleMonitoring()
        statusBar.refresh()
    }

    func statusBarRequestedOpenPreferences() {
        preferences.showAndFocus()
    }

    func statusBarRequestedSetTheme(_ theme: Theme) {
        controller.setTheme(theme)
        statusBar.refresh()
    }

    func statusBarRequestedQuit() {
        NSApp.terminate(nil)
    }
}

extension AppDelegate: PreferencesWindowControllerDelegate {
    func preferencesDidSave(backend: String, apiKey: String?, srcLang: String, destLang: String, theme: Theme) {
        controller.reloadFromConfig()
        controller.setLanguages(source: srcLang, target: destLang)
        controller.setTheme(theme)
        statusBar.refresh()
        NotificationManager.shared.post(
            title: "偏好设置已保存",
            body: "后端：\(backend == "llm" ? "大模型" : "谷歌翻译")  \(Languages.name(for: srcLang)) → \(Languages.name(for: destLang))  主题：\(theme.displayName)"
        )
    }

    func preferencesCurrentSourceLang() -> String { controller.currentSourceLang }
    func preferencesCurrentDestLang() -> String { controller.currentDestLang }
    func preferencesCurrentTheme() -> Theme { controller.currentTheme }
}

// MARK: - Entry Point

func main() {
    if runOCRHelperIfRequested() {
        return
    }

    // 加载持久化配置 → 同步到环境变量（不覆盖已有变量）
    ConfigStore.shared.applyToEnvironment()

    guard ensureAccessibilityPermission() else {
        exit(1)
    }

    // 如果选择大模型但没有 API Key，自动回退到谷歌
    let backend = ProcessInfo.processInfo.environment["TRANSLATOR_BACKEND"] ?? "llm"
    if backend == "llm" {
        let apiKey = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
            ?? ProcessInfo.processInfo.environment["LLM_API_KEY"]
        if apiKey == nil || apiKey!.isEmpty {
            AppLog.error("未设置 API Key，回退到谷歌翻译。可在菜单栏 → 偏好设置中配置。")
            setenv("TRANSLATOR_BACKEND", "google", 1)
        }
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    signal(SIGINT, SIG_DFL)

    let delegate = AppDelegate()
    app.delegate = delegate

    app.run()
    _ = delegate // 保活
}

main()
