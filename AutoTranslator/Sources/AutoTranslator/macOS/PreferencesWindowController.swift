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
    private let modelField = NSTextField()
    private let baseURLField = NSTextField()
    private let srcLangPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let destLangPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let statusLabel = NSTextField(labelWithString: "")
    private let configPathLabel = NSTextField(labelWithString: "")
    private let engineSummaryLabel = NSTextField(labelWithString: "")
    private let languageSummaryLabel = NSTextField(labelWithString: "")
    private let themeSummaryLabel = NSTextField(labelWithString: "")

    /// 主题选项的顺序（与 popup 的 indexOfSelectedItem 对应）
    private let themeOrder: [Theme] = [.system, .light, .dark]

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "偏好设置"
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

        let titleLabel = createLabel(fontSize: 25, color: TEXT_PRIMARY, bold: true, wraps: false)
        titleLabel.stringValue = "偏好配置"

        let subtitleLabel = createLabel(fontSize: 13, color: TEXT_SECONDARY, wraps: true)
        subtitleLabel.stringValue = "管理划词后的翻译行为、默认语言和浮窗外观。"
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
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(savePreferences))
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded
        saveButton.contentTintColor = CORAL_ACCENT
        let cancelButton = NSButton(title: "关闭", target: self, action: #selector(closeWindow))
        cancelButton.keyEquivalent = "\u{1b}" // ESC
        cancelButton.bezelStyle = .rounded

        for control in [backendPopup, srcLangPopup, destLangPopup, themePopup] {
            configurePopup(control)
            control.target = self
            control.action = #selector(preferenceControlChanged)
        }

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        buttonRow.addView(statusLabel, in: .leading)
        buttonRow.addView(spacer, in: .center)
        buttonRow.addView(cancelButton, in: .trailing)
        buttonRow.addView(saveButton, in: .trailing)

        apiKeyField.placeholderString = "sk-... (DeepSeek / DashScope)"
        modelField.placeholderString = LLMTranslator.defaultModel
        baseURLField.placeholderString = LLMTranslator.defaultBaseURL

        for field in [apiKeyField, modelField, baseURLField] {
            configureTextField(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 292).isActive = true
            field.heightAnchor.constraint(equalToConstant: 34).isActive = true
        }

        let headerIcon = NSImageView()
        if let image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 21, weight: .medium)
            headerIcon.image = image.withSymbolConfiguration(config)
            headerIcon.contentTintColor = CORAL_ACCENT
        }
        headerIcon.translatesAutoresizingMaskIntoConstraints = false

        let iconShell = NSView()
        styleSurface(iconShell, background: TOOLBAR_ACTIVE_BG, radius: 8, border: TOOLBAR_ACTIVE_BORDER)
        iconShell.translatesAutoresizingMaskIntoConstraints = false
        iconShell.addSubview(headerIcon)
        NSLayoutConstraint.activate([
            iconShell.widthAnchor.constraint(equalToConstant: 44),
            iconShell.heightAnchor.constraint(equalToConstant: 44),
            headerIcon.centerXAnchor.constraint(equalTo: iconShell.centerXAnchor),
            headerIcon.centerYAnchor.constraint(equalTo: iconShell.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 28),
            headerIcon.heightAnchor.constraint(equalToConstant: 28),
        ])

        let summaryPanel = makeSummaryPanel()
        let engineSection = makeSection(
            title: "翻译引擎",
            subtitle: "Google 更轻量；大模型更适合长句和语气改写。",
            rows: [
                makeSettingRow(icon: "cpu", title: "后端", detail: "选择划词后实际使用的翻译服务。", control: backendPopup),
                makeSettingRow(icon: "key", title: "API Key", detail: "仅大模型后端需要；留空时会回退到 Google。", control: apiKeyField),
                makeSettingRow(icon: "cube", title: "Model", detail: "留空使用默认模型。", control: modelField),
                makeSettingRow(icon: "link", title: "Base URL", detail: "填到 /v1 即可，代码会自动拼接接口路径。", control: baseURLField),
            ]
        )

        let languageSection = makeSection(
            title: "语言与外观",
            subtitle: "源语言可自动检测；目标语言保持明确，翻译方向更稳定。",
            rows: [
                makeSettingRow(icon: "text.viewfinder", title: "源语言", detail: "划词文本的原始语言。", control: srcLangPopup),
                makeSettingRow(icon: "character.book.closed", title: "目标语言", detail: "译文输出语言。", control: destLangPopup),
                makeSettingRow(icon: "paintpalette", title: "外观主题", detail: "控制浮窗和偏好配置窗口的明暗外观。", control: themePopup),
            ]
        )

        let footerBar = NSView()
        styleSurface(footerBar, background: SURFACE_BG_SOFT, radius: CARD_RADIUS, border: CARD_BORDER)
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        footerBar.addSubview(configPathLabel)
        footerBar.addSubview(buttonRow)
        configPathLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            configPathLabel.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 16),
            configPathLabel.topAnchor.constraint(equalTo: footerBar.topAnchor, constant: 12),
            configPathLabel.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -16),
            buttonRow.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 16),
            buttonRow.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -16),
            buttonRow.topAnchor.constraint(equalTo: configPathLabel.bottomAnchor, constant: 12),
            buttonRow.bottomAnchor.constraint(equalTo: footerBar.bottomAnchor, constant: -12),
        ])

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 5
        headerStack.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [iconShell, headerStack])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 14
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [headerRow, summaryPanel, engineSection, languageSection, footerBar])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            titleLabel.heightAnchor.constraint(equalToConstant: 31),
        ])
    }

    private func makeSummaryPanel() -> NSView {
        let panel = NSView()
        styleSurface(panel, background: SURFACE_BG, radius: CARD_RADIUS, border: CARD_BORDER, shadow: true)
        panel.translatesAutoresizingMaskIntoConstraints = false

        configureSummaryLabel(engineSummaryLabel)
        configureSummaryLabel(languageSummaryLabel)
        configureSummaryLabel(themeSummaryLabel)

        let row = NSStackView(views: [
            makeSummaryItem(icon: "bolt.horizontal", title: "引擎", valueLabel: engineSummaryLabel),
            makeSummaryItem(icon: "arrow.left.arrow.right", title: "语言", valueLabel: languageSummaryLabel),
            makeSummaryItem(icon: "circle.lefthalf.filled", title: "主题", valueLabel: themeSummaryLabel),
        ])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
        ])
        return panel
    }

    private func makeSummaryItem(icon: String, title: String, valueLabel: NSTextField) -> NSView {
        let iconView = makeIconView(symbolName: icon, tint: CORAL_ACCENT, background: TOOLBAR_ACTIVE_BG)
        let titleLabel = createLabel(fontSize: 11, color: TEXT_MUTED, bold: true, wraps: false)
        titleLabel.stringValue = title

        let textStack = NSStackView(views: [titleLabel, valueLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let item = NSStackView(views: [iconView, textStack])
        item.orientation = .horizontal
        item.alignment = .centerY
        item.spacing = 10
        item.translatesAutoresizingMaskIntoConstraints = false
        return item
    }

    private func makeSection(title: String, subtitle: String, rows: [NSView]) -> NSView {
        let card = NSView()
        styleSurface(card, background: SURFACE_BG, radius: CARD_RADIUS, border: CARD_BORDER, shadow: true)
        card.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = createLabel(fontSize: 15.5, color: TEXT_PRIMARY, bold: true, wraps: false)
        titleLabel.stringValue = title

        let subtitleLabel = createLabel(fontSize: 12, color: TEXT_SECONDARY, wraps: true)
        subtitleLabel.stringValue = subtitle
        subtitleLabel.maximumNumberOfLines = 2

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 5

        var rowViews: [NSView] = []
        for (index, row) in rows.enumerated() {
            if index > 0 {
                rowViews.append(makeDivider())
            }
            rowViews.append(row)
        }

        let stack = NSStackView(views: [headerStack] + rowViews)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func makeSettingRow(icon: String, title: String, detail: String, control: NSView) -> NSView {
        let iconView = makeIconView(symbolName: icon, tint: TEXT_SECONDARY, background: SURFACE_BG_SOFT)

        let titleLabel = createLabel(fontSize: 13, color: TEXT_PRIMARY, bold: true, wraps: false)
        titleLabel.stringValue = title
        let detailLabel = createLabel(fontSize: 11.5, color: TEXT_SECONDARY, wraps: true)
        detailLabel.stringValue = detail
        detailLabel.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let leadingStack = NSStackView(views: [iconView, textStack])
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = 12
        leadingStack.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [leadingStack, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        leadingStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 252),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 176),
        ])
        return row
    }

    private func makeIconView(symbolName: String, tint: NSColor, background: NSColor) -> NSView {
        let shell = NSView()
        styleSurface(shell, background: background, radius: 8, border: BUTTON_BORDER)
        shell.translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView()
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            imageView.image = image.withSymbolConfiguration(config)
            imageView.contentTintColor = tint
        }
        imageView.translatesAutoresizingMaskIntoConstraints = false
        shell.addSubview(imageView)

        NSLayoutConstraint.activate([
            shell.widthAnchor.constraint(equalToConstant: 30),
            shell.heightAnchor.constraint(equalToConstant: 30),
            imageView.centerXAnchor.constraint(equalTo: shell.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
        ])
        return shell
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = CARD_BORDER.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    private func configureSummaryLabel(_ label: NSTextField) {
        label.textColor = TEXT_PRIMARY
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
    }

    private func configurePopup(_ popup: NSPopUpButton) {
        popup.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        popup.controlSize = .large
        popup.isBordered = false
        popup.focusRingType = .none
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.heightAnchor.constraint(equalToConstant: 32).isActive = true
        styleSurface(popup, background: SURFACE_BG_SOFT, radius: CONTROL_RADIUS, border: BUTTON_BORDER)
    }

    private func configureTextField(_ field: NSTextField) {
        field.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        styleSurface(field, background: SURFACE_BG_SOFT, radius: CONTROL_RADIUS, border: BUTTON_BORDER)
    }

    private func loadCurrentValues() {
        let backend = ConfigStore.shared.get(.backend) ?? "llm"
        backendPopup.selectItem(at: backend == "google" ? 1 : 0)

        let apiKey = ConfigStore.shared.get(.deepseekKey) ?? ConfigStore.shared.get(.llmKey) ?? ""
        apiKeyField.stringValue = apiKey
        modelField.stringValue = ConfigStore.shared.get(.llmModel)
            ?? ProcessInfo.processInfo.environment["LLM_MODEL"]
            ?? ""
        baseURLField.stringValue = ConfigStore.shared.get(.llmBaseURL)
            ?? ProcessInfo.processInfo.environment["LLM_BASE_URL"]
            ?? ""

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
        updateSummary()
    }

    // MARK: - Actions

    @objc private func preferenceControlChanged() {
        updateSummary()
    }

    @objc private func savePreferences() {
        let backend = backendPopup.indexOfSelectedItem == 1 ? "google" : "llm"
        let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespaces)
        let model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

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
        updates[.llmModel] = model.isEmpty ? nil : model
        updates[.llmBaseURL] = baseURL.isEmpty ? nil : baseURL
        ConfigStore.shared.update(updates)

        statusLabel.stringValue = "已保存 \(timestamp())"
        updateSummary()
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

    private func updateSummary() {
        let backend = backendPopup.indexOfSelectedItem == 1 ? "Google" : "大模型"
        let src = srcLangPopup.titleOfSelectedItem ?? "自动检测"
        let dest = destLangPopup.titleOfSelectedItem ?? "中文简体"
        let theme = themePopup.titleOfSelectedItem ?? Theme.default.displayName

        engineSummaryLabel.stringValue = backend
        languageSummaryLabel.stringValue = "\(src) → \(dest)"
        themeSummaryLabel.stringValue = theme
    }
}
