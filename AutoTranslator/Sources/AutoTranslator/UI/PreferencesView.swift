import SwiftUI

struct PreferencesSnapshot {
    var backend: String
    var apiKey: String
    var model: String
    var baseURL: String
    var ttsApiKey: String
    var ttsAutoPlay: Bool
    var ttsModel: String
    var ttsVoice: String
    var ttsBaseURL: String
    var sourceLang: String
    var targetLang: String
    var theme: Theme
    var floatingWindowMode: FloatingWindowMode
    var clipboardFallback: Bool
}

struct PreferencesSavePayload {
    let backend: String
    let apiKey: String?
    let model: String?
    let baseURL: String?
    let ttsApiKey: String?
    let ttsAutoPlay: Bool
    let ttsModel: String?
    let ttsVoice: String?
    let ttsBaseURL: String?
    let sourceLang: String
    let targetLang: String
    let theme: Theme
    let floatingWindowMode: FloatingWindowMode
    let clipboardFallback: Bool
}

private enum PreferencesPane: String, CaseIterable, Identifiable {
    case translation
    case selection
    case speech
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translation: return "翻译"
        case .selection: return "取词"
        case .speech: return "语音"
        case .appearance: return "语言与外观"
        }
    }

    var icon: String {
        switch self {
        case .translation: return "bolt.horizontal"
        case .selection: return "text.viewfinder"
        case .speech: return "speaker.wave.2"
        case .appearance: return "paintpalette"
        }
    }
}

private enum PreferenceMetrics {
    static let controlWidth: CGFloat = 292
    static let controlHeight: CGFloat = 36
}

struct PreferencesView: View {
    @State private var backend: String
    @State private var apiKey: String
    @State private var model: String
    @State private var baseURL: String
    @State private var ttsApiKey: String
    @State private var ttsAutoPlay: Bool
    @State private var ttsModel: String
    @State private var ttsVoice: String
    @State private var ttsBaseURL: String
    @State private var sourceLang: String
    @State private var targetLang: String
    @State private var theme: Theme
    @State private var floatingWindowMode: FloatingWindowMode
    @State private var clipboardFallback: Bool
    @State private var statusText = ""
    @State private var selectedPane: PreferencesPane = .translation

    let configPath: String
    let onSave: (PreferencesSavePayload) -> Void
    let onClose: () -> Void

    init(snapshot: PreferencesSnapshot,
         configPath: String,
         onSave: @escaping (PreferencesSavePayload) -> Void,
         onClose: @escaping () -> Void) {
        _backend = State(initialValue: snapshot.backend)
        _apiKey = State(initialValue: snapshot.apiKey)
        _model = State(initialValue: snapshot.model)
        _baseURL = State(initialValue: snapshot.baseURL)
        _ttsApiKey = State(initialValue: snapshot.ttsApiKey)
        _ttsAutoPlay = State(initialValue: snapshot.ttsAutoPlay)
        _ttsModel = State(initialValue: snapshot.ttsModel)
        _ttsVoice = State(initialValue: snapshot.ttsVoice)
        _ttsBaseURL = State(initialValue: snapshot.ttsBaseURL)
        _sourceLang = State(initialValue: snapshot.sourceLang)
        _targetLang = State(initialValue: snapshot.targetLang)
        _theme = State(initialValue: snapshot.theme)
        _floatingWindowMode = State(initialValue: snapshot.floatingWindowMode)
        _clipboardFallback = State(initialValue: snapshot.clipboardFallback)
        self.configPath = configPath
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: AppUI.Space.l) {
                header
                paneSelector
            }
            .padding(.top, AppUI.Space.xxl)
            .padding(.horizontal, AppUI.Space.xxl)
            .padding(.bottom, AppUI.Space.l)
            .background(AppUI.panelTop)

            Rectangle()
                .fill(AppUI.cardBorder)
                .frame(height: 1)

            ScrollView {
                paneContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, AppUI.Space.xxl)
                    .padding(.vertical, AppUI.Space.l)
            }
            .id(selectedPane)
            .frame(maxHeight: .infinity)

            footer
        }
        .frame(minWidth: 640, minHeight: 620)
        .background(AppUI.panelBottom)
        .tint(AppUI.accent)
    }

    private var header: some View {
        HStack(spacing: AppUI.Space.l) {
            SymbolBadge(
                symbol: "slider.horizontal.3",
                tint: AppUI.accent,
                background: AppUI.activeToolbar,
                size: 44
            )
            VStack(alignment: .leading, spacing: AppUI.Space.xs) {
                Text("偏好设置")
                    .font(.system(size: AppUI.FontSize.display, weight: .bold))
                    .foregroundStyle(AppUI.textPrimary)
                Text("配置翻译、取词、语音和浮窗外观。")
                    .font(.system(size: AppUI.FontSize.base))
                    .foregroundStyle(AppUI.textSecondary)
            }
            Spacer()
        }
    }

    private var paneSelector: some View {
        HStack(spacing: AppUI.Space.xs) {
            ForEach(PreferencesPane.allCases) { pane in
                Button {
                    selectedPane = pane
                } label: {
                    HStack(spacing: AppUI.Space.s) {
                        Image(systemName: pane.icon)
                            .font(.system(size: AppUI.FontSize.base, weight: .semibold))
                        Text(pane.title)
                            .font(.system(size: AppUI.FontSize.base, weight: .semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selectedPane == pane ? AppUI.accent : AppUI.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                    .background {
                        if selectedPane == pane {
                            RoundedRectangle(cornerRadius: AppUI.controlRadius - 2, style: .continuous)
                                .fill(AppUI.activeToolbar)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if selectedPane == pane {
                            Capsule()
                                .fill(AppUI.accent)
                                .frame(width: 24, height: 2)
                                .padding(.bottom, AppUI.Space.xs)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedPane == pane ? .isSelected : [])
                .help(pane.title)
            }
        }
        .padding(AppUI.Space.xs)
        .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selectedPane {
        case .translation:
            engineSection
        case .selection:
            selectionSection
        case .speech:
            speechSection
        case .appearance:
            languageSection
        }
    }

    private var engineSection: some View {
        SettingsSection(title: "翻译 API", subtitle: "控制划词翻译、词典解释和流式输出所使用的服务。") {
            SettingRow(icon: "cpu", title: "后端", detail: "选择划词后实际使用的翻译服务。") {
                Picker("", selection: $backend) {
                    Text("大模型 (DeepSeek)").tag("llm")
                    Text("谷歌翻译").tag("google")
                    if TranslationBackend.isAppleAvailable {
                        Text("系统翻译（离线）").tag("apple")
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .frame(width: PreferenceMetrics.controlWidth, alignment: .trailing)
            }
            SettingDivider()
            SettingRow(icon: "key", title: "翻译 API Key", detail: "仅大模型后端需要；留空时会回退到 Google。") {
                SecureField("sk-... (DeepSeek / DashScope)", text: $apiKey)
                    .preferenceTextField()
            }
            SettingDivider()
            SettingRow(icon: "cube", title: "翻译模型", detail: "留空使用默认翻译模型。") {
                TextField(LLMTranslator.defaultModel, text: $model)
                    .preferenceTextField()
            }
            SettingDivider()
            SettingRow(icon: "link", title: "翻译 Base URL", detail: "填到 /v1 即可，代码会自动拼接接口路径。") {
                TextField(LLMTranslator.defaultBaseURL, text: $baseURL)
                    .preferenceTextField()
            }
        }
    }

    private var selectionSection: some View {
        SettingsSection(title: "取词方式", subtitle: "控制划词时如何读取其他应用中的选中文本。") {
            SettingRow(
                icon: "doc.on.clipboard",
                title: "剪贴板回退",
                detail: "Accessibility 取词失败时，临时模拟 ⌘C 复制选中文本并尽量恢复原剪贴板。关闭后完全不触碰剪贴板，但部分应用（不提供 AX 选区）将无法划词。"
            ) {
                Toggle("", isOn: $clipboardFallback)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .frame(width: PreferenceMetrics.controlWidth, alignment: .trailing)
            }
        }
    }

    private var speechSection: some View {
        SettingsSection(title: "语音 API", subtitle: "单独配置 DashScope CosyVoice 非实时语音合成。") {
            SettingRow(icon: "key", title: "语音 API Key", detail: "写入 TTS_API_KEY；留空时沿用环境中的 DashScope Key。") {
                SecureField("sk-... (DashScope TTS)", text: $ttsApiKey)
                    .preferenceTextField()
            }
            SettingDivider()
            SettingRow(icon: "speaker.wave.2", title: "自动播放", detail: "单词释义完成后自动朗读原词。") {
                Toggle("", isOn: $ttsAutoPlay)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.large)
                    .frame(width: PreferenceMetrics.controlWidth, alignment: .trailing)
            }
            SettingDivider()
            SettingRow(icon: "waveform", title: "语音模型", detail: "留空使用 cosyvoice-v3-flash。") {
                TextField(SpeechService.defaultModel, text: $ttsModel)
                    .preferenceTextField()
            }
            SettingDivider()
            SettingRow(icon: "person.wave.2", title: "音色", detail: "默认使用 longanyang；取决于服务商支持。") {
                TextField(SpeechService.defaultVoice, text: $ttsVoice)
                    .preferenceTextField()
            }
            SettingDivider()
            SettingRow(icon: "link.badge.plus", title: "语音 Endpoint", detail: "留空使用 DashScope SpeechSynthesizer 接口。") {
                TextField(SpeechService.defaultEndpoint, text: $ttsBaseURL)
                    .preferenceTextField()
            }
        }
    }

    private var languageSection: some View {
        SettingsSection(title: "语言与外观", subtitle: "源语言可自动检测；目标语言保持明确，翻译方向更稳定。") {
            SettingRow(icon: "text.viewfinder", title: "源语言", detail: "划词文本的原始语言。") {
                Picker("", selection: $sourceLang) {
                    ForEach(Languages.sourceOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .frame(width: PreferenceMetrics.controlWidth, alignment: .trailing)
            }
            SettingDivider()
            SettingRow(icon: "character.book.closed", title: "目标语言", detail: "译文输出语言。") {
                Picker("", selection: $targetLang) {
                    ForEach(Languages.targetOptions, id: \.code) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .frame(width: PreferenceMetrics.controlWidth, alignment: .trailing)
            }
            SettingDivider()
            SettingRow(icon: "paintpalette", title: "外观主题", detail: "控制浮窗和偏好配置窗口的明暗外观。") {
                Picker("", selection: $theme) {
                    ForEach(Theme.allCases, id: \.rawValue) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.large)
                .frame(width: PreferenceMetrics.controlWidth, alignment: .trailing)
            }
            SettingDivider()
            SettingRow(icon: "rectangle", title: "极简浮窗", detail: "只显示划词后的译文内容，隐藏原文、语言和工具按钮。") {
                Toggle("", isOn: Binding(
                    get: { floatingWindowMode == .minimal },
                    set: { floatingWindowMode = $0 ? .minimal : .standard }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.large)
                .frame(width: PreferenceMetrics.controlWidth, alignment: .trailing)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: AppUI.Space.l) {
            VStack(alignment: .leading, spacing: AppUI.Space.xs) {
                HStack(spacing: AppUI.Space.s) {
                    Text("配置文件")
                        .font(.system(size: AppUI.FontSize.micro, weight: .semibold))
                        .foregroundStyle(AppUI.textMuted)
                    if !statusText.isEmpty {
                        Label(statusText, systemImage: "checkmark.circle.fill")
                            .font(.system(size: AppUI.FontSize.micro, weight: .medium))
                            .foregroundStyle(AppUI.teal)
                    }
                }
                Text(configPath)
                    .font(.system(size: AppUI.FontSize.micro, design: .monospaced))
                    .foregroundStyle(AppUI.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(configPath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: AppUI.Space.s) {
                Button("关闭") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(AppUI.textSecondary)
                .frame(minWidth: 72, minHeight: 44)

                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(AppUI.accent)
                .frame(minWidth: 72, minHeight: 44)
            }
        }
        .padding(.horizontal, AppUI.Space.xxl)
        .padding(.vertical, AppUI.Space.m)
        .background(AppUI.surface)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(AppUI.cardBorder)
                .frame(height: 1)
        }
    }

    private func save() {
        var target = targetLang
        if target == "auto" {
            target = Languages.defaultTargetCode
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespaces)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTTSKey = ttsApiKey.trimmingCharacters(in: .whitespaces)
        let trimmedTTSModel = ttsModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTTSVoice = ttsVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTTSBaseURL = ttsBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        onSave(PreferencesSavePayload(
            backend: backend,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
            model: trimmedModel.isEmpty ? nil : trimmedModel,
            baseURL: trimmedBaseURL.isEmpty ? nil : trimmedBaseURL,
            ttsApiKey: trimmedTTSKey.isEmpty ? nil : trimmedTTSKey,
            ttsAutoPlay: ttsAutoPlay,
            ttsModel: trimmedTTSModel.isEmpty ? nil : trimmedTTSModel,
            ttsVoice: trimmedTTSVoice.isEmpty ? nil : trimmedTTSVoice,
            ttsBaseURL: trimmedTTSBaseURL.isEmpty ? nil : trimmedTTSBaseURL,
            sourceLang: sourceLang,
            targetLang: target,
            theme: theme,
            floatingWindowMode: floatingWindowMode,
            clipboardFallback: clipboardFallback
        ))
        statusText = "已保存 \(timestamp())"
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Space.m) {
            VStack(alignment: .leading, spacing: AppUI.Space.xs) {
                Text(title)
                    .font(.system(size: AppUI.FontSize.section, weight: .semibold))
                    .foregroundStyle(AppUI.textPrimary)
                Text(subtitle)
                    .font(.system(size: AppUI.FontSize.small))
                    .foregroundStyle(AppUI.textSecondary)
            }
            content
        }
        .padding(AppUI.Space.l)
        .appSurface(shadow: true)
    }
}

private struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: AppUI.Space.l) {
            HStack(spacing: AppUI.Space.m) {
                SymbolBadge(symbol: icon, tint: AppUI.textSecondary, background: AppUI.surfaceSoft, size: 30)
                VStack(alignment: .leading, spacing: AppUI.Space.xs) {
                    Text(title)
                        .font(.system(size: AppUI.FontSize.base, weight: .semibold))
                        .foregroundStyle(AppUI.textPrimary)
                    Text(detail)
                        .font(.system(size: AppUI.FontSize.small))
                        .foregroundStyle(AppUI.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: 206, maxWidth: .infinity, alignment: .leading)

            content
        }
        .frame(minHeight: 46)
    }
}

private struct SettingDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppUI.cardBorder)
            .frame(height: 1)
    }
}

private extension View {
    func preferenceTextField() -> some View {
        textFieldStyle(.plain)
            .font(.system(size: AppUI.FontSize.small, design: .monospaced))
            .foregroundStyle(AppUI.textPrimary)
            .padding(.horizontal, AppUI.Space.s)
            .frame(width: PreferenceMetrics.controlWidth, height: PreferenceMetrics.controlHeight)
            .appSurface(
                background: AppUI.surfaceSoft,
                radius: AppUI.controlRadius,
                border: AppUI.buttonBorder
            )
    }
}
