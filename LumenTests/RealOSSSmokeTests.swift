import Foundation
import Testing
@testable import Lumen

#if REAL_OSS_SMOKE
private let realOSSSmokeEnabled = true
#else
private let realOSSSmokeEnabled = false
#endif

struct RealOSSSmokeTests {
    private let prefix = "lumen-v003-smoke/"

    @Test(.enabled(
        if: realOSSSmokeEnabled,
        "Requires the explicit REAL_OSS_SMOKE compilation condition and a locally saved Lumen account"
    ))
    func uploadListDownloadRenameAndCleanUp() async throws {
        let accounts = AccountStore.load()
        guard let account = accounts.first else { throw SmokeFailure.noSavedAccount }
        let credentials = try AccountStore.credentials(for: account)
        let service = OSSClient(
            credentials: credentials,
            region: account.regionID,
            endpointHost: account.apiHost(for: nil),
            bucket: nil
        )
        let buckets = try await service.listBuckets()
        let preferredName = UserDefaults.standard.string(forKey: "nav.lastBucket")
        guard let bucket = buckets.first(where: { $0.name == preferredName }) ?? buckets.first else {
            throw SmokeFailure.noBucket
        }
        let client = service.scoped(to: bucket, account: account)

        let initial = try await client.listAllObjects(prefix: prefix, includePlaceholders: true)
        guard !initial.truncated else { throw SmokeFailure.incompleteListing }
        guard initial.objects.isEmpty else { throw SmokeFailure.prefixNotEmpty }

        let smallKey = checkedKey("small.txt")
        let largeKey = checkedKey("multipart/large.bin")
        let specialKey = checkedKey("special/空 格+?#.txt")
        let renamedKey = checkedKey("renamed/small-renamed.txt")
        let cleanupKeys = [smallKey, largeKey, specialKey, renamedKey]
        let smallData = Data("Lumen 0.0.3 real OSS smoke\n".utf8)
        let specialData = Data("路径与签名 smoke ✓\n".utf8)

        let localRoot = FileManager.default.temporaryDirectory
            .appending(path: "lumen-v003-oss-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: localRoot) }
        let largeURL = localRoot.appending(path: "large.bin")
        try Data(repeating: 0xA5, count: Int(OSSClient.multipartThreshold + 257)).write(to: largeURL)

        do {
            try await client.putData(key: smallKey, data: smallData, contentType: "text/plain", acl: .private)
            try await client.putObject(
                key: largeKey,
                fileURL: largeURL,
                contentType: "application/octet-stream",
                acl: .private
            )
            try await client.putData(key: specialKey, data: specialData, contentType: "text/plain", acl: .private)

            let listing = try await client.listAllObjects(prefix: prefix)
            guard !listing.truncated else { throw SmokeFailure.incompleteListing }
            #expect(Set(listing.objects.map(\.key)) == Set([smallKey, largeKey, specialKey]))

            #expect(try await client.objectData(key: smallKey) == smallData)
            let downloadURL = localRoot.appending(path: "special-download.txt")
            try await client.download(key: specialKey, to: downloadURL, within: localRoot)
            #expect(try Data(contentsOf: downloadURL) == specialData)

            try await client.renameObject(from: smallKey, to: renamedKey, overwrite: false)
            #expect(!(try await client.objectExists(key: smallKey)))
            #expect(try await client.objectData(key: renamedKey) == smallData)

            let signedURL = try #require(client.presignedURL(key: renamedKey))
            #expect(signedURL.scheme == "https")
            #expect(signedURL.path(percentEncoded: false).hasSuffix("/\(renamedKey)"))
        } catch {
            await clean(client: client, keys: cleanupKeys)
            let remaining = try? await client.listAllObjects(prefix: prefix, includePlaceholders: true)
            guard remaining?.objects.isEmpty == true else { throw SmokeFailure.cleanupFailed }
            throw error
        }

        await clean(client: client, keys: cleanupKeys)
        let final = try await client.listAllObjects(prefix: prefix, includePlaceholders: true)
        guard !final.truncated else { throw SmokeFailure.incompleteListing }
        #expect(final.objects.isEmpty)
    }

    private func checkedKey(_ suffix: String) -> String {
        let key = prefix + suffix
        precondition(key.hasPrefix(prefix) && key != prefix)
        return key
    }

    private func clean(client: OSSClient, keys: [String]) async {
        for key in keys where key.hasPrefix(prefix) && key != prefix {
            try? await client.deleteObject(key: key)
        }
    }
}

private enum SmokeFailure: LocalizedError {
    case noSavedAccount
    case noBucket
    case prefixNotEmpty
    case incompleteListing
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .noSavedAccount: "没有找到本机已保存的 Lumen 账号"
        case .noBucket: "账号下没有可用于冒烟测试的 Bucket"
        case .prefixNotEmpty: "冒烟测试前缀不是空的，已拒绝写入"
        case .incompleteListing: "冒烟测试前缀列表不完整，已停止"
        case .cleanupFailed: "冒烟测试清理失败，前缀仍有对象"
        }
    }
}
