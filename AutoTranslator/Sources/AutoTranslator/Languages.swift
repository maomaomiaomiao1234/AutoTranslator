import Foundation

/// 支持的翻译语言。`(显示名, 语言代码)`，保持顺序以便 UI 展示。
/// `auto` 仅在源语言中合法（自动检测），目标语言不应使用。
nonisolated enum Languages {

    static let all: [(name: String, code: String)] = [
        ("自动检测", "auto"),
        ("中文简体", "zh-CN"),
        ("英语", "en"),
        ("日语", "ja"),
        ("韩语", "ko"),
        ("法语", "fr"),
        ("德语", "de"),
        ("俄语", "ru"),
    ]

    /// 显示名 → 代码
    static let codeByName: [String: String] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name, $0.code) }
    )

    /// 代码 → 显示名
    static let nameByCode: [String: String] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.code, $0.name) }
    )

    static func name(for code: String) -> String {
        nameByCode[code] ?? code
    }

    static func code(for name: String) -> String? {
        codeByName[name]
    }

    /// 源语言可选项（包含自动检测）
    static var sourceOptions: [(name: String, code: String)] { all }

    /// 目标语言可选项（去除自动检测）
    static var targetOptions: [(name: String, code: String)] {
        all.filter { $0.code != "auto" }
    }

    static let defaultSourceCode = "auto"
    static let defaultTargetCode = "zh-CN"
}
