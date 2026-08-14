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

    static func get(account: String) -> String? {
        guard let value = try? backend.get(account), !value.isEmpty else { return nil }
        return value
    }

    static func delete(account: String) {
        try? backend.delete(account)
    }

    static func migrateLegacySecrets() throws {
        let legacy = loadLegacy()
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

    private static func loadLegacy() -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let box = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return box
    }

    private static func saveLegacy(_ box: [String: String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(box)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "studio.lumen.oss", directoryHint: .isDirectory)
    }

    private static var fileURL: URL {
        directory.appending(path: "secrets.json")
    }
}

enum SecretStoreError: LocalizedError {
    case migrationIncomplete(Int)

    var errorDescription: String? {
        switch self {
        case .migrationIncomplete(let count):
            return "有 \(count) 项旧凭证未能迁移到 macOS 钥匙串；原文件已保留，请重新打开 Lumen 后再试。"
        }
    }
}
