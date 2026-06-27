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

    /// 保留系统词典原有标题和释义，在标题之后插入醒目的英文翻译字段。
    static func definition(_ definition: String, addingEnglishTranslation translation: String) -> String {
        let localDefinition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        let english = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !english.isEmpty else { return localDefinition }
        guard let newline = localDefinition.firstIndex(of: "\n") else {
            return "\(localDefinition)\n英文翻译：\(english)"
        }

        let title = localDefinition[..<newline]
        let bodyStart = localDefinition.index(after: newline)
        let body = localDefinition[bodyStart...]
        return "\(title)\n英文翻译：\(english)\n\(body)"
    }
}
