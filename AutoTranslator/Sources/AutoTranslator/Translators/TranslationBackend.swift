import Foundation

/// 翻译后端的元数据映射。仅集中显示用文案与校验，不替换各处以 String 存储后端 id 的现状。
/// 现支持：`llm`（大模型）、`google`（谷歌翻译）、`apple`（系统翻译，离线，macOS 15+）。
nonisolated enum TranslationBackend {
    static let llm = "llm"
    static let google = "google"
    static let apple = "apple"

    static func isValid(_ id: String) -> Bool {
        id == llm || id == google || id == apple
    }

    /// 完整显示名（用于通知、Picker 等）。
    static func displayName(_ id: String) -> String {
        switch id {
        case llm: return "大模型"
        case apple: return "系统翻译"
        default: return "谷歌翻译"
        }
    }

    /// 简短名（用于状态行、历史标签等紧凑场景）。
    static func shortName(_ id: String) -> String {
        switch id {
        case llm: return "大模型"
        case apple: return "系统"
        default: return "谷歌"
        }
    }

    /// 系统翻译后端是否在当前系统可用（需 macOS 15+）。
    static var isAppleAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }
}
