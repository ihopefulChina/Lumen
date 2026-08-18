import Foundation

enum AccountRecoveryKind: Equatable, Sendable {
    case restoredBackup
    case unrecoverable
}

struct AccountRecovery: Equatable, Sendable {
    var kind: AccountRecoveryKind
    var message: String
}

struct AccountLoadResult: Sendable {
    var accounts: [OSSAccount]
    var recovery: AccountRecovery?
    /// Only a successfully decoded primary file that still matches the
    /// repository's last committed authority snapshot can prove that a
    /// Keychain credential no longer belongs to an account. A missing or
    /// externally replaced file and a recovered backup can omit newer accounts.
    var permitsCredentialCleanup: Bool
}

struct AccountRepository {
    let directory: URL
    let primaryURL: URL
    let backupURL: URL
    let cleanupAuthorityURL: URL

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.primaryURL = directory.appending(path: "accounts.json")
        self.backupURL = directory.appending(path: "accounts.backup.json")
        self.cleanupAuthorityURL = directory.appending(path: "accounts.cleanup-authority.json")
        self.fileManager = fileManager
    }

    func load() -> AccountLoadResult {
        guard fileManager.fileExists(atPath: primaryURL.path) else {
            return recoverConfiguration(primaryWasMissing: true)
        }
        do {
            let accounts = try decode(primaryURL)
            let authority = try? decode(cleanupAuthorityURL)
            return AccountLoadResult(
                accounts: accounts,
                recovery: nil,
                permitsCredentialCleanup: authority == accounts
            )
        } catch {
            return recoverConfiguration(primaryWasMissing: false)
        }
    }

    func save(_ accounts: [OSSAccount]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(accounts)
        _ = try decoder.decode([OSSAccount].self, from: data)
        let previousPrimary = try snapshot(primaryURL)
        let previousBackup = try snapshot(backupURL)
        let previousAuthority = try snapshot(cleanupAuthorityURL)

        do {
            let validPrimary = previousPrimary.flatMap(validatedAccountData)
            let backupAccounts = previousBackup.flatMap(decodedAccounts)
            if let validPrimary {
                // A save whose target equals the backup is a transaction
                // rollback (for example, after a Keychain write failed). Keep
                // that known-good backup instead of replacing it with the
                // failed intermediate account list.
                if backupAccounts != accounts {
                    try validPrimary.write(to: backupURL, options: .atomic)
                }
            } else if previousBackup == nil {
                // The first save also gets a redundant copy, so losing the
                // primary file does not strand otherwise valid credentials.
                try data.write(to: backupURL, options: .atomic)
            }

            try data.write(to: primaryURL, options: .atomic)
            _ = try decode(primaryURL)
            // This separate commit proof makes orphan cleanup fail closed if
            // accounts.json is lost, externally replaced with valid JSON, or
            // restored from an older backup on a previous launch.
            try data.write(to: cleanupAuthorityURL, options: .atomic)
            _ = try decode(cleanupAuthorityURL)
        } catch {
            let primary = error
            do {
                try restore(previousPrimary, at: primaryURL)
                try restore(previousBackup, at: backupURL)
                try restore(previousAuthority, at: cleanupAuthorityURL)
            } catch let rollbackError {
                throw AccountRepositoryError.rollbackFailed(
                    primary: primary.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw primary
        }
    }

    private func recoverConfiguration(primaryWasMissing: Bool) -> AccountLoadResult {
        let recoverySource: (url: URL, accounts: [OSSAccount])? = {
            // The authority snapshot is written only after a primary save has
            // been verified, so it is newer than the rotating backup and is
            // the best available recovery source.
            if let accounts = try? decode(cleanupAuthorityURL) {
                return (cleanupAuthorityURL, accounts)
            }
            if let accounts = try? decode(backupURL) {
                return (backupURL, accounts)
            }
            return nil
        }()
        guard let recoverySource
        else {
            let hasBrokenConfiguration = fileManager.fileExists(atPath: primaryURL.path)
                || fileManager.fileExists(atPath: backupURL.path)
                || fileManager.fileExists(atPath: cleanupAuthorityURL.path)
            return AccountLoadResult(
                accounts: [],
                recovery: hasBrokenConfiguration
                    ? AccountRecovery(
                        kind: .unrecoverable,
                        message: "账号配置无法读取。原文件已保留，请从帮助中的支持入口获取恢复说明。"
                    )
                    : nil,
                permitsCredentialCleanup: false
            )
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !primaryWasMissing, fileManager.fileExists(atPath: primaryURL.path) {
                let suffix = ISO8601DateFormatter()
                    .string(from: .now)
                    .replacingOccurrences(of: ":", with: "-")
                var preservedURL = directory.appending(path: "accounts.corrupt-\(suffix).json")
                if fileManager.fileExists(atPath: preservedURL.path) {
                    preservedURL = directory.appending(path: "accounts.corrupt-\(suffix)-\(UUID().uuidString).json")
                }
                try fileManager.moveItem(at: primaryURL, to: preservedURL)
            }
            let recoveryData = try Data(contentsOf: recoverySource.url)
            try recoveryData.write(to: primaryURL, options: .atomic)
            _ = try decode(primaryURL)
            return AccountLoadResult(
                accounts: recoverySource.accounts,
                recovery: AccountRecovery(
                    kind: .restoredBackup,
                    message: "账号配置曾损坏，已恢复上一次可用的账号列表。密钥仍保存在钥匙串中。"
                ),
                permitsCredentialCleanup: false
            )
        } catch {
            return AccountLoadResult(
                accounts: [],
                recovery: AccountRecovery(
                    kind: .unrecoverable,
                    message: "账号配置无法恢复。原文件已保留，请从帮助中的支持入口获取恢复说明。"
                ),
                permitsCredentialCleanup: false
            )
        }
    }

    private func decode(_ url: URL) throws -> [OSSAccount] {
        try decoder.decode([OSSAccount].self, from: Data(contentsOf: url))
    }

    private func validatedAccountData(_ data: Data) -> Data? {
        decodedAccounts(data) == nil ? nil : data
    }

    private func decodedAccounts(_ data: Data) -> [OSSAccount]? {
        try? decoder.decode([OSSAccount].self, from: data)
    }

    private func snapshot(_ url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func restore(_ data: Data?, at url: URL) throws {
        if let data {
            try data.write(to: url, options: .atomic)
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

enum AccountRepositoryError: LocalizedError {
    case rollbackFailed(primary: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .rollbackFailed(let primary, let rollback):
            return "账号配置保存失败：\(primary)；恢复原配置也失败：\(rollback)"
        }
    }
}

enum AccountACLConfirmation {
    static func requiresConfirmation(from previous: ObjectACL?, to proposed: ObjectACL) -> Bool {
        guard proposed == .publicRead || proposed == .publicReadWrite else { return false }
        return previous != proposed
    }

    static func message(for acl: ObjectACL) -> String {
        switch acl {
        case .publicRead:
            "新上传对象将允许任何知道链接的人读取。确认只把它用于需要公开分发的内容。"
        case .publicReadWrite:
            "公共读写允许互联网上的其他人改写对象。这通常不安全，只应在你明确控制风险时使用。"
        case .default, .private:
            ""
        }
    }
}
