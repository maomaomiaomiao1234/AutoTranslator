import AppKit
import Foundation

// 端到端验证驱动（临时，验证后删除）：用真实生产代码
// (TranslationHistoryStore + HistoryExportRenderer) 生成四种格式的导出文件，供人工检视。
_ = NSApplication.shared // CLI 进程中先建立 AppKit 环境，供 NSPrintOperation 使用
let outputDir = URL(fileURLWithPath: "/tmp/at-export-verify")
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let store = TranslationHistoryStore(
    fileURL: outputDir.appendingPathComponent("history.json"),
    maxRecentItems: 500
)

// 造数据：含 Markdown/HTML 特殊字符、多行文本、词典/翻译两种类型、收藏与非收藏。
let id1 = store.record(
    sourceText: "The quick **brown** fox <jumps> & \"escapes\" [markdown](tricks)",
    translatedText: "敏捷的**棕色**狐狸<跳过>并且&成功\"逃脱\"了[markdown](陷阱)",
    sourceLanguage: "en",
    targetLanguage: "zh-CN",
    backend: "google",
    kind: .translation,
    at: Date(timeIntervalSince1970: 1_752_400_000)
)
store.toggleFavorite(id: id1!)

_ = store.record(
    sourceText: "ephemeral",
    translatedText: "短暂的；朝生暮死\n\n形容词：转瞬即逝的，生命短暂的。\n例句：Fashions are ephemeral. 时尚是短暂的。",
    sourceLanguage: "en",
    targetLanguage: "zh-CN",
    backend: "llm",
    kind: .dictionary,
    at: Date(timeIntervalSince1970: 1_752_500_000)
)

let id3 = store.record(
    sourceText: "こんにちは、世界。今日はいい天気ですね。",
    translatedText: "你好，世界。今天天气真好啊。",
    sourceLanguage: "ja",
    targetLanguage: "zh-CN",
    backend: "apple",
    kind: .translation,
    at: Date(timeIntervalSince1970: 1_752_540_000)
)
store.toggleFavorite(id: id3!)

// 导出全部格式（全部条目）+ 一份仅收藏的 Markdown。
for format in HistoryExportFormat.allCases {
    let url = outputDir.appendingPathComponent("all.\(format.fileExtension)")
    let count = try store.exportEntries(favoritesOnly: false, format: format, to: url)
    print("exported \(count) entries -> \(url.path)")
}
let favURL = outputDir.appendingPathComponent("favorites-only.md")
let favCount = try store.exportEntries(favoritesOnly: true, format: .markdown, to: favURL)
print("exported \(favCount) favorites -> \(favURL.path)")
print("DRIVER_OK")
