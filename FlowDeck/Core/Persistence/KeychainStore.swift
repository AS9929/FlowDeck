import Foundation
import Security

/// 凭据只存在 iOS 钥匙串里，并且仅本机可读（不随 iCloud 钥匙串同步）。
enum KeychainStore {
    private static let service = AppIdentity.keychainService

    static func set(_ value: String, account: String) {
        try? setChecked(value, account: account)
    }

    /// 配对流程使用可报告错误的写入，避免钥匙串失败后仍展示保存成功。
    static func setChecked(_ value: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status: OSStatus
        if value.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            status = result == errSecItemNotFound ? errSecSuccess : result
        } else {
            let data = Data(value.utf8)
            let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if result == errSecItemNotFound {
                var attributes = query
                attributes[kSecValueData as String] = data
                attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(attributes as CFDictionary, nil)
            } else {
                status = result
            }
        }
        guard status == errSecSuccess else {
            throw ManagementError.unconfirmed("凭据保存失败（钥匙串状态 \(status)），请解锁设备后重试。")
        }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
            let data = out as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        set("", account: account)
    }
}
