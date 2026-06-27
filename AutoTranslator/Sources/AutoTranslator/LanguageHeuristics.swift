import Foundation

enum LanguageHeuristics {
    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2A6DF,
                 0x2A700...0x2B73F,
                 0x2B740...0x2B81F,
                 0x2B820...0x2CEAF,
                 0x30000...0x3134F:
                return true
            default:
                return false
            }
        }
    }

    static func effectiveTargetLanguage(sourceLanguage: String,
                                        configuredTargetLanguage: String,
                                        text: String) -> String {
        guard sourceLanguage == Languages.defaultSourceCode,
              configuredTargetLanguage == Languages.defaultTargetCode,
              containsChinese(text) else {
            return configuredTargetLanguage
        }
        return "en"
    }
}
