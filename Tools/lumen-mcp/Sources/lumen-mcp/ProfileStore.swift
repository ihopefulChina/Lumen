import Foundation
import Security

/// MCP profile stored as a generic-password keychain item, fully isolated
/// from the Lumen GUI app's keychain entries (which are ACL-bound to the
/// app's ad-hoc signature and would prompt on every CLI access).
struct MCPOSSProfile: Codable, Sendable {
    var name: String
    var region: String
    var accessKeyId: String
    var accessKeySecret: String
    var securityToken: String?
    var endpoint: String?

    var signingRegion: String { region.strippingOSSPrefix() }

    var credentials: OSSCredentials {
        OSSCredentials(accessKeyId: accessKeyId, accessKeySecret: accessKeySecret, securityToken: securityToken)
    }

    var apiEndpoint: String {
        if let endpoint, !endpoint.trimmingCharacters(in: .whitespaces).isEmpty {
            // Keep an explicitly configured scheme and port. Normalizing this
            // to a bare host used to turn http:// localhost/S3-compatible
            // endpoints into HTTPS later in MCPOSSClient.
            return endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "oss-\(signingRegion).aliyuncs.com"
    }
}

enum ProfileStore {
    static let service = "studio.lumen.mcp"
    static let defaultProfileName = "default"

    // MARK: - Keychain CRUD

    static func save(_ profile: MCPOSSProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.name,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Credentials must not migrate to another Mac through backups.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ProfileStoreError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw ProfileStoreError.keychain(status)
        }
    }

    static func load(name: String) throws -> MCPOSSProfile {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecItemNotFound {
                throw ProfileStoreError.notFound(name)
            }
            throw ProfileStoreError.keychain(status)
        }
        guard let profile = try? JSONDecoder().decode(MCPOSSProfile.self, from: data) else {
            throw ProfileStoreError.corrupted(name)
        }
        return profile
    }

    static func delete(name: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProfileStoreError.keychain(status)
        }
    }

    static func listNames() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &items) == errSecSuccess,
              let array = items as? [[String: Any]] else {
            return []
        }
        return array.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    // MARK: - Active profile pointer

    private static var activePointerURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LumenMCP", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("active-profile")
    }

    static func activeName() -> String {
        if let data = try? Data(contentsOf: activePointerURL),
           let name = String(data: data, encoding: .utf8),
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           listNames().contains(name) {
            return name
        }
        return defaultProfileName
    }

    static func setActiveName(_ name: String) throws {
        try name.trimmingCharacters(in: .whitespacesAndNewlines).write(to: activePointerURL, atomically: true, encoding: .utf8)
    }

    static func loadActive() throws -> MCPOSSProfile {
        try load(name: activeName())
    }
}

enum ProfileStoreError: LocalizedError {
    case notFound(String)
    case corrupted(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "找不到配置档案「\(name)」。先运行 lumen-mcp auth 添加。"
        case .corrupted(let name):
            return "配置档案「\(name)」数据损坏，请重新添加。"
        case .keychain(let status):
            return "钥匙串访问失败（OSStatus \(status)）。"
        }
    }
}
