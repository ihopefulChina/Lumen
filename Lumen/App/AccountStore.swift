import Foundation

enum AccountStore {
    static func load() -> [OSSAccount] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([OSSAccount].self, from: data)
        } catch {
            return []
        }
    }

    static func save(_ accounts: [OSSAccount]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(accounts)
        try data.write(to: fileURL, options: .atomic)
    }

    static func secretAccount(_ id: UUID) -> String { id.uuidString }
    static func tokenAccount(_ id: UUID) -> String { id.uuidString + ".sts" }

    static func credentials(for account: OSSAccount) throws -> OSSCredentials {
        guard let secret = SecretStore.get(account: secretAccount(account.id)), !secret.isEmpty else {
            throw OSSServiceError(
                statusCode: 0,
                code: "MissingSecret",
                message: "没有这个账号的密钥。请编辑账号，重新填写 AccessKey Secret 后再连接。",
                requestId: ""
            )
        }
        let token = SecretStore.get(account: tokenAccount(account.id))
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
            SecretStore.delete(account: tokenAccount(id))
        }
    }

    static func deleteSecrets(id: UUID) {
        SecretStore.delete(account: secretAccount(id))
        SecretStore.delete(account: tokenAccount(id))
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "studio.lumen.oss", directoryHint: .isDirectory)
    }

    private static var fileURL: URL {
        directory.appending(path: "accounts.json")
    }
}
