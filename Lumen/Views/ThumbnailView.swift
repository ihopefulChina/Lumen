import AppKit
import ImageIO
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
                            .interpolation(.medium)
                            .scaledToFill()
                    } else if failed || !ImageKind.imgProcessable(key: object.key) {
                        Image(systemName: "photo")
                            .font(.system(size: style == .row ? 11 : 22, weight: .light))
                            .foregroundStyle(.secondary)
                    } else if style != .row {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    FinderFileIcon(key: object.key, size: style == .row ? 16 : 64)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: object.etag + object.key + style.cacheKey) {
                await load()
            }
    }

    private func load() async {
        guard object.isImage, ImageKind.imgProcessable(key: object.key) else { return }
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
    private let limit = 6

    func load(object: OSSObject, style: OSSImageProcess, client: OSSClient) async -> NSImage? {
        let token = style.cacheKey + object.key + object.etag
        if let cached = memory[token] { return cached }
        if let existing = inflight[token] {
            return await existing.value
        }
        let key = object.key
        let queries = style.queries(for: key)
        let maxPixel = style.maxPixel
        let size = object.size
        let allowOriginal = size < 256_000 && ImageKind.imgProcessable(key: key)
        let task = Task { () -> NSImage? in
            await ThumbnailCache.shared.waitForSlot()
            defer { ThumbnailCache.shared.finishSlot() }
            for process in queries {
                if let data = try? await client.objectData(key: key, process: process),
                   data.count < 1_500_000,
                   let image = ThumbnailCache.decode(data, maxPixel: maxPixel) {
                    return image
                }
            }
            if allowOriginal,
               let data = try? await client.objectData(key: key),
               data.count < 1_500_000 {
                return ThumbnailCache.decode(data, maxPixel: maxPixel)
            }
            return nil
        }
        inflight[token] = task
        let image = await task.value
        inflight[token] = nil
        if let image {
            if memory.count > 280 {
                memory.removeAll(keepingCapacity: true)
            }
            memory[token] = image
        }
        return image
    }

    private static func decode(_ data: Data, maxPixel: CGFloat) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        if let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 {
            return image
        }
        return nil
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
