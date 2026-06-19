import Foundation

/// 系统 `Translation` 框架后端（离线、免费、无需 Key），仅 macOS 15+ 可用。
/// 按整句返回，不支持流式（沿用 TranslatorProtocol 默认单段包装）。
/// 词典释义不由本后端承担：AppController 对单词优先走系统词典 / 大模型。
@available(macOS 15.0, *)
final class AppleTranslator: TranslatorProtocol {
    let source: String
    let target: String
    let supportsStreaming = false

    init(source: String = "auto", target: String = "zh-CN") {
        self.source = source
        self.target = target
    }

    func translate(_ text: String) async throws -> String {
        try await AppleTranslationBridge.shared.translate(text, source: source, target: target)
    }
}
