import Foundation

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
    /// are deliberately preserved so cleanup cannot erase unrelated or
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

}
