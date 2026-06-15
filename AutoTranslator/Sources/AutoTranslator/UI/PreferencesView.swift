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
    @State private var statusText = ""

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
        self.configPath = configPath
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: AppUI.Space.l) {
            header
            summaryPanel
            ScrollView {
                VStack(spacing: AppUI.Space.l) {
                    engineSection
                    speechSection
                    languageSection
                }
                .padding(.vertical, AppUI.Space.xxs)
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .padding(.top, AppUI.Space.xxl)
        .padding(.horizontal, AppUI.Space.xxl)
        .padding(.bottom, AppUI.Space.xl)
        .frame(width: 640, height: 740)
        .background(AppUI.panelBottom)
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
                Text("偏好配置")
                    .font(.system(size: AppUI.FontSize.display, weight: .bold))
                    .foregroundStyle(AppUI.textPrimary)
                Text("管理划词后的翻译行为、默认语言和浮窗外观。")
                    .font(.system(size: AppUI.FontSize.base))
                    .foregroundStyle(AppUI.textSecondary)
            }
            Spacer()
        }
    }

    private var summaryPanel: some View {
        HStack(spacing: AppUI.Space.m) {
            SummaryItem(icon: "bolt.horizontal", title: "引擎", value: backend == "google" ? "Google" : "大模型")
            SummaryItem(icon: "speaker.wave.2", title: "语音", value: speechSummary)
            SummaryItem(icon: "arrow.left.arrow.right", title: "语言", value: "\(Languages.name(for: sourceLang)) → \(Languages.name(for: targetLang))")
            SummaryItem(icon: "circle.lefthalf.filled", title: "主题", value: theme.displayName)
        }
        .padding(AppUI.Space.l)
        .appSurface(shadow: true)
    }

    private var speechSummary: String {
        let mode = ttsAutoPlay ? "自动" : "手动"
        let hasDedicatedKey = !ttsApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSharedKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasDedicatedKey { return "\(mode) · 独立" }
        return hasSharedKey ? "\(mode) · 共用" : "\(mode) · 未配置"
    }

    private var engineSection: some View {
        SettingsSection(title: "翻译 API", subtitle: "控制划词翻译、词典解释和流式输出所使用的服务。") {
            SettingRow(icon: "cpu", title: "后端", detail: "选择划词后实际使用的翻译服务。") {
                Picker("", selection: $backend) {
                    Text("大模型 (DeepSeek)").tag("llm")
                    Text("谷歌翻译").tag("google")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 252)
            }
            SettingDivider()
            SettingRow(icon: "key", title: "翻译 API Key", detail: "仅大模型后端需要；留空时会回退到 Google。") {
                SecureField("sk-... (DeepSeek / DashScope)", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppUI.FontSize.small, design: .monospaced))
                    .padding(.horizontal, AppUI.Space.s)
                    .frame(width: 292, height: 34)
                    .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
            }
            SettingDivider()
            SettingRow(icon: "cube", title: "翻译模型", detail: "留空使用默认翻译模型。") {
                TextField(LLMTranslator.defaultModel, text: $model)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppUI.FontSize.small, design: .monospaced))
                    .padding(.horizontal, AppUI.Space.s)
                    .frame(width: 292, height: 34)
                    .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
            }
            SettingDivider()
            SettingRow(icon: "link", title: "翻译 Base URL", detail: "填到 /v1 即可，代码会自动拼接接口路径。") {
                TextField(LLMTranslator.defaultBaseURL, text: $baseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppUI.FontSize.small, design: .monospaced))
                    .padding(.horizontal, AppUI.Space.s)
                    .frame(width: 292, height: 34)
                    .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
            }
        }
    }

    private var speechSection: some View {
        SettingsSection(title: "语音 API", subtitle: "单独配置 DashScope CosyVoice 非实时语音合成。") {
            SettingRow(icon: "key", title: "语音 API Key", detail: "写入 TTS_API_KEY；留空时沿用环境中的 DashScope Key。") {
                SecureField("sk-... (DashScope TTS)", text: $ttsApiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppUI.FontSize.small, design: .monospaced))
                    .padding(.horizontal, AppUI.Space.s)
                    .frame(width: 292, height: 34)
                    .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
            }
            SettingDivider()
            SettingRow(icon: "speaker.wave.2", title: "自动播放", detail: "单词释义完成后自动朗读原词。") {
                Toggle("", isOn: $ttsAutoPlay)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .frame(width: 252, alignment: .trailing)
            }
            SettingDivider()
            SettingRow(icon: "waveform", title: "语音模型", detail: "留空使用 cosyvoice-v3-flash。") {
                TextField(SpeechService.defaultModel, text: $ttsModel)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppUI.FontSize.small, design: .monospaced))
                    .padding(.horizontal, AppUI.Space.s)
                    .frame(width: 292, height: 34)
                    .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
            }
            SettingDivider()
            SettingRow(icon: "person.wave.2", title: "音色", detail: "默认使用 longanyang；取决于服务商支持。") {
                TextField(SpeechService.defaultVoice, text: $ttsVoice)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppUI.FontSize.small, design: .monospaced))
                    .padding(.horizontal, AppUI.Space.s)
                    .frame(width: 292, height: 34)
                    .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
            }
            SettingDivider()
            SettingRow(icon: "link.badge.plus", title: "语音 Endpoint", detail: "留空使用 DashScope SpeechSynthesizer 接口。") {
                TextField(SpeechService.defaultEndpoint, text: $ttsBaseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppUI.FontSize.small, design: .monospaced))
                    .padding(.horizontal, AppUI.Space.s)
                    .frame(width: 292, height: 34)
                    .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
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
                .frame(width: 252)
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
                .frame(width: 252)
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
                .frame(width: 252)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: AppUI.Space.m) {
            Text("配置文件：\(configPath)")
                .font(.system(size: AppUI.FontSize.micro, design: .monospaced))
                .foregroundStyle(AppUI.textMuted)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: AppUI.Space.s) {
                Text(statusText)
                    .font(.system(size: AppUI.FontSize.small, weight: .medium))
                    .foregroundStyle(AppUI.teal)
                Spacer()
                Button("关闭") {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .tint(AppUI.accent)
            }
        }
        .padding(AppUI.Space.l)
        .appSurface(background: AppUI.surfaceSoft)
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
            theme: theme
        ))
        statusText = "已保存 \(timestamp())"
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

private struct SummaryItem: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: AppUI.Space.s) {
            SymbolBadge(symbol: icon, tint: AppUI.accent, background: AppUI.activeToolbar, size: 30)
            VStack(alignment: .leading, spacing: AppUI.Space.xs) {
                Text(title)
                    .font(.system(size: AppUI.FontSize.mini, weight: .bold))
                    .foregroundStyle(AppUI.textMuted)
                Text(value)
                    .font(.system(size: AppUI.FontSize.base, weight: .semibold))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    .font(.system(size: AppUI.FontSize.section, weight: .bold))
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
                        .font(.system(size: AppUI.FontSize.base, weight: .bold))
                        .foregroundStyle(AppUI.textPrimary)
                    Text(detail)
                        .font(.system(size: AppUI.FontSize.small))
                        .foregroundStyle(AppUI.textSecondary)
                        .lineLimit(2)
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
