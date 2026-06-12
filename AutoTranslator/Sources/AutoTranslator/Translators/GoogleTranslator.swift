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

    func translate(_ text: String) async throws -> String {
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
        let json = try JSONSerialization.jsonObject(with: data) as? [Any]
        guard let sentences = json?[0] as? [[Any]], !sentences.isEmpty else {
            throw RuntimeError("Google Translate 返回为空")
        }
        let result = sentences.compactMap { $0[0] as? String }.joined()
        guard !result.isEmpty else {
            throw RuntimeError("Google Translate 返回为空")
        }
        return result
    }
}
