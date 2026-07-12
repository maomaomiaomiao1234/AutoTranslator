import Combine
import SwiftUI

// MARK: - View Model

@MainActor
final class OverlayTranslationViewModel: ObservableObject {

    enum Phase: Equatable {
        case recognizing
        case translating
        case done
        case noText
        case failed(String)
    }

    enum BlockState: Equatable {
        case pending
        case translated
        case failed
    }

    /// 控制条相对贴图图像区的摆放位置（由控制器按屏幕余量决定）。
    enum StripPlacement {
        case below
        case above
        case inside
    }

    struct BlockItem: Identifiable {
        let id: Int
        /// 骨架期占位矩形（相对图像区、点坐标）；翻译完成后以 layout 为准。
        let ptRect: CGRect
        let style: PatchStyle
        var layout: BlockLayout?
        var state: BlockState = .pending

        var patchRect: CGRect {
            layout?.patchRect
                ?? ptRect.insetBy(dx: -OVERLAY_PATCH_INFLATE_X, dy: -OVERLAY_PATCH_INFLATE_Y)
        }
    }

    @Published var image: NSImage?
    @Published var imagePtSize: CGSize = .zero
    @Published var phase: Phase = .recognizing
    @Published var blocks: [BlockItem] = []
    @Published var doneCount = 0
    @Published var totalCount = 0
    @Published var langChipText = ""
    @Published var stripPlacement: StripPlacement = .below
    @Published var alignsTrailing = true
    @Published var stripWidth: CGFloat = 320
    @Published var appearanceVersion = 0

    var onCopyImage: (() -> Void)?
    var onSave: (() -> Void)?
    var onOpenInWindow: (() -> Void)?
    var onClose: (() -> Void)?
    var onRetry: (() -> Void)?
    var onCopyBlockText: ((String) -> Void)?

    var failedCount: Int {
        blocks.filter { $0.state == .failed }.count
    }

    var hasExportableResult: Bool {
        switch phase {
        case .done, .noText:
            return image != nil
        case .recognizing, .translating, .failed:
            return false
        }
    }
}

// MARK: - View

struct OverlayTranslationView: View {
    @ObservedObject var model: OverlayTranslationViewModel

    var body: some View {
        let _ = model.appearanceVersion
        Group {
            switch model.stripPlacement {
            case .below:
                VStack(alignment: horizontalAlignment, spacing: OVERLAY_STRIP_GAP) {
                    imageArea
                    strip
                }
            case .above:
                VStack(alignment: horizontalAlignment, spacing: OVERLAY_STRIP_GAP) {
                    strip
                    imageArea
                }
            case .inside:
                ZStack(alignment: model.alignsTrailing ? .bottomTrailing : .bottomLeading) {
                    imageArea
                    strip.padding(AppUI.Space.s)
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: model.alignsTrailing ? .topTrailing : .topLeading
        )
    }

    private var horizontalAlignment: HorizontalAlignment {
        model.alignsTrailing ? .trailing : .leading
    }

    // MARK: 图像区（原图 + 译文色块）

    private var imageArea: some View {
        ZStack(alignment: .topLeading) {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: model.imagePtSize.width, height: model.imagePtSize.height)
            }
            ForEach(model.blocks) { block in
                blockPatch(block)
            }
        }
        .frame(width: model.imagePtSize.width, height: model.imagePtSize.height)
        .clipShape(RoundedRectangle(cornerRadius: OVERLAY_PIN_RADIUS, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OVERLAY_PIN_RADIUS, style: .continuous)
                .stroke(AppUI.panelBorder, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func blockPatch(_ block: OverlayTranslationViewModel.BlockItem) -> some View {
        let rect = block.patchRect
        ZStack {
            switch block.state {
            case .pending:
                SkeletonPatch(color: block.style.background)
            case .translated:
                if let layout = block.layout {
                    translatedPatch(layout, patchRect: rect)
                }
            case .failed:
                // 失败块不遮挡原文，仅在角落缀一枚琥珀色小点提示。
                RoundedRectangle(cornerRadius: OVERLAY_PATCH_RADIUS, style: .continuous)
                    .fill(.clear)
                    .overlay(alignment: .topTrailing) {
                        Circle()
                            .fill(AppUI.amber)
                            .frame(width: 6, height: 6)
                            .offset(x: 2, y: -2)
                            .help("该块翻译失败，可点击控制条中的重试")
                    }
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX, y: rect.minY)
    }

    /// 骨架色块：采样底色低透明度呼吸，示意"这块正在翻译"。
    /// 各自持有动画状态——晚于首帧插入的块也能正常开始呼吸。
    private struct SkeletonPatch: View {
        let color: NSColor
        @State private var pulsing = false

        var body: some View {
            RoundedRectangle(cornerRadius: OVERLAY_PATCH_RADIUS, style: .continuous)
                .fill(Color(nsColor: color))
                .opacity(pulsing ? 0.55 : 0.30)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulsing = true
                    }
                }
        }
    }

    private func translatedPatch(_ layout: BlockLayout, patchRect: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: OVERLAY_PATCH_RADIUS, style: .continuous)
                .fill(Color(nsColor: layout.patchColor))
            Text(layout.text)
                .font(.system(size: layout.font.pointSize))
                .foregroundStyle(Color(nsColor: layout.textColor))
                .multilineTextAlignment(layout.alignment == .center ? .center : .leading)
                .frame(
                    width: layout.ptRect.width,
                    height: min(patchRect.height, layout.ptRect.height),
                    alignment: layout.alignment == .center ? .center : .leading
                )
                .clipped()
        }
        .contextMenu {
            Button("复制该块译文") {
                model.onCopyBlockText?(layout.text)
            }
        }
        .transition(.opacity.combined(with: .offset(y: 2)))
    }

    // MARK: 控制条

    private var strip: some View {
        HStack(spacing: AppUI.Space.s) {
            switch model.phase {
            case .recognizing:
                progressLabel("识别文字中…")
            case .translating:
                progressLabel("翻译中 \(model.doneCount)/\(model.totalCount)")
            case .done:
                Chip(
                    text: model.langChipText,
                    foreground: AppUI.textSecondary,
                    background: AppUI.chipWarm
                )
                if model.failedCount > 0 {
                    retryButton(title: "重试 \(model.failedCount) 块")
                }
                Spacer(minLength: 0)
                actionButtons
            case .noText:
                Chip(
                    text: "未识别到文字",
                    foreground: AppUI.amber,
                    background: AppUI.chipWarm
                )
                Spacer(minLength: 0)
                actionButtons
            case .failed(let message):
                Chip(
                    text: message,
                    foreground: AppUI.amber,
                    background: AppUI.chipWarm
                )
                retryButton(title: "重试")
                Spacer(minLength: 0)
            }

            closeButton
        }
        .padding(.horizontal, AppUI.Space.m)
        .frame(width: model.stripWidth, height: OVERLAY_STRIP_HEIGHT)
        .background(stripBackground)
    }

    private func progressLabel(_ text: String) -> some View {
        HStack(spacing: AppUI.Space.s) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.system(size: AppUI.FontSize.small))
                .foregroundStyle(AppUI.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: AppUI.Space.s) {
            Button { model.onCopyImage?() } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .disabled(!model.hasExportableResult)
            .help("复制贴图图片")

            Button { model.onSave?() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(IconButtonStyle(size: 28))
            .disabled(!model.hasExportableResult)
            .help("保存贴图图片…")

            if model.phase == .done {
                Button { model.onOpenInWindow?() } label: {
                    Image(systemName: "macwindow.on.rectangle")
                }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("在浮窗中查看原文与译文")
            }
        }
    }

    private func retryButton(title: String) -> some View {
        // IconButtonStyle 固定宽度只适合图标；重试是文字按钮，用自适应宽度的同风格胶囊。
        Button { model.onRetry?() } label: {
            Text(title)
                .font(.system(size: AppUI.FontSize.small, weight: .medium))
                .foregroundStyle(AppUI.amber)
                .lineLimit(1)
                .padding(.horizontal, AppUI.Space.m)
                .frame(height: 28)
                .background(AppUI.chipWarm)
                .clipShape(Capsule())
                .overlay {
                    Capsule().stroke(AppUI.buttonBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("重新翻译失败的块")
    }

    private var closeButton: some View {
        Button { model.onClose?() } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(IconButtonStyle(size: 28))
        .help("关闭贴图 (Esc)")
    }

    /// 与极简浮窗同配方：磨砂玻璃 + 暖色薄膜 + 细描边（胶囊形）。
    private var stripBackground: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
            Capsule(style: .continuous)
                .fill(AppUI.minimalPanel)
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppUI.minimalPanelTop, AppUI.minimalPanelBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(AppUI.minimalPanelBorder, lineWidth: 1)
        }
    }
}
