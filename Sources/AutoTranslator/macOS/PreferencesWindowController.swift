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
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "AutoTranslator 偏好设置"
        window.titlebarAppearsTransparent = true
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

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = PANEL_BOTTOM.cgColor

        let titleLabel = createLabel(fontSize: 24, color: TEXT_PRIMARY, bold: true, wraps: false)
        titleLabel.stringValue = "AutoTranslator"

        let subtitleLabel = createLabel(fontSize: 12, color: TEXT_SECONDARY, wraps: true)
        subtitleLabel.stringValue = "设置划词后的翻译引擎、默认语言和窗口外观。更改保存后会立即应用。"
        subtitleLabel.maximumNumberOfLines = 2

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

        configPathLabel.textColor = TEXT_MUTED
        configPathLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        configPathLabel.maximumNumberOfLines = 2
        configPathLabel.lineBreakMode = .byTruncatingMiddle
        configPathLabel.stringValue = "配置文件：\(ConfigStore.shared.configFileURL.path)"

        statusLabel.textColor = TEAL_ACCENT
        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(savePreferences))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.contentTintColor = CORAL_ACCENT
        let cancelButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        cancelButton.keyEquivalent = "\u{1b}" // ESC
        cancelButton.bezelStyle = .rounded

        for control in [backendPopup, srcLangPopup, destLangPopup, themePopup] {
            control.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        }

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addView(statusLabel, in: .leading)
        buttonRow.addView(spacer, in: .center)
        buttonRow.addView(cancelButton, in: .trailing)
        buttonRow.addView(saveButton, in: .trailing)

        apiKeyField.placeholderString = "sk-... (DeepSeek / DashScope)"
        apiKeyField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true

        let engineGrid = makeGrid([
            [formLabel("翻译后端"), backendPopup],
            [formLabel("API Key"), apiKeyField],
        ])

        let engineHint = makeHint("API Key 仅在使用大模型后端时需要；未配置时会回退到 Google 翻译。")

        let engineSection = makeSection(
            title: "翻译引擎",
            subtitle: "选择速度优先的 Google，或使用大模型获得更自然的表达。",
            bodyViews: [engineGrid, engineHint]
        )

        let languageGrid = makeGrid([
            [formLabel("源语言"), srcLangPopup],
            [formLabel("目标语言"), destLangPopup],
            [formLabel("外观主题"), themePopup],
        ])

        let languageSection = makeSection(
            title: "语言与外观",
            subtitle: "源语言可自动检测；目标语言保持明确，避免翻译方向不稳定。",
            bodyViews: [languageGrid]
        )

        let footerCard = NSView()
        styleSurface(footerCard, background: SURFACE_BG_SOFT, radius: CARD_RADIUS, border: CARD_BORDER)
        footerCard.translatesAutoresizingMaskIntoConstraints = false
        footerCard.addSubview(configPathLabel)
        footerCard.addSubview(buttonRow)
        configPathLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            configPathLabel.leadingAnchor.constraint(equalTo: footerCard.leadingAnchor, constant: 14),
            configPathLabel.topAnchor.constraint(equalTo: footerCard.topAnchor, constant: 12),
            configPathLabel.trailingAnchor.constraint(equalTo: footerCard.trailingAnchor, constant: -14),
            buttonRow.leadingAnchor.constraint(equalTo: footerCard.leadingAnchor, constant: 14),
            buttonRow.trailingAnchor.constraint(equalTo: footerCard.trailingAnchor, constant: -14),
            buttonRow.topAnchor.constraint(equalTo: configPathLabel.bottomAnchor, constant: 12),
            buttonRow.bottomAnchor.constraint(equalTo: footerCard.bottomAnchor, constant: -12),
        ])

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headerStack, engineSection, languageSection, footerCard])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
            titleLabel.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func formLabel(_ title: String) -> NSTextField {
        let label = createLabel(fontSize: 12, color: TEXT_SECONDARY, bold: true, wraps: false)
        label.stringValue = title
        label.alignment = .right
        return label
    }

    private func makeHint(_ text: String) -> NSTextField {
        let hint = createLabel(fontSize: 11, color: TEXT_MUTED, wraps: true)
        hint.stringValue = text
        hint.maximumNumberOfLines = 2
        return hint
    }

    private func makeGrid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        return grid
    }

    private func makeSection(title: String, subtitle: String, bodyViews: [NSView]) -> NSView {
        let card = NSView()
        styleSurface(card, background: SURFACE_BG, radius: CARD_RADIUS, border: CARD_BORDER, shadow: true)
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = createLabel(fontSize: 14, color: TEXT_PRIMARY, bold: true, wraps: false)
        titleLabel.stringValue = title

        let subtitleLabel = createLabel(fontSize: 11, color: TEXT_SECONDARY, wraps: true)
        subtitleLabel.stringValue = subtitle
        subtitleLabel.maximumNumberOfLines = 2

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        let stack = NSStackView(views: [headerStack] + bodyViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
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
