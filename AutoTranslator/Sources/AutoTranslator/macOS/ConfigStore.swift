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

    /// 敏感秘钥：存 Keychain，不落 config.json。
    private static let secretKeys: Set<Key> = [.deepseekKey, .llmKey, .dashscopeKey, .ttsKey]

    private static func isSecret(_ rawKey: String) -> Bool {
        secretKeys.contains { $0.rawValue == rawKey }
    }

    private let fileURL: URL
    private let directoryURL: URL
    private var cache: [String: String] = [:]

    private init() {
        directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoTranslator")
        fileURL = directoryURL.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        migrateLegacyPlaintextSecrets()
        reload()
    }

    /// 重新从磁盘加载配置（不含秘钥；秘钥按需从 Keychain 读取）。
    @discardableResult
    func reload() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            cache = [:]
            return cache
        }
        var result: [String: String] = [:]
        for key in Key.allCases where !Self.secretKeys.contains(key) {
            if let value = json[key.rawValue]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                result[key.rawValue] = value
            }
        }
        cache = result
        return cache
    }

    /// 将当前配置导出到进程环境变量（不覆盖已有环境变量）。
    /// 非秘钥来自 cache；秘钥从 Keychain 读出（仅注入内存环境，不落盘）。
    func applyToEnvironment() {
        for (key, value) in cache where ProcessInfo.processInfo.environment[key] == nil {
            setenv(key, value, 0)
        }
        for key in Self.secretKeys where ProcessInfo.processInfo.environment[key.rawValue] == nil {
            if let value = KeychainStore.shared.value(forKey: key.rawValue), !value.isEmpty {
                setenv(key.rawValue, value, 0)
            }
        }
    }

    func get(_ key: Key) -> String? {
        if Self.secretKeys.contains(key) {
            return KeychainStore.shared.value(forKey: key.rawValue)
        }
        return cache[key.rawValue]
    }

    /// 写入若干键值，nil 表示删除该键。秘钥写 Keychain，其余写 config.json；两者都同步到环境变量。
    func update(_ updates: [Key: String?]) {
        for (key, value) in updates {
            let trimmed = value?.trimmingCharacters(in: .whitespaces)
            if let trimmed, !trimmed.isEmpty {
                if Self.secretKeys.contains(key) {
                    KeychainStore.shared.set(trimmed, forKey: key.rawValue)
                } else {
                    cache[key.rawValue] = trimmed
                }
                setenv(key.rawValue, trimmed, 1)
            } else {
                if Self.secretKeys.contains(key) {
                    KeychainStore.shared.remove(forKey: key.rawValue)
                } else {
                    cache.removeValue(forKey: key.rawValue)
                }
                unsetenv(key.rawValue)
            }
        }
        persist()
    }

    private func persist() {
        // 防御性：秘钥永不进 cache，但仍显式排除，确保 config.json 不含明文秘钥。
        let sanitized = cache.filter { !Self.isSecret($0.key) }
        do {
            let data = try JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            AppLog.error("保存配置失败: \(error)")
        }
    }

    /// 一次性迁移：把旧 config.json 中的明文秘钥搬到 Keychain，并从 JSON 抹除。
    /// 安全第一：先确认写入 Keychain 成功（回读校验）再删除明文。
    private func migrateLegacyPlaintextSecrets() {
        guard let data = try? Data(contentsOf: fileURL),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }

        var migratedCount = 0
        for key in Self.secretKeys {
            guard let value = json[key.rawValue]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                continue
            }
            KeychainStore.shared.set(value, forKey: key.rawValue)
            guard KeychainStore.shared.value(forKey: key.rawValue) == value else {
                AppLog.error("秘钥迁移校验失败，保留 config.json 中的明文 key=\(key.rawValue)")
                continue
            }
            json.removeValue(forKey: key.rawValue)
            migratedCount += 1
        }

        guard migratedCount > 0 else { return }
        do {
            let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try out.write(to: fileURL, options: [.atomic])
            AppLog.debug("已将 \(migratedCount) 个 API 秘钥迁移到 Keychain，并从 config.json 移除")
        } catch {
            AppLog.error("迁移后重写 config.json 失败: \(error)")
        }
    }

    var configFileURL: URL { fileURL }
}
