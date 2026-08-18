import Foundation

struct SecretMigrationResult {
    var remainingLegacy: [String: String]
    var migratedAccounts: Set<String>
}

enum SecretMigration {
    static func migrate(
        legacy: [String: String],
        backend: any SecureSecretBackend
    ) -> SecretMigrationResult {
        var remaining = legacy
        var migrated = Set<String>()
        for (account, value) in legacy {
            do {
                try backend.set(value, for: account)
                guard try backend.get(account) == value else { continue }
                remaining.removeValue(forKey: account)
                migrated.insert(account)
            } catch {
                continue
            }
        }
        return SecretMigrationResult(
            remainingLegacy: remaining,
            migratedAccounts: migrated
        )
    }
}

enum SecretStore {
    private static let backend = KeychainSecretBackend()

    static func set(_ value: String, account: String) throws {
        try backend.set(value, for: account)
    }

    static func read(account: String) throws -> String? {
        guard let value = try backend.get(account), !value.isEmpty else { return nil }
        return value
    }

    static func remove(account: String) throws {
        try backend.delete(account)
    }

    /// Removes credentials left behind if the process exited after committing
    /// an account deletion but before Keychain cleanup. Unknown/non-UUID items
    /// are deliberately preserved so this migration cannot erase unrelated or
    /// future-format entries that happen to share the service name.
    @discardableResult
    static func removeOrphanedCredentials(validAccountIDs: Set<UUID>) throws -> Int {
        let stored = try KeychainStore.allAccounts()
        let orphaned = orphanedCredentialAccounts(
            stored,
            validAccountIDs: validAccountIDs,
            configurationIsAuthoritative: true
        )
        for account in orphaned.sorted() {
            try remove(account: account)
        }
        return orphaned.count
    }

    static func orphanedCredentialAccounts(
        _ storedAccounts: Set<String>,
        validAccountIDs: Set<UUID>,
        configurationIsAuthoritative: Bool
    ) -> Set<String> {
        guard configurationIsAuthoritative else { return [] }
        return storedAccounts.filter { account in
            let rawID = account.hasSuffix(".sts") ? String(account.dropLast(4)) : account
            guard let id = UUID(uuidString: rawID) else { return false }
            return !validAccountIDs.contains(id)
        }
    }

    static func migrateLegacySecrets() throws {
        let legacy = try loadLegacy()
        guard !legacy.isEmpty else { return }
        let result = SecretMigration.migrate(legacy: legacy, backend: backend)
        if result.remainingLegacy.isEmpty {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        try saveLegacy(result.remainingLegacy)
        throw SecretStoreError.migrationIncomplete(result.remainingLegacy.count)
    }

    private static func loadLegacy() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw SecretStoreError.invalidLegacyFile(error.localizedDescription)
        }
    }

    private static func saveLegacy(_ box: [String: String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(box)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base.appending(path: "studio.lumen.oss", directoryHint: .isDirectory)
    }

    private static var fileURL: URL {
        directory.appending(path: "secrets.json")
    }
}

enum SecretStoreError: LocalizedError {
    case migrationIncomplete(Int)
    case invalidLegacyFile(String)

    var errorDescription: String? {
        switch self {
        case .migrationIncomplete(let count):
            return "有 \(count) 项旧凭证未能迁移到 macOS 钥匙串；原文件已保留，请重新打开 Lumen 后再试。"
        case .invalidLegacyFile(let detail):
            return "旧凭证文件无法读取或已经损坏，原文件已保留：\(detail)"
        }
    }
}
