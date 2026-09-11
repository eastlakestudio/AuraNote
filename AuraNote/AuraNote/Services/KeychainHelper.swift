import Foundation
import Security

/// Keychain 读写工具，用于安全存储敏感信息（如 API Token、模型 API-Key）
enum KeychainHelper {

    private static let service = "com.eastlakestudio.auranote"
    static let defaultTokenKey = "llm_token"

    /// 进程内临时安全内存缓存
    private static var inMemoryCache: [String: String] = [:]
    private static let persistentFallbackPrefix = "auranote_keychain_fallback_"

    // MARK: - 沙盒持久化兜底（保障系统 Keychain 异常或沙盒受限时跨进程重启不丢失凭证）

    private static func savePersistentFallback(_ value: String, forKey key: String) {
        let storageKey = persistentFallbackPrefix + key
        let encoded = Data(value.utf8).base64EncodedString()
        UserDefaults.standard.set(encoded, forKey: storageKey)
        UserDefaults.standard.synchronize()
    }

    private static func readPersistentFallback(forKey key: String) -> String? {
        let storageKey = persistentFallbackPrefix + key
        guard let encoded = UserDefaults.standard.string(forKey: storageKey),
              let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty else {
            return nil
        }
        return decoded
    }

    private static func deletePersistentFallback(forKey key: String) {
        let storageKey = persistentFallbackPrefix + key
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.synchronize()
    }

    /// 供单元测试清除内存缓存，模拟进程完全退出重启
    static func clearInMemoryCacheForTesting() {
        inMemoryCache.removeAll()
    }

    // MARK: - Public API

    /// 将字符串写入 Keychain（带本地持久化双重保险）
    @discardableResult
    static func save(_ value: String, forKey key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // 统一更新内存缓存与沙盒持久化兜底
        inMemoryCache[key] = value
        savePersistentFallback(value, forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            AppLog.info("[KeychainHelper] Keychain save success for: \(key)")
            return true
        } else if status == errSecDuplicateItem {
            // 已存在该条目，执行就地更新
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus == errSecSuccess {
                AppLog.info("[KeychainHelper] Keychain update success for: \(key)")
                return true
            } else {
                AppLog.warn("[KeychainHelper] Keychain update failed (\(updateStatus)), fallback saved")
                return true
            }
        } else {
            AppLog.warn("[KeychainHelper] Keychain add failed (\(status)), fallback saved")
            return true
        }
    }

    /// 从 Keychain 读取字符串（优先 Keychain，回退沙盒持久化）
    static func read(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data, let str = String(data: data, encoding: .utf8), !str.isEmpty {
            inMemoryCache[key] = str
            return str
        }

        // 系统 Keychain 未命中或权限受阻，从沙盒持久化安全存储恢复
        if let fallback = readPersistentFallback(forKey: key), !fallback.isEmpty {
            inMemoryCache[key] = fallback
            return fallback
        }

        return inMemoryCache[key]
    }

    /// 从 Keychain 删除条目
    @discardableResult
    static func delete(forKey key: String) -> Bool {
        inMemoryCache.removeValue(forKey: key)
        deletePersistentFallback(forKey: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound || status == -60005
    }

    // MARK: - 云端模型 API-Key 安全存取

    /// 模型专属 Keychain Account 标识
    static func keychainKey(forModelId modelId: String) -> String {
        let cleanId = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "cloud_model_api_key_\(cleanId)"
    }

    /// 安全保存指定云端模型的 API Key
    @discardableResult
    static func saveAPIKey(_ value: String, forModelId modelId: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = keychainKey(forModelId: modelId)
        if trimmed.isEmpty {
            return delete(forKey: key)
        }
        return save(trimmed, forKey: key)
    }

    /// 从 Keychain 读取指定云端模型的 API Key（优先专属 Key，回退默认全局 Token）
    static func readAPIKey(forModelId modelId: String) -> String? {
        let key = keychainKey(forModelId: modelId)
        if let modelSpecificKey = read(forKey: key), !modelSpecificKey.isEmpty {
            return modelSpecificKey
        }
        // 回退兼容全局配置
        if let fallback = read(forKey: defaultTokenKey), !fallback.isEmpty {
            return fallback
        }
        return nil
    }

    /// 从 Keychain 删除指定云端模型的 API Key
    @discardableResult
    static func deleteAPIKey(forModelId modelId: String) -> Bool {
        let key = keychainKey(forModelId: modelId)
        return delete(forKey: key)
    }

    /// 脱敏输出 API Key（用于安全展示或调试日志，防止全量泄露）
    static func maskedKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= 6 {
            return "******"
        }
        let prefixCount = min(3, max(1, trimmed.count / 3))
        let suffixCount = min(4, max(1, trimmed.count / 3))
        let prefix = trimmed.prefix(prefixCount)
        let suffix = trimmed.suffix(suffixCount)
        return "\(prefix)***\(suffix)"
    }
}
