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

    /// 中文词条在系统词典命中后还需要补充英译，因此词典模式固定以英语为目标语言。
    static func effectiveDictionaryTargetLanguage(sourceLanguage: String,
                                                  configuredTargetLanguage: String,
                                                  word: String) -> String {
        if containsChinese(word) {
            return "en"
        }
        return effectiveTargetLanguage(
            sourceLanguage: sourceLanguage,
            configuredTargetLanguage: configuredTargetLanguage,
            text: word
        )
    }

    /// 中文没有天然的空格分词，不能仅凭“无空格”判定为单词。
    /// 只有系统词典确认存在完整词条时才使用词典模式；拉丁文字仍沿用单词规则。
    static func shouldUseDictionaryMode(for word: String,
                                        systemDefinitionAvailable: Bool) -> Bool {
        !containsChinese(word) || systemDefinitionAvailable
    }
}
