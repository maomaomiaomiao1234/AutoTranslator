import SwiftUI

struct PreferencesSnapshot {
    var backend: String
    var apiKey: String
    var model: String
    var baseURL: String
    var sourceLang: String
    var targetLang: String
    var theme: Theme
}

struct PreferencesSavePayload {
    let backend: String
    let apiKey: String?
    let model: String?
    let baseURL: String?
    let sourceLang: String
    let targetLang: String
    let theme: Theme
}

struct PreferencesView: View {
    @State private var backend: String
    @State private var apiKey: String
    @State private var model: String
    @State private var baseURL: String
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
        _sourceLang = State(initialValue: snapshot.sourceLang)
        _targetLang = State(initialValue: snapshot.targetLang)
        _theme = State(initialValue: snapshot.theme)
        self.configPath = configPath
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            summaryPanel
            ScrollView {
                VStack(spacing: 16) {
                    engineSection
                    languageSection
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)
            footer
        }
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 640, height: 620)
        .background(AppUI.panelBottom)
    }

    private var header: some View {
        HStack(spacing: 14) {
            SymbolBadge(
                symbol: "slider.horizontal.3",
                tint: AppUI.accent,
                background: AppUI.activeToolbar,
                size: 44
            )
            VStack(alignment: .leading, spacing: 5) {
                Text("偏好配置")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(AppUI.textPrimary)
                Text("管理划词后的翻译行为、默认语言和浮窗外观。")
                    .font(.system(size: 13))
                    .foregroundStyle(AppUI.textSecondary)
            }
            Spacer()
        }
    }

    private var summaryPanel: some View {
        HStack(spacing: 12) {
            SummaryItem(icon: "bolt.horizontal", title: "引擎", value: backend == "google" ? "Google" : "大模型")
            SummaryItem(icon: "arrow.left.arrow.right", title: "语言", value: "\(Languages.name(for: sourceLang)) → \(Languages.name(for: targetLang))")
            SummaryItem(icon: "circle.lefthalf.filled", title: "主题", value: theme.displayName)
        }
        .padding(16)
        .appSurface(shadow: true)
    }

    private var engineSection: some View {
        SettingsSection(title: "翻译引擎", subtitle: "Google 更轻量；大模型更适合长句和语气改写。") {
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
            SettingRow(icon: "key", title: "API Key", detail: "仅大模型后端需要；留空时会回退到 Google。") {
                SecureField("sk-... (DeepSeek / DashScope)", text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(width: 292, height: 34)
                    .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
            }
            SettingDivider()
            SettingRow(icon: "cube", title: "Model", detail: "留空使用默认模型。") {
                TextField(LLMTranslator.defaultModel, text: $model)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .frame(width: 292, height: 34)
                    .appSurface(background: AppUI.surfaceSoft, radius: AppUI.controlRadius, border: AppUI.buttonBorder)
            }
            SettingDivider()
            SettingRow(icon: "link", title: "Base URL", detail: "填到 /v1 即可，代码会自动拼接接口路径。") {
                TextField(LLMTranslator.defaultBaseURL, text: $baseURL)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
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
        VStack(spacing: 12) {
            Text("配置文件：\(configPath)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AppUI.textMuted)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
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
        .padding(16)
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

        onSave(PreferencesSavePayload(
            backend: backend,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
            model: trimmedModel.isEmpty ? nil : trimmedModel,
            baseURL: trimmedBaseURL.isEmpty ? nil : trimmedBaseURL,
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
        HStack(spacing: 10) {
            SymbolBadge(symbol: icon, tint: AppUI.accent, background: AppUI.activeToolbar, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppUI.textMuted)
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15.5, weight: .bold))
                    .foregroundStyle(AppUI.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AppUI.textSecondary)
            }
            content
        }
        .padding(18)
        .appSurface(shadow: true)
    }
}

private struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                SymbolBadge(symbol: icon, tint: AppUI.textSecondary, background: AppUI.surfaceSoft, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(AppUI.textPrimary)
                    Text(detail)
                        .font(.system(size: 11.5))
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
