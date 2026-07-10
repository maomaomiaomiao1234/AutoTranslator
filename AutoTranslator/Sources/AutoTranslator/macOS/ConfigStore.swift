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
        case clipboardFallback = "CLIPBOARD_FALLBACK"
    }

    /// 敏感秘钥：存 Keychain，不落 config.json。
    private static let secretKeys: Set<Key> = [.deepseekKey, .llmKey, .dashscopeKey, .ttsKey]

    /// 所有秘钥合并存放在 Keychain 同一条目（account）下，避免每个秘钥各占一个条目、
    /// 启动时逐个读取触发多次授权弹窗——合并后整组秘钥只需一次读取（即一次授权）。
    private static let secretsKeychainAccount = "AutoTranslatorSecrets"

    private static func isSecret(_ rawKey: String) -> Bool {
        secretKeys.contains { $0.rawValue == rawKey }
    }

    private let fileURL: URL
    private let directoryURL: URL
    private var cache: [String: String] = [:]

    /// 秘钥内存缓存（环境变量名 -> 值），从 Keychain 合并条目按需读出一次后复用。
    /// 避免同一进程内重复访问 Keychain（对 ad-hoc 签名的 App，重复访问可能再次弹窗）。
    private var secretsCache: [String: String] = [:]
    private var secretsLoaded = false

    private init() {
        directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoTranslator")
        fileURL = directoryURL.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        migrateLegacySecretsToConsolidatedKeychain()
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
    /// 非秘钥来自 cache；秘钥从 Keychain 合并条目一次性读出（仅注入内存环境，不落盘）。
    func applyToEnvironment() {
        for (key, value) in cache where ProcessInfo.processInfo.environment[key] == nil {
            setenv(key, value, 0)
        }
        loadSecretsIfNeeded()
        for (account, value) in secretsCache
            where !value.isEmpty && ProcessInfo.processInfo.environment[account] == nil {
            setenv(account, value, 0)
        }
    }

    func get(_ key: Key) -> String? {
        if Self.secretKeys.contains(key) {
            loadSecretsIfNeeded()
            let value = secretsCache[key.rawValue]
            return (value?.isEmpty == false) ? value : nil
        }
        return cache[key.rawValue]
    }

    /// 写入若干键值，nil 表示删除该键。秘钥写 Keychain 合并条目，其余写 config.json；两者都同步到环境变量。
    func update(_ updates: [Key: String?]) {
        var secretsChanged = false
        for (key, value) in updates {
            let trimmed = value?.trimmingCharacters(in: .whitespaces)
            if let trimmed, !trimmed.isEmpty {
                if Self.secretKeys.contains(key) {
                    loadSecretsIfNeeded()
                    secretsCache[key.rawValue] = trimmed
                    secretsChanged = true
                } else {
                    cache[key.rawValue] = trimmed
                }
                setenv(key.rawValue, trimmed, 1)
            } else {
                if Self.secretKeys.contains(key) {
                    loadSecretsIfNeeded()
                    if secretsCache.removeValue(forKey: key.rawValue) != nil {
                        secretsChanged = true
                    }
                } else {
                    cache.removeValue(forKey: key.rawValue)
                }
                unsetenv(key.rawValue)
            }
        }
        if secretsChanged {
            persistSecrets()
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

    // MARK: - Secrets（Keychain 单一合并条目）

    /// 按需从 Keychain 合并条目读出全部秘钥到内存（每进程仅读一次）。
    private func loadSecretsIfNeeded() {
        guard !secretsLoaded else { return }
        secretsLoaded = true
        guard let json = KeychainStore.shared.value(forKey: Self.secretsKeychainAccount),
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            secretsCache = [:]
            return
        }
        secretsCache = dict.filter { !$0.value.isEmpty }
    }

    /// 把内存中的秘钥整体写回 Keychain 合并条目；全空则删除该条目。
    private func persistSecrets() {
        let nonEmpty = secretsCache.filter { !$0.value.isEmpty }
        guard !nonEmpty.isEmpty else {
            KeychainStore.shared.remove(forKey: Self.secretsKeychainAccount)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: nonEmpty, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            AppLog.error("秘钥序列化失败，未能写入 Keychain")
            return
        }
        KeychainStore.shared.set(json, forKey: Self.secretsKeychainAccount)
    }

    /// 迁移历史遗留秘钥到「单一合并条目」：
    /// (1) 旧版 config.json 中的明文秘钥；(2) 旧版「每个秘钥一个 Keychain 条目」。
    /// 安全第一：先把合并条目写入并回读校验成功，才删除旧的明文/分散条目。
    /// 注意：迁移当次会逐个读取旧的分散条目（最多 4 次授权），完成后即合并删除，此后每次启动仅一次授权。
    private func migrateLegacySecretsToConsolidatedKeychain() {
        loadSecretsIfNeeded()

        // (1) 收集旧明文 config.json 中的秘钥（暂不删除）
        var legacyJSON: [String: String]?
        if let data = try? Data(contentsOf: fileURL) {
            legacyJSON = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        }
        var plaintextAccounts: [String] = []
        if let legacyJSON {
            for key in Self.secretKeys {
                guard let value = legacyJSON[key.rawValue]?.trimmingCharacters(in: .whitespaces),
                      !value.isEmpty else { continue }
                if (secretsCache[key.rawValue] ?? "").isEmpty {
                    secretsCache[key.rawValue] = value
                }
                plaintextAccounts.append(key.rawValue)
            }
        }

        // (2) 收集旧的「每秘钥一个条目」（暂不删除）
        var legacyKeychainAccounts: [String] = []
        for key in Self.secretKeys {
            guard let value = KeychainStore.shared.value(forKey: key.rawValue),
                  !value.isEmpty else { continue }
            if (secretsCache[key.rawValue] ?? "").isEmpty {
                secretsCache[key.rawValue] = value
            }
            legacyKeychainAccounts.append(key.rawValue)
        }

        guard !plaintextAccounts.isEmpty || !legacyKeychainAccounts.isEmpty else { return }

        persistSecrets()

        // 回读校验合并条目，确认无误后才做任何删除。
        guard let blob = KeychainStore.shared.value(forKey: Self.secretsKeychainAccount),
              let blobData = blob.data(using: .utf8),
              let stored = try? JSONSerialization.jsonObject(with: blobData) as? [String: String] else {
            AppLog.error("秘钥合并写入校验失败，保留旧的明文/分散 Keychain 条目")
            return
        }

        // 删除已确认合并成功的旧「每秘钥」条目。
        var removedKeychain = 0
        for account in legacyKeychainAccounts where stored[account] == secretsCache[account] {
            KeychainStore.shared.remove(forKey: account)
            removedKeychain += 1
        }

        // 从 config.json 抹除已确认合并成功的明文秘钥。
        if var json = legacyJSON, !plaintextAccounts.isEmpty {
            var removedPlaintext = false
            for account in plaintextAccounts where stored[account] == secretsCache[account] {
                if json.removeValue(forKey: account) != nil { removedPlaintext = true }
            }
            if removedPlaintext,
               let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: fileURL, options: [.atomic])
            }
        }

        AppLog.debug("已将秘钥合并到单一 Keychain 条目（清理旧分散条目=\(removedKeychain)，明文=\(plaintextAccounts.count)）")
    }

    var configFileURL: URL { fileURL }
}
