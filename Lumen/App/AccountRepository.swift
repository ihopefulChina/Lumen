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
}

struct AccountRepository {
    let directory: URL
    let primaryURL: URL
    let backupURL: URL

    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.primaryURL = directory.appending(path: "accounts.json")
        self.backupURL = directory.appending(path: "accounts.backup.json")
        self.fileManager = fileManager
    }

    func load() -> AccountLoadResult {
        guard fileManager.fileExists(atPath: primaryURL.path) else {
            return recoverFromBackup(primaryWasMissing: true)
        }
        do {
            return AccountLoadResult(accounts: try decode(primaryURL), recovery: nil)
        } catch {
            return recoverFromBackup(primaryWasMissing: false)
        }
    }

    func save(_ accounts: [OSSAccount]) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(accounts)
        _ = try decoder.decode([OSSAccount].self, from: data)

        if fileManager.fileExists(atPath: primaryURL.path),
           let current = try? Data(contentsOf: primaryURL),
           (try? decoder.decode([OSSAccount].self, from: current)) != nil
        {
            try current.write(to: backupURL, options: .atomic)
        }

        try data.write(to: primaryURL, options: .atomic)
        _ = try decode(primaryURL)
    }

    private func recoverFromBackup(primaryWasMissing: Bool) -> AccountLoadResult {
        guard fileManager.fileExists(atPath: backupURL.path),
              let accounts = try? decode(backupURL)
        else {
            let hasBrokenConfiguration = fileManager.fileExists(atPath: primaryURL.path)
                || fileManager.fileExists(atPath: backupURL.path)
            return AccountLoadResult(
                accounts: [],
                recovery: hasBrokenConfiguration
                    ? AccountRecovery(
                        kind: .unrecoverable,
                        message: "账号配置无法读取。原文件已保留，请从帮助中的支持入口获取恢复说明。"
                    )
                    : nil
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
            let backupData = try Data(contentsOf: backupURL)
            try backupData.write(to: primaryURL, options: .atomic)
            _ = try decode(primaryURL)
            return AccountLoadResult(
                accounts: accounts,
                recovery: AccountRecovery(
                    kind: .restoredBackup,
                    message: "账号配置曾损坏，已恢复上一次可用的账号列表。密钥仍保存在钥匙串中。"
                )
            )
        } catch {
            return AccountLoadResult(
                accounts: [],
                recovery: AccountRecovery(
                    kind: .unrecoverable,
                    message: "账号配置无法恢复。原文件已保留，请从帮助中的支持入口获取恢复说明。"
                )
            )
        }
    }

    private func decode(_ url: URL) throws -> [OSSAccount] {
        try decoder.decode([OSSAccount].self, from: Data(contentsOf: url))
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
