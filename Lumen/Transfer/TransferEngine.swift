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
    private var running = 0
    private var scopedRoots: [URL] = []

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
        var releaseSource: Bool
        var failure: String?
    }

    struct UploadPlan {
        var items: [PlannedUpload]
        var skipped: Int
        var scopedRoots: [URL]
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
    ) -> Int {
        let plan = Self.planUploads(
            urls: urls,
            prefix: prefix,
            template: account.prefixTemplate,
            applyTemplate: applyTemplate,
            settings: settings
        )
        enqueue(plan: plan, client: client, account: account, bucket: bucket, settings: settings)
        return plan.skipped
    }

    static func planUploads(
        urls: [URL],
        prefix: String,
        template: String,
        applyTemplate: Bool,
        settings: AppSettings
    ) -> UploadPlan {
        var roots: [URL] = []
        for root in urls {
            if root.startAccessingSecurityScopedResource() {
                roots.append(root)
            }
        }
        let expansion = expand(urls, imagesOnly: settings.imagesOnly)
        var items: [PlannedUpload] = []
        for entry in expansion.files {
            let url = entry.url
            let accessed = url.startAccessingSecurityScopedResource()
            do {
                let prepared = try prepare(url: url, convertHEIC: settings.convertHEIC)
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
                        releaseSource: accessed,
                        failure: nil
                    )
                )
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                items.append(
                    PlannedUpload(
                        sourceURL: url,
                        fileURL: url,
                        filename: url.lastPathComponent,
                        contentType: "",
                        size: 0,
                        objectKey: "",
                        releaseSource: false,
                        failure: error.localizedDescription
                    )
                )
            }
        }
        return UploadPlan(items: items, skipped: expansion.skipped, scopedRoots: roots)
    }

    func enqueue(
        plan: UploadPlan,
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        settings: AppSettings,
        excludingSources: Set<URL> = []
    ) {
        concurrency = settings.concurrentUploads
        var addedActive = false
        scopedRoots.append(contentsOf: plan.scopedRoots)
        for item in plan.items {
            if let failure = item.failure {
                jobs.append(
                    TransferJob(
                        id: UUID(),
                        kind: .upload,
                        status: .failed,
                        title: item.filename,
                        objectKey: "",
                        localURL: item.sourceURL,
                        transferred: 0,
                        total: 0,
                        errorMessage: failure,
                        publicURL: nil,
                        finishedAt: .now
                    )
                )
                continue
            }
            if excludingSources.contains(item.sourceURL) {
                if item.releaseSource {
                    item.sourceURL.stopAccessingSecurityScopedResource()
                }
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
                publicURL: account.publicURL(bucketName: client.bucket ?? bucket?.name ?? "", bucket: bucket, key: item.objectKey),
                finishedAt: nil
            )
            jobs.append(job)
            addedActive = true
            let jobID = job.id
            tasks[jobID] = Task { [weak self] in
                await self?.runUpload(
                    id: jobID,
                    client: client,
                    key: item.objectKey,
                    fileURL: item.fileURL,
                    contentType: item.contentType,
                    acl: account.defaultACL,
                    release: item.releaseSource ? item.sourceURL : nil,
                    playSound: settings.playCompleteSound
                )
            }
        }
        if !addedActive {
            for root in plan.scopedRoots {
                root.stopAccessingSecurityScopedResource()
            }
            scopedRoots.removeAll { plan.scopedRoots.contains($0) }
        }
        updateDockBadge()
    }

    func abandon(plan: UploadPlan) {
        for item in plan.items where item.releaseSource {
            item.sourceURL.stopAccessingSecurityScopedResource()
        }
        for root in plan.scopedRoots {
            root.stopAccessingSecurityScopedResource()
        }
    }

    func enqueueDownloads(objects: [OSSObject], client: OSSClient, folder: URL) {
        enqueueDownloadJobs(
            items: objects.map { ($0, folder.appending(path: $0.name)) },
            client: client,
            scopedRoot: folder
        )
    }

    func enqueueDownloadJobs(
        items: [(object: OSSObject, destination: URL)],
        client: OSSClient,
        scopedRoot: URL
    ) {
        guard !items.isEmpty else { return }
        if scopedRoot.startAccessingSecurityScopedResource() {
            scopedRoots.append(scopedRoot)
        }
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
            tasks[jobID] = Task { [weak self] in
                await self?.runDownload(id: jobID, client: client, key: key, destination: dest)
            }
        }
        updateDockBadge()
    }

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
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
        jobs.removeAll { !$0.isActive }
    }

    func retry(_ id: UUID, client: OSSClient, account: OSSAccount, settings: AppSettings) {
        guard let job = jobs.first(where: { $0.id == id }), let local = job.localURL else { return }
        if job.kind == .upload {
            enqueueUploads(urls: [local], client: client, account: account, bucket: nil, prefix: PathTemplate.parentPrefix(job.objectKey), settings: settings)
        }
    }

    private func runUpload(
        id: UUID,
        client: OSSClient,
        key: String,
        fileURL: URL,
        contentType: String,
        acl: ObjectACL,
        release: URL?,
        playSound: Bool
    ) async {
        await waitForSlot(id: id)
        guard !Task.isCancelled else {
            mutate(id) { $0.status = .cancelled; $0.finishedAt = .now }
            finishSlot()
            return
        }
        mutate(id) { $0.status = .running }
        do {
            try await client.putObject(key: key, fileURL: fileURL, contentType: contentType, acl: acl) { [weak self] sent, total in
                Task { @MainActor in
                    self?.mutate(id) { job in
                        job.transferred = sent
                        if total > 0 { job.total = total }
                    }
                }
            }
            mutate(id) { job in
                job.status = .completed
                job.transferred = job.total
                job.finishedAt = .now
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
        if let release {
            release.stopAccessingSecurityScopedResource()
        }
        finishSlot()
    }

    private func runDownload(id: UUID, client: OSSClient, key: String, destination: URL) async {
        await waitForSlot(id: id)
        guard !Task.isCancelled else {
            mutate(id) { $0.status = .cancelled; $0.finishedAt = .now }
            finishSlot()
            return
        }
        mutate(id) { $0.status = .running }
        do {
            try await client.download(key: key, to: destination) { [weak self] sent, total in
                Task { @MainActor in
                    self?.mutate(id) { job in
                        job.transferred = sent
                        if total > 0 { job.total = total }
                    }
                }
            }
            mutate(id) { job in
                job.status = .completed
                job.transferred = max(job.transferred, job.total)
                job.finishedAt = .now
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
        finishSlot()
    }

    private func waitForSlot(id: UUID) async {
        while running >= concurrency && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(80))
        }
        running += 1
    }

    private func finishSlot() {
        running = max(0, running - 1)
        pumpFinished()
    }

    private func pumpFinished() {
        tasks = tasks.filter { pair in
            jobs.first(where: { $0.id == pair.key })?.isActive ?? false
        }
        if activeCount == 0 {
            for root in scopedRoots {
                root.stopAccessingSecurityScopedResource()
            }
            scopedRoots.removeAll()
        }
        updateDockBadge()
    }

    private func mutate(_ id: UUID, _ body: (inout TransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }

    private func updateDockBadge() {
        let count = activeCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
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

    private static func expand(_ urls: [URL], imagesOnly: Bool) -> Expansion {
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

    private static func prepare(url: URL, convertHEIC: Bool) throws -> PreparedUpload {
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
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey])
        if values.ubiquitousItemDownloadingStatus == .notDownloaded {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        return PreparedUpload(
            fileURL: url,
            filename: url.lastPathComponent,
            contentType: ImageKind.contentType(for: url.lastPathComponent),
            size: Int64(values.fileSize ?? 0)
        )
    }
}
