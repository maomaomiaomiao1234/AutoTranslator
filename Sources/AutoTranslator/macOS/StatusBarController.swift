import Cocoa

protocol StatusBarControllerDelegate: AnyObject {
    var currentBackend: String { get }
    var isMonitoringPaused: Bool { get }
    var currentTheme: Theme { get }
    func statusBarRequestedSwitchBackend(to backend: String)
    func statusBarRequestedTogglePause()
    func statusBarRequestedOpenPreferences()
    func statusBarRequestedSetTheme(_ theme: Theme)
    func statusBarRequestedQuit()
}

/// 菜单栏图标 + 下拉菜单。
final class StatusBarController: NSObject {

    weak var delegate: StatusBarControllerDelegate?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let backendLLMItem = NSMenuItem(title: "大模型 (DeepSeek)", action: #selector(switchToLLM), keyEquivalent: "")
    private let backendGoogleItem = NSMenuItem(title: "谷歌翻译", action: #selector(switchToGoogle), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "暂停监听", action: #selector(togglePause), keyEquivalent: "p")
    private let prefsItem = NSMenuItem(title: "偏好设置…", action: #selector(openPreferences), keyEquivalent: ",")
    private let quitItem = NSMenuItem(title: "退出 AutoTranslator", action: #selector(quitApp), keyEquivalent: "q")
    private let statusItemMenuItem = NSMenuItem(title: "AutoTranslator", action: nil, keyEquivalent: "")

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
        statusItemMenuItem.isEnabled = false
        menu.addItem(statusItemMenuItem)
        menu.addItem(.separator())

        let backendHeader = NSMenuItem(title: "翻译后端", action: nil, keyEquivalent: "")
        backendHeader.isEnabled = false
        menu.addItem(backendHeader)

        backendLLMItem.target = self
        backendGoogleItem.target = self
        menu.addItem(backendLLMItem)
        menu.addItem(backendGoogleItem)
        menu.addItem(.separator())

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

        let currentTheme = delegate.currentTheme
        for (theme, item) in themeItems {
            item.state = theme == currentTheme ? .on : .off
        }
        themeMenuItem.title = "主题外观（\(currentTheme.displayName)）"

        let paused = delegate.isMonitoringPaused
        pauseItem.title = paused ? "恢复监听" : "暂停监听"
        statusItemMenuItem.title = paused
            ? "AutoTranslator · 已暂停"
            : "AutoTranslator · \(backend == "llm" ? "大模型" : "谷歌")"

        if let button = statusItem.button {
            button.appearsDisabled = paused
        }
    }

    // MARK: - Actions

    @objc private func switchToLLM() {
        delegate?.statusBarRequestedSwitchBackend(to: "llm")
    }

    @objc private func switchToGoogle() {
        delegate?.statusBarRequestedSwitchBackend(to: "google")
    }

    @objc private func togglePause() {
        delegate?.statusBarRequestedTogglePause()
    }

    @objc private func openPreferences() {
        delegate?.statusBarRequestedOpenPreferences()
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let theme = Theme(rawValue: raw) else { return }
        delegate?.statusBarRequestedSetTheme(theme)
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
