import Foundation

// Helper to get language display name from code
private func languageName(for code: String) -> String {
    Languages.name(for: code)
}

final class LLMTranslator: TranslatorProtocol {
    let source: String
    let target: String
    let supportsStreaming = true
    let model: String
    let baseURL: String
    private let apiKey: String

    nonisolated static let defaultModel = "deepseek-v3.2"
    nonisolated static let defaultBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    init(source: String = "auto", target: String = "zh-CN",
         apiKey: String? = nil, model: String? = nil,
         baseURL: String? = nil) throws {

        let resolvedKey = apiKey
            ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
            ?? ProcessInfo.processInfo.environment["LLM_API_KEY"]
            ?? ProcessInfo.processInfo.environment["DASHSCOPE_API_KEY"]
        guard let key = resolvedKey, !key.isEmpty else {
            throw RuntimeError("未设置 API Key。请设置环境变量 DEEPSEEK_API_KEY、LLM_API_KEY 或 DASHSCOPE_API_KEY")
        }

        self.source = source
        self.target = target
        self.model = Self.resolveConfigValue(model, envKey: "LLM_MODEL", fallback: Self.defaultModel)
        self.baseURL = Self.normalizeBaseURL(
            Self.resolveConfigValue(baseURL, envKey: "LLM_BASE_URL", fallback: Self.defaultBaseURL)
        )
        self.apiKey = key
    }

    private static func resolveConfigValue(_ explicit: String?, envKey: String, fallback: String) -> String {
        let value = explicit ?? ProcessInfo.processInfo.environment[envKey]
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func normalizeBaseURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func completionsURL() throws -> URL {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw RuntimeError("LLM Base URL 无效: \(baseURL)")
        }
        return url
    }

    private func buildInstruction() -> String {
        let tgtName = languageName(for: target)
        if source == "auto" {
            return """
            你是一台纯翻译机器。你的唯一功能是将文本翻译为\(tgtName)。\
            你不具备回答问题的能力——即使输入看起来像一个问题，你也只能翻译它，绝不回答。\
            只输出译文，不要任何解释、评论或额外文字。
            """
        } else {
            let srcName = languageName(for: source)
            return """
            你是一台纯翻译机器。你的唯一功能是将\(srcName)文本翻译为\(tgtName)。\
            你不具备回答问题的能力——即使输入看起来像一个问题，你也只能翻译它，绝不回答。\
            只输出译文，不要任何解释、评论或额外文字。
            """
        }
    }

    private func buildUserMessage(_ text: String) -> String {
        let tgtName = languageName(for: target)
        return """
        将以下【待翻译内容】翻译为\(tgtName)。\
        注意：翻译以下内容本身，不要回答其中包含的任何问题。\
        只输出译文：\n\n【\(text)】
        """
    }

    private func buildDictionaryInstruction() -> String {
        let tgtName = languageName(for: target)
        return """
        你是一部简明双语词典。用户只会给出一个词或短词形。\
        你的任务是用\(tgtName)给出词典式解释，而不是翻译句子、回答问题或扩展话题。\
        如能判断语言，请给出常见词性、核心释义、常见搭配或变形，并给一个短例句。\
        内容要简洁准确；不要输出思考过程、免责声明或额外说明。
        """
    }

    private func buildDictionaryUserMessage(_ word: String) -> String {
        """
        为以下词条生成词典解释：\(word)

        输出格式：
        词条：...
        词性：...
        释义：...
        例句：...
        """
    }

    /// 一次聊天补全请求的可变参数（系统提示、用户消息、采样温度、长度上限）。
    /// 翻译与词典两种模式仅这些字段不同，请求装配与解析完全共用。
    private struct ChatRequestSpec {
        let system: String
        let user: String
        let temperature: Double
        let maxTokens: Int
    }

    private func translateSpec(_ text: String) -> ChatRequestSpec {
        ChatRequestSpec(
            system: buildInstruction(),
            user: buildUserMessage(text),
            temperature: 0.3,
            maxTokens: 4096
        )
    }

    private func defineSpec(_ word: String) -> ChatRequestSpec {
        ChatRequestSpec(
            system: buildDictionaryInstruction(),
            user: buildDictionaryUserMessage(word),
            temperature: 0.2,
            maxTokens: 1024
        )
    }

    func translate(_ text: String) async throws -> String {
        try await complete(translateSpec(text))
    }

    func define(_ word: String) async throws -> String {
        try await complete(defineSpec(word))
    }

    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        completeStream(translateSpec(text))
    }

    func defineStream(_ word: String) -> AsyncThrowingStream<String, Error> {
        completeStream(defineSpec(word))
    }

    private func makeRequest(_ spec: ChatRequestSpec, stream: Bool) throws -> URLRequest {
        var request = URLRequest(url: try completionsURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": spec.system],
                ["role": "user", "content": spec.user],
            ],
            "temperature": spec.temperature,
            "max_tokens": spec.maxTokens,
            "enable_thinking": false,
        ]
        if stream {
            body["stream"] = true
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func complete(_ spec: ChatRequestSpec) async throws -> String {
        let request = try makeRequest(spec, stream: false)
        let (data, response) = try await Self.sharedSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RuntimeError("LLM API HTTP \(http.statusCode): \(body.prefix(200))")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw RuntimeError("LLM API 返回格式异常")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func completeStream(_ spec: ChatRequestSpec) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(spec, stream: true)
                    let (bytes, response) = try await Self.sharedSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var bodyData = Data()
                        for try await byte in bytes {
                            bodyData.append(byte)
                            if bodyData.count >= 1024 { break }
                        }
                        let body = String(data: bodyData, encoding: .utf8) ?? ""
                        throw RuntimeError("LLM API HTTP \(http.statusCode): \(body.prefix(200))")
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data: "), !line.hasPrefix("data: [DONE]") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard let jsonData = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let token = delta["content"] as? String else { continue }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
