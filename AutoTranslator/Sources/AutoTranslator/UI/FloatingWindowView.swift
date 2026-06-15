import SwiftUI
import Combine

enum FloatingPresentation {
    case translation
    case dictionary
    case systemDictionary

    var isDictionary: Bool {
        switch self {
        case .dictionary, .systemDictionary:
            return true
        case .translation:
            return false
        }
    }
}

final class FloatingWindowViewModel: ObservableObject {
    @Published var sourceText = ""
    @Published var destText = ""
    @Published var backend = "google"
    @Published var presentation: FloatingPresentation = .translation
    @Published var isPinned = false
    @Published var state: TranslationState = .idle
    @Published var errorStatusText = "翻译失败"
    @Published var sourceOptions: [String] = []
    @Published var targetOptions: [String] = []
    @Published var selectedSource = "自动检测"
    @Published var selectedTarget = "中文简体"
    @Published var appearanceVersion = 0
    @Published var sourceCardHeight: CGFloat = SOURCE_CARD_MIN_HEIGHT
    @Published var speechState: SpeechPlaybackState = .idle

    var onPin: (() -> Void)?
    var onCopySource: (() -> Void)?
    var onCopyDest: (() -> Void)?
    var onSpeakSource: (() -> Void)?
    var onToggleBackend: (() -> Void)?
    var onScreenshotTranslation: (() -> Void)?
    var onHide: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onSwapLanguages: (() -> Void)?
    var onSourceLineCountChanged: ((Int) -> Void)?
    var onSourceResizeEnded: (() -> Void)?
    var onSourceResizeInteractionChanged: ((Bool) -> Void)?
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
        switch presentation {
        case .translation:
            return "\(selectedSource) → \(selectedTarget) · \(backend == "llm" ? "大模型" : "Google")"
        case .dictionary:
            return "\(selectedSource) → \(selectedTarget) · 词典解释"
        case .systemDictionary:
            return "\(selectedSource) → \(selectedTarget) · 本地词典"
        }
    }

    var sourceMeta: String {
        let count = sourceText.trimmingCharacters(in: .whitespacesAndNewlines).count
        return count > 0 ? "\(count) 字符" : "等待选中"
    }

    var canCopySource: Bool { !sourceText.isEmpty }
    var canSpeakSource: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isSpeechBusy: Bool { speechState == .preparing }
    var canCopyDest: Bool { !destText.isEmpty }
    var canRefresh: Bool { !sourceText.isEmpty }
    var canSwap: Bool { selectedSource != "自动检测" }
    var canToggleBackend: Bool { presentation == .translation }
    var destinationTitle: String {
        switch presentation {
        case .translation:
            return backendDisplayName
        case .dictionary:
            return "词典解释"
        case .systemDictionary:
            return "系统词典"
        }
    }
    var destinationTint: Color {
        switch presentation {
        case .translation:
            return backendTint
        case .dictionary:
            return AppUI.teal
        case .systemDictionary:
            return AppUI.accent
        }
    }
    var destinationBadgeText: String {
        switch presentation {
        case .translation:
            return backendBadgeText
        case .dictionary:
            return "Aa"
        case .systemDictionary:
            return "辞"
        }
    }
    var sourceVisibleLineCount: Int {
        let textHeight = max(SOURCE_TEXT_MIN_HEIGHT, sourceCardHeight - SOURCE_CARD_CHROME_HEIGHT)
        return max(minSourceLineCount, Int((textHeight / SOURCE_TEXT_LINE_HEIGHT).rounded(.down)))
    }
    var minSourceLineCount: Int {
        max(1, Int((SOURCE_TEXT_MIN_HEIGHT / SOURCE_TEXT_LINE_HEIGHT).rounded(.up)))
    }
    var maxSourceLineCount: Int {
        max(minSourceLineCount, Int((SOURCE_TEXT_MAX_HEIGHT / SOURCE_TEXT_LINE_HEIGHT).rounded(.down)))
    }

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
    @State private var sourceResizeStartHeight: CGFloat?
    @State private var sourceResizeLastLineCount: Int?
    @State private var isHoveringSourceResizeHandle = false
    @State private var sourceResizePreviewLineCount: Int?

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
                .padding(.leading, AppUI.Space.l)
                .padding(.top, AppUI.Space.xs)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppUI.panelRadius, style: .continuous)
                .stroke(AppUI.panelBorder, lineWidth: 1)
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .padding(.trailing, AppUI.Space.s)
                .padding(.bottom, AppUI.Space.s)
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
        VStack(spacing: AppUI.Space.s) {
            HStack(spacing: AppUI.Space.m) {
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

                VStack(alignment: .leading, spacing: AppUI.Space.xs) {
                    Text("划词翻译")
                        .font(.system(size: AppUI.FontSize.title, weight: .bold))
                        .foregroundStyle(AppUI.textPrimary)
                    Text(model.headerSubtitle)
                        .font(.system(size: AppUI.FontSize.small))
                        .foregroundStyle(AppUI.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button { model.onScreenshotTranslation?() } label: {
                    Image(systemName: "text.viewfinder")
                }
                .buttonStyle(IconButtonStyle(
                    tint: AppUI.accent,
                    background: AppUI.activeToolbar,
                    border: AppUI.activeToolbarBorder
                ))
                .help("截图翻译")

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
        VStack(alignment: .leading, spacing: AppUI.Space.s) {
            HStack(spacing: AppUI.Space.s) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: AppUI.FontSize.small, weight: .semibold))
                    .foregroundStyle(AppUI.accent)
                    .frame(width: 22, height: 22)
                    .background(AppUI.activeToolbar)
                    .clipShape(RoundedRectangle(cornerRadius: AppUI.Radius.chip, style: .continuous))

                Text("原文")
                    .font(.system(size: AppUI.FontSize.mini, weight: .bold))
                    .foregroundStyle(AppUI.textPrimary)

                Chip(text: model.sourceMeta)

                if model.speechState.isVisible {
                    SpeechStatusChip(state: model.speechState)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

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

                Button { model.onSpeakSource?() } label: {
                    speechButtonLabel
                }
                .buttonStyle(IconButtonStyle(
                    tint: speechButtonTint,
                    background: speechButtonBackground,
                    border: speechButtonBorder,
                    size: 24
                ))
                .disabled(!model.canSpeakSource || model.isSpeechBusy)
                .opacity(model.canSpeakSource ? 1 : 0.36)
                .help(model.speechState.helpText)
            }
            .animation(.easeInOut(duration: 0.16), value: model.speechState)

            ScrollView {
                Text(model.sourceText.isEmpty ? " " : model.sourceText)
                    .font(.system(size: SOURCE_FONT_SIZE, weight: .regular))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, AppUI.Space.xxs)
            }
            .frame(height: sourceTextAreaHeight)

            sourceResizeHandle
        }
        .padding(.horizontal, AppUI.Space.l)
        .padding(.vertical, AppUI.Space.m)
        .frame(height: model.sourceCardHeight, alignment: .top)
        .appSurface(background: Color(nsColor: SOURCE_CARD_BG), shadow: true)
    }

    @ViewBuilder
    private var speechButtonLabel: some View {
        if model.speechState == .preparing {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.55)
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: model.speechState.buttonSymbol)
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var speechButtonTint: Color {
        switch model.speechState {
        case .idle:
            return AppUI.accent
        case .preparing, .playing:
            return AppUI.teal
        case .failed:
            return AppUI.accent
        }
    }

    private var speechButtonBackground: Color {
        switch model.speechState {
        case .idle:
            return AppUI.activeToolbar
        case .preparing, .playing:
            return AppUI.chipTeal
        case .failed:
            return AppUI.chipWarm
        }
    }

    private var speechButtonBorder: Color {
        switch model.speechState {
        case .idle:
            return AppUI.activeToolbarBorder
        case .preparing, .playing:
            return AppUI.teal.opacity(isDarkMode ? 0.34 : 0.26)
        case .failed:
            return AppUI.activeToolbarBorder
        }
    }

    private var sourceTextAreaHeight: CGFloat {
        max(SOURCE_TEXT_MIN_HEIGHT, model.sourceCardHeight - SOURCE_CARD_CHROME_HEIGHT)
    }

    private var sourceResizeHandle: some View {
        HStack(spacing: AppUI.Space.s) {
            sourceLineButton(systemName: "minus", targetLineCount: displayedSourceLineCount - 1)

            sourceDragHandle

            sourceLineButton(systemName: "plus", targetLineCount: displayedSourceLineCount + 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: SOURCE_RESIZE_HANDLE_HEIGHT)
        .help("拖动调整原文显示行数")
    }

    private var sourceDragHandle: some View {
        HStack(spacing: AppUI.Space.s) {
            Capsule()
                .fill(AppUI.textMuted.opacity(isDarkMode ? 0.48 : 0.40))
                .frame(width: 44, height: 3)

            Text("\(displayedSourceLineCount) 行")
                .font(.system(size: AppUI.FontSize.micro, weight: .semibold))
                .foregroundStyle(sourceResizePreviewLineCount == nil ? AppUI.textMuted : AppUI.accent)
                .monospacedDigit()

            Image(systemName: "arrow.up.and.down")
                .font(.system(size: AppUI.FontSize.micro, weight: .semibold))
                .foregroundStyle(AppUI.textMuted.opacity(0.78))
        }
        .frame(maxWidth: .infinity)
        .frame(height: SOURCE_RESIZE_HANDLE_HEIGHT)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHoveringSourceResizeHandle = hovering
            model.onSourceResizeInteractionChanged?(hovering || sourceResizeStartHeight != nil)
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let startHeight = sourceResizeStartHeight ?? model.sourceCardHeight
                    if sourceResizeStartHeight == nil {
                        sourceResizeStartHeight = startHeight
                        sourceResizeLastLineCount = model.sourceVisibleLineCount
                        model.onSourceResizeInteractionChanged?(true)
                    }
                    let proposedLineCount = sourceLineCount(for: startHeight + value.translation.height)
                    guard proposedLineCount != sourceResizeLastLineCount else { return }
                    sourceResizeLastLineCount = proposedLineCount
                    sourceResizePreviewLineCount = proposedLineCount
                }
                .onEnded { _ in
                    if let previewLineCount = sourceResizePreviewLineCount {
                        model.onSourceLineCountChanged?(previewLineCount)
                    }
                    sourceResizeStartHeight = nil
                    sourceResizeLastLineCount = nil
                    sourceResizePreviewLineCount = nil
                    model.onSourceResizeEnded?()
                    model.onSourceResizeInteractionChanged?(isHoveringSourceResizeHandle)
                }
        )
        .help("拖动调整原文显示行数")
    }

    private var displayedSourceLineCount: Int {
        sourceResizePreviewLineCount ?? model.sourceVisibleLineCount
    }

    private func sourceLineButton(systemName: String, targetLineCount: Int) -> some View {
        let clampedTarget = min(model.maxSourceLineCount, max(model.minSourceLineCount, targetLineCount))
        let enabled = clampedTarget != displayedSourceLineCount
        return Button {
            model.onSourceLineCountChanged?(clampedTarget)
            model.onSourceResizeEnded?()
        } label: {
            Image(systemName: systemName)
        }
        .buttonStyle(IconButtonStyle(tint: AppUI.textMuted, size: 28))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.34)
        .help(systemName == "plus" ? "增加原文显示行数" : "减少原文显示行数")
    }

    private func sourceLineCount(for proposedHeight: CGFloat) -> Int {
        let rawTextHeight = proposedHeight - SOURCE_CARD_CHROME_HEIGHT
        let lineCount = Int((rawTextHeight / SOURCE_TEXT_LINE_HEIGHT).rounded())
        return min(model.maxSourceLineCount, max(model.minSourceLineCount, lineCount))
    }

    private var languageBar: some View {
        HStack(spacing: AppUI.Space.m) {
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
        .padding(.horizontal, AppUI.Space.l)
        .frame(height: LANG_BAR_HEIGHT)
        .appSurface(background: Color(nsColor: LANG_BAR_BG))
    }

    private var destinationCard: some View {
        VStack(spacing: AppUI.Space.s) {
            HStack(spacing: AppUI.Space.s) {
                Text(model.destinationBadgeText)
                    .font(.system(size: AppUI.FontSize.micro, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(model.destinationTint)
                    .clipShape(RoundedRectangle(cornerRadius: AppUI.Radius.chip, style: .continuous))

                Text(model.destinationTitle)
                    .font(.system(size: AppUI.FontSize.base, weight: .bold))
                    .foregroundStyle(AppUI.textPrimary)

                Spacer()

                stateChip

                if model.canToggleBackend {
                    Button { model.onToggleBackend?() } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(IconButtonStyle(tint: AppUI.textSecondary, size: 24))
                    .help("切换翻译后端")
                }
            }

            ScrollView {
                destinationContent
            }
            .frame(minHeight: DEST_TEXT_MIN_HEIGHT, maxHeight: .infinity)

            HStack(spacing: AppUI.Space.s) {
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
        .padding(.horizontal, AppUI.Space.l)
        .padding(.vertical, AppUI.Space.m)
        .frame(minHeight: DEST_CARD_MIN_HEIGHT, maxHeight: .infinity, alignment: .top)
        .appSurface(background: Color(nsColor: DEST_CARD_BG), shadow: true)
    }

    @ViewBuilder
    private var destinationContent: some View {
        if model.presentation.isDictionary,
           model.state == .done,
           !model.destText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            DictionaryDefinitionView(word: model.sourceText, definition: model.destText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            Text(model.destText.isEmpty ? "正在翻译..." : model.destText)
                .font(.system(size: BODY_FONT_SIZE))
                .foregroundStyle(destTextColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var stateChip: some View {
        switch model.state {
        case .done:
            if model.presentation == .systemDictionary {
                return Chip(text: "本地", foreground: AppUI.teal, background: AppUI.chipTeal)
            }
            if model.presentation == .dictionary {
                return Chip(text: "词典", foreground: AppUI.teal, background: AppUI.chipTeal)
            }
            return Chip(text: "已完成", foreground: AppUI.teal, background: AppUI.chipTeal)
        case .loading:
            return Chip(text: model.presentation.isDictionary ? "查询中" : "翻译中",
                        foreground: AppUI.amber,
                        background: AppUI.chipWarm)
        case .idle:
            return Chip(text: "待翻译", foreground: AppUI.textMuted, background: AppUI.surfaceSoft)
        case .error:
            return Chip(text: model.errorStatusText, foreground: AppUI.accent, background: AppUI.chipWarm)
        }
    }

    private var destTextColor: Color {
        switch model.state {
        case .loading: return AppUI.textMuted
        case .error: return AppUI.accent
        default: return AppUI.textPrimary
        }
    }
}

enum TranslationState {
    case idle, loading, done, error
}

enum SpeechPlaybackState: Equatable {
    case idle
    case preparing
    case playing
    case failed

    var isVisible: Bool {
        self != .idle
    }

    var label: String {
        switch self {
        case .idle:
            return ""
        case .preparing:
            return "生成中"
        case .playing:
            return "播放中"
        case .failed:
            return "失败"
        }
    }

    var buttonSymbol: String {
        switch self {
        case .idle:
            return "speaker.wave.2"
        case .preparing:
            return "speaker.wave.2"
        case .playing:
            return "speaker.wave.3.fill"
        case .failed:
            return "exclamationmark"
        }
    }

    var helpText: String {
        switch self {
        case .idle:
            return "播放发音"
        case .preparing:
            return "正在生成语音"
        case .playing:
            return "正在播放"
        case .failed:
            return "发音失败"
        }
    }
}

private struct SpeechStatusChip: View {
    let state: SpeechPlaybackState

    var body: some View {
        HStack(spacing: AppUI.Space.xs) {
            if state == .preparing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.45)
                    .frame(width: 10, height: 10)
                    .tint(foreground)
            } else {
                Image(systemName: state.buttonSymbol)
                    .font(.system(size: 9, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
            }

            Text(state.label)
                .font(.system(size: AppUI.FontSize.micro, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, AppUI.Space.s)
        .frame(height: 20)
        .background(background)
        .clipShape(Capsule())
        .accessibilityLabel(state.helpText)
    }

    private var foreground: Color {
        switch state {
        case .idle:
            return AppUI.textMuted
        case .preparing, .playing:
            return AppUI.teal
        case .failed:
            return AppUI.accent
        }
    }

    private var background: Color {
        switch state {
        case .idle:
            return AppUI.surfaceSoft
        case .preparing, .playing:
            return AppUI.chipTeal
        case .failed:
            return AppUI.chipWarm
        }
    }
}

private struct DictionaryDefinitionView: View {
    let entry: DictionaryDisplayEntry

    init(word: String, definition: String) {
        entry = DictionaryDefinitionFormatter.entry(word: word, definition: definition)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Space.m) {
            heading

            VStack(alignment: .leading, spacing: AppUI.Space.s) {
                ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
        }
        .padding(.top, AppUI.Space.xs)
        .padding(.bottom, AppUI.Space.s)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: AppUI.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppUI.Space.s) {
                Text(entry.title)
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let pronunciation = entry.pronunciation {
                    Text(pronunciation)
                        .font(.system(size: AppUI.FontSize.base, weight: .medium))
                        .foregroundStyle(AppUI.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Rectangle()
                .fill(AppUI.cardBorder)
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func lineView(_ line: DictionaryDisplayEntry.Line) -> some View {
        switch line.kind {
        case .section:
            Text(line.text)
                .font(.system(size: AppUI.FontSize.base, weight: .semibold))
                .foregroundStyle(AppUI.accent)
                .textCase(.none)
                .padding(.top, AppUI.Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .sense:
            HStack(alignment: .firstTextBaseline, spacing: AppUI.Space.s) {
                Text(line.marker ?? "")
                    .font(.system(size: AppUI.FontSize.base, weight: .bold))
                    .foregroundStyle(AppUI.accent)
                    .frame(width: 18, alignment: .leading)

                Text(line.value ?? line.text)
                    .font(.system(size: DICTIONARY_BODY_FONT_SIZE, weight: .regular))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .example:
            HStack(alignment: .firstTextBaseline, spacing: AppUI.Space.s) {
                Text(line.marker ?? "▸")
                    .font(.system(size: AppUI.FontSize.small, weight: .bold))
                    .foregroundStyle(AppUI.textMuted)
                    .frame(width: 18, alignment: .leading)

                Text(line.value ?? line.text)
                    .font(.system(size: DICTIONARY_BODY_FONT_SIZE, weight: .medium))
                    .foregroundStyle(AppUI.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 18)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .keyValue:
            HStack(alignment: .firstTextBaseline, spacing: AppUI.Space.m) {
                Text(line.key ?? "")
                    .font(.system(size: AppUI.FontSize.small, weight: .semibold))
                    .foregroundStyle(AppUI.textMuted)
                    .frame(width: 42, alignment: .leading)

                Text(line.value ?? line.text)
                    .font(.system(size: DICTIONARY_BODY_FONT_SIZE, weight: .regular))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .body:
            Text(line.text)
                .font(.system(size: DICTIONARY_BODY_FONT_SIZE, weight: .regular))
                .foregroundStyle(AppUI.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
