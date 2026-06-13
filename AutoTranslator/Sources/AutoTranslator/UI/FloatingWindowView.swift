import SwiftUI
import Combine

final class FloatingWindowViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var destText = ""
    @Published var backend = "google"
    @Published var isPinned = false
    @Published var state: TranslationState = .idle
    @Published var sourceOptions: [String] = []
    @Published var targetOptions: [String] = []
    @Published var selectedSource = "自动检测"
    @Published var selectedTarget = "中文简体"
    @Published var appearanceVersion = 0
    @Published var sourceCardHeight: CGFloat = SOURCE_CARD_MIN_HEIGHT

    var onPin: (() -> Void)?
    var onCopySource: (() -> Void)?
    var onCopyDest: (() -> Void)?
    var onToggleBackend: (() -> Void)?
    var onHide: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSwapLanguages: (() -> Void)?
    var onLanguageChanged: ((String, String) -> Void)?

    var backendDisplayName: String {
        backend == "llm" ? "大模型翻译" : "Google 翻译"
    }

    var backendBadgeText: String {
        backend == "llm" ? "AI" : "G"
    }

    var backendTint: Color {
        backend == "llm" ? AppUI.teal : AppUI.blue
    }

    var headerSubtitle: String {
        "\(selectedSource) → \(selectedTarget) · \(backend == "llm" ? "大模型" : "Google")"
    }

    var sourceMeta: String {
        let count = sourceText.trimmingCharacters(in: .whitespacesAndNewlines).count
        return count > 0 ? "\(count) 字符" : "等待选中"
    }

    var canCopySource: Bool { !sourceText.isEmpty }
    var canCopyDest: Bool { !destText.isEmpty }
    var canRefresh: Bool { !sourceText.isEmpty }
    var canSwap: Bool { selectedSource != "自动检测" }

    func selectSource(_ value: String) {
        selectedSource = value
        onLanguageChanged?(selectedSource, selectedTarget)
    }

    func selectTarget(_ value: String) {
        selectedTarget = value
        onLanguageChanged?(selectedSource, selectedTarget)
    }
}

struct FloatingWindowView: View {
    @ObservedObject var model: FloatingWindowViewModel

    var body: some View {
        let _ = model.appearanceVersion
        VStack(spacing: AppUI.sectionGap) {
            header
            sourceCard
            languageBar
            destinationCard
        }
        .padding(AppUI.outerPadding)
        .frame(minWidth: MIN_WINDOW_WIDTH, maxWidth: MAX_WINDOW_WIDTH)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppUI.panelRadius, style: .continuous))
        .overlay(alignment: .topLeading) {
            Capsule()
                .fill(AppUI.accent.opacity(isDarkMode ? 0.72 : 0.84))
                .frame(width: 116, height: 3)
                .padding(.leading, 16)
                .padding(.top, 4)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppUI.panelRadius, style: .continuous)
                .stroke(AppUI.panelBorder, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .padding(.trailing, 7)
                .padding(.bottom, 7)
        }
    }

    private var panelBackground: some View {
        LinearGradient(
            colors: [AppUI.panelTop, AppUI.panelBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    model.onPin?()
                } label: {
                    Image(systemName: "pin.fill")
                }
                .buttonStyle(IconButtonStyle(
                    tint: model.isPinned ? AppUI.accent : AppUI.textSecondary,
                    background: model.isPinned ? AppUI.activeToolbar : AppUI.toolbarGhost,
                    border: model.isPinned ? AppUI.activeToolbarBorder : AppUI.buttonBorder
                ))
                .help("固定窗口")

                VStack(alignment: .leading, spacing: 3) {
                    Text("划词翻译")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(AppUI.textPrimary)
                    Text(model.headerSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppUI.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button { model.onCopySource?() } label: {
                    Image(systemName: "text.quote")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!model.canCopySource)
                .opacity(model.canCopySource ? 1 : 0.36)
                .help("复制原文")

                Button { model.onCopyDest?() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!model.canCopyDest)
                .opacity(model.canCopyDest ? 1 : 0.36)
                .help("复制译文")

                Button { model.onToggleBackend?() } label: {
                    Text(model.backend == "llm" ? "AI" : "G")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(IconButtonStyle(
                    tint: model.backend == "llm" ? AppUI.teal : AppUI.textSecondary,
                    background: model.backend == "llm" ? AppUI.chipTeal : AppUI.toolbarGhost,
                    size: TOOLBAR_BUTTON_SIZE,
                    pillWidth: BACKEND_BTN_WIDTH
                ))
                .help("切换翻译后端")

                Button { model.onHide?() } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .help("隐藏窗口")
            }

            Rectangle()
                .fill(Color(nsColor: PANEL_HAIRLINE))
                .frame(height: 1)
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppUI.accent)
                    .frame(width: 22, height: 22)
                    .background(AppUI.activeToolbar)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text("原文")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppUI.textPrimary)

                Chip(text: model.sourceMeta)

                Spacer(minLength: 8)

                Chip(
                    text: model.selectedSource,
                    foreground: model.selectedSource == "自动检测" ? AppUI.textSecondary : AppUI.blue,
                    background: model.selectedSource == "自动检测" ? AppUI.surfaceSoft : AppUI.chipBlue
                )

                Button { model.onCopySource?() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle(tint: AppUI.textSecondary, size: 24))
                .disabled(!model.canCopySource)
                .opacity(model.canCopySource ? 1 : 0.36)
                .help("复制原文")
            }

            ScrollView {
                Text(model.sourceText.isEmpty ? " " : model.sourceText)
                    .font(.system(size: SOURCE_FONT_SIZE, weight: .regular))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 2)
            }
            .frame(height: sourceTextAreaHeight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(height: model.sourceCardHeight, alignment: .top)
        .appSurface(background: Color(nsColor: SOURCE_CARD_BG), shadow: true)
    }

    private var sourceTextAreaHeight: CGFloat {
        max(SOURCE_TEXT_MIN_HEIGHT, model.sourceCardHeight - SOURCE_CARD_CHROME_HEIGHT)
    }

    private var languageBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(
                get: { model.selectedSource },
                set: { model.selectSource($0) }
            )) {
                ForEach(model.sourceOptions, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Button { model.onSwapLanguages?() } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(IconButtonStyle(tint: AppUI.textPrimary, size: 28))
            .disabled(!model.canSwap)
            .opacity(model.canSwap ? 1 : 0.36)
            .help("互换语言")

            Picker("", selection: Binding(
                get: { model.selectedTarget },
                set: { model.selectTarget($0) }
            )) {
                ForEach(model.targetOptions, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 16)
        .frame(height: LANG_BAR_HEIGHT)
        .appSurface(background: Color(nsColor: LANG_BAR_BG))
    }

    private var destinationCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(model.backendBadgeText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(model.backendTint)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(model.backendDisplayName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppUI.textPrimary)

                Spacer()

                stateChip

                Button { model.onToggleBackend?() } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(IconButtonStyle(tint: AppUI.textSecondary, size: 24))
                .help("切换翻译后端")
            }

            ScrollView {
                Text(model.destText.isEmpty ? "正在翻译..." : model.destText)
                    .font(.system(size: BODY_FONT_SIZE))
                    .foregroundStyle(model.state == .loading ? AppUI.textMuted : AppUI.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 64, maxHeight: .infinity)

            HStack(spacing: 8) {
                Button { model.onCopyDest?() } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(IconButtonStyle(tint: AppUI.textPrimary, size: 24))
                .disabled(!model.canCopyDest)
                .opacity(model.canCopyDest ? 1 : 0.36)
                .help("复制译文")

                Button { model.onRefresh?() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle(tint: AppUI.textPrimary, size: 24))
                .disabled(!model.canRefresh)
                .opacity(model.canRefresh ? 1 : 0.36)
                .help("重新翻译")

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: DEST_CARD_MIN_HEIGHT, maxHeight: .infinity, alignment: .top)
        .appSurface(background: Color(nsColor: DEST_CARD_BG), shadow: true)
    }

    private var stateChip: some View {
        switch model.state {
        case .done:
            return Chip(text: "已完成", foreground: AppUI.teal, background: AppUI.chipTeal)
        case .loading:
            return Chip(text: "翻译中", foreground: AppUI.amber, background: AppUI.chipWarm)
        case .idle:
            return Chip(text: "待翻译", foreground: AppUI.textMuted, background: AppUI.surfaceSoft)
        }
    }
}

enum TranslationState {
    case idle, loading, done
}
