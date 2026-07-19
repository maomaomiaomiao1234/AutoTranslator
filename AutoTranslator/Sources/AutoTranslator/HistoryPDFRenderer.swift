import AppKit
import Foundation

/// 用 TextKit 直接分页排版生成 PDF。
///
/// 之前的实现走 HTML → `NSAttributedString(html:)` → `NSPrintOperation`，
/// 该 HTML 渲染器的 CSS 支持非常有限（卡片、间距、弹性布局全部丢失），
/// 也没有页码。这里改为按块排版：逐条目测量高度、控制分页点，
/// 绘制文档标题、条目分隔线、续页页眉与「第 X 页 · 共 N 页」页脚。
@MainActor
enum HistoryPDFRenderer {

    // MARK: - 版面常量（pt，A4 @ 72dpi；排版坐标统一为自上而下）

    private enum Layout {
        static let pageSize = CGSize(width: 595.28, height: 841.89)
        static let margin = NSEdgeInsets(top: 64, left: 56, bottom: 64, right: 56)
        static let contentWidth = pageSize.width - margin.left - margin.right
        /// 条目之间的总间距，分隔线居中其间。
        static let entrySpacing: CGFloat = 28
        /// 条目内区块（标题 / 原文 / 译文）之间的间距。
        static let blockSpacing: CGFloat = 12
        /// 新条目起排所需的最小剩余高度，不足则整体移到下一页，
        /// 避免条目标题孤悬页尾。
        static let entryKeepTogether: CGFloat = 120
        static let footerRuleY = pageSize.height - 42
        static let footerTextY = pageSize.height - 38
    }

    /// 印刷固定使用浅色配色（取应用浅色主题的实色），不随系统外观变化。
    private enum Ink {
        static let primary = NSColor(srgbRed: 31 / 255, green: 29 / 255, blue: 27 / 255, alpha: 1)
        static let secondary = NSColor(srgbRed: 88 / 255, green: 80 / 255, blue: 72 / 255, alpha: 1)
        static let muted = NSColor(srgbRed: 128 / 255, green: 121 / 255, blue: 113 / 255, alpha: 1)
        static let accent = NSColor(srgbRed: 194 / 255, green: 75 / 255, blue: 48 / 255, alpha: 1)
        static let hairline = NSColor(srgbRed: 87 / 255, green: 71 / 255, blue: 58 / 255, alpha: 0.2)
    }

    // MARK: - 入口

    static func render(entries: [TranslationHistoryEntry],
                       context: HistoryExportContext) throws -> Data {
        // 页脚要写「共 N 页」，先完整排版一遍拿总页数，再正式绘制。
        let pageCount = try renderPass(entries: entries, context: context, totalPages: nil).pageCount
        return try renderPass(entries: entries, context: context, totalPages: pageCount).data
    }

    // MARK: - 排版与绘制

    private static func renderPass(
        entries: [TranslationHistoryEntry],
        context: HistoryExportContext,
        totalPages: Int?
    ) throws -> (data: Data, pageCount: Int) {
        let output = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: Layout.pageSize)
        let documentInfo: [CFString: Any] = [
            kCGPDFContextTitle: "AutoTranslator 翻译历史",
            kCGPDFContextCreator: "AutoTranslator",
        ]
        guard let consumer = CGDataConsumer(data: output),
              let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, documentInfo as CFDictionary) else {
            throw HistoryExportError.pdfRenderingFailed
        }

        let previousGraphicsContext = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previousGraphicsContext }

        let contentBottom = Layout.pageSize.height - Layout.margin.bottom
        var pageNumber = 0
        var cursorY: CGFloat = Layout.margin.top

        func drawHairline(atY y: CGFloat) {
            pdf.saveGState()
            pdf.setStrokeColor(Ink.hairline.cgColor)
            pdf.setLineWidth(0.7)
            pdf.move(to: CGPoint(x: Layout.margin.left, y: y))
            pdf.addLine(to: CGPoint(x: Layout.pageSize.width - Layout.margin.right, y: y))
            pdf.strokePath()
            pdf.restoreGState()
        }

        func drawFooter() {
            drawHairline(atY: Layout.footerRuleY)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font(8.5, .medium),
                .foregroundColor: Ink.muted,
            ]
            NSAttributedString(string: "AutoTranslator", attributes: attributes)
                .draw(at: CGPoint(x: Layout.margin.left, y: Layout.footerTextY))

            let pageText = totalPages.map { "第 \(pageNumber) 页 · 共 \($0) 页" } ?? "第 \(pageNumber) 页"
            let pageLabel = NSAttributedString(string: pageText, attributes: attributes)
            pageLabel.draw(at: CGPoint(
                x: Layout.pageSize.width - Layout.margin.right - pageLabel.size().width,
                y: Layout.footerTextY
            ))
        }

        func drawRunningHeader() {
            NSAttributedString(
                string: "AutoTranslator 翻译历史",
                attributes: [
                    .font: font(8.5, .medium),
                    .foregroundColor: Ink.muted,
                    .kern: 0.4,
                ]
            ).draw(at: CGPoint(x: Layout.margin.left, y: 28))
            drawHairline(atY: 44)
        }

        func beginPage() {
            if pageNumber > 0 {
                pdf.restoreGState()
                pdf.endPDFPage()
            }
            pageNumber += 1
            pdf.beginPDFPage(nil)
            // 坐标系翻转为自上而下，AppKit 文本绘制走 flipped 图形上下文。
            pdf.saveGState()
            pdf.translateBy(x: 0, y: Layout.pageSize.height)
            pdf.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: true)
            cursorY = Layout.margin.top
            drawFooter()
            if pageNumber > 1 {
                drawRunningHeader()
            }
        }

        /// 绘制一个文本块；放不下时按行断到后续页。块前间距在换页后不再重复。
        func drawBlock(_ text: NSAttributedString, spacingBefore: CGFloat) throws {
            let storage = NSTextStorage(attributedString: text)
            let layoutManager = NSLayoutManager()
            layoutManager.usesFontLeading = true
            storage.addLayoutManager(layoutManager)

            var spacing = spacingBefore
            while true {
                if contentBottom - cursorY - spacing < 16 {
                    beginPage()
                    spacing = 0
                }
                cursorY += spacing
                spacing = 0

                let container = NSTextContainer(size: CGSize(
                    width: Layout.contentWidth,
                    height: contentBottom - cursorY
                ))
                container.lineFragmentPadding = 0
                layoutManager.addTextContainer(container)

                let glyphRange = layoutManager.glyphRange(for: container)
                if glyphRange.length == 0 {
                    // 整页高度都排不下一行时视为渲染异常，避免死循环。
                    guard cursorY > Layout.margin.top + 0.5 else {
                        throw HistoryExportError.pdfRenderingFailed
                    }
                    beginPage()
                    continue
                }

                layoutManager.drawGlyphs(
                    forGlyphRange: glyphRange,
                    at: CGPoint(x: Layout.margin.left, y: cursorY)
                )
                cursorY += ceil(layoutManager.usedRect(for: container).height)

                if NSMaxRange(glyphRange) >= layoutManager.numberOfGlyphs {
                    return
                }
                beginPage()
            }
        }

        beginPage()

        try drawBlock(documentHeader(entryCount: entries.count, context: context), spacingBefore: 0)
        cursorY += 12
        drawHairline(atY: cursorY)
        pdf.setFillColor(Ink.accent.cgColor)
        pdf.fill(CGRect(x: Layout.margin.left, y: cursorY - 1.1, width: 48, height: 2.2))
        cursorY += 22

        if entries.isEmpty {
            try drawBlock(
                NSAttributedString(string: "没有可导出的记录。", attributes: [
                    .font: font(11.5, .regular),
                    .foregroundColor: Ink.secondary,
                ]),
                spacingBefore: 0
            )
        }

        let dateFormatter = HistoryExportRenderer.makeDateFormatter()
        for (offset, entry) in entries.enumerated() {
            if offset > 0 {
                if contentBottom - cursorY < Layout.entrySpacing + Layout.entryKeepTogether {
                    beginPage()
                } else {
                    cursorY += Layout.entrySpacing / 2
                    drawHairline(atY: cursorY)
                    cursorY += Layout.entrySpacing / 2
                }
            } else if contentBottom - cursorY < Layout.entryKeepTogether {
                beginPage()
            }

            try drawBlock(
                entryHeader(index: offset + 1, entry: entry, formatter: dateFormatter),
                spacingBefore: 0
            )
            try drawBlock(
                textBlock(label: "原文", text: entry.sourceText),
                spacingBefore: Layout.blockSpacing
            )
            try drawBlock(
                textBlock(label: entry.kind == .translation ? "译文" : "释义", text: entry.translatedText),
                spacingBefore: Layout.blockSpacing
            )
        }

        pdf.restoreGState()
        pdf.endPDFPage()
        pdf.closePDF()
        return (output as Data, pageNumber)
    }

    // MARK: - 文本块构造

    private static func documentHeader(entryCount: Int,
                                       context: HistoryExportContext) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 7
        result.append(NSAttributedString(string: "AutoTranslator 翻译历史\n", attributes: [
            .font: font(21, .bold, design: .serif),
            .foregroundColor: Ink.primary,
            .paragraphStyle: titleStyle,
        ]))

        var summary = "共 \(entryCount) 条记录 · 导出于 "
        summary += HistoryExportRenderer.makeDateFormatter().string(from: context.generatedAt)
        if context.favoritesOnly {
            summary += " · 仅收藏"
        }
        result.append(NSAttributedString(string: summary, attributes: [
            .font: font(10.5, .regular),
            .foregroundColor: Ink.secondary,
        ]))
        return result
    }

    private static func entryHeader(index: Int,
                                    entry: TranslationHistoryEntry,
                                    formatter: DateFormatter) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: String(format: "%02d", index), attributes: [
            .font: font(13, .semibold),
            .foregroundColor: Ink.accent,
        ]))
        result.append(NSAttributedString(string: "  \(entry.languageDescription)\n", attributes: [
            .font: font(13, .semibold),
            .foregroundColor: Ink.primary,
        ]))

        let metaStyle = NSMutableParagraphStyle()
        metaStyle.paragraphSpacingBefore = 3
        var meta = "\(entry.kind.displayName) · \(entry.backendDescription)"
        meta += " · \(formatter.string(from: entry.createdAt))"
        if entry.isFavorite {
            meta += " · ★ 收藏"
        }
        result.append(NSAttributedString(string: meta, attributes: [
            .font: font(9.5, .regular),
            .foregroundColor: Ink.muted,
            .paragraphStyle: metaStyle,
        ]))
        return result
    }

    private static func textBlock(label: String, text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let labelStyle = NSMutableParagraphStyle()
        labelStyle.paragraphSpacing = 4
        result.append(NSAttributedString(string: "\(label)\n", attributes: [
            .font: font(9.5, .semibold),
            .foregroundColor: Ink.accent,
            .kern: 1.6,
            .paragraphStyle: labelStyle,
        ]))

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 4
        bodyStyle.paragraphSpacing = 2
        result.append(NSAttributedString(string: text, attributes: [
            .font: font(11.5, .regular),
            .foregroundColor: Ink.primary,
            .paragraphStyle: bodyStyle,
        ]))
        return result
    }

    private static func font(_ size: CGFloat,
                             _ weight: NSFont.Weight,
                             design: NSFontDescriptor.SystemDesign? = nil) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let design,
              let descriptor = base.fontDescriptor.withDesign(design),
              let styled = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return styled
    }
}
