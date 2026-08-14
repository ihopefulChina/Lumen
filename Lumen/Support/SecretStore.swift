import Foundation

enum SecretStore {
    static func set(_ value: String, account: String) throws {
        var box = load()
        box[account] = value
        try save(box)
    }

    static func get(account: String) -> String? {
        if let stored = load()[account], !stored.isEmpty {
            return stored
        }
        guard let recovered = KeychainStore.recover(account: account), !recovered.isEmpty else {
            return nil
        }
        try? set(recovered, account: account)
        return recovered
    }

    static func delete(account: String) {
        var box = load()
        box.removeValue(forKey: account)
        try? save(box)
        KeychainStore.delete(account: account)
    }

    private static func load() -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let box = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return box
    }

    private static func save(_ box: [String: String]) throws {
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
