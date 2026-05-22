import Cocoa

protocol PreferencesWindowControllerDelegate: AnyObject {
    /// 用户保存了偏好设置；controller 负责重新初始化翻译器并应用语言/主题。
    func preferencesDidSave(backend: String, apiKey: String?, srcLang: String, destLang: String, theme: Theme)
    /// 让 controller 提供当前语言/主题（用于打开窗口时填回）
    func preferencesCurrentSourceLang() -> String
    func preferencesCurrentDestLang() -> String
    func preferencesCurrentTheme() -> Theme
}

/// 偏好设置窗口：选择翻译后端、填写 API Key、设定源/目标语言。
final class PreferencesWindowController: NSWindowController {

    weak var prefDelegate: PreferencesWindowControllerDelegate?

    private let backendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let apiKeyField = NSSecureTextField()
    private let srcLangPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let destLangPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let configPathLabel = NSTextField(labelWithString: "")

    /// 主题选项的顺序（与 popup 的 indexOfSelectedItem 对应）
    private let themeOrder: [Theme] = [.system, .light, .dark]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AutoTranslator 偏好设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        buildLayout()
        loadCurrentValues()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showAndFocus() {
        loadCurrentValues()
        statusLabel.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        let backendLabel = NSTextField(labelWithString: "翻译后端：")
        let apiKeyLabel = NSTextField(labelWithString: "API Key：")
        let srcLangLabel = NSTextField(labelWithString: "源语言：")
        let destLangLabel = NSTextField(labelWithString: "目标语言：")
        let themeLabel = NSTextField(labelWithString: "外观主题：")

        let hint = NSTextField(labelWithString: "API Key 仅在使用大模型后端时需要；源语言可选自动检测。")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        backendPopup.addItems(withTitles: ["大模型 (DeepSeek)", "谷歌翻译"])

        // 源语言：包含 "自动检测"
        for option in Languages.sourceOptions {
            srcLangPopup.addItem(withTitle: option.name)
        }
        // 目标语言：不含 "自动检测"
        for option in Languages.targetOptions {
            destLangPopup.addItem(withTitle: option.name)
        }

        // 主题选项
        for theme in themeOrder {
            themePopup.addItem(withTitle: theme.displayName)
        }

        configPathLabel.textColor = .tertiaryLabelColor
        configPathLabel.font = NSFont.systemFont(ofSize: 10)
        configPathLabel.maximumNumberOfLines = 2
        configPathLabel.lineBreakMode = .byTruncatingMiddle
        configPathLabel.stringValue = "配置文件：\(ConfigStore.shared.configFileURL.path)"

        statusLabel.textColor = .systemGreen
        statusLabel.font = NSFont.systemFont(ofSize: 11)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(savePreferences))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        cancelButton.keyEquivalent = "\u{1b}" // ESC

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.addView(statusLabel, in: .leading)
        buttonRow.addView(cancelButton, in: .trailing)
        buttonRow.addView(saveButton, in: .trailing)

        apiKeyField.placeholderString = "sk-... (DeepSeek / DashScope)"
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true

        // 4 行表单使用统一 label 宽度的 grid
        let grid = NSGridView(views: [
            [backendLabel, backendPopup],
            [apiKeyLabel, apiKeyField],
            [srcLangLabel, srcLangPopup],
            [destLangLabel, destLangPopup],
            [themeLabel, themePopup],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [grid, hint, NSView(), configPathLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
        ])
    }

    private func loadCurrentValues() {
        let backend = ConfigStore.shared.get(.backend) ?? "llm"
        backendPopup.selectItem(at: backend == "google" ? 1 : 0)

        let apiKey = ConfigStore.shared.get(.deepseekKey) ?? ConfigStore.shared.get(.llmKey) ?? ""
        apiKeyField.stringValue = apiKey

        let srcCode = prefDelegate?.preferencesCurrentSourceLang()
            ?? ConfigStore.shared.get(.srcLang)
            ?? Languages.defaultSourceCode
        let destCode = prefDelegate?.preferencesCurrentDestLang()
            ?? ConfigStore.shared.get(.destLang)
            ?? Languages.defaultTargetCode

        srcLangPopup.selectItem(withTitle: Languages.name(for: srcCode))
        destLangPopup.selectItem(withTitle: Languages.name(for: destCode))

        let currentTheme = prefDelegate?.preferencesCurrentTheme()
            ?? Theme.from(rawValue: ConfigStore.shared.get(.theme))
        if let idx = themeOrder.firstIndex(of: currentTheme) {
            themePopup.selectItem(at: idx)
        }
    }

    // MARK: - Actions

    @objc private func savePreferences() {
        let backend = backendPopup.indexOfSelectedItem == 1 ? "google" : "llm"
        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespaces)

        let srcName = srcLangPopup.titleOfSelectedItem ?? ""
        let destName = destLangPopup.titleOfSelectedItem ?? ""
        let srcCode = Languages.code(for: srcName) ?? Languages.defaultSourceCode
        var destCode = Languages.code(for: destName) ?? Languages.defaultTargetCode
        if destCode == "auto" { destCode = Languages.defaultTargetCode }

        var updates: [ConfigStore.Key: String?] = [
            .backend: backend,
            .srcLang: srcCode,
            .destLang: destCode,
        ]
        let themeIdx = themePopup.indexOfSelectedItem
        let theme: Theme = (themeIdx >= 0 && themeIdx < themeOrder.count) ? themeOrder[themeIdx] : .default
        updates[.theme] = theme.rawValue
        if apiKey.isEmpty {
            updates[.deepseekKey] = nil
            updates[.llmKey] = nil
        } else {
            updates[.deepseekKey] = apiKey
            updates[.llmKey] = apiKey
        }
        ConfigStore.shared.update(updates)

        statusLabel.stringValue = "已保存 \(timestamp())"
        prefDelegate?.preferencesDidSave(
            backend: backend,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            srcLang: srcCode,
            destLang: destCode,
            theme: theme
        )
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
