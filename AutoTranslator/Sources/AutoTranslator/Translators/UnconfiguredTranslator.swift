import Foundation

/// 占位翻译器：当前后端因缺少配置（如未填 API Key）或系统版本不满足而不可用时使用。
/// 不发起任何网络请求，调用即抛出带配置引导的错误，由浮窗以错误态展示。
/// 用它替代「静默改发其他云服务」的旧回退行为：用户没选过的服务不应收到用户的文本。
final class UnconfiguredTranslator: TranslatorProtocol {
    let source: String
    let target: String
    let supportsStreaming = false

    private let message: String

    init(source: String, target: String, message: String) {
        self.source = source
        self.target = target
        self.message = message
    }

    func translate(_ text: String) async throws -> String {
        throw RuntimeError(message)
    }
}
