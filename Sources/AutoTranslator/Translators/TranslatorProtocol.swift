import Foundation

protocol TranslatorProtocol: AnyObject {
    var source: String { get }
    var target: String { get }
    var supportsStreaming: Bool { get }
    func translate(_ text: String) async throws -> String
    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error>
}
