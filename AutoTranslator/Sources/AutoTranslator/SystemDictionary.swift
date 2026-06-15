import CoreServices
import Foundation

enum SystemDictionary {
    static func definition(for term: String) -> String? {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let cfText = normalized as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        guard let definition = DCSCopyTextDefinition(nil, cfText, range)?.takeRetainedValue() else {
            return nil
        }

        let text = (definition as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
