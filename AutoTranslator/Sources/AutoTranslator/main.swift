import Cocoa
import Darwin

// MARK: - OCR Helper Mode

func withStandardOutputRedirectedToStandardError<T>(_ work: () throws -> T) rethrows -> T {
    let originalStdout = dup(STDOUT_FILENO)
    if originalStdout >= 0 {
        fflush(stdout)
        _ = dup2(STDERR_FILENO, STDOUT_FILENO)
    }

    defer {
        if originalStdout >= 0 {
            fflush(stdout)
            _ = dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
        }
    }

    return try work()
}

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

    // 结构化模式（贴图翻译）：JSON 写入 --output 指定的文件而非 stdout，
    // 从根源绕开 Vision 框架把日志混入 stdout 的问题。
    if arguments.contains("--structured") {
        guard let outputPath = value(after: "--output") else {
            AppLog.error("OCR 子进程缺少 --output 参数")
            exit(2)
        }
        do {
            let result = try withStandardOutputRedirectedToStandardError {
                try OCRService.recognizeStructuredForCommandLine(
                    inFileAt: URL(fileURLWithPath: imagePath),
                    sourceLanguage: sourceLanguage
                )
            }
            let data = try JSONEncoder().encode(result)
            try data.write(to: URL(fileURLWithPath: outputPath), options: [.atomic])
            return true
        } catch {
            AppLog.error("结构化 OCR 子进程失败: \(error.localizedDescription)")
            exit(2)
        }
    }

    do {
        let text = try withStandardOutputRedirectedToStandardError {
            try OCRService.recognizeTextForCommandLine(
                inFileAt: URL(fileURLWithPath: imagePath),
                sourceLanguage: sourceLanguage
            )
        }
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

func isRunningUnderTests() -> Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestConfigurationFilePath"] != nil
        || environment["XCInjectBundleInto"] != nil
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    let controller: AppController
    let statusBar: StatusBarController
    let preferences: PreferencesWindowController
    let history: HistoryWindowController
    let globalHotKeys: GlobalHotKeyManager
    let accessibilityPermission: AccessibilityPermissionCoordinator

    override init() {
        controller = AppController()
        statusBar = StatusBarController()
        preferences = PreferencesWindowController()
        history = HistoryWindowController(store: TranslationHistoryStore.shared)
        globalHotKeys = GlobalHotKeyManager()
        accessibilityPermission = AccessibilityPermissionCoordinator()
        super.init()
        statusBar.delegate = self
        preferences.prefDelegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        guard !isRunningUnderTests() else { return }
        controller.prepare()
        configureGlobalHotKeys()

        // 未授权时不再退出：应用照常驻留菜单栏（翻译输入/截图/历史可用），
        // 引导授权并在授权到位后自动启动划词监听，无需重启。
        let grantedAtLaunch = AXIsProcessTrusted()
        accessibilityPermission.onGranted = { [weak self] in
            guard let self else { return }
            self.controller.start()
            self.statusBar.refresh()
            if !grantedAtLaunch {
                NotificationManager.shared.post(
                    title: "辅助功能已授权",
                    body: "划词翻译已启用。"
                )
            }
            let backendName = TranslationBackend.displayName(self.controller.currentBackend)
            AppLog.debug("翻译器已启动（\(backendName)），支持语言切换")
        }
        accessibilityPermission.begin()

        statusBar.refresh()
        NotificationManager.shared.requestAuthorization()
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityPermission.stop()
        globalHotKeys.stop()
        controller.stop()
        // 历史写入是去抖的后台异步操作；退出前同步落盘，避免丢失最近记录。
        TranslationHistoryStore.shared.flush()
    }

    private func configureGlobalHotKeys() {
        globalHotKeys.onToggleMonitoring = { [weak self] in
            DispatchQueue.main.async {
                self?.controller.toggleMonitoring()
                self?.statusBar.refresh()
            }
        }
        globalHotKeys.start()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "隐藏 AutoTranslator",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "退出 AutoTranslator",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        addEditItem(to: editMenu, title: "撤销", action: "undo:", key: "z")
        addEditItem(to: editMenu, title: "重做", action: "redo:", key: "Z", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        addEditItem(to: editMenu, title: "剪切", action: "cut:", key: "x")
        addEditItem(to: editMenu, title: "拷贝", action: "copy:", key: "c")
        addEditItem(to: editMenu, title: "粘贴", action: "paste:", key: "v")
        addEditItem(to: editMenu, title: "粘贴并匹配样式", action: "pasteAsPlainText:", key: "V", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        addEditItem(to: editMenu, title: "全选", action: "selectAll:", key: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func addEditItem(to menu: NSMenu,
                             title: String,
                             action: String,
                             key: String,
                             modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.target = nil
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
    }
}

extension AppDelegate: StatusBarControllerDelegate {
    var currentBackend: String { controller.currentBackend }
    var isMonitoringPaused: Bool { controller.isMonitoringPaused }
    var currentTheme: Theme { controller.currentTheme }
    var isAccessibilityGranted: Bool { accessibilityPermission.isGranted }

    func statusBarRequestedManualTranslation() {
        controller.presentManualInput()
    }

    func statusBarRequestedOpenAccessibilitySettings() {
        AccessibilityPermissionCoordinator.openSystemSettings()
    }

    func statusBarRequestedScreenshotTranslation() {
        Task { @MainActor [controller] in
            controller.startScreenshotTranslation()
        }
    }

    func statusBarRequestedOverlayTranslation() {
        Task { @MainActor [controller] in
            controller.startOverlayTranslation()
        }
    }

    func statusBarRequestedOpenHistory() {
        history.showAndFocus()
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
    func preferencesDidSave(
        backend: String,
        apiKey: String?,
        srcLang: String,
        destLang: String,
        theme: Theme,
        floatingWindowMode: FloatingWindowMode
    ) {
        controller.reloadFromConfig()
        controller.setLanguages(source: srcLang, target: destLang)
        controller.setTheme(theme)
        controller.setFloatingWindowMode(floatingWindowMode)
        statusBar.refresh()
        NotificationManager.shared.post(
            title: "偏好设置已保存",
            body: "后端：\(TranslationBackend.displayName(backend))  \(Languages.name(for: srcLang)) → \(Languages.name(for: destLang))  外观：\(theme.displayName) · \(floatingWindowMode.displayName)"
        )
    }

    func preferencesCurrentSourceLang() -> String { controller.currentSourceLang }
    func preferencesCurrentDestLang() -> String { controller.currentDestLang }
    func preferencesCurrentTheme() -> Theme { controller.currentTheme }
    func preferencesCurrentFloatingWindowMode() -> FloatingWindowMode { controller.currentFloatingWindowMode }
}

// MARK: - Entry Point

func main() {
    if runOCRHelperIfRequested() {
        return
    }

    // 加载持久化配置 → 同步到环境变量（不覆盖已有变量）
    ConfigStore.shared.applyToEnvironment()

    // 注意：不在此处做「无 API Key 回退谷歌」的静默改道。
    // 后端可用性由 AppController.createTranslator 处理：macOS 15+ 回退本机系统翻译并通知，
    // 更早系统在使用时展示配置引导，用户的文本永远不会发给未选择的服务。

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    signal(SIGINT, SIG_DFL)

    let delegate = AppDelegate()
    app.delegate = delegate

    app.run()
    _ = delegate // 保活
}

main()
