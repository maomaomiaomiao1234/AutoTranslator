import Foundation

protocol TranslatorProtocol: AnyObject {
    var source: String { get }
    var target: String { get }
    var supportsStreaming: Bool { get }
    func translate(_ text: String) async throws -> String
    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error>
}

extension TranslatorProtocol {
    // Default: wrap non-streaming translate() in a single-yield stream.
    // Translators that natively support streaming should override.
    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await self.translate(text)
                    continuation.yield(result)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
