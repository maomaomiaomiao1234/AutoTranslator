import Foundation

final class GoogleTranslator: TranslatorProtocol {
    let source: String
    let target: String
    let supportsStreaming = false

    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    init(source: String = "auto", target: String = "zh-CN") {
        self.source = source
        self.target = target
    }

    /// 非官方接口通过 GET 查询串携带原文，URL 过长会被服务端拒绝；
    /// 超限时直接给出明确错误，而不是让用户看到晦涩的 4xx。
    private static let maxInputLength = 1800

    func translate(_ text: String) async throws -> String {
        guard text.count <= Self.maxInputLength else {
            throw RuntimeError("文本过长（\(text.count) 字符）：谷歌后端单次最多约 \(Self.maxInputLength) 字符")
        }
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text),
        ]

        let (data, response) = try await Self.sharedSession.data(from: components.url!)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RuntimeError("Google Translate HTTP \(http.statusCode): \(body.prefix(200))")
        }
        // 返回结构为嵌套数组；空数组/异常结构一律按「返回为空」处理，
        // 禁止任何未经检查的下标访问（曾因 json[0]/$0[0] 对空数组越界崩溃）。
        let json = try JSONSerialization.jsonObject(with: data) as? [Any]
        guard let sentences = json?.first as? [[Any]], !sentences.isEmpty else {
            throw RuntimeError("Google Translate 返回为空")
        }
        let result = sentences.compactMap { $0.first as? String }.joined()
        guard !result.isEmpty else {
            throw RuntimeError("Google Translate 返回为空")
        }
        return result
    }

    func define(_ word: String) async throws -> String {
        let translated = try await translate(word)
        return """
        词条：\(word)
        释义：\(translated)
        """
    }
}
