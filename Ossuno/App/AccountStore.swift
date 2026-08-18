import Foundation

enum AccountStore {
    struct Secrets: Equatable {
        var secret: String?
        var token: String?
    }

    static func load() -> AccountLoadResult {
        repository.load()
    }

    static func save(_ accounts: [OSSAccount]) throws {
        try repository.save(accounts)
    }

    static func secretAccount(_ id: UUID) -> String { id.uuidString }
    static func tokenAccount(_ id: UUID) -> String { id.uuidString + ".sts" }

    static func credentials(for account: OSSAccount) throws -> OSSCredentials {
        guard let secret = try SecretStore.read(account: secretAccount(account.id)), !secret.isEmpty else {
            throw OSSServiceError(
                statusCode: 0,
                code: "MissingSecret",
                message: "没有这个账号的密钥。请编辑账号，重新填写 AccessKey Secret 后再连接。",
                requestId: ""
            )
        }
        let token = try SecretStore.read(account: tokenAccount(account.id))
        return OSSCredentials(
            accessKeyId: account.accessKeyId,
            accessKeySecret: secret,
            securityToken: token?.isEmpty == false ? token : nil
        )
    }

    static func storeSecrets(id: UUID, secret: String, token: String?) throws {
        try SecretStore.set(secret, account: secretAccount(id))
        if let token, !token.isEmpty {
            try SecretStore.set(token, account: tokenAccount(id))
        } else {
            try SecretStore.remove(account: tokenAccount(id))
        }
    }

    static func secrets(id: UUID) throws -> Secrets {
        Secrets(
            secret: try SecretStore.read(account: secretAccount(id)),
            token: try SecretStore.read(account: tokenAccount(id))
        )
    }

    static func restoreSecrets(id: UUID, snapshot: Secrets) throws {
        if let secret = snapshot.secret {
            try SecretStore.set(secret, account: secretAccount(id))
        } else {
            try SecretStore.remove(account: secretAccount(id))
        }
        if let token = snapshot.token {
            try SecretStore.set(token, account: tokenAccount(id))
        } else {
            try SecretStore.remove(account: tokenAccount(id))
        }
    }

    static func deleteSecrets(id: UUID) throws {
        let snapshot = try secrets(id: id)
        do {
            try SecretStore.remove(account: secretAccount(id))
            try SecretStore.remove(account: tokenAccount(id))
        } catch {
            do {
                try restoreSecrets(id: id, snapshot: snapshot)
            } catch let rollbackError {
                throw AccountStoreError.rollbackFailed(
                    primary: error.localizedDescription,
                    rollback: rollbackError.localizedDescription
                )
            }
            throw error
        }
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return base.appending(path: "studio.ossuno.oss", directoryHint: .isDirectory)
    }

    private static var repository: AccountRepository { AccountRepository(directory: directory) }
}

enum AccountStoreError: LocalizedError {
    case rollbackFailed(primary: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .rollbackFailed(let primary, let rollback):
            return "账号凭证操作失败：\(primary)；恢复原凭证也失败：\(rollback)"
        }
    }
}
