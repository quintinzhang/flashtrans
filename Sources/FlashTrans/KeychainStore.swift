import Foundation
import Security

/// API Key 存取。
///
/// 2026-10-21 起改为 UserDefaults 本地存储：钥匙串方案在重装/换签名后会反复触发
/// 「允许访问钥匙串」弹窗，影响使用；翻译 Key（免费额度、低风险）存本地足够。
/// delete() 会顺手清理旧版本可能残留的钥匙串条目（只删不读，不会触发弹窗）。
enum KeychainStore {
    private static let defaultsKey = "glm_api_key"
    private static let legacyKeychainQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.zq.flashtrans.apikey",
        kSecAttrAccount as String: "glm",
    ]

    static func set(_ value: String) throws {
        UserDefaults.standard.set(value, forKey: defaultsKey)
    }

    static func get() -> String? {
        let value = UserDefaults.standard.string(forKey: defaultsKey)
        return (value?.isEmpty == false) ? value : nil
    }

    static func delete() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        SecItemDelete(legacyKeychainQuery as CFDictionary)
    }
}
