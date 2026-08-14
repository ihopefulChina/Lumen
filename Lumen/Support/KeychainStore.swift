import Foundation
import Security

enum KeychainStore {
    static let service = "studio.lumen.oss"

    static func recover(account: String) -> String? {
        if let modern = readQuiet(account: account, modern: true) {
            return modern
        }
        return readQuiet(account: account, modern: false)
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account, modern: true) as CFDictionary)
        SecItemDelete(query(account: account, modern: false) as CFDictionary)
    }

    private static func readQuiet(account: String, modern: Bool) -> String? {
        var lookup = query(account: account, modern: modern)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func query(account: String, modern: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if modern {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}
