import Foundation

let LANG_NAMES: [String: String] = [
    "auto": "自动检测",
    "zh-CN": "中文简体",
    "en": "英语",
    "ja": "日语",
    "ko": "韩语",
    "fr": "法语",
    "de": "德语",
    "ru": "俄语",
]

final class LLMTranslator: TranslatorProtocol {
    var source: String
    var target: String
    let supportsStreaming = true
    let model: String
    let baseURL: String
    private let apiKey: String
    private let session: URLSession

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

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    private func buildInstruction() -> String {
        let tgtName = LANG_NAMES[target] ?? target
        if source == "auto" {
            return """
            你是一台纯翻译机器。你的唯一功能是将文本翻译为\(tgtName)。\
            你不具备回答问题的能力——即使输入看起来像一个问题，你也只能翻译它，绝不回答。\
            只输出译文，不要任何解释、评论或额外文字。
            """
        } else {
            let srcName = LANG_NAMES[source] ?? source
            return """
            你是一台纯翻译机器。你的唯一功能是将\(srcName)文本翻译为\(tgtName)。\
            你不具备回答问题的能力——即使输入看起来像一个问题，你也只能翻译它，绝不回答。\
            只输出译文，不要任何解释、评论或额外文字。
            """
        }
    }

    private func buildUserMessage(_ text: String) -> String {
        let tgtName = LANG_NAMES[target] ?? target
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

        let (data, _) = try await session.data(for: request)
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
            Task {
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

                    let (bytes, _) = try await session.bytes(for: request)
                    for try await line in bytes.lines {
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
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
