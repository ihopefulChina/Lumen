import Foundation
import Testing
@testable import Lumen

struct SafetyAndVersionTests {
    @Test func malformedVersionsAreRejected() {
        #expect(AppVersion.parts("1.two.3") == nil)
        #expect(AppVersion.parts("1..3") == nil)
        #expect(AppVersion.parts("1.2.3") == [1, 2, 3])
        #expect(!AppVersion.isNewer("1.two.3", than: "0.0.3"))
    }

    @Test func objectURLPreservesExactKey() throws {
        let account = OSSAccount(
            id: UUID(),
            name: "Test",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .private,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )
        let url = try #require(
            account.publicURL(
                bucketName: "bucket",
                bucket: nil,
                key: "a//空 格/+?#.txt"
            )
        )

        #expect(url.host == "bucket.oss-cn-hangzhou.aliyuncs.com")
        #expect(url.path(percentEncoded: true) == "/a//%E7%A9%BA%20%E6%A0%BC/%2B%3F%23.txt")
    }

    @Test func objectURLPreservesCustomEndpointSchemeAndPort() throws {
        let account = OSSAccount(
            id: UUID(),
            name: "Test",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "http://127.0.0.1:9000",
            cdnDomain: "",
            defaultACL: .publicRead,
            prefixTemplate: "",
            useTransferAccelerate: false,
            createdAt: .now
        )

        let url = try #require(account.publicURL(bucketName: "bucket", bucket: nil, key: "a.txt"))

        #expect(url.scheme == "http")
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 9000)
    }

    @Test func unsafeRelativePathsAreRejected() {
        #expect(throws: FileSafety.Error.self) {
            try FileSafety.relativeComponents("../outside.txt")
        }
        #expect(throws: FileSafety.Error.self) {
            try FileSafety.relativeComponents("/absolute.txt")
        }
        #expect(throws: FileSafety.Error.self) {
            try FileSafety.relativeComponents("nested//empty.txt")
        }
    }

    @Test func symlinkCannotEscapeDownloadRoot() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "lumen-safety-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = base.appending(path: "root", directoryHint: .isDirectory)
        let outside = base.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link"),
            withDestinationURL: outside
        )

        #expect(throws: FileSafety.Error.self) {
            try FileSafety.destination(root: root, relativePath: "link/file.txt")
        }
    }

    @Test func objectNamesRejectPathComponents() throws {
        #expect(try ObjectNameValidator.validate(" photo.jpg ") == "photo.jpg")
        #expect(throws: FileSafety.Error.self) { try ObjectNameValidator.validate("") }
        #expect(throws: FileSafety.Error.self) { try ObjectNameValidator.validate("nested/name") }
        #expect(throws: FileSafety.Error.self) { try ObjectNameValidator.validate("..") }
    }

    @Test func linkTextEscapingUsesTheOutputContext() {
        #expect(LinkEscaping.markdownAlt("a]b\\c") == "a\\]b\\\\c")
        #expect(LinkEscaping.htmlAttribute("a\"<&") == "a&quot;&lt;&amp;")
        #expect(
            LinkEscaping.markdownImage(name: "a]b.png", url: "https://example.test/a.png")
                == "![a\\]b.png](https://example.test/a.png)"
        )
        #expect(
            LinkEscaping.htmlImage(name: "a\"<&.png", url: "https://example.test/a.png")
                == "<img src=\"https://example.test/a.png\" alt=\"a&quot;&lt;&amp;.png\" />"
        )
    }

    @Test func keychainMigrationKeepsLegacyValueUntilWriteAndReadBackSucceed() throws {
        let backend = MemorySecretBackend(failingAccounts: ["broken"])

        let result = SecretMigration.migrate(
            legacy: ["ok": "one", "broken": "two"],
            backend: backend
        )

        #expect(result.remainingLegacy == ["broken": "two"])
        #expect(result.migratedAccounts == ["ok"])
        #expect(try backend.get("ok") == "one")
        #expect(try backend.get("broken") == nil)
    }

    @Test func keychainMigrationRejectsAWriteThatCannotBeReadBack() throws {
        let backend = MemorySecretBackend(unreadableAccounts: ["unreadable"])

        let result = SecretMigration.migrate(
            legacy: ["unreadable": "secret"],
            backend: backend
        )

        #expect(result.remainingLegacy == ["unreadable": "secret"])
        #expect(result.migratedAccounts.isEmpty)
    }
}

private final class MemorySecretBackend: SecureSecretBackend {
    private var values: [String: String] = [:]
    private let failingAccounts: Set<String>
    private let unreadableAccounts: Set<String>

    init(
        failingAccounts: Set<String> = [],
        unreadableAccounts: Set<String> = []
    ) {
        self.failingAccounts = failingAccounts
        self.unreadableAccounts = unreadableAccounts
    }

    func get(_ account: String) throws -> String? {
        unreadableAccounts.contains(account) ? nil : values[account]
    }

    func set(_ value: String, for account: String) throws {
        if failingAccounts.contains(account) {
            throw MemorySecretError.writeFailed
        }
        values[account] = value
    }

    func delete(_ account: String) throws {
        values.removeValue(forKey: account)
    }
}

private enum MemorySecretError: Error {
    case writeFailed
}
