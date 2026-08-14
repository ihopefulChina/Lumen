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

    @discardableResult
    func enqueueUploads(
        urls: [URL],
        client: OSSClient,
        account: OSSAccount,
        bucket: OSSBucket?,
        prefix: String,
        settings: AppSettings
    ) -> Int {
        concurrency = settings.concurrentUploads
        for root in urls {
            if root.startAccessingSecurityScopedResource() {
                scopedRoots.append(root)
            }
        }
        let expansion = Self.expand(urls, imagesOnly: settings.imagesOnly)
        let expanded = expansion.files
        for url in expanded {
            let accessed = url.startAccessingSecurityScopedResource()
            let prepared: PreparedUpload
            do {
                prepared = try Self.prepare(url: url, convertHEIC: settings.convertHEIC)
            } catch {
                jobs.insert(
                    TransferJob(
                        id: UUID(),
                        kind: .upload,
                        status: .failed,
                        title: url.lastPathComponent,
                        objectKey: "",
                        localURL: url,
                        transferred: 0,
                        total: 0,
                        errorMessage: error.localizedDescription,
                        publicURL: nil,
                        finishedAt: .now
                    ),
                    at: 0
                )
                if accessed { url.stopAccessingSecurityScopedResource() }
                continue
            }

            let template = account.prefixTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            let extra: String
            if prefix.isEmpty, !template.isEmpty {
                extra = PathTemplate.expand(template, filename: prepared.filename)
            } else {
                extra = ""
            }
            let tail = extra.isEmpty ? prepared.filename : PathTemplate.join(extra, key: prepared.filename)
            let key = PathTemplate.join(prefix, key: tail)
            let job = TransferJob(
                id: UUID(),
                kind: .upload,
                status: .queued,
                title: prepared.filename,
                objectKey: key,
                localURL: prepared.fileURL,
                transferred: 0,
                total: prepared.size,
                errorMessage: nil,
                publicURL: account.publicURL(bucketName: client.bucket ?? bucket?.name ?? "", bucket: bucket, key: key),
                finishedAt: nil
            )
            jobs.insert(job, at: 0)
            let jobID = job.id
            let scopedClient = client
            let acl = account.defaultACL
            tasks[jobID] = Task { [weak self] in
                await self?.runUpload(
                    id: jobID,
                    client: scopedClient,
                    key: key,
                    fileURL: prepared.fileURL,
                    contentType: prepared.contentType,
                    acl: acl,
                    release: accessed ? url : nil,
                    playSound: settings.playCompleteSound
                )
            }
        }
        updateDockBadge()
        return expansion.skipped
    }

    func enqueueDownloads(objects: [OSSObject], client: OSSClient, folder: URL) {
        for object in objects {
            let dest = folder.appending(path: object.name)
            let job = TransferJob(
                id: UUID(),
                kind: .download,
                status: .queued,
                title: object.name,
                objectKey: object.key,
                localURL: dest,
                transferred: 0,
                total: object.size,
                errorMessage: nil,
                publicURL: nil,
                finishedAt: nil
            )
            jobs.insert(job, at: 0)
            let jobID = job.id
            tasks[jobID] = Task { [weak self] in
                await self?.runDownload(id: jobID, client: client, key: object.key, destination: dest)
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

    private struct Expansion {
        var files: [URL]
        var skipped: Int
    }

    private static func expand(_ urls: [URL], imagesOnly: Bool) -> Expansion {
        var result: [URL] = []
        var skipped = 0
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let file as URL in enumerator {
                        if imagesOnly && !ImageKind.isSupported(key: file.lastPathComponent) {
                            skipped += 1
                            continue
                        }
                        result.append(file)
                    }
                }
            } else {
                if imagesOnly && !ImageKind.isSupported(key: url.lastPathComponent) {
                    skipped += 1
                    continue
                }
                result.append(url)
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
