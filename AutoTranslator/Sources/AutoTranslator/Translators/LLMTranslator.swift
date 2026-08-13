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

    nonisolated static let defaultModel = "deepseek-v4-flash"
    nonisolated static let defaultBaseURL = "https://dashscope.aliyuncs.com/compatible-mode/v1"

    private nonisolated static let sharedSession: URLSession = {
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

    nonisolated static func isOpenRouterBaseURL(_ value: String) -> Bool {
        guard let host = URL(string: value)?.host?.lowercased() else { return false }
        return host == "openrouter.ai" || host.hasSuffix(".openrouter.ai")
    }

    nonisolated static func isOfficialDeepSeekBaseURL(_ value: String) -> Bool {
        URL(string: value)?.host?.lowercased() == "api.deepseek.com"
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
        如果词条包含中文，必须先给出对应英文翻译，同时保留词性、释义和例句等词典说明。\
        如能判断语言，请给出常见词性、核心释义、常见搭配或变形，并给一个短例句。\
        内容要简洁准确；不要输出思考过程、免责声明或额外说明。
        """
    }

    private func buildDictionaryUserMessage(_ word: String) -> String {
        if LanguageHeuristics.isLikelyChinese(word) {
            return """
            为以下词条生成词典解释：\(word)

            输出格式：
            词条：...
            英译：...
            词性：...
            释义：...
            例句：...
            """
        }

        return """
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
        ]
        // enable_thinking 是 DashScope 专有参数（关闭 Qwen 系列的思考模式）。
        // OpenAI 等标准端点会对未知参数返回 400 Unrecognized argument，故仅对 DashScope 发送。
        if baseURL.lowercased().contains("dashscope") {
            body["enable_thinking"] = false
        }
        // OpenRouter 使用统一 reasoning 参数；effort=none 会在支持关闭推理的模型上禁用思考。
        // 强制推理模型可能拒绝该设置，此时应由服务端返回明确错误，而不是静默产生推理费用。
        if Self.isOpenRouterBaseURL(baseURL) {
            body["reasoning"] = ["effort": "none"]
        }
        // DeepSeek 官方 OpenAI 兼容接口使用 thinking.type 控制双模式 V4 模型。
        if Self.isOfficialDeepSeekBaseURL(baseURL) {
            body["thinking"] = ["type": "disabled"]
        }
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
            // 请求在调用方线程装配（只读实例常量，成本一次性）；
            // 字节流消费与逐 token JSON 解析放 detached 任务——工程默认
            // MainActor 隔离下裸 Task {} 会继承主 actor，每个 token 都在主线程解析。
            let request: URLRequest
            do {
                request = try makeRequest(spec, stream: true)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let task = Task.detached(priority: .userInitiated) {
                do {
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
                    var parser = LLMStreamParser()
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let token = try parser.consume(line: line) {
                            continuation.yield(token)
                        }
                    }
                    try parser.validateCompletion()
                    continuation.finish()
                } catch {
                    // 取消也必须以抛错结束：静默 finish() 会让消费端把半截译文
                    // 当成功结果写进缓存和历史，此后同一文本永远命中残缺译文。
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

/// OpenAI 兼容 SSE 流的逐行解析器。纯状态机、不做 IO，便于单元测试。
///
/// 完整性判定只认 `finish_reason == "stop"`：`data: [DONE]` 不构成证据——
/// length 截断后端点照样发 [DONE]，把它当完成标记会让截断译文进缓存。
nonisolated struct LLMStreamParser {
    private var sawStopReason = false
    private var truncationReason: String?
    private var yieldedAnyToken = false

    /// 处理一行 SSE，返回要透传给消费方的增量 token（无则 nil）。
    /// 流中出现服务端错误对象（`{"error": …}` 行）时抛错，不再静默吞掉。
    mutating func consume(line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        // 兼容 `data: {…}` 与 `data:{…}` 两种变体。
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil // 无法解析的 chunk 跳过，完整性由 finish_reason 兜底
        }
        if let errorObject = json["error"] as? [String: Any] {
            let message = (errorObject["message"] as? String) ?? "\(errorObject)"
            throw RuntimeError("LLM 流式响应返回错误: \(message.prefix(200))")
        }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return nil }
        if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
            if finishReason == "stop" {
                sawStopReason = true
            } else {
                truncationReason = finishReason
            }
        }
        guard let delta = choice["delta"] as? [String: Any],
              let token = delta["content"] as? String,
              !token.isEmpty else { return nil }
        yieldedAnyToken = true
        return token
    }

    /// 字节流走完后调用：校验译文完整性，失败即抛错，阻止半截译文按成功返回。
    func validateCompletion() throws {
        if let truncationReason {
            throw RuntimeError("LLM 输出被截断（finish_reason=\(truncationReason)），译文不完整")
        }
        // 网络中断时 SSE 字节流会「正常」结束而没有 finish_reason=stop。
        if yieldedAnyToken && !sawStopReason {
            throw RuntimeError("LLM 流式响应中断，译文不完整")
        }
    }
}
