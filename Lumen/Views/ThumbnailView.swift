import AppKit
import SwiftUI

struct ThumbnailView: View {
    let object: OSSObject
    var style: OSSImageProcess = .grid
    @Environment(AppModel.self) private var model
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Color(nsColor: .quaternaryLabelColor)
            .opacity(0.18)
            .overlay {
                if object.isImage {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } else if failed {
                        Image(systemName: "photo")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    FinderFileIcon(key: object.key, size: 64)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: object.etag + object.key + style.cacheKey) {
                await load()
            }
    }

    private func load() async {
        guard object.isImage else { return }
        guard let client = model.makeClient() else {
            failed = true
            return
        }
        if let nsImage = await ThumbnailCache.shared.load(object: object, style: style, client: client) {
            image = nsImage
        } else {
            failed = true
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private var memory: [String: NSImage] = [:]
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var running = 0
    private let limit = 4

    func load(object: OSSObject, style: OSSImageProcess, client: OSSClient) async -> NSImage? {
        let token = style.cacheKey + object.key + object.etag
        if let cached = memory[token] { return cached }
        if let existing = inflight[token] {
            return await existing.value
        }
        let key = object.key
        let size = object.size
        let process = style.query
        let task = Task { () -> NSImage? in
            await ThumbnailCache.shared.waitForSlot()
            defer { ThumbnailCache.shared.finishSlot() }
            let data: Data?
            if let processed = try? await client.objectData(key: key, process: process) {
                data = processed
            } else if let processed = try? await client.objectData(key: key, process: "image/resize,m_lfit,w_160,limit_1") {
                data = processed
            } else if size < 256_000 {
                data = try? await client.objectData(key: key)
            } else {
                data = nil
            }
            guard let data, let image = NSImage(data: data) else { return nil }
            return image
        }
        inflight[token] = task
        let image = await task.value
        inflight[token] = nil
        if let image {
            if memory.count > 200 {
                memory.removeAll(keepingCapacity: true)
            }
            memory[token] = image
        }
        return image
    }

    private func waitForSlot() async {
        while running >= limit {
            try? await Task.sleep(for: .milliseconds(40))
        }
        running += 1
    }

    private func finishSlot() {
        running = max(0, running - 1)
    }
}
