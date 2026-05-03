import Foundation

protocol TranslatorProtocol: AnyObject {
    var source: String { get set }
    var target: String { get set }
    func translate(_ text: String) async throws -> String
    func translateStream(_ text: String) -> AsyncThrowingStream<String, Error>
}
