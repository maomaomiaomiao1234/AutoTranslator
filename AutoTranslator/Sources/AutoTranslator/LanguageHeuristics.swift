import Foundation

enum LanguageHeuristics {
    /// 是否包含汉字（CJK 统一表意文字）。日文中的汉字也会命中，不能单独用来判断语言。
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

    /// 文本是否更可能是中文，而不是同样含有汉字的日文或韩文。
    static func isLikelyChinese(_ text: String) -> Bool {
        containsChinese(text)
            && !containsJapaneseKana(text)
            && !containsHangul(text)
    }

    static func effectiveTargetLanguage(sourceLanguage: String,
                                        configuredTargetLanguage: String,
                                        text: String) -> String {
        guard sourceLanguage == Languages.defaultSourceCode,
              configuredTargetLanguage == Languages.defaultTargetCode,
              isLikelyChinese(text) else {
            return configuredTargetLanguage
        }
        return "en"
    }

    /// 中文词条在系统词典命中后还需要补充英译，因此词典模式固定以英语为目标语言。
    static func effectiveDictionaryTargetLanguage(sourceLanguage: String,
                                                  configuredTargetLanguage: String,
                                                  word: String) -> String {
        if isLikelyChinese(word) {
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

    private static func containsJapaneseKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F,   // Hiragana
                 0x30A0...0x30FF,   // Katakana
                 0x31F0...0x31FF,   // Katakana Phonetic Extensions
                 0xFF65...0xFF9F,   // Halfwidth Katakana
                 0x1AFF0...0x1AFFF, // Kana Extended-B
                 0x1B000...0x1B0FF, // Kana Supplement
                 0x1B100...0x1B12F, // Kana Extended-A
                 0x1B130...0x1B16F: // Small Kana Extension
                return true
            default:
                return false
            }
        }
    }

    private static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF,
                 0x3130...0x318F,
                 0xA960...0xA97F,
                 0xAC00...0xD7AF,
                 0xD7B0...0xD7FF:
                return true
            default:
                return false
            }
        }
    }
}
