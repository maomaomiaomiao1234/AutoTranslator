import Foundation

final class GoogleTranslator: TranslatorProtocol {
    var source: String
    var target: String
    let supportsStreaming = false

    private let session: URLSession = {
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

        let (data, _) = try await session.data(from: components.url!)
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

    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let result = try await self.translate(text)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
