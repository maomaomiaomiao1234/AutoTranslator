import AppKit
import Foundation
import UniformTypeIdentifiers

enum HistoryExportError: LocalizedError {
    case pdfRenderingFailed

    var errorDescription: String? {
        switch self {
        case .pdfRenderingFailed:
            return "生成 PDF 失败。"
        }
    }
}

/// 翻译历史/收藏的导出格式。`json` 保留用于「导入」回填，其余为人类可读格式。
enum HistoryExportFormat: String, CaseIterable, Identifiable {
    case markdown
    case html
    case pdf
    case json

    var id: String { rawValue }

    /// 保存对话框下拉框展示的文案。
    var displayName: String {
        switch self {
        case .markdown: return "Markdown（.md）"
        case .html: return "网页（.html）"
        case .pdf: return "PDF（.pdf）"
        case .json: return "JSON（.json，可再次导入）"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .html: return "html"
        case .pdf: return "pdf"
        case .json: return "json"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown:
            return UTType("net.daringfireball.markdown")
                ?? UTType(filenameExtension: "md")
                ?? .plainText
        case .html: return .html
        case .pdf: return .pdf
        case .json: return .json
        }
    }
}

/// 将历史条目渲染为各种可读格式。Markdown/HTML 为纯字符串生成，便于单测；
/// PDF 依赖 AppKit 文本排版组件。均在主线程执行（工程默认 MainActor 隔离，
/// 且条目的展示辅助属性为主线程隔离）。
enum HistoryExportRenderer {

    // MARK: - Markdown

    static func markdown(for entries: [TranslationHistoryEntry]) -> String {
        let formatter = makeDateFormatter()
        var lines: [String] = []
        lines.append("# AutoTranslator 翻译历史")
        lines.append("")
        lines.append("共 \(entries.count) 条记录。")
        lines.append("")

        for (index, entry) in entries.enumerated() {
            let translationTitle = entry.kind == .translation ? "译文" : "释义"
            lines.append("## \(index + 1). \(entry.languageDescription)")
            lines.append("")

            var meta = "\(entry.kind.displayName) · \(entry.backendDescription) · \(formatter.string(from: entry.createdAt))"
            if entry.isFavorite {
                meta += " · ⭐️ 收藏"
            }
            lines.append("*\(escapeMarkdownInline(meta))*")
            lines.append("")

            lines.append("**原文**")
            lines.append("")
            lines.append(markdownBlockquote(entry.sourceText))
            lines.append("")

            lines.append("**\(translationTitle)**")
            lines.append("")
            lines.append(markdownBlockquote(entry.translatedText))
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - HTML

    static func html(for entries: [TranslationHistoryEntry]) -> String {
        let formatter = makeDateFormatter()
        var cards: [String] = []

        for (index, entry) in entries.enumerated() {
            let translationTitle = entry.kind == .translation ? "译文" : "释义"
            let favoriteBadge = entry.isFavorite
                ? "<span class=\"chip chip-star\">⭐️ 收藏</span>"
                : ""
            let card = """
                <article class="card">
                  <header class="card-head">
                    <h2>\(index + 1). \(escapeHTML(entry.languageDescription))</h2>
                    <div class="chips">
                      <span class="chip">\(escapeHTML(entry.kind.displayName))</span>
                      <span class="chip">\(escapeHTML(entry.backendDescription))</span>
                      <span class="chip">\(escapeHTML(formatter.string(from: entry.createdAt)))</span>
                      \(favoriteBadge)
                    </div>
                  </header>
                  <section class="block">
                    <h3>原文</h3>
                    <div class="text">\(escapeHTML(entry.sourceText))</div>
                  </section>
                  <section class="block">
                    <h3>\(translationTitle)</h3>
                    <div class="text">\(escapeHTML(entry.translatedText))</div>
                  </section>
                </article>
                """
            cards.append(card)
        }

        return """
            <!DOCTYPE html>
            <html lang="zh">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>AutoTranslator 翻译历史</title>
            <style>
            :root { color-scheme: light dark; }
            body {
              font-family: -apple-system, "PingFang SC", "Helvetica Neue", Arial, sans-serif;
              margin: 40px auto; max-width: 720px; padding: 0 20px;
              color: #1c1c1e; background: #ffffff; line-height: 1.6;
            }
            h1 { font-size: 24px; margin: 0 0 4px; }
            .summary { color: #6b6b70; margin: 0 0 28px; font-size: 14px; }
            .card {
              border: 1px solid #e2e2e6; border-radius: 12px;
              padding: 18px 20px; margin: 0 0 18px; background: #fbfbfd;
            }
            .card-head { margin-bottom: 12px; }
            .card-head h2 { font-size: 17px; margin: 0 0 8px; }
            .chips { display: flex; flex-wrap: wrap; gap: 6px; }
            .chip {
              font-size: 12px; color: #4b4b50; background: #ededf0;
              border-radius: 6px; padding: 2px 8px;
            }
            .chip-star { background: #fff1cc; color: #8a6d00; }
            .block { margin-top: 12px; }
            .block h3 {
              font-size: 13px; text-transform: none; color: #8a8a8f;
              margin: 0 0 6px; font-weight: 600;
            }
            .text {
              white-space: pre-wrap; word-break: break-word;
              font-size: 15px; color: #1c1c1e;
            }
            @media (prefers-color-scheme: dark) {
              body { color: #f2f2f7; background: #1c1c1e; }
              .card { border-color: #38383c; background: #262629; }
              .chip { color: #d0d0d5; background: #38383c; }
              .chip-star { background: #4a3d10; color: #ffd75e; }
              .text { color: #f2f2f7; }
              .block h3 { color: #9a9aa0; }
            }
            </style>
            </head>
            <body>
            <h1>AutoTranslator 翻译历史</h1>
            <p class="summary">共 \(entries.count) 条记录。</p>
            \(cards.joined(separator: "\n"))
            </body>
            </html>
            """
    }

    // MARK: - PDF

    /// 由 HTML 渲染出 PDF，保证版式与 HTML 导出一致。
    /// 走 AppKit 同步链路（`NSAttributedString(html:)` → 离屏 `NSTextView` → `NSPrintOperation`），
    /// 不引入 WebKit。须在主线程调用（AppKit 文本组件要求）。
    @MainActor
    static func pdfData(for entries: [TranslationHistoryEntry]) throws -> Data {
        let htmlString = html(for: entries)
        guard let htmlData = htmlString.data(using: .utf8),
              let attributed = NSAttributedString(
                html: htmlData,
                options: [.characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else {
            throw HistoryExportError.pdfRenderingFailed
        }

        let printInfo = NSPrintInfo(dictionary: [:])
        printInfo.paperSize = NSSize(width: 595, height: 842) // A4
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let contentWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 100))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributed)

        // 强制排版，算出内容总高度后再定尺寸，供分页打印使用。
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: ceil(used.height))
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autotranslator-export-\(UUID().uuidString).pdf")

        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = tempURL

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false

        guard operation.run() else {
            throw HistoryExportError.pdfRenderingFailed
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }
        return try Data(contentsOf: tempURL)
    }

    // MARK: - Helpers

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    /// 转义 Markdown 行内结构字符，避免原文内容破坏排版。反斜杠须最先替换。
    private static func escapeMarkdownInline(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\", with: "\\\\")
        for character in ["`", "*", "_", "[", "]", "<", ">", "#", "|"] {
            result = result.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return result
    }

    /// 将多行文本转为 Markdown 引用块，逐行加 `> ` 前缀并转义。
    private static func markdownBlockquote(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines
            .map { "> " + escapeMarkdownInline($0) }
            .joined(separator: "\n")
    }

    /// HTML 实体转义。`&` 须最先替换。换行由 CSS `white-space: pre-wrap` 保留。
    private static func escapeHTML(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }
}
