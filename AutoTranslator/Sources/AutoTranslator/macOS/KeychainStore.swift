import Foundation
import Security

/// 封装 macOS Keychain 通用密码项（kSecClassGenericPassword）的读写，
/// 用于保存 API 秘钥，避免明文落在 config.json。
/// 失败均记录日志、不抛出，保持与 ConfigStore 一致的容错风格。
final class KeychainStore {

    static let shared = KeychainStore()

    /// 同一 service 下用 account 区分各秘钥（account 即环境变量名，如 DEEPSEEK_API_KEY）。
    private let service: String

    private init() {
        service = Bundle.main.bundleIdentifier ?? "whang1234.AutoTranslator"
    }

    /// 读取指定 account 的秘钥；不存在返回 nil。
    func value(forKey account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                AppLog.error("Keychain 读取失败 account=\(account) status=\(status)")
            }
            return nil
        }
        guard let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// 写入/更新指定 account 的秘钥。
    func set(_ value: String, forKey account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // 已存在则更新，否则新增。
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            AppLog.error("Keychain 更新失败 account=\(account) status=\(updateStatus)")
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            AppLog.error("Keychain 写入失败 account=\(account) status=\(addStatus)")
        }
    }

    /// 删除指定 account 的秘钥；不存在视为成功。
    func remove(forKey account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            AppLog.error("Keychain 删除失败 account=\(account) status=\(status)")
        }
    }
}
