import Foundation

// Helper to get language display name from code
private func languageName(for code: String) -> String {
    // LANG_DICT maps display name -> code, so we need to reverse lookup
    // or just use a simple mapping for common cases
    switch code {
    case "auto": return "自动检测"
    case "zh-CN": return "中文简体"
    case "en": return "英语"
    case "ja": return "日语"
    case "ko": return "韩语"
    case "fr": return "法语"
    case "de": return "德语"
    case "ru": return "俄语"
    default: return code
    }
}

final class LLMTranslator: TranslatorProtocol {
    let source: String
    let target: String
    let supportsStreaming = true
    let model: String
    let baseURL: String
    private let apiKey: String

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    init(source: String = "auto", target: String = "zh-CN",
         apiKey: String? = nil, model: String = "deepseek-v3.2",
         baseURL: String = "https://dashscope.aliyuncs.com/compatible-mode/v1") throws {

        let resolvedKey = apiKey
            ?? ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"]
            ?? ProcessInfo.processInfo.environment["LLM_API_KEY"]
        guard let key = resolvedKey, !key.isEmpty else {
            throw RuntimeError("未设置 API Key。请设置环境变量 DEEPSEEK_API_KEY 或 LLM_API_KEY")
        }

        self.source = source
        self.target = target
        self.model = model
        self.baseURL = baseURL
        self.apiKey = key
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

    func translate(_ text: String) async throws -> String {
        let url = URL(string: "\(baseURL)/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": buildInstruction()],
                ["role": "user", "content": buildUserMessage(text)],
            ],
            "temperature": 0.3,
            "max_tokens": 4096,
            "enable_thinking": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = URL(string: "\(baseURL)/chat/completions")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

                    let body: [String: Any] = [
                        "model": model,
                        "messages": [
                            ["role": "system", "content": buildInstruction()],
                            ["role": "user", "content": buildUserMessage(text)],
                        ],
                        "temperature": 0.3,
                        "max_tokens": 4096,
                        "enable_thinking": false,
                        "stream": true,
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

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
