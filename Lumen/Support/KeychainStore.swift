import Foundation
import Security

protocol SecureSecretBackend {
    func get(_ account: String) throws -> String?
    func set(_ value: String, for account: String) throws
    func delete(_ account: String) throws
}

protocol KeychainItemAccessing: Sendable {
    func read(account: String, modern: Bool) throws -> String?
    func set(_ value: String, for account: String, modern: Bool) throws
    func delete(account: String, modern: Bool) throws
}

struct KeychainSecretBackend: SecureSecretBackend {
    enum Storage {
        case automatic
        case dataProtection
        case fileBased
    }

    private let storage: Storage
    private let access: any KeychainItemAccessing

    init(
        storage: Storage = .automatic,
        access: any KeychainItemAccessing = SystemKeychainItemAccess()
    ) {
        self.storage = storage
        self.access = access
    }

    func get(_ account: String) throws -> String? {
        switch storage {
        case .dataProtection:
            return try access.read(account: account, modern: true)
        case .fileBased:
            return try access.read(account: account, modern: false)
        case .automatic:
            do {
                if let modern = try access.read(account: account, modern: true) {
                    return modern
                }
            } catch KeychainStoreError.status(errSecMissingEntitlement) {
                // Public builds use the default Keychain access group.
            }
            return try access.read(account: account, modern: false)
        }
    }

    func set(_ value: String, for account: String) throws {
        switch storage {
        case .dataProtection:
            try access.set(value, for: account, modern: true)
        case .fileBased:
            try access.set(value, for: account, modern: false)
        case .automatic:
            do {
                try access.set(value, for: account, modern: true)
            } catch KeychainStoreError.status(errSecMissingEntitlement) {
                try access.set(value, for: account, modern: false)
            }
        }
    }

    func delete(_ account: String) throws {
        let modes: [Bool]
        switch storage {
        case .automatic: modes = [true, false]
        case .dataProtection: modes = [true]
        case .fileBased: modes = [false]
        }

        // Snapshot every reachable backend before mutating either one. Public
        // and locally signed builds can resolve `automatic` to different
        // Keychains; a failure deleting the second copy must not silently lose
        // the first copy and leave the account impossible to roll back.
        var snapshots: [(modern: Bool, value: String?)] = []
        for modern in modes {
            do {
                snapshots.append((modern, try access.read(account: account, modern: modern)))
            } catch KeychainStoreError.status(errSecMissingEntitlement) where modern {
                continue
            }
        }

        var deleted: [(modern: Bool, value: String?)] = []
        do {
            for snapshot in snapshots {
                try access.delete(account: account, modern: snapshot.modern)
                deleted.append(snapshot)
            }
        } catch {
            let primary = error
            do {
                for snapshot in deleted.reversed() {
                    if let value = snapshot.value {
                        try access.set(value, for: account, modern: snapshot.modern)
                    }
                }
            } catch let rollbackError {
                throw KeychainStoreError.rollbackFailed(
                    primary: primary.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw primary
        }
    }
}

struct SystemKeychainItemAccess: KeychainItemAccessing {
    func read(account: String, modern: Bool) throws -> String? {
        var lookup = KeychainStore.query(account: account, modern: modern)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError(status: status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw KeychainStoreError.invalidData
        }
        return value
    }

    func set(_ value: String, for account: String, modern: Bool) throws {
        let data = Data(value.utf8)
        let lookup = KeychainStore.query(account: account, modern: modern)
        let changes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, changes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError(status: updateStatus)
        }

        var item = lookup
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError(status: addStatus)
        }
    }

    func delete(account: String, modern: Bool) throws {
        let status = SecItemDelete(KeychainStore.query(account: account, modern: modern) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }
}

enum KeychainStore {
    static let service = "studio.lumen.oss"
    private static let backend = KeychainSecretBackend()

    static func recover(account: String) throws -> String? {
        try backend.get(account)
    }

    static func store(_ value: String, account: String) throws {
        try backend.set(value, for: account)
    }

    static func delete(account: String) throws {
        try backend.delete(account)
    }

    static func allAccounts() throws -> Set<String> {
        var result = Set<String>()
        for modern in [true, false] {
            do {
                result.formUnion(try accounts(modern: modern))
            } catch KeychainStoreError.status(errSecMissingEntitlement) where modern {
                continue
            }
        }
        return result
    }

    private static func accounts(modern: Bool) throws -> Set<String> {
        var lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        if modern {
            lookup[kSecUseDataProtectionKeychain as String] = true
        }
        var items: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainStoreError(status: status) }
        let dictionaries: [[String: Any]]
        if let many = items as? [[String: Any]] {
            dictionaries = many
        } else if let one = items as? [String: Any] {
            dictionaries = [one]
        } else {
            throw KeychainStoreError.invalidData
        }
        return Set(dictionaries.compactMap { $0[kSecAttrAccount as String] as? String })
    }

    fileprivate static func query(account: String, modern: Bool) -> [String: Any] {
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

enum KeychainStoreError: LocalizedError {
    case status(OSStatus)
    case invalidData
    case rollbackFailed(primary: String, rollback: String)

    init(status: OSStatus) {
        self = .status(status)
    }

    var errorDescription: String? {
        switch self {
        case .status(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "无法访问 macOS 钥匙串：\(detail)"
        case .invalidData:
            return "钥匙串中的凭证格式无效"
        case .rollbackFailed(let primary, let rollback):
            return "钥匙串删除失败：\(primary)；恢复原凭证也失败：\(rollback)"
        }
    }
}
