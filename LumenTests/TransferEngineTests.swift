import Foundation
import Testing
@testable import Lumen

@MainActor
struct TransferEngineTests {
    @Test func transferResourceFinishesOnlyOnceAndDeletesOwnedTemporaryFile() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "lumen-transfer-resource-\(UUID().uuidString)")
        try Data("temporary".utf8).write(to: temporary)
        let counter = LockedCounter()
        let resource = TransferResource(cleanupURLs: [temporary]) {
            counter.increment()
        }

        resource.finish()
        resource.finish()

        #expect(counter.value == 1)
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
    }

    @Test func cancellingAQueuedUploadImmediatelyFinishesItsResource() async throws {
        let firstURL = try Self.temporaryFile(named: "first.txt")
        let secondURL = try Self.temporaryFile(named: "second.txt")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let firstCounter = LockedCounter()
        let secondCounter = LockedCounter()
        let transport = BlockingUploadTransport()
        let client = OSSClient(
            credentials: OSSCredentials(accessKeyId: "test", accessKeySecret: "secret", securityToken: nil),
            region: "cn-hangzhou",
            endpointHost: "oss-cn-hangzhou.aliyuncs.com",
            bucket: "bucket",
            transport: transport
        )
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
        let settings = Self.settings(concurrency: 1)
        let engine = TransferEngine()
        let plan = TransferEngine.UploadPlan(
            items: [
                Self.item(url: firstURL, key: "first.txt", resource: TransferResource { firstCounter.increment() }),
                Self.item(url: secondURL, key: "second.txt", resource: TransferResource { secondCounter.increment() })
            ],
            skipped: 0
        )

        engine.enqueue(plan: plan, client: client, account: account, bucket: nil, settings: settings)
        try await Self.waitUntil { engine.jobs.first?.status == .running }
        try await Self.waitForRequest(transport)
        let queuedID = try #require(engine.jobs.last?.id)
        engine.cancel(queuedID)

        #expect(engine.jobs.last?.status == .cancelled)
        #expect(secondCounter.value == 1)
        #expect(firstCounter.value == 0)

        await transport.resumeFirst()
        try await Self.waitUntil { engine.jobs.first?.status == .completed }
        #expect(firstCounter.value == 1)
    }

    @Test func abandoningAPlanDeletesExplicitlyOwnedSourceFiles() async throws {
        let source = try Self.temporaryFile(named: "clipboard.jpg")
        let plan = await TransferEngine.planUploads(
            urls: [source],
            prefix: "folder/",
            template: "",
            applyTemplate: false,
            options: .init(
                imagesOnly: false,
                convertHEIC: false,
                ownedTemporaryURLs: [source]
            )
        )
        let engine = TransferEngine()

        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(plan.items.count == 1)
        engine.abandon(plan: plan)

        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func retryingAnUploadKeepsTheExactOriginalObjectKey() async throws {
        let source = try Self.temporaryFile(named: "local-name.txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let transport = RetryTransport()
        let client = Self.client(transport: transport)
        let engine = TransferEngine()
        let account = Self.account(prefixTemplate: "generated/{yyyy}/")
        let settings = Self.settings(concurrency: 1)
        let exactKey = "chosen/final-name.txt"
        let plan = TransferEngine.UploadPlan(
            items: [Self.item(url: source, key: exactKey, resource: TransferResource())],
            skipped: 0
        )

        engine.enqueue(plan: plan, client: client, account: account, bucket: nil, settings: settings)
        try await Self.waitUntil { engine.jobs.first?.status == .failed }
        let failedID = try #require(engine.jobs.first?.id)
        engine.retry(failedID)
        try await Self.waitUntil { engine.jobs.count == 2 && engine.jobs.last?.status == .completed }

        let paths = await transport.requestPaths
        #expect(paths == ["/chosen/final-name.txt", "/chosen/final-name.txt"])
    }

    @Test func failedDownloadCanRetryToTheSameDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lumen-download-retry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "download.txt")
        let downloadedTemporary = directory.appending(path: "transport.tmp")
        try Data("downloaded".utf8).write(to: downloadedTemporary)
        let transport = RetryTransport(downloadURL: downloadedTemporary)
        let client = Self.client(transport: transport)
        let engine = TransferEngine()
        let object = OSSObject(
            key: "remote/download.txt",
            size: 10,
            etag: "etag",
            lastModified: nil,
            storageClass: "Standard"
        )

        engine.enqueueDownloadJobs(
            items: [(object, destination)],
            client: client,
            scopedRoot: directory
        )
        try await Self.waitUntil { engine.jobs.first?.status == .failed }
        let failedID = try #require(engine.jobs.first?.id)
        engine.retry(failedID)
        try await Self.waitUntil { engine.jobs.count == 2 && engine.jobs.last?.status == .completed }

        #expect(try Data(contentsOf: destination) == Data("downloaded".utf8))
        let paths = await transport.requestPaths
        #expect(paths == ["/remote/download.txt", "/remote/download.txt"])
    }

    private static func item(
        url: URL,
        key: String,
        resource: TransferResource
    ) -> TransferEngine.PlannedUpload {
        TransferEngine.PlannedUpload(
            sourceURL: url,
            fileURL: url,
            filename: url.lastPathComponent,
            contentType: "text/plain",
            size: 9,
            objectKey: key,
            resource: resource,
            failure: nil
        )
    }

    private static func settings(concurrency: Int) -> AppSettings {
        let suite = "LumenTests.TransferEngine.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(concurrency, forKey: "settings.concurrentUploads")
        return AppSettings(defaults: defaults)
    }

    private static func client(transport: some OSSHTTPTransport) -> OSSClient {
        OSSClient(
            credentials: OSSCredentials(accessKeyId: "test", accessKeySecret: "secret", securityToken: nil),
            region: "cn-hangzhou",
            endpointHost: "oss-cn-hangzhou.aliyuncs.com",
            bucket: "bucket",
            transport: transport
        )
    }

    private static func account(prefixTemplate: String = "") -> OSSAccount {
        OSSAccount(
            id: UUID(),
            name: "Test",
            accessKeyId: "test",
            regionID: "cn-hangzhou",
            endpointOverride: "",
            cdnDomain: "",
            defaultACL: .private,
            prefixTemplate: prefixTemplate,
            useTransferAccelerate: false,
            createdAt: .now
        )
    }

    private static func temporaryFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-\(name)")
        try Data("test data".utf8).write(to: url)
        return url
    }

    private static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for transfer state")
    }

    private static func waitForRequest(_ transport: BlockingUploadTransport) async throws {
        for _ in 0..<200 {
            if await transport.hasPendingRequest { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for upload request")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private actor BlockingUploadTransport: OSSHTTPTransport {
    private var continuation: CheckedContinuation<OSSHTTPResult, Never>?

    var hasPendingRequest: Bool { continuation != nil }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeFirst() {
        continuation?.resume(
            returning: OSSHTTPResult(
                status: 200,
                headers: [:],
                data: Data(),
                temporaryDownloadURL: nil
            )
        )
        continuation = nil
    }
}

private actor RetryTransport: OSSHTTPTransport {
    private(set) var requestPaths: [String] = []
    private let downloadURL: URL?

    init(downloadURL: URL? = nil) {
        self.downloadURL = downloadURL
    }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        requestPaths.append(request.url?.path ?? "")
        if requestPaths.count == 1 {
            return OSSHTTPResult(
                status: 500,
                headers: [:],
                data: Data("<Error><Code>InternalError</Code><Message>retry</Message></Error>".utf8),
                temporaryDownloadURL: nil
            )
        }
        return OSSHTTPResult(
            status: 200,
            headers: [:],
            data: Data(),
            temporaryDownloadURL: download ? downloadURL : nil
        )
    }
}
