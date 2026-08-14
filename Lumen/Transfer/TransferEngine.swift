import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class TransferEngine {
    var jobs: [TransferJob] = []
    var concurrency = 3
    var onUploadFinished: (@MainActor () -> Void)?

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var resources: [UUID: TransferResource] = [:]
    private var retryDescriptors: [UUID: RetryDescriptor] = [:]
    private var persistedRetries: [UUID: PersistedTransferRetry] = [:]
    private var unavailableRetryReasons: [UUID: String] = [:]
    private var running = 0
    private let journal: any TransferJournaling
    private let bookmarks: any TransferBookmarking
    private let now: @MainActor @Sendable () -> Date
    private var lastProgressPersistenceAt: Date?
    private let clientProvider: @MainActor @Sendable (OSSAccount, OSSBucket?) throws -> OSSClient

    init(
        journal: any TransferJournaling = NoopTransferJournal(),
        bookmarks: any TransferBookmarking = SecurityScopedTransferBookmarks(),
        now: @escaping @MainActor @Sendable () -> Date = { .now },
        clientProvider: @escaping @MainActor @Sendable (OSSAccount, OSSBucket?) throws -> OSSClient = { account, bucket in
            OSSClient(
                credentials: try AccountStore.credentials(for: account),
                region: account.signingRegion(for: bucket),
                endpointHost: account.apiHost(for: bucket),
                bucket: bucket?.name
            )
        }
    ) {
        self.journal = journal
        self.bookmarks = bookmarks
        self.now = now
        self.clientProvider = clientProvider
    }

    var activeCount: Int { jobs.filter(\.isActive).count }
    var hasJobs: Bool { !jobs.isEmpty }
    var completedThisSession: [TransferJob] { jobs.filter { $0.status == .completed } }

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
        let expansion = expand(urls, imagesOnly: options.imagesOnly)
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
        excludingSources: Set<URL> = []
    ) {
        enqueue(
            plan: plan,
            client: client,
            account: account,
            bucket: bucket,
            concurrentUploads: settings.concurrentUploads,
            playCompleteSound: settings.playCompleteSound,
            excludingSources: excludingSources
        )
    }

    func abandon(plan: UploadPlan) {
        plan.items.forEach { $0.resource.finish() }
    }

    func enqueueDownloads(
        objects: [OSSObject],
        client: OSSClient,
        account: OSSAccount? = nil,
        bucket: OSSBucket? = nil,
        folder: URL
    ) {
        enqueueDownloadJobs(
            items: objects.map { ($0, folder.appending(path: $0.name)) },
            client: client,
            account: account,
            bucket: bucket,
            scopedRoot: folder
        )
    }

    func enqueueDownloadJobs(
        items: [(object: OSSObject, destination: URL)],
        client: OSSClient,
        account: OSSAccount? = nil,
        bucket: OSSBucket? = nil,
        scopedRoot: URL
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
            let key = item.object.key
            retryDescriptors[jobID] = .download(
                DownloadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: bucket,
                    object: item.object,
                    destination: dest,
                    scopedRoot: scopedRoot
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
                        relativeDestination: relativeDestination
                    )
                )
            }
            resources[jobID] = TransferResource(
                retainedResources: [rootLease].compactMap { $0 }
            )
            tasks[jobID] = Task { [weak self] in
                await self?.runDownload(
                    id: jobID,
                    client: client,
                    key: key,
                    destination: dest,
                    root: scopedRoot
                )
            }
        }
        persistJournal()
        updateDockBadge()
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
        finishResource(id)
        mutate(id) { job in
            if job.isActive {
                job.status = .cancelled
                job.finishedAt = .now
            }
        }
        pumpFinished()
    }

    func cancelAll() {
        jobs.filter(\.isActive).forEach { cancel($0.id) }
    }

    func clearFinished() {
        let removedIDs = Set(jobs.filter { !$0.isActive }.map(\.id))
        jobs.removeAll { !$0.isActive }
        for id in removedIDs {
            retryDescriptors[id] = nil
            persistedRetries[id] = nil
            unavailableRetryReasons[id] = nil
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
                    playCompleteSound: upload.playSound
                )
            }
        case .download(let download):
            enqueueDownloadJobs(
                items: [(download.object, download.destination)],
                client: download.client,
                account: download.account,
                bucket: download.bucket,
                scopedRoot: download.scopedRoot
            )
        }
    }

    func restore(accounts: [OSSAccount]) {
        guard let records = try? journal.load() else { return }
        jobs = records.map(\.job)
        retryDescriptors.removeAll()
        persistedRetries.removeAll()
        unavailableRetryReasons.removeAll()

        for record in records {
            let id = record.job.id
            if jobs.first(where: { $0.id == id })?.isActive == true {
                mutate(id, persist: false) { job in
                    job.status = .failed
                    job.errorMessage = "上次退出时传输中断，可重试"
                    job.finishedAt = .now
                }
            }
            guard let retry = record.retry else { continue }
            persistedRetries[id] = retry
            restore(retry: retry, for: id, accounts: accounts)
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
        playCompleteSound: Bool,
        excludingSources: Set<URL> = []
    ) {
        concurrency = concurrentUploads
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
                    objectKey: item.objectKey,
                    options: plan.options,
                    playSound: playCompleteSound
                )
            )
            if let sourceBookmark = try? bookmarks.makeBookmark(for: item.sourceURL) {
                persistedRetries[job.id] = .upload(
                    PersistedUploadRetry(
                        accountID: account.id,
                        bucket: bucket,
                        sourceBookmark: sourceBookmark,
                        objectKey: item.objectKey,
                        imagesOnly: plan.options.imagesOnly,
                        convertHEIC: plan.options.convertHEIC,
                        playSound: playCompleteSound
                    )
                )
            }
            resources[job.id] = item.resource
            tasks[job.id] = Task { [weak self] in
                await self?.runUpload(
                    id: job.id,
                    client: client,
                    key: item.objectKey,
                    fileURL: item.fileURL,
                    contentType: item.contentType,
                    acl: account.defaultACL,
                    playSound: playCompleteSound
                )
            }
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
        playSound: Bool
    ) async {
        guard await waitForSlot() else {
            mutate(id) { $0.status = .cancelled; $0.finishedAt = .now }
            finishResource(id)
            return
        }
        defer {
            finishResource(id)
            finishSlot()
        }
        mutate(id) { $0.status = .running }
        do {
            let integrityVerified = try await client.putObject(key: key, fileURL: fileURL, contentType: contentType, acl: acl) { [weak self] sent, total in
                Task { @MainActor in
                    self?.recordProgress(id, transferred: sent, total: total)
                }
            }
            mutate(id) { job in
                job.status = .completed
                job.transferred = job.total
                job.finishedAt = .now
                job.integrityVerified = integrityVerified
            }
            Haptics.commit()
            if playSound {
                NSSound(named: "Glass")?.play()
            }
            onUploadFinished?()
        } catch is CancellationError {
            mutate(id) { $0.status = .cancelled; $0.finishedAt = .now }
        } catch {
            mutate(id) { job in
                job.status = .failed
                job.errorMessage = error.localizedDescription
                job.finishedAt = .now
            }
        }
    }

    private func runDownload(
        id: UUID,
        client: OSSClient,
        key: String,
        destination: URL,
        root: URL
    ) async {
        guard await waitForSlot() else {
            mutate(id) { $0.status = .cancelled; $0.finishedAt = .now }
            finishResource(id)
            return
        }
        defer {
            finishResource(id)
            finishSlot()
        }
        mutate(id) { $0.status = .running }
        do {
            let integrityVerified = try await client.download(key: key, to: destination, within: root) { [weak self] sent, total in
                Task { @MainActor in
                    self?.recordProgress(id, transferred: sent, total: total)
                }
            }
            mutate(id) { job in
                job.status = .completed
                job.transferred = max(job.transferred, job.total)
                job.finishedAt = .now
                job.integrityVerified = integrityVerified
            }
            Haptics.commit()
        } catch is CancellationError {
            mutate(id) { $0.status = .cancelled; $0.finishedAt = .now }
        } catch {
            mutate(id) { job in
                job.status = .failed
                job.errorMessage = error.localizedDescription
                job.finishedAt = .now
            }
        }
    }

    private func waitForSlot() async -> Bool {
        while running >= concurrency && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !Task.isCancelled else { return false }
        running += 1
        return true
    }

    private func finishSlot() {
        running = max(0, running - 1)
        pumpFinished()
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

    func recordProgress(_ id: UUID, transferred: Int64, total: Int64) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].isActive else { return }
        jobs[index].transferred = transferred
        if total > 0 { jobs[index].total = total }

        let timestamp = now()
        if let lastProgressPersistenceAt,
           timestamp.timeIntervalSince(lastProgressPersistenceAt) < 1 {
            return
        }
        lastProgressPersistenceAt = timestamp
        persistJournal()
    }

    private func updateDockBadge() {
        let count = activeCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
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
        var objectKey: String
        var options: UploadPreparationOptions
        var playSound: Bool
    }

    private struct DownloadRetryDescriptor: Sendable {
        var client: OSSClient
        var account: OSSAccount?
        var bucket: OSSBucket?
        var object: OSSObject
        var destination: URL
        var scopedRoot: URL
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
            retryDescriptors[id] = .upload(
                UploadRetryDescriptor(
                    client: client,
                    account: account,
                    bucket: upload.bucket,
                    sourceURL: source,
                    objectKey: upload.objectKey,
                    options: UploadPreparationOptions(
                        imagesOnly: upload.imagesOnly,
                        convertHEIC: upload.convertHEIC
                    ),
                    playSound: upload.playSound
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
                    scopedRoot: root
                )
            )
        }
    }

    private func persistJournal() {
        let records = jobs.map { job in
            PersistedTransfer(job: job, retry: persistedRetries[job.id])
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

    nonisolated private static func expand(_ urls: [URL], imagesOnly: Bool) -> Expansion {
        var result: [ExpandedFile] = []
        var skipped = 0
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
                        if imagesOnly && !ImageKind.isSupported(key: file.lastPathComponent) {
                            skipped += 1
                            continue
                        }
                        let relative = PathTemplate.nestedRelative(
                            rootName: url.lastPathComponent,
                            rootPath: url.path,
                            filePath: file.path
                        )
                        result.append(ExpandedFile(url: file, relativePath: relative))
                    }
                }
            } else {
                if imagesOnly && !ImageKind.isSupported(key: url.lastPathComponent) {
                    skipped += 1
                    continue
                }
                result.append(ExpandedFile(url: url, relativePath: url.lastPathComponent))
            }
        }
        return Expansion(files: result, skipped: skipped)
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
