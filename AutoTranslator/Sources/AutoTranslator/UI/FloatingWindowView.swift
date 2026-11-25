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
    @Published var windowMode: FloatingWindowMode = .standard
    @Published var isFavorite = false
    @Published var canFavorite = false
    /// 自增以请求把焦点切到原文编辑框（菜单「翻译输入」唤出空白浮窗时使用）。
    @Published var sourceFocusRequest = 0

    var onPin: (() -> Void)?
    var onCopySource: (() -> Void)?
    var onCopyDest: (() -> Void)?
    var onSpeakSource: (() -> Void)?
    var onToggleBackend: (() -> Void)?
    var onSelectBackend: ((String) -> Void)?
    var onScreenshotTranslation: (() -> Void)?
    var onOverlayTranslation: (() -> Void)?
    var onHide: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onToggleWindowMode: (() -> Void)?
    var onSwapLanguages: (() -> Void)?
    var onSourceLineCountChanged: ((Int) -> Void)?
    var onSourceResizeEnded: (() -> Void)?
    var onSourceResizeInteractionChanged: ((Bool) -> Void)?
    var onLanguageChanged: ((String, String) -> Void)?
    /// 用户提交（编辑后的）原文以发起翻译。
    var onSubmitSource: (() -> Void)?
    /// 用户在原文框内编辑文本时同步到窗口侧（保持复制/朗读读到最新文本）。
    var onSourceEdited: ((String) -> Void)?

    var availableBackends: [(id: String, name: String)] {
        var items: [(id: String, name: String)] = [
            (TranslationBackend.llm, TranslationBackend.displayName(TranslationBackend.llm)),
            (TranslationBackend.google, TranslationBackend.displayName(TranslationBackend.google)),
        ]
        if TranslationBackend.isAppleAvailable {
            items.append((TranslationBackend.apple, TranslationBackend.displayName(TranslationBackend.apple)))
        }
        return items
    }

    var backendTint: Color {
        switch backend {
        case TranslationBackend.llm: return AppUI.teal
        case TranslationBackend.apple: return AppUI.accent
        default: return AppUI.blue
        }
    }

    var compactEngineLabel: String {
        switch presentation {
        case .translation:
            return TranslationBackend.shortName(backend)
        case .dictionary:
            return "词典"
        case .systemDictionary:
            return "本地词典"
        }
    }

    var destinationTitle: String {
        switch presentation {
        case .translation:
            return TranslationBackend.displayName(backend)
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

    var copyableDestText: String {
        presentation.isDictionary
            ? DictionaryDefinitionFormatter.measurementText(word: sourceText, definition: destText)
            : destText
    }

    var canCopySource: Bool { !sourceText.isEmpty }
    var canSpeakSource: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var canSubmitSource: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isSpeechBusy: Bool { speechState == .preparing }
    var canCopyDest: Bool { !destText.isEmpty && !isAwaitingTranslation }
    var canRefresh: Bool { !sourceText.isEmpty }
    var canSwap: Bool { selectedSource != "自动检测" }
    var canToggleBackend: Bool { presentation == .translation }

    /// 词典结果是否就绪（切换到词典排版而非纯译文展示）。
    var isDictionaryResult: Bool {
        presentation.isDictionary
            && state == .done
            && !destText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否仍在等待首批译文（占位符阶段，尚无流式内容）。
    var isAwaitingTranslation: Bool {
        guard state == .loading else { return false }
        let trimmed = destText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "正在翻译..."
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

    func selectBackend(_ id: String) {
        if let onSelectBackend {
            onSelectBackend(id)
        } else {
            onToggleBackend?()
        }
    }
}

struct FloatingWindowView: View {
    @ObservedObject var model: FloatingWindowViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSourceFocused: Bool
    @State private var sourceResizeStartHeight: CGFloat?
    @State private var sourceResizeLastLineCount: Int?
    @State private var isHoveringSourceSection = false
    @State private var isHoveringSourceResizeHandle = false
    @State private var isHoveringMinimalWindow = false
    @State private var sourceResizePreviewLineCount: Int?
    @State private var swapRotationAngle: Double = 0
    @State private var refreshRotationAngle: Double = 0

    var body: some View {
        let _ = model.appearanceVersion
        Group {
            if model.windowMode == .minimal {
                minimalBody
            } else {
                standardBody
            }
        }
    }

    // MARK: - Standard Mode

    private var standardBody: some View {
        VStack(spacing: 0) {
            header
            Spacer().frame(height: SECTION_GAP)
            sourceSection
            sourceResizeHandle
            controlBar
            hairlineDivider
            destinationSection
        }
        .padding(.horizontal, OUTER_PADDING)
        .padding(.top, PANEL_TOP_PADDING)
        .padding(.bottom, PANEL_BOTTOM_PADDING)
        .frame(minWidth: MIN_WINDOW_WIDTH, maxWidth: MAX_WINDOW_WIDTH)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppUI.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppUI.panelRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.14 : 0.65),
                            AppUI.panelBorder
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip()
                .padding(.trailing, AppUI.Space.s)
                .padding(.bottom, AppUI.Space.s)
        }
    }

    private var panelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppUI.panelRadius, style: .continuous)
                .fill(.regularMaterial)

            LinearGradient(
                colors: [
                    AppUI.panelTop.opacity(colorScheme == .dark ? 0.90 : 0.92),
                    AppUI.panelBottom.opacity(colorScheme == .dark ? 0.92 : 0.94)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 面板留白与非交互区域的点击直接拖动窗口。
            WindowDragArea()
        }
    }

    private var header: some View {
        HStack(spacing: AppUI.Space.xs) {
            Button {
                model.onPin?()
            } label: {
                Image(systemName: model.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(GhostIconButtonStyle(
                tint: model.isPinned ? AppUI.accent : AppUI.textMuted,
                activeBackground: AppUI.activeToolbar,
                size: TOOLBAR_BUTTON_SIZE,
                isActive: model.isPinned
            ))
            .help(model.isPinned ? "取消固定窗口" : "固定窗口")
            .accessibilityLabel(model.isPinned ? "取消固定窗口" : "固定窗口")

            if model.speechState.isVisible {
                SpeechStatusChip(state: model.speechState)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }

            Spacer(minLength: AppUI.Space.s)

            Button { model.onScreenshotTranslation?() } label: {
                Image(systemName: "text.viewfinder")
            }
            .buttonStyle(GhostIconButtonStyle(tint: AppUI.textSecondary, size: TOOLBAR_BUTTON_SIZE))
            .help("截图翻译")
            .accessibilityLabel("截图翻译")

            Button { model.onOverlayTranslation?() } label: {
                Image(systemName: "photo.on.rectangle.angled")
            }
            .buttonStyle(GhostIconButtonStyle(tint: AppUI.textSecondary, size: TOOLBAR_BUTTON_SIZE))
            .help("贴图翻译（译文贴回原位）")
            .accessibilityLabel("贴图翻译")

            Button { model.onToggleWindowMode?() } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .buttonStyle(GhostIconButtonStyle(tint: AppUI.textSecondary, size: TOOLBAR_BUTTON_SIZE))
            .help("切换到极简模式")
            .accessibilityLabel("切换到极简模式")

            Button { model.onHide?() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(GhostIconButtonStyle(tint: AppUI.textMuted, size: TOOLBAR_BUTTON_SIZE))
            .help("隐藏窗口 (Esc)")
            .accessibilityLabel("隐藏窗口")
        }
        .frame(height: HEADER_HEIGHT)
        .animation(.easeInOut(duration: 0.16), value: model.speechState)
        .background(WindowDragArea())
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: AppUI.Space.xs) {
            ZStack(alignment: .topLeading) {
                if model.sourceText.isEmpty {
                    Text("输入或划选要翻译的文字…")
                        .font(.system(size: SOURCE_FONT_SIZE, weight: .regular))
                        .foregroundStyle(AppUI.textMuted)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(
                    get: { model.sourceText },
                    set: { newValue in
                        model.sourceText = newValue
                        model.onSourceEdited?(newValue)
                    }
                ))
                .font(.system(size: SOURCE_FONT_SIZE, weight: .regular))
                .foregroundStyle(AppUI.textPrimary)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .focused($isSourceFocused)
            }
            .frame(height: sourceTextAreaHeight)
            .onChange(of: model.sourceFocusRequest) { _ in
                DispatchQueue.main.async { isSourceFocused = true }
            }

            HStack(spacing: AppUI.Space.xxs) {
                Spacer(minLength: 8)

                if !model.sourceText.isEmpty && (isHoveringSourceSection || isSourceFocused) {
                    Button {
                        model.sourceText = ""
                        model.onSourceEdited?("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(GhostIconButtonStyle(tint: AppUI.textMuted, size: 22))
                    .help("清空原文")
                    .accessibilityLabel("清空原文")
                    .transition(.opacity)
                }

                CopyFeedbackButton(textToCopy: { model.sourceText }, size: 22, helpText: "复制原文", ghost: true)
                    .disabled(!model.canCopySource)
                    .opacity(model.canCopySource ? 1 : 0.32)

                speakButton(size: 22)

                Button { model.onSubmitSource?() } label: {
                    Image(systemName: "arrow.turn.down.left")
                }
                .buttonStyle(GhostIconButtonStyle(
                    tint: model.canSubmitSource ? AppUI.accent : AppUI.textMuted,
                    activeBackground: AppUI.activeToolbar,
                    size: 22,
                    isActive: isSourceFocused && model.canSubmitSource
                ))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSubmitSource)
                .opacity(model.canSubmitSource ? 1 : 0.32)
                .help("翻译输入的原文（⌘↩）")
                .accessibilityLabel("翻译输入的原文")
            }
            .frame(height: 22)
            .animation(.easeInOut(duration: 0.14), value: isHoveringSourceSection)
            .animation(.easeInOut(duration: 0.16), value: model.speechState)
        }
        .padding(.horizontal, CARD_INSET_X)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .frame(height: model.sourceCardHeight, alignment: .top)
        .background(Color(nsColor: SOURCE_CARD_BG))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSourceFocused ? AppUI.accent.opacity(0.45) : Color(nsColor: SOURCE_CARD_BORDER),
                    lineWidth: 1
                )
        }
        .onHover { isHoveringSourceSection = $0 }
    }

    private var sourceTextAreaHeight: CGFloat {
        max(SOURCE_TEXT_MIN_HEIGHT, model.sourceCardHeight - SOURCE_CARD_CHROME_HEIGHT)
    }

    private var sourceResizeHandle: some View {
        ZStack {
            Capsule()
                .fill(
                    sourceResizePreviewLineCount != nil || isHoveringSourceResizeHandle
                        ? AppUI.accent.opacity(0.55)
                        : AppUI.textMuted.opacity(colorScheme == .dark ? 0.24 : 0.18)
                )
                .frame(
                    width: isHoveringSourceResizeHandle || sourceResizePreviewLineCount != nil ? 40 : 28,
                    height: 3
                )

            if isHoveringSourceResizeHandle || sourceResizePreviewLineCount != nil {
                Text("\(displayedSourceLineCount) 行")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(sourceResizePreviewLineCount == nil ? AppUI.textSecondary : AppUI.accent)
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(AppUI.surface)
                    .clipShape(Capsule())
                    .offset(x: 42)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: SOURCE_RESIZE_HANDLE_HEIGHT)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: isHoveringSourceResizeHandle)
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
        .help("上下拖动调整原文显示行数")
    }

    private var displayedSourceLineCount: Int {
        sourceResizePreviewLineCount ?? model.sourceVisibleLineCount
    }

    private func sourceLineCount(for proposedHeight: CGFloat) -> Int {
        let rawTextHeight = proposedHeight - SOURCE_CARD_CHROME_HEIGHT
        let lineCount = Int((rawTextHeight / SOURCE_TEXT_LINE_HEIGHT).rounded())
        return min(model.maxSourceLineCount, max(model.minSourceLineCount, lineCount))
    }

    private var controlBar: some View {
        HStack(spacing: AppUI.Space.xs) {
            languageMenu(
                title: model.selectedSource,
                options: model.sourceOptions,
                accessibilityLabel: "源语言",
                onSelect: { model.selectSource($0) }
            )

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    swapRotationAngle += 180
                }
                model.onSwapLanguages?()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10.5, weight: .medium))
                    .rotationEffect(.degrees(swapRotationAngle))
            }
            .buttonStyle(GhostIconButtonStyle(tint: AppUI.textSecondary, size: 22))
            .disabled(!model.canSwap)
            .opacity(model.canSwap ? 1 : 0.32)
            .help("互换语言")
            .accessibilityLabel("互换语言")

            languageMenu(
                title: model.selectedTarget,
                options: model.targetOptions,
                accessibilityLabel: "目标语言",
                onSelect: { model.selectTarget($0) }
            )

            Spacer(minLength: AppUI.Space.s)

            backendControl
        }
        .frame(height: LANG_BAR_HEIGHT)
        .background(WindowDragArea())
    }

    private func languageMenu(
        title: String,
        options: [String],
        accessibilityLabel: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if option == title {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: AppUI.FontSize.small, weight: .medium))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(AppUI.textMuted)
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.045))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var backendControl: some View {
        if model.canToggleBackend {
            Menu {
                ForEach(model.availableBackends, id: \.id) { item in
                    Button {
                        model.selectBackend(item.id)
                    } label: {
                        if item.id == model.backend {
                            Label(item.name, systemImage: "checkmark")
                        } else {
                            Text(item.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.destinationTint)
                        .frame(width: 6, height: 6)
                    Text(model.compactEngineLabel)
                        .font(.system(size: AppUI.FontSize.mini, weight: .medium))
                        .foregroundStyle(AppUI.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(AppUI.textMuted)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035))
                .clipShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("切换翻译后端")
            .accessibilityLabel("切换翻译后端，当前：\(model.destinationTitle)")
        } else {
            HStack(spacing: 5) {
                Circle()
                    .fill(model.destinationTint)
                    .frame(width: 6, height: 6)
                Text(model.compactEngineLabel)
                    .font(.system(size: AppUI.FontSize.mini, weight: .medium))
                    .foregroundStyle(AppUI.textMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .allowsHitTesting(false)
            .accessibilityLabel(model.destinationTitle)
        }
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.065))
            .frame(height: 1)
            .allowsHitTesting(false)
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                destinationContent
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
            }
            .frame(minHeight: destinationTextMinHeight, maxHeight: .infinity)

            HStack(spacing: AppUI.Space.xxs) {
                CopyFeedbackButton(
                    textToCopy: { model.copyableDestText },
                    size: 24,
                    helpText: "复制译文",
                    ghost: true
                )
                .disabled(!model.canCopyDest)
                .opacity(model.canCopyDest ? 1 : 0.32)

                Button {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                        refreshRotationAngle += 360
                    }
                    model.onRefresh?()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(refreshRotationAngle))
                }
                .buttonStyle(GhostIconButtonStyle(tint: AppUI.textSecondary, size: 24))
                .disabled(!model.canRefresh)
                .opacity(model.canRefresh ? 1 : 0.32)
                .help("重新翻译")
                .accessibilityLabel("重新翻译")

                favoriteButton(size: 24, inactiveOpacity: 0.32)

                Spacer()
            }
            .frame(height: 24)
            .background(WindowDragArea())
        }
        .frame(minHeight: destinationCardMinHeight, maxHeight: .infinity, alignment: .top)
    }

    private var destinationTextMinHeight: CGFloat {
        model.presentation.isDictionary ? DICTIONARY_TEXT_MIN_HEIGHT : DEST_TEXT_MIN_HEIGHT
    }

    private var destinationCardMinHeight: CGFloat {
        model.presentation.isDictionary ? DICTIONARY_DEST_CARD_MIN_HEIGHT : DEST_CARD_MIN_HEIGHT
    }

    @ViewBuilder
    private var destinationContent: some View {
        if model.isDictionaryResult {
            DictionaryDefinitionView(word: model.sourceText, definition: model.destText, compact: false)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        } else if model.isAwaitingTranslation {
            MinimalLoadingIndicator(tint: model.destinationTint)
        } else if model.state == .error {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(model.errorStatusText)
                        .font(.system(size: AppUI.FontSize.small, weight: .semibold))
                }
                .foregroundStyle(AppUI.accent)

                Text(model.destText)
                    .font(.system(size: BODY_FONT_SIZE))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(model.destText.isEmpty ? destinationPlaceholder : model.destText)
                .font(.system(size: BODY_FONT_SIZE))
                .foregroundStyle(model.destText.isEmpty ? AppUI.textMuted : AppUI.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var destinationPlaceholder: String {
        model.state == .idle ? "输入原文后按 ⌘↩ 翻译" : "正在翻译..."
    }

    // MARK: - Minimal Mode

    private var minimalBody: some View {
        VStack(spacing: MINIMAL_TOOLBAR_GAP) {
            minimalToolbar

            ScrollView {
                minimalDestinationContent
                    .padding(.bottom, AppUI.Space.xxs)
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: MINIMAL_TEXT_MIN_HEIGHT, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, MINIMAL_WINDOW_PADDING_X)
        .padding(.vertical, MINIMAL_WINDOW_PADDING_Y)
        .frame(
            minWidth: MINIMAL_WINDOW_MIN_WIDTH,
            maxWidth: MINIMAL_WINDOW_MAX_WIDTH,
            minHeight: MINIMAL_WINDOW_MIN_HEIGHT,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(minimalPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: MINIMAL_PANEL_RADIUS, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MINIMAL_PANEL_RADIUS, style: .continuous)
                .stroke(AppUI.minimalPanelBorder, lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: MINIMAL_PANEL_RADIUS, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [AppUI.minimalPanelHighlight, .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
        }
        .onHover { isHoveringMinimalWindow = $0 }
    }

    private var minimalToolbar: some View {
        HStack(spacing: AppUI.Space.xs) {
            if !model.isAwaitingTranslation {
                HStack(spacing: 5) {
                    MinimalEngineDot(tint: model.destinationTint)
                    Text(model.compactEngineLabel)
                        .font(.system(size: AppUI.FontSize.mini, weight: .medium))
                        .foregroundStyle(AppUI.textMuted)
                        .lineLimit(1)
                }
                .accessibilityLabel(model.destinationTitle)
                .allowsHitTesting(false)
            }

            if model.speechState.isVisible {
                SpeechStatusChip(state: model.speechState)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }

            Spacer(minLength: AppUI.Space.s)

            HStack(spacing: 2) {
                CopyFeedbackButton(
                    textToCopy: { model.copyableDestText },
                    size: MINIMAL_TOOLBAR_BUTTON_SIZE,
                    helpText: "复制译文",
                    ghost: true
                )
                .disabled(!model.canCopyDest)
                .opacity(model.canCopyDest ? 1 : 0.30)

                speakButton(size: MINIMAL_TOOLBAR_BUTTON_SIZE, inactiveOpacity: 0.30)

                favoriteButton(size: MINIMAL_TOOLBAR_BUTTON_SIZE, inactiveOpacity: 0.30)

                Button { model.onToggleWindowMode?() } label: {
                    Image(systemName: "rectangle.expand.vertical")
                }
                .buttonStyle(GhostIconButtonStyle(
                    tint: AppUI.textSecondary,
                    size: MINIMAL_TOOLBAR_BUTTON_SIZE
                ))
                .help("切换到完整模式")
                .accessibilityLabel("切换到完整模式")
            }
            .opacity(isHoveringMinimalWindow || model.isFavorite || model.speechState != .idle ? 1.0 : 0.78)
            .animation(.easeInOut(duration: 0.16), value: isHoveringMinimalWindow)
        }
        .frame(height: MINIMAL_TOOLBAR_HEIGHT)
        .animation(.easeInOut(duration: 0.16), value: model.speechState)
        // 极简模式没有标题栏，这条工具栏的留白就是它的拖动区。
        .background(WindowDragArea())
    }

    private var minimalDestinationContent: some View {
        Group {
            if model.isDictionaryResult {
                DictionaryDefinitionView(word: model.sourceText, definition: model.destText, compact: true)
                    .textSelection(.enabled)
            } else if model.isAwaitingTranslation {
                MinimalLoadingIndicator(tint: model.destinationTint)
            } else {
                Text(model.destText)
                    .font(.system(size: BODY_FONT_SIZE, weight: .regular))
                    .foregroundStyle(model.state == .error ? AppUI.accent : AppUI.textPrimary)
                    .lineSpacing(4)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var minimalPanelBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MINIMAL_PANEL_RADIUS, style: .continuous)
                .fill(.regularMaterial)

            RoundedRectangle(cornerRadius: MINIMAL_PANEL_RADIUS, style: .continuous)
                .fill(AppUI.minimalPanel)

            RoundedRectangle(cornerRadius: MINIMAL_PANEL_RADIUS, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppUI.minimalPanelTop, AppUI.minimalPanelBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }

    // MARK: - Shared Action Buttons

    private func speakButton(size: CGFloat, inactiveOpacity: Double = 0.32) -> some View {
        Button { model.onSpeakSource?() } label: {
            speechButtonLabel
        }
        .buttonStyle(GhostIconButtonStyle(
            tint: speechButtonTint,
            activeBackground: speechButtonBackground,
            size: size,
            isActive: model.speechState != .idle
        ))
        .disabled(!model.canSpeakSource || model.isSpeechBusy)
        .opacity(model.canSpeakSource ? 1 : inactiveOpacity)
        .help(model.speechState.helpText)
        .accessibilityLabel(model.speechState.helpText)
    }

    private func favoriteButton(size: CGFloat, inactiveOpacity: Double = 0.32) -> some View {
        Button { model.onToggleFavorite?() } label: {
            Image(systemName: model.isFavorite ? "star.fill" : "star")
        }
        .buttonStyle(GhostIconButtonStyle(
            tint: model.isFavorite ? AppUI.amber : AppUI.textSecondary,
            activeBackground: AppUI.chipWarm,
            size: size,
            isActive: model.isFavorite
        ))
        .disabled(!model.canFavorite)
        .opacity(model.canFavorite ? 1 : inactiveOpacity)
        .help(model.isFavorite ? "取消收藏" : "收藏当前结果")
        .accessibilityLabel(model.isFavorite ? "取消收藏" : "收藏当前结果")
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
            return AppUI.textSecondary
        case .preparing, .playing:
            return AppUI.teal
        case .failed:
            return AppUI.accent
        }
    }

    private var speechButtonBackground: Color {
        switch model.speechState {
        case .idle:
            return .clear
        case .preparing, .playing:
            return AppUI.chipTeal
        case .failed:
            return AppUI.chipWarm
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
        case .idle, .preparing:
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
        .frame(height: 18)
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

private struct MinimalLoadingIndicator: View {
    var tint: Color
    @State private var animating = false

    var body: some View {
        HStack(spacing: AppUI.Space.s) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                        .opacity(animating ? 1 : 0.28)
                        .scaleEffect(animating ? 1 : 0.7)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(index) * 0.18),
                            value: animating
                        )
                }
            }

            Text("正在翻译")
                .font(.system(size: AppUI.FontSize.small, weight: .medium))
                .foregroundStyle(AppUI.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { animating = true }
    }
}

private struct MinimalEngineDot: View {
    var tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .overlay {
                Circle().stroke(tint.opacity(0.24), lineWidth: 2.5)
            }
            .opacity(0.9)
            .accessibilityHidden(true)
    }
}

private struct DictionaryDefinitionView: View {
    let entry: DictionaryDisplayEntry
    let compact: Bool

    init(word: String, definition: String, compact: Bool = false) {
        entry = DictionaryDefinitionFormatter.entry(word: word, definition: definition)
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Space.s) {
            heading

            VStack(alignment: .leading, spacing: compact ? AppUI.Space.xs : AppUI.Space.s) {
                ForEach(Array(displayLines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
        }
        .padding(.bottom, compact ? 0 : AppUI.Space.xs)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: AppUI.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: AppUI.Space.s) {
                Text(entry.title)
                    .font(.system(size: DICTIONARY_TITLE_FONT_SIZE, weight: .bold, design: .serif))
                    .foregroundStyle(AppUI.textPrimary)
                    .lineLimit(compact ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                if let partOfSpeech {
                    Text(partOfSpeech)
                        .font(.system(size: AppUI.FontSize.micro, weight: .bold))
                        .foregroundStyle(AppUI.accent)
                        .padding(.horizontal, AppUI.Space.s)
                        .frame(height: 18)
                        .background(AppUI.activeToolbar)
                        .clipShape(Capsule())
                }

                if !compact, let pronunciation = entry.pronunciation {
                    Text(pronunciation)
                        .font(.system(size: DICTIONARY_PRONUNCIATION_FONT_SIZE, weight: .medium))
                        .foregroundStyle(AppUI.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if compact, let pronunciation = entry.pronunciation {
                Text(pronunciation)
                    .font(.system(size: DICTIONARY_PRONUNCIATION_FONT_SIZE, weight: .medium))
                    .foregroundStyle(AppUI.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(compact ? AppUI.minimalPanelBorder : AppUI.cardBorder)
                .frame(height: 1)
        }
    }

    private var partOfSpeech: String? {
        guard let first = entry.lines.first,
              case .body = first.kind else {
            return nil
        }
        let text = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 24,
              text.rangeOfCharacter(from: CharacterSet(charactersIn: "①②③④⑤⑥⑦⑧⑨⑩▸,，.;；:：")) == nil else {
            return nil
        }
        return text
    }

    private var displayLines: [DictionaryDisplayEntry.Line] {
        if partOfSpeech != nil {
            return Array(entry.lines.dropFirst())
        }
        return entry.lines
    }

    @ViewBuilder
    private func lineView(_ line: DictionaryDisplayEntry.Line) -> some View {
        switch line.kind {
        case .section:
            Text(line.text)
                .font(.system(size: compact ? AppUI.FontSize.small : AppUI.FontSize.base, weight: .semibold))
                .foregroundStyle(AppUI.accent)
                .padding(.top, AppUI.Space.xxs)
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
                    .font(.system(size: compact ? AppUI.FontSize.base : DICTIONARY_BODY_FONT_SIZE, weight: .medium))
                    .foregroundStyle(AppUI.textSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, compact ? 0 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .keyValue:
            HStack(alignment: .firstTextBaseline, spacing: compact ? AppUI.Space.s : AppUI.Space.m) {
                Text(line.key ?? "")
                    .font(.system(size: AppUI.FontSize.small, weight: .semibold))
                    .foregroundStyle(AppUI.textMuted)
                    .frame(width: compact ? 34 : 42, alignment: .leading)

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
