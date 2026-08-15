import Foundation
import Testing
@testable import Lumen

@MainActor
struct TransferEngineTests {
    @Test func oldJournalRecordDecodesWithoutCheckpoint() throws {
        let record = PersistedTransfer(job: Self.persistedJob(status: .failed), retry: nil)
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "checkpoint")

        let decoded = try JSONDecoder().decode(
            PersistedTransfer.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.checkpoint == nil)
    }

    @Test func multipartCheckpointRoundTripsThroughJournalRecord() throws {
        let checkpoint = TransferCheckpoint.upload(
            MultipartUploadCheckpoint(
                bucketName: "design-assets",
                objectKey: "art/hero.psd",
                sourceSize: 18_000_000,
                sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                partSize: 8 * 1_024 * 1_024,
                uploadID: "upload-1",
                completedParts: [
                    MultipartCompletedPart(number: 1, etag: "etag-1"),
                    MultipartCompletedPart(number: 2, etag: "etag-2")
                ]
            )
        )
        let record = PersistedTransfer(
            job: Self.persistedJob(status: .paused),
            retry: nil,
            checkpoint: checkpoint
        )

        let decoded = try JSONDecoder().decode(
            PersistedTransfer.self,
            from: JSONEncoder().encode(record)
        )

        #expect(decoded == record)
        #expect(!decoded.job.isActive)
        #expect(decoded.job.isResumable)
    }

    @Test func transferPreferencesPersistWithSafeDefaults() {
        let suite = "LumenTests.TransferPreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let first = AppSettings(defaults: defaults)

        #expect(first.concurrentDownloads == 3)
        #expect(first.transferConflictPolicy == .ask)
        #expect(first.uploadSpeedLimit == .unlimited)
        #expect(first.downloadLocation == .ask)
        #expect(first.signedLinkLifetime == .oneHour)

        first.concurrentDownloads = 5
        first.transferConflictPolicy = .keepBoth
        first.uploadSpeedLimit = .megabytesPerSecond(10)
        first.downloadLocation = .downloads
        first.signedLinkLifetime = .sevenDays

        let restored = AppSettings(defaults: defaults)
        #expect(restored.concurrentDownloads == 5)
        #expect(restored.transferConflictPolicy == .keepBoth)
        #expect(restored.uploadSpeedLimit == .megabytesPerSecond(10))
        #expect(restored.downloadLocation == .downloads)
        #expect(restored.signedLinkLifetime == .sevenDays)
    }

    @Test func clearingHistoryKeepsActiveTransfers() {
        let engine = TransferEngine()
        let running = Self.persistedJob(status: .running)
        let completed = Self.persistedJob(status: .completed)
        let failed = Self.persistedJob(status: .failed)
        engine.jobs = [running, completed, failed]

        engine.clearFinished()

        #expect(engine.jobs == [running])
    }

    @Test func journalRoundTripRemovesLocalPathsAndSignedURLs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "lumen-transfer-journal-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "transfers.json")
        let journal = FileTransferJournal(url: url)
        var job = Self.persistedJob(status: .failed)
        job.localURL = URL(filePath: "/Users/private/Documents/source.txt")
        job.publicURL = URL(string: "https://example.test/file?Signature=signed-secret")
        let record = PersistedTransfer(
            job: job,
            retry: .upload(
                PersistedUploadRetry(
                    accountID: Self.fixedAccount.id,
                    bucket: nil,
                    sourceBookmark: Data([1, 2, 3]),
                    objectKey: "exact/object.txt",
                    imagesOnly: false,
                    convertHEIC: false,
                    playSound: false
                )
            )
        )

        try journal.save([record])

        let storedText = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(!storedText.contains("/Users/private"))
        #expect(!storedText.contains("signed-secret"))
        #expect(!storedText.contains("Authorization"))
        let loaded = try journal.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].job.localURL == nil)
        #expect(loaded[0].job.publicURL == nil)
        #expect(loaded[0].job.objectKey == "exact/object.txt")
    }

    @Test func runningJobRestoresAsRetryableInterruptedFailure() throws {
        let source = try Self.temporaryFile(named: "restored-upload.txt")
        defer { try? FileManager.default.removeItem(at: source) }
        let bookmark = Data([7, 0, 0, 7])
        let record = PersistedTransfer(
            job: Self.persistedJob(status: .running),
            retry: .upload(
                PersistedUploadRetry(
                    accountID: Self.fixedAccount.id,
                    bucket: nil,
                    sourceBookmark: bookmark,
                    objectKey: "chosen/exact.txt",
                    imagesOnly: false,
                    convertHEIC: false,
                    playSound: false
                )
            )
        )
        let journal = MemoryTransferJournal(records: [record])
        let engine = TransferEngine(
            journal: journal,
            bookmarks: FixedTransferBookmarks(bookmark: bookmark, resolvedURL: source),
            clientProvider: { _, _ in Self.client(transport: RetryTransport()) }
        )

        engine.restore(accounts: [Self.fixedAccount])

        let restored = try #require(engine.jobs.first)
        #expect(restored.status == .failed)
        #expect(restored.errorMessage == "上次退出时传输中断，可重试")
        #expect(engine.canRetry(restored.id))
        #expect(journal.records.first?.job.status == .failed)
    }

    @Test func staleBookmarkKeepsHistoryAndExplainsWhyRetryIsUnavailable() throws {
        let record = PersistedTransfer(
            job: Self.persistedJob(status: .queued),
            retry: .upload(
                PersistedUploadRetry(
                    accountID: Self.fixedAccount.id,
                    bucket: nil,
                    sourceBookmark: Data([9]),
                    objectKey: "chosen/exact.txt",
                    imagesOnly: false,
                    convertHEIC: false,
                    playSound: false
                )
            )
        )
        let engine = TransferEngine(
            journal: MemoryTransferJournal(records: [record]),
            bookmarks: FailingTransferBookmarks(),
            clientProvider: { _, _ in Self.client(transport: RetryTransport()) }
        )

        engine.restore(accounts: [Self.fixedAccount])

        let restored = try #require(engine.jobs.first)
        #expect(restored.status == .failed)
        #expect(!engine.canRetry(restored.id))
        #expect(engine.unavailableRetryReason(restored.id) == "原文件或文件夹权限已失效，请重新选择后再上传。")
    }

    @Test func progressJournalWritesAreThrottled() {
        let journal = CountingTransferJournal()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let engine = TransferEngine(journal: journal)
        let job = Self.persistedJob(status: .running)
        engine.jobs = [job]

        engine.recordProgress(job.id, transferred: 4, total: 10, at: fixedNow)
        engine.recordProgress(job.id, transferred: 5, total: 10, at: fixedNow)

        #expect(engine.jobs.first?.transferred == 5)
        #expect(journal.saveCount == 1)
        #expect(journal.records.first?.job.transferred == 4)
    }

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

    @Test func finishingOneUploadNeverExceedsConfiguredConcurrency() async throws {
        let urls = try (1...4).map { try Self.temporaryFile(named: "concurrency-\($0).txt") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let transport = ControllableUploadTransport()
        let client = Self.client(transport: transport)
        let engine = TransferEngine()
        let plan = TransferEngine.UploadPlan(
            items: urls.enumerated().map { index, url in
                Self.item(
                    url: url,
                    key: "item-\(index + 1).txt",
                    resource: TransferResource()
                )
            },
            skipped: 0
        )

        engine.enqueue(
            plan: plan,
            client: client,
            account: Self.account(),
            bucket: nil,
            settings: Self.settings(concurrency: 2)
        )
        try await Self.waitUntil { await transport.requestCount == 2 }
        let firstPath = try #require(await transport.requestPaths.first)
        await transport.resume(path: firstPath)
        try await Self.waitUntil { await transport.requestCount >= 3 }
        try await Task.sleep(for: .milliseconds(250))

        #expect(await transport.requestCount == 3)

        await transport.resumeAll()
        try await Self.waitUntil { await transport.requestCount == 4 }
        await transport.resumeAll()
        try await Self.waitUntil { engine.jobs.allSatisfy { $0.status == .completed } }
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
            transport: transport,
            retryPolicy: OSSRetryPolicy(maxAttempts: 1, jitter: { 0 })
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

    private static let fixedAccount = OSSAccount(
        id: UUID(uuidString: "F79B4573-CB60-43BC-8C3C-5D4BF98F8180")!,
        name: "Test",
        accessKeyId: "test",
        regionID: "cn-hangzhou",
        endpointOverride: "",
        cdnDomain: "",
        defaultACL: .private,
        prefixTemplate: "",
        useTransferAccelerate: false,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    private static func persistedJob(status: TransferStatus) -> TransferJob {
        TransferJob(
            id: UUID(uuidString: "1B248760-1DE8-483C-9C02-00D5455898D0")!,
            kind: .upload,
            status: status,
            title: "source.txt",
            objectKey: "exact/object.txt",
            localURL: nil,
            transferred: 3,
            total: 10,
            errorMessage: nil,
            publicURL: nil,
            finishedAt: nil
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

    private static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous transfer state")
    }

    private static func waitForRequest(_ transport: BlockingUploadTransport) async throws {
        for _ in 0..<200 {
            if await transport.hasPendingRequest { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for upload request")
    }
}

private final class MemoryTransferJournal: TransferJournaling, @unchecked Sendable {
    var records: [PersistedTransfer]

    init(records: [PersistedTransfer] = []) {
        self.records = records
    }

    func load() throws -> [PersistedTransfer] {
        records
    }

    func save(_ records: [PersistedTransfer]) throws {
        self.records = records
    }
}

private final class CountingTransferJournal: TransferJournaling, @unchecked Sendable {
    private(set) var records: [PersistedTransfer] = []
    private(set) var saveCount = 0

    func load() throws -> [PersistedTransfer] { records }

    func save(_ records: [PersistedTransfer]) throws {
        self.records = records
        saveCount += 1
    }
}

private struct FixedTransferBookmarks: TransferBookmarking {
    var bookmark: Data
    var resolvedURL: URL

    func makeBookmark(for url: URL) throws -> Data {
        bookmark
    }

    func resolve(_ bookmark: Data) throws -> URL {
        guard bookmark == self.bookmark else { throw TransferBookmarkError.stale }
        return resolvedURL
    }
}

private struct FailingTransferBookmarks: TransferBookmarking {
    func makeBookmark(for url: URL) throws -> Data {
        throw TransferBookmarkError.stale
    }

    func resolve(_ bookmark: Data) throws -> URL {
        throw TransferBookmarkError.stale
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

private actor ControllableUploadTransport: OSSHTTPTransport {
    private(set) var requestPaths: [String] = []
    private var continuations: [String: CheckedContinuation<OSSHTTPResult, Never>] = [:]

    var requestCount: Int { requestPaths.count }

    func send(
        _ request: URLRequest,
        body: OSSHTTPBody,
        download: Bool,
        onProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> OSSHTTPResult {
        let path = request.url?.path ?? UUID().uuidString
        requestPaths.append(path)
        return await withCheckedContinuation { continuation in
            continuations[path] = continuation
        }
    }

    func resume(path: String) {
        continuations.removeValue(forKey: path)?.resume(returning: Self.success)
    }

    func resumeAll() {
        let pending = Array(continuations.values)
        continuations.removeAll()
        pending.forEach { $0.resume(returning: Self.success) }
    }

    private static var success: OSSHTTPResult {
        OSSHTTPResult(status: 200, headers: [:], data: Data(), temporaryDownloadURL: nil)
    }
}
