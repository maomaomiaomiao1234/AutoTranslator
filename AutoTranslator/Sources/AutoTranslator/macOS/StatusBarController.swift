import Cocoa

protocol StatusBarControllerDelegate: AnyObject {
    var currentBackend: String { get }
    var isMonitoringPaused: Bool { get }
    var currentTheme: Theme { get }
    var isAccessibilityGranted: Bool { get }
    func statusBarRequestedManualTranslation()
    func statusBarRequestedScreenshotTranslation()
    func statusBarRequestedOpenHistory()
    func statusBarRequestedSwitchBackend(to backend: String)
    func statusBarRequestedTogglePause()
    func statusBarRequestedOpenPreferences()
    func statusBarRequestedSetTheme(_ theme: Theme)
    func statusBarRequestedOpenAccessibilitySettings()
    func statusBarRequestedQuit()
}

/// 菜单栏图标 + 下拉菜单。
final class StatusBarController: NSObject {

    weak var delegate: StatusBarControllerDelegate?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let backendLLMItem = NSMenuItem(title: "大模型 (DeepSeek)", action: #selector(switchToLLM), keyEquivalent: "")
    private let backendGoogleItem = NSMenuItem(title: "谷歌翻译", action: #selector(switchToGoogle), keyEquivalent: "")
    private let backendAppleItem = NSMenuItem(title: "系统翻译（离线）", action: #selector(switchToApple), keyEquivalent: "")
    private let manualInputItem = NSMenuItem(title: "翻译输入…", action: #selector(startManualTranslation), keyEquivalent: "")
    private let screenshotItem = NSMenuItem(title: "截图翻译", action: #selector(startScreenshotTranslation), keyEquivalent: "")
    private let historyItem = NSMenuItem(title: "翻译历史…", action: #selector(openHistory), keyEquivalent: "")
    private let pauseItem = NSMenuItem(
        title: "暂停监听 (\(GlobalHotKeyManager.monitoringShortcutLabel))",
        action: #selector(togglePause),
        keyEquivalent: ""
    )
    private let prefsItem = NSMenuItem(title: "偏好设置…", action: #selector(openPreferences), keyEquivalent: ",")
    private let quitItem = NSMenuItem(title: "退出 AutoTranslator", action: #selector(quitApp), keyEquivalent: "q")
    private let statusItemMenuItem = NSMenuItem(title: "AutoTranslator", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(
        title: "打开辅助功能设置…",
        action: #selector(openAccessibilitySettings),
        keyEquivalent: ""
    )

    // 主题子菜单
    private let themeMenuItem = NSMenuItem(title: "主题外观", action: nil, keyEquivalent: "")
    private let themeSubmenu = NSMenu()
    private var themeItems: [Theme: NSMenuItem] = [:]

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        buildMenu()
    }

    private func configureButton() {
        if let button = statusItem.button {
            // SF Symbol：翻译图标；老版本系统回退到文本。
            if #available(macOS 11.0, *),
               let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "AutoTranslator") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "译"
            }
            button.toolTip = "AutoTranslator"
        }
    }

    private func buildMenu() {
        // 手动管理 isEnabled（如未授权时禁用「暂停监听」），需关闭 AppKit 的自动启用。
        menu.autoenablesItems = false
        statusItemMenuItem.isEnabled = false
        menu.addItem(statusItemMenuItem)
        // 仅在辅助功能未授权时显示（见 refresh()），提供直达系统设置的入口。
        accessibilityItem.target = self
        accessibilityItem.isHidden = true
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())

        let backendHeader = NSMenuItem(title: "翻译后端", action: nil, keyEquivalent: "")
        backendHeader.isEnabled = false
        menu.addItem(backendHeader)

        backendLLMItem.target = self
        backendGoogleItem.target = self
        backendAppleItem.target = self
        menu.addItem(backendLLMItem)
        menu.addItem(backendGoogleItem)
        if TranslationBackend.isAppleAvailable {
            menu.addItem(backendAppleItem)
        }
        menu.addItem(.separator())

        manualInputItem.target = self
        menu.addItem(manualInputItem)

        screenshotItem.target = self
        menu.addItem(screenshotItem)

        historyItem.target = self
        menu.addItem(historyItem)

        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        // 主题外观子菜单
        for theme in Theme.allCases {
            let item = NSMenuItem(
                title: theme.displayName,
                action: #selector(selectTheme(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = theme.rawValue
            themeSubmenu.addItem(item)
            themeItems[theme] = item
        }
        themeMenuItem.submenu = themeSubmenu
        menu.addItem(themeMenuItem)
        menu.addItem(.separator())

        prefsItem.target = self
        menu.addItem(prefsItem)
        menu.addItem(.separator())

        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    /// 由外部在状态变更后调用以刷新勾选/标题。
    func refresh() {
        guard let delegate = delegate else { return }
        let backend = delegate.currentBackend
        backendLLMItem.state = backend == "llm" ? .on : .off
        backendGoogleItem.state = backend == "google" ? .on : .off
        backendAppleItem.state = backend == "apple" ? .on : .off

        let currentTheme = delegate.currentTheme
        for (theme, item) in themeItems {
            item.state = theme == currentTheme ? .on : .off
        }
        themeMenuItem.title = "主题外观（\(currentTheme.displayName)）"

        let paused = delegate.isMonitoringPaused
        pauseItem.title = paused
            ? "恢复监听 (\(GlobalHotKeyManager.monitoringShortcutLabel))"
            : "暂停监听 (\(GlobalHotKeyManager.monitoringShortcutLabel))"

        let accessibilityGranted = delegate.isAccessibilityGranted
        accessibilityItem.isHidden = accessibilityGranted
        pauseItem.isEnabled = accessibilityGranted
        if !accessibilityGranted {
            statusItemMenuItem.title = "AutoTranslator · 等待辅助功能授权"
        } else {
            statusItemMenuItem.title = paused
                ? "AutoTranslator · 已暂停"
                : "AutoTranslator · \(TranslationBackend.shortName(backend))"
        }

        if let button = statusItem.button {
            button.appearsDisabled = paused || !accessibilityGranted
        }
    }

    // MARK: - Actions

    @objc private func switchToLLM() {
        delegate?.statusBarRequestedSwitchBackend(to: "llm")
    }

    @objc private func switchToGoogle() {
        delegate?.statusBarRequestedSwitchBackend(to: "google")
    }

    @objc private func switchToApple() {
        delegate?.statusBarRequestedSwitchBackend(to: "apple")
    }

    @objc private func togglePause() {
        delegate?.statusBarRequestedTogglePause()
    }

    @objc private func startManualTranslation() {
        delegate?.statusBarRequestedManualTranslation()
    }

    @objc private func startScreenshotTranslation() {
        delegate?.statusBarRequestedScreenshotTranslation()
    }

    @objc private func openHistory() {
        delegate?.statusBarRequestedOpenHistory()
    }

    @objc private func openPreferences() {
        delegate?.statusBarRequestedOpenPreferences()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = Theme(rawValue: raw) else { return }
        delegate?.statusBarRequestedSetTheme(theme)
    }

    @objc private func openAccessibilitySettings() {
        delegate?.statusBarRequestedOpenAccessibilitySettings()
    }

    @objc private func quitApp() {
        delegate?.statusBarRequestedQuit()
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }
}
