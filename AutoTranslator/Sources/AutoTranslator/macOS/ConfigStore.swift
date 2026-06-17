import Foundation

/// 统一管理 ~/Library/Application Support/AutoTranslator/config.json
/// 读取/写入翻译后端、API Key 等配置项。
final class ConfigStore {

    static let shared = ConfigStore()

    enum Key: String, CaseIterable {
        case backend = "TRANSLATOR_BACKEND"
        case deepseekKey = "DEEPSEEK_API_KEY"
        case llmKey = "LLM_API_KEY"
        case dashscopeKey = "DASHSCOPE_API_KEY"
        case llmModel = "LLM_MODEL"
        case llmBaseURL = "LLM_BASE_URL"
        case ttsAutoPlay = "TTS_AUTO_PLAY"
        case ttsModel = "TTS_MODEL"
        case ttsVoice = "TTS_VOICE"
        case ttsBaseURL = "TTS_BASE_URL"
        case ttsKey = "TTS_API_KEY"
        case srcLang = "SRC_LANG"
        case destLang = "DEST_LANG"
        case theme = "THEME"
        case floatingWindowMode = "FLOATING_WINDOW_MODE"
    }

    private let fileURL: URL
    private let directoryURL: URL
    private var cache: [String: String] = [:]

    private init() {
        directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoTranslator")
        fileURL = directoryURL.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        reload()
    }

    /// 重新从磁盘加载配置。
    @discardableResult
    func reload() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            cache = [:]
            return cache
        }
        var result: [String: String] = [:]
        for key in Key.allCases {
            if let value = json[key.rawValue]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                result[key.rawValue] = value
            }
        }
        cache = result
        return cache
    }

    /// 将当前配置导出到进程环境变量（不覆盖已有环境变量）。
    func applyToEnvironment() {
        for (key, value) in cache where ProcessInfo.processInfo.environment[key] == nil {
            setenv(key, value, 0)
        }
    }

    func get(_ key: Key) -> String? {
        cache[key.rawValue]
    }

    /// 写入若干键值，nil 表示删除该键。完成后会同步到环境变量。
    func update(_ updates: [Key: String?]) {
        for (key, value) in updates {
            if let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                cache[key.rawValue] = value
                setenv(key.rawValue, value, 1)
            } else {
                cache.removeValue(forKey: key.rawValue)
                unsetenv(key.rawValue)
            }
        }
        persist()
    }

    private func persist() {
        do {
            let data = try JSONSerialization.data(withJSONObject: cache, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.error("保存配置失败: \(error)")
        }
    }

    var configFileURL: URL { fileURL }
}
