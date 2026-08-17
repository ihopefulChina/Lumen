import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class TransferEngine {
    var jobs: [TransferJob] = []
    var concurrency = 3
    var downloadConcurrency = 3
    var uploadSpeedLimit = TransferSpeedLimit.unlimited
    var downloadSpeedLimit = TransferSpeedLimit.unlimited
    var onUploadFinished: (@MainActor () -> Void)?
    var onAllFinished: (@MainActor () -> Void)?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var resources: [UUID: TransferResource] = [:]
    private var retryDescriptors: [UUID: RetryDescriptor] = [:]
    private var persistedRetries: [UUID: PersistedTransferRetry] = [:]
    private var unavailableRetryReasons: [UUID: String] = [:]
    private var checkpoints: [UUID: TransferCheckpoint] = [:]
    private var userIntents: [UUID: UserIntent] = [:]
    private var progressSamples: [UUID: [(date: Date, bytes: Int64)]] = [:]
    private var runningUploads = 0
    private var runningDownloads = 0
    private let journal: any TransferJournaling
    private let bookmarks: any TransferBookmarking
    private var lastProgressPersistenceAt: Date?
    private var lastCheckpointWrite: [UUID: TimeInterval] = [:]
    private let clientProvider: @MainActor @Sendable (OSSAccount, OSSBucket?) throws -> OSSClient

    init(
        journal: any TransferJournaling = NoopTransferJournal(),
        bookmarks: any TransferBookmarking = SecurityScopedTransferBookmarks()
    ) {
        self.journal = journal
        self.bookmarks = bookmarks
        self.clientProvider = Self.defaultClient
    }

    init(
        journal: any TransferJournaling,
        bookmarks: any TransferBookmarking,
        clientProvider: @escaping @MainActor @Sendable (OSSAccount, OSSBucket?) throws -> OSSClient
    ) {
        self.journal = journal
        self.bookmarks = bookmarks
        self.clientProvider = clientProvider
    }

    private static func defaultClient(account: OSSAccount, bucket: OSSBucket?) throws -> OSSClient {
        OSSClient(
            credentials: try AccountStore.credentials(for: account),
            region: account.signingRegion(for: bucket),
            endpointHost: account.apiHost(for: bucket),
            bucket: bucket?.name
        )
    }

    var activeCount: Int { jobs.filter(\.isActive).count }
    var hasJobs: Bool { !jobs.isEmpty }

    struct PlannedUpload {
        var sourceURL: URL
        var fileURL: URL
        var filename: String
        var contentType: String
        var size: Int64
        var objectKey: String
        var resource: TransferResource
        var failure: String?
    }

    struct UploadPlan {
        var items: [PlannedUpload]
        var skipped: Int
        var options = UploadPreparationOptions(imagesOnly: false, convertHEIC: false)
    }

    struct UploadPreparationOptions: Sendable {
        var imagesOnly: Bool
        var convertHEIC: Bool
        var ownedTemporaryURLs: Set<URL> = []
    }

    @discardableResult
    func enqueueUploads(
        urls: [URL],
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        prefix: String,
        settings: AppSettings,
        applyTemplate: Bool = true
    ) async -> Int {
        let options = UploadPreparationOptions(
            imagesOnly: settings.imagesOnly,
            convertHEIC: settings.convertHEIC
        )
        let plan = await Self.planUploads(
            urls: urls,
            prefix: prefix,
            template: account.prefixTemplate,
            applyTemplate: applyTemplate,
            options: options
        )
        enqueue(plan: plan, client: client, account: account, bucket: bucket, settings: settings)
        return plan.skipped
    }

    nonisolated static func planUploads(
        urls: [URL],
        prefix: String,
        template: String,
        applyTemplate: Bool,
        options: UploadPreparationOptions
    ) async -> UploadPlan {
        let rootLeases = urls.compactMap(SecurityScopeLease.init(url:))
        let expansion = expand(urls)
        var items: [PlannedUpload] = []
        for entry in expansion.files {
            let url = entry.url
            let sourceLease = SecurityScopeLease(url: url)
            do {
                let prepared = try await prepare(url: url, convertHEIC: options.convertHEIC)
                var cleanupURLs = prepared.fileURL == url ? [] : [prepared.fileURL]
                if options.ownedTemporaryURLs.contains(url) {
                    cleanupURLs.append(url)
                }
                let retained: [AnyObject] = rootLeases + [sourceLease].compactMap { $0 }
                let resource = TransferResource(
                    cleanupURLs: cleanupURLs,
                    retainedResources: retained
                )
                var relative = entry.relativePath
                if prepared.filename != url.lastPathComponent {
                    relative = PathTemplate.replacingLastComponent(relative, with: prepared.filename)
                }
                let key = PathTemplate.destinationKey(
                    prefix: prefix,
                    filename: relative,
                    applyTemplate: applyTemplate,
                    template: template
                )
                items.append(
                    PlannedUpload(
                        sourceURL: url,
                        fileURL: prepared.fileURL,
                        filename: prepared.filename,
                        contentType: prepared.contentType,
                        size: prepared.size,
                        objectKey: key,
                        resource: resource,
                        failure: nil
                    )
                )
            } catch {
                let retained: [AnyObject] = rootLeases + [sourceLease].compactMap { $0 }
                let cleanupURLs = options.ownedTemporaryURLs.contains(url) ? [url] : []
                items.append(
                    PlannedUpload(
                        sourceURL: url,
                        fileURL: url,
                        filename: url.lastPathComponent,
                        contentType: "",
                        size: 0,
                        objectKey: "",
                        resource: TransferResource(
                            cleanupURLs: cleanupURLs,
                            retainedResources: retained
                        ),
                        failure: error.localizedDescription
                    )
                )
            }
        }
        return UploadPlan(items: items, skipped: expansion.skipped, options: options)
    }

    func enqueue(
        plan: UploadPlan,
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        settings: AppSettings,
        excludingSources: Set<URL> = [],
        allowOverwrite: Bool = false
    ) {
        enqueue(
            plan: plan,
            client: client,
            account: account,
            bucket: bucket,
            concurrentUploads: settings.concurrentUploads,
            speedLimit: settings.uploadSpeedLimit,
            playCompleteSound: settings.playCompleteSound,
            excludingSources: excludingSources,
            allowOverwrite: allowOverwrite
        )
    }

    func abandon(plan: UploadPlan) {
        plan.items.forEach { $0.resource.finish() }
    }

    func enqueueDownloadJobs(
        items: [(object: OSSObject, destination: URL)],
        client: OSSClient,
        account: OSSAccount? = nil,
        bucket: OSSBucket? = nil,
        scopedRoot: URL,
        speedLimit: TransferSpeedLimit? = nil,
        allowOverwrite: Bool = false
    ) {
        guard !items.isEmpty else { return }
        let rootLease = SecurityScopeLease(url: scopedRoot)
        for item in items {
            let dest = item.destination
            let job = TransferJob(
                id: UUID(),
                kind: .download,
                status: .queued,
                title: item.object.name,
                objectKey: item.object.key,
                localURL: dest,
                transferred: 0,
                total: item.object.size,
                errorMessage: nil,
                publicURL: nil,
                finishedAt: nil
            )
            jobs.append(job)
            let jobID = job.id
            retryDescriptors[jobID] = .download(
                DownloadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: bucket,
                    object: item.object,
                    destination: dest,
                    scopedRoot: scopedRoot,
                    speedLimit: speedLimit ?? downloadSpeedLimit,
                    allowOverwrite: allowOverwrite
                )
            )
            if let account,
               let relativeDestination = Self.relativePath(from: scopedRoot, to: dest),
               let rootBookmark = try? bookmarks.makeBookmark(for: scopedRoot) {
                persistedRetries[jobID] = .download(
                    PersistedDownloadRetry(
                        accountID: account.id,
                        bucket: bucket,
                        rootBookmark: rootBookmark,
                        object: item.object,
                        relativeDestination: relativeDestination,
                        allowOverwrite: allowOverwrite
                    )
                )
            }
            resources[jobID] = TransferResource(
                retainedResources: [rootLease].compactMap { $0 }
            )
            startTask(for: jobID)
        }
        persistJournal()
        updateDockBadge()
    }

    func pause(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.isActive else { return }
        userIntents[id] = .pause
        tasks[id]?.cancel()
        mutate(id) { current in
            current.status = .paused
            current.finishedAt = nil
            current.errorMessage = nil
        }
        if job.status == .queued {
            tasks[id] = nil
        }
        pumpFinished()
    }

    func resume(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }),
              job.status == .paused,
              retryDescriptors[id] != nil
        else { return }
        mutate(id) { current in
            current.status = .queued
            current.finishedAt = nil
            current.errorMessage = nil
        }
        startTask(for: id)
    }

    func pauseAll() {
        jobs.filter { $0.status == .running }.forEach { pause($0.id) }
    }

    func resumeAll() {
        jobs.filter { $0.status == .paused }.forEach { resume($0.id) }
    }

    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }),
              job.isActive || job.status == .paused
        else { return }
        userIntents[id] = .cancel
        tasks[id]?.cancel()
        mutate(id) { current in
            current.status = .cancelled
            current.finishedAt = .now
        }
        if job.status != .running {
            tasks[id] = nil
            let descriptor = retryDescriptors[id]
            let checkpoint = checkpoints[id]
            Task { [weak self] in
                await self?.discardCheckpoint(checkpoint, descriptor: descriptor)
            }
            checkpoints[id] = nil
            finishResource(id)
        }
        pumpFinished()
        if activeCount == 0, !jobs.contains(where: { $0.status == .paused }) {
            onAllFinished?()
        }
    }

    func cancelAll() {
        jobs.filter { $0.isActive || $0.status == .paused }.forEach { cancel($0.id) }
    }

    func clearFinished() {
        let removedIDs = Set(jobs.filter(\.isFinished).map(\.id))
        jobs.removeAll(where: \.isFinished)
        for id in removedIDs {
            let checkpoint = checkpoints[id]
            let descriptor = retryDescriptors[id]
            Task { [weak self] in
                await self?.discardCheckpoint(checkpoint, descriptor: descriptor)
            }
            retryDescriptors[id] = nil
            persistedRetries[id] = nil
            unavailableRetryReasons[id] = nil
            checkpoints[id] = nil
            progressSamples[id] = nil
        }
        persistJournal()
    }

    func canRetry(_ id: UUID) -> Bool {
        guard let descriptor = retryDescriptors[id] else { return false }
        switch descriptor {
        case .upload(let upload):
            return FileManager.default.fileExists(atPath: upload.sourceURL.path)
        case .download:
            return true
        }
    }

    func canResume(_ id: UUID) -> Bool {
        jobs.first(where: { $0.id == id })?.status == .paused && retryDescriptors[id] != nil
    }

    func checkpoint(for id: UUID) -> TransferCheckpoint? {
        checkpoints[id]
    }

    func recordCheckpoint(_ id: UUID, checkpoint: TransferCheckpoint?) {
        checkpoints[id] = checkpoint
        // Checkpoint callbacks fire per chunk; persist at most every ~0.5 s
        // per job instead of rewriting the whole journal per chunk. The final
        // state is always flushed by the status-change persistJournal calls.
        let now = ProcessInfo.processInfo.systemUptime
        if checkpoint == nil || now - (lastCheckpointWrite[id] ?? -.infinity) >= 0.5 {
            lastCheckpointWrite[id] = now
            persistJournal()
        }
    }

    func moveToTop(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status == .queued
        else { return }
        let job = jobs.remove(at: index)
        let destination = jobs.firstIndex(where: { $0.status == .queued }) ?? jobs.endIndex
        jobs.insert(job, at: destination)
        persistJournal()
    }

    func unavailableRetryReason(_ id: UUID) -> String? {
        unavailableRetryReasons[id]
    }

    func retry(_ id: UUID) {
        guard let descriptor = retryDescriptors[id] else { return }
        switch descriptor {
        case .upload(let upload):
            guard FileManager.default.fileExists(atPath: upload.sourceURL.path) else { return }
            Task {
                let plan = await Self.planUploads(
                    urls: [upload.sourceURL],
                    prefix: "",
                    template: "",
                    applyTemplate: false,
                    options: upload.options
                )
                var exactPlan = plan
                if !exactPlan.items.isEmpty {
                    exactPlan.items[0].objectKey = upload.objectKey
                }
                enqueue(
                    plan: exactPlan,
                    client: upload.client,
                    account: upload.account,
                    bucket: upload.bucket,
                    concurrentUploads: concurrency,
                    speedLimit: upload.speedLimit,
                    playCompleteSound: upload.playSound,
                    allowOverwrite: upload.allowOverwrite
                )
            }
        case .download(let download):
            enqueueDownloadJobs(
                items: [(download.object, download.destination)],
                client: download.client,
                account: download.account,
                bucket: download.bucket,
                scopedRoot: download.scopedRoot,
                speedLimit: download.speedLimit,
                allowOverwrite: download.allowOverwrite
            )
        }
    }

    func restore(accounts: [OSSAccount]) {
        guard let records = try? journal.load() else { return }
        jobs = records.map(\.job)
        retryDescriptors.removeAll()
        persistedRetries.removeAll()
        unavailableRetryReasons.removeAll()
        var restored: [UUID: TransferCheckpoint] = [:]
        for record in records {
            if let checkpoint = record.checkpoint {
                restored[record.job.id] = checkpoint
            }
        }
        checkpoints = restored

        for record in records {
            let id = record.job.id
            if jobs.first(where: { $0.id == id })?.isActive == true,
               record.checkpoint != nil {
                mutate(id, persist: false) { job in
                    job.status = .paused
                    job.errorMessage = nil
                    job.finishedAt = nil
                }
            } else if jobs.first(where: { $0.id == id })?.isActive == true {
                mutate(id, persist: false) { job in
                    job.status = .failed
                    job.errorMessage = "上次退出时传输中断，可重试"
                    job.finishedAt = .now
                }
            }
            guard let retry = record.retry else { continue }
            persistedRetries[id] = retry
            restore(retry: retry, for: id, accounts: accounts)
            rehydrateJobURLs(id)
        }
        persistJournal()
        updateDockBadge()
    }

    private func enqueue(
        plan: UploadPlan,
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        concurrentUploads: Int,
        speedLimit: TransferSpeedLimit,
        playCompleteSound: Bool,
        excludingSources: Set<URL> = [],
        allowOverwrite: Bool = false
    ) {
        concurrency = concurrentUploads
        uploadSpeedLimit = speedLimit
        for item in plan.items {
            if let failure = item.failure {
                jobs.append(
                    TransferJob(
                        id: UUID(),
                        kind: .upload,
                        status: .failed,
                        title: item.filename,
                        objectKey: item.objectKey,
                        localURL: item.sourceURL,
                        transferred: 0,
                        total: 0,
                        errorMessage: failure,
                        publicURL: nil,
                        finishedAt: .now
                    )
                )
                item.resource.finish()
                continue
            }
            if excludingSources.contains(item.sourceURL) {
                item.resource.finish()
                continue
            }
            let job = TransferJob(
                id: UUID(),
                kind: .upload,
                status: .queued,
                title: item.filename,
                objectKey: item.objectKey,
                localURL: item.fileURL,
                transferred: 0,
                total: item.size,
                errorMessage: nil,
                publicURL: account.publicURL(
                    bucketName: client.bucket ?? bucket?.name ?? "",
                    bucket: bucket,
                    key: item.objectKey
                ),
                finishedAt: nil
            )
            jobs.append(job)
            retryDescriptors[job.id] = .upload(
                UploadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: bucket,
                    sourceURL: item.sourceURL,
                    preparedFileURL: item.fileURL,
                    objectKey: item.objectKey,
                    contentType: item.contentType,
                    acl: account.defaultACL,
                    options: plan.options,
                    speedLimit: speedLimit,
                    playSound: playCompleteSound,
                    allowOverwrite: allowOverwrite
                )
            )
            if let sourceBookmark = try? bookmarks.makeBookmark(for: item.sourceURL) {
                let preparedBookmark: Data?
                if item.fileURL.standardizedFileURL != item.sourceURL.standardizedFileURL {
                    preparedBookmark = try? bookmarks.makeBookmark(for: item.fileURL)
                } else {
                    preparedBookmark = nil
                }
                persistedRetries[job.id] = .upload(
                    PersistedUploadRetry(
                        accountID: account.id,
                        bucket: bucket,
                        sourceBookmark: sourceBookmark,
                        objectKey: item.objectKey,
                        imagesOnly: plan.options.imagesOnly,
                        convertHEIC: plan.options.convertHEIC,
                        playSound: playCompleteSound,
                        allowOverwrite: allowOverwrite,
                        preparedBookmark: preparedBookmark
                    )
                )
            }
            resources[job.id] = item.resource
            startTask(for: job.id)
        }
        persistJournal()
        updateDockBadge()
    }

    private func runUpload(
        id: UUID,
        client: OSSClient,
        key: String,
        fileURL: URL,
        contentType: String,
        acl: ObjectACL,
        speedLimit: TransferSpeedLimit,
        playSound: Bool,
        allowOverwrite: Bool
    ) async {
        guard await waitForSlot(id: id, kind: .upload) else {
            if jobs.first(where: { $0.id == id })?.status == .cancelled {
                finishResource(id)
            }
            return
        }
        defer {
            finishSlot(kind: .upload)
        }
        mutate(id) { $0.status = .running }
        do {
            let suppliedCheckpoint: MultipartUploadCheckpoint?
            if case .upload(let checkpoint) = checkpoints[id] {
                suppliedCheckpoint = checkpoint
            } else {
                suppliedCheckpoint = nil
            }
            let integrityVerified = try await client.putObject(
                key: key,
                fileURL: fileURL,
                contentType: contentType,
                acl: acl,
                overwrite: allowOverwrite,
                speedLimit: speedLimit,
                checkpoint: suppliedCheckpoint,
                onCheckpoint: { [weak self] checkpoint in
                    Task { @MainActor in
                        self?.recordCheckpoint(
                            id,
                            checkpoint: checkpoint.map(TransferCheckpoint.upload)
                        )
                    }
                },
                onProgress: { [weak self] sent, total in
                Task { @MainActor in
                    self?.recordProgress(id, transferred: sent, total: total)
                }
            })
            mutate(id) { job in
                job.status = .completed
                job.transferred = job.total
                job.finishedAt = .now
                job.integrityVerified = integrityVerified
            }
            checkpoints[id] = nil
            finishResource(id)
            Haptics.commit()
            if playSound {
                NSSound(named: "Glass")?.play()
            }
            onUploadFinished?()
        } catch is CancellationError {
            await finishCancellation(id: id)
        } catch {
            // Failed jobs are only retried from scratch (never resumed), so
            // discard the checkpoint now: otherwise a failed multipart upload
            // keeps its uploadID (and billed parts) on OSS forever, and a
            // failed download leaves its .partial file behind.
            let checkpoint = checkpoints[id]
            let descriptor = retryDescriptors[id]
            Task { [weak self] in
                await self?.discardCheckpoint(checkpoint, descriptor: descriptor)
            }
            checkpoints[id] = nil
            mutate(id) { job in
                job.status = .failed
                job.errorMessage = error.localizedDescription
                job.finishedAt = .now
            }
            finishResource(id)
        }
    }

    private func startTask(for id: UUID) {
        guard let descriptor = retryDescriptors[id] else { return }
        switch descriptor {
        case .upload(let upload):
            tasks[id] = Task { [weak self] in
                await self?.runPreparedUpload(id: id, upload: upload)
            }
        case .download(let download):
            tasks[id] = Task { [weak self] in
                await self?.runDownload(
                    id: id,
                    client: download.client,
                    key: download.object.key,
                    destination: download.destination,
                    root: download.scopedRoot,
                    speedLimit: download.speedLimit,
                    overwrite: download.allowOverwrite
                )
            }
        }
    }

    private func runPreparedUpload(id: UUID, upload: UploadRetryDescriptor) async {
        var fileURL = upload.preparedFileURL
        var contentType = upload.contentType
        if upload.needsPreparation {
            do {
                let prepared = try await Self.prepare(
                    url: upload.sourceURL,
                    convertHEIC: upload.options.convertHEIC
                )
                fileURL = prepared.fileURL
                contentType = prepared.contentType
                if prepared.fileURL != upload.sourceURL {
                    resources[id] = TransferResource(cleanupURLs: [prepared.fileURL])
                    if case .upload(var persisted) = persistedRetries[id] {
                        persisted.preparedBookmark = try? bookmarks.makeBookmark(for: prepared.fileURL)
                        persistedRetries[id] = .upload(persisted)
                    }
                }
                var updated = upload
                updated.preparedFileURL = fileURL
                updated.contentType = contentType
                updated.needsPreparation = false
                retryDescriptors[id] = .upload(updated)
                mutate(id) { job in
                    job.total = prepared.size
                }
            } catch {
                mutate(id) { job in
                    job.status = .failed
                    job.errorMessage = error.localizedDescription
                    job.finishedAt = .now
                }
                finishResource(id)
                pumpFinished()
                if activeCount == 0, !jobs.contains(where: { $0.status == .paused }) {
                    onAllFinished?()
                }
                return
            }
        }
        await runUpload(
            id: id,
            client: upload.client,
            key: upload.objectKey,
            fileURL: fileURL,
            contentType: contentType,
            acl: upload.acl,
            speedLimit: upload.speedLimit,
            playSound: upload.playSound,
            allowOverwrite: upload.allowOverwrite
        )
    }

    private func finishCancellation(id: UUID) async {
        let intent = userIntents.removeValue(forKey: id) ?? .cancel
        if intent == .pause {
            if jobs.first(where: { $0.id == id })?.status != .queued {
                mutate(id) { job in
                    job.status = .paused
                    job.finishedAt = nil
                    job.errorMessage = nil
                }
            }
            return
        }
        let checkpoint = checkpoints[id]
        await discardCheckpoint(checkpoint, descriptor: retryDescriptors[id])
        checkpoints[id] = nil
        finishResource(id)
        mutate(id) { job in
            job.status = .cancelled
            job.finishedAt = .now
        }
    }

    private func discardCheckpoint(
        _ checkpoint: TransferCheckpoint?,
        descriptor: RetryDescriptor?
    ) async {
        guard let checkpoint, let descriptor else { return }
        switch (checkpoint, descriptor) {
        case (.upload(let upload), .upload(let retry)):
            try? await retry.client.abortMultipartUpload(upload)
        case (.download(let download), .download(let retry)):
            try? retry.client.removePartialDownload(
                checkpoint: download,
                destination: retry.destination,
                within: retry.scopedRoot
            )
        default:
            break
        }
    }

    private func runDownload(
        id: UUID,
        client: OSSClient,
        key: String,
        destination: URL,
        root: URL,
        speedLimit: TransferSpeedLimit,
        overwrite: Bool
    ) async {
        guard await waitForSlot(id: id, kind: .download) else {
            if jobs.first(where: { $0.id == id })?.status == .cancelled {
                finishResource(id)
            }
            return
        }
        defer {
            finishSlot(kind: .download)
        }
        mutate(id) { $0.status = .running }
        do {
            let suppliedCheckpoint: RangeDownloadCheckpoint?
            if case .download(let checkpoint) = checkpoints[id] {
                suppliedCheckpoint = checkpoint
            } else {
                suppliedCheckpoint = nil
            }
            let expectedSize = jobs.first(where: { $0.id == id })?.total ?? 0
            let integrityVerified = try await client.downloadResumable(
                key: key,
                to: destination,
                within: root,
                expectedSize: expectedSize,
                overwrite: overwrite,
                speedLimit: speedLimit,
                checkpoint: suppliedCheckpoint,
                onCheckpoint: { [weak self] checkpoint in
                    Task { @MainActor in
                        self?.recordCheckpoint(
                            id,
                            checkpoint: checkpoint.map(TransferCheckpoint.download)
                        )
                    }
                },
                onProgress: { [weak self] sent, total in
                    Task { @MainActor in
                        self?.recordProgress(id, transferred: sent, total: total)
                    }
                }
            )
            mutate(id) { job in
                job.status = .completed
                job.transferred = max(job.transferred, job.total)
                job.finishedAt = .now
                job.integrityVerified = integrityVerified
            }
            checkpoints[id] = nil
            finishResource(id)
            Haptics.commit()
        } catch is CancellationError {
            await finishCancellation(id: id)
        } catch {
            // See the upload path: a failed download must not keep its
            // .partial file around for retries that start from scratch.
            let checkpoint = checkpoints[id]
            let descriptor = retryDescriptors[id]
            Task { [weak self] in
                await self?.discardCheckpoint(checkpoint, descriptor: descriptor)
            }
            checkpoints[id] = nil
            mutate(id) { job in
                job.status = .failed
                job.errorMessage = error.localizedDescription
                job.finishedAt = .now
            }
            finishResource(id)
        }
    }

    private func waitForSlot(id: UUID, kind: TransferKind) async -> Bool {
        while !Task.isCancelled {
            guard let index = jobs.firstIndex(where: { $0.id == id }),
                  jobs[index].status == .queued
            else { return false }
            let hasEarlierQueued = jobs[..<index].contains { $0.status == .queued && $0.kind == kind }
            let hasCapacity = kind == .upload
                ? runningUploads < concurrency
                : runningDownloads < downloadConcurrency
            if hasCapacity && !hasEarlierQueued { break }
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !Task.isCancelled else { return false }
        if kind == .upload {
            runningUploads += 1
        } else {
            runningDownloads += 1
        }
        return true
    }

    private func finishSlot(kind: TransferKind) {
        if kind == .upload {
            runningUploads = max(0, runningUploads - 1)
        } else {
            runningDownloads = max(0, runningDownloads - 1)
        }
        pumpFinished()
        // Paused jobs are deliberately not active; only fire "all finished"
        // when nothing is running, queued, or paused.
        if activeCount == 0, !jobs.contains(where: { $0.status == .paused }) {
            onAllFinished?()
        }
    }

    private func pumpFinished() {
        tasks = tasks.filter { pair in
            jobs.first(where: { $0.id == pair.key })?.isActive ?? false
        }
        updateDockBadge()
    }

    private func finishResource(_ id: UUID) {
        resources.removeValue(forKey: id)?.finish()
    }

    private func mutate(_ id: UUID, persist: Bool = true, _ body: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
        if persist { persistJournal() }
    }

    func recordProgress(
        _ id: UUID,
        transferred: Int64,
        total: Int64,
        at timestamp: Date = .now
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isActive else { return }
        jobs[index].transferred = transferred
        if total > 0 { jobs[index].total = total }
        var samples = progressSamples[id, default: []]
        samples.append((timestamp, transferred))
        let cutoff = timestamp.addingTimeInterval(-30)
        samples.removeAll { $0.date < cutoff }
        if samples.count > 8 {
            samples.removeFirst(samples.count - 8)
        }
        progressSamples[id] = samples

        if let lastProgressPersistenceAt,
           timestamp.timeIntervalSince(lastProgressPersistenceAt) < 1 {
            return
        }
        lastProgressPersistenceAt = timestamp
        persistJournal()
    }

    func currentBytesPerSecond(_ id: UUID) -> Double? {
        guard let samples = progressSamples[id],
              let first = samples.first,
              let last = samples.last,
              last.date > first.date,
              last.bytes >= first.bytes
        else { return nil }
        return Double(last.bytes - first.bytes) / last.date.timeIntervalSince(first.date)
    }

    func estimatedRemaining(_ id: UUID) -> TimeInterval? {
        guard let job = jobs.first(where: { $0.id == id }),
              let rate = currentBytesPerSecond(id), rate > 0
        else { return nil }
        return Double(max(0, job.total - job.transferred)) / rate
    }

    private func updateDockBadge() {
        let count = activeCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        ProcessLifetime.setTransfersActive(count > 0)
    }

    private enum RetryDescriptor: Sendable {
        case upload(UploadRetryDescriptor)
        case download(DownloadRetryDescriptor)
    }

    private struct UploadRetryDescriptor: Sendable {
        var client: OSSClient
        var account: OSSAccount
        var bucket: OSSBucket?
        var sourceURL: URL
        var preparedFileURL: URL
        var objectKey: String
        var contentType: String
        var acl: ObjectACL
        var options: UploadPreparationOptions
        var speedLimit: TransferSpeedLimit
        var playSound: Bool
        var allowOverwrite: Bool
        var needsPreparation: Bool = false
    }

    private struct DownloadRetryDescriptor: Sendable {
        var client: OSSClient
        var account: OSSAccount?
        var bucket: OSSBucket?
        var object: OSSObject
        var destination: URL
        var scopedRoot: URL
        var speedLimit: TransferSpeedLimit
        var allowOverwrite: Bool = false
    }

    private func restore(
        retry: PersistedTransferRetry,
        for id: UUID,
        accounts: [OSSAccount]
    ) {
        switch retry {
        case .upload(let upload):
            guard let account = accounts.first(where: { $0.id == upload.accountID }) else {
                unavailableRetryReasons[id] = "原账号已不存在，无法重试。"
                return
            }
            guard let source = try? bookmarks.resolve(upload.sourceBookmark) else {
                unavailableRetryReasons[id] = "原文件或文件夹权限已失效，请重新选择后再上传。"
                return
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                unavailableRetryReasons[id] = "原文件已移动或删除，请重新选择后再上传。"
                return
            }
            guard let client = try? clientProvider(account, upload.bucket) else {
                unavailableRetryReasons[id] = "账号密钥不可用，请重新编辑账号后再重试。"
                return
            }
            let converted = upload.convertHEIC && Self.isConvertibleHEIC(source)
            var prepared = source
            var needsPreparation = false
            if converted {
                if let preparedBookmark = upload.preparedBookmark,
                   let preparedURL = try? bookmarks.resolve(preparedBookmark),
                   FileManager.default.fileExists(atPath: preparedURL.path) {
                    prepared = preparedURL
                    resources[id] = TransferResource(cleanupURLs: [preparedURL])
                } else {
                    needsPreparation = true
                }
            }
            retryDescriptors[id] = .upload(
                UploadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: upload.bucket,
                    sourceURL: source,
                    preparedFileURL: prepared,
                    objectKey: upload.objectKey,
                    contentType: converted
                        ? "image/jpeg"
                        : (UTType(filenameExtension: source.pathExtension)?.preferredMIMEType
                            ?? "application/octet-stream"),
                    acl: account.defaultACL,
                    options: UploadPreparationOptions(
                        imagesOnly: upload.imagesOnly,
                        convertHEIC: upload.convertHEIC
                    ),
                    speedLimit: uploadSpeedLimit,
                    playSound: upload.playSound,
                    allowOverwrite: upload.allowOverwrite == true,
                    needsPreparation: needsPreparation
                )
            )
        case .download(let download):
            guard let account = accounts.first(where: { $0.id == download.accountID }) else {
                unavailableRetryReasons[id] = "原账号已不存在，无法重试。"
                return
            }
            guard let root = try? bookmarks.resolve(download.rootBookmark),
                  let destination = try? FileSafety.destination(
                    root: root,
                    relativePath: download.relativeDestination
                  ) else {
                unavailableRetryReasons[id] = "下载目录权限已失效，请重新选择目录。"
                return
            }
            guard let client = try? clientProvider(account, download.bucket) else {
                unavailableRetryReasons[id] = "账号密钥不可用，请重新编辑账号后再重试。"
                return
            }
            retryDescriptors[id] = .download(
                DownloadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: download.bucket,
                    object: download.object,
                    destination: destination,
                    scopedRoot: root,
                    speedLimit: downloadSpeedLimit,
                    allowOverwrite: download.allowOverwrite == true
                )
            )
        }
    }

    private func rehydrateJobURLs(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              let descriptor = retryDescriptors[id]
        else { return }
        switch descriptor {
        case .download(let download):
            jobs[index].localURL = download.destination
        case .upload(let upload):
            if jobs[index].localURL == nil {
                jobs[index].localURL = upload.sourceURL
            }
            if jobs[index].publicURL == nil {
                jobs[index].publicURL = upload.account.publicURL(
                    bucketName: upload.client.bucket ?? upload.bucket?.name ?? "",
                    bucket: upload.bucket,
                    key: upload.objectKey
                )
            }
        }
    }

    nonisolated private static func isConvertibleHEIC(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "heic" || ext == "heif"
    }

    private func persistJournal() {
        let records = jobs.map { job in
            PersistedTransfer(
                job: job,
                retry: persistedRetries[job.id],
                checkpoint: checkpoints[job.id]
            )
        }
        try? journal.save(records)
    }

    nonisolated private static func relativePath(from root: URL, to destination: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let destinationPath = destination.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard destinationPath.hasPrefix(prefix) else { return nil }
        return String(destinationPath.dropFirst(prefix.count))
    }

    private struct PreparedUpload {
        var fileURL: URL
        var filename: String
        var contentType: String
        var size: Int64
    }

    private struct ExpandedFile {
        var url: URL
        var relativePath: String
    }

    private struct Expansion {
        var files: [ExpandedFile]
        var skipped: Int
    }

    private enum UserIntent {
        case pause
        case cancel
    }

    nonisolated private static func expand(_ urls: [URL]) -> Expansion {
        var result: [ExpandedFile] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let file as URL in enumerator {
                        let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
                        if values?.isRegularFile == false { continue }
                        let relative = PathTemplate.nestedRelative(
                            rootName: url.lastPathComponent,
                            rootPath: url.path,
                            filePath: file.path
                        )
                        result.append(ExpandedFile(url: file, relativePath: relative))
                    }
                }
            } else {
                result.append(ExpandedFile(url: url, relativePath: url.lastPathComponent))
            }
        }
        return Expansion(files: result, skipped: 0)
    }

    nonisolated private static func prepare(url: URL, convertHEIC: Bool) async throws -> PreparedUpload {
        try await ensureUbiquitousItemIsDownloaded(url)
        let ext = url.pathExtension.lowercased()
        if convertHEIC, ext == "heic" || ext == "heif" {
            guard let image = NSImage(contentsOf: url),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            else {
                throw OSSServiceError(statusCode: 0, code: "HEICConvert", message: "无法将 HEIC 转为 JPEG", requestId: "")
            }
            let name = (url.lastPathComponent as NSString).deletingPathExtension + ".jpg"
            let dest = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + "-" + name)
            try jpeg.write(to: dest)
            return PreparedUpload(fileURL: dest, filename: name, contentType: "image/jpeg", size: Int64(jpeg.count))
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return PreparedUpload(
            fileURL: url,
            filename: url.lastPathComponent,
            contentType: ImageKind.contentType(for: url.lastPathComponent),
            size: Int64(values.fileSize ?? 0)
        )
    }

    nonisolated private static func ensureUbiquitousItemIsDownloaded(_ url: URL) async throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var values = try url.resourceValues(forKeys: keys)
        guard values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus == .notDownloaded
        else { return }

        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<300 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
            values = try url.resourceValues(forKeys: keys)
            if values.ubiquitousItemDownloadingStatus != .notDownloaded {
                return
            }
        }
        throw OSSServiceError(
            statusCode: 0,
            code: "ICloudDownloadTimeout",
            message: "等待 iCloud 下载文件超时",
            requestId: ""
        )
    }
}
