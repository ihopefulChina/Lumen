import AppKit
import CoreTransferable
import Foundation
import UniformTypeIdentifiers

enum CloudOperationMode: String, Codable, Sendable {
    case copy
    case move
}

struct CloudObjectMapping: Hashable, Sendable {
    var sourceKey: String
    var destinationKey: String
}

struct CloudDragPayload: Codable, Hashable, Transferable, Sendable {
    var accountID: UUID
    var bucketName: String
    var sourceRegionID: String? = nil
    var objectKeys: [String]
    var folderPrefixes: [String]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .lumenCloudItems)
    }

    var itemCount: Int {
        objectKeys.count + folderPrefixes.count
    }

    var isEmpty: Bool {
        objectKeys.isEmpty && folderPrefixes.isEmpty
    }
}

struct CloudClipboardItem: Codable, Equatable, Sendable {
    var payload: CloudDragPayload
    var mode: CloudOperationMode
}

enum CloudClipboard {
    static var pasteboardType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType(UTType.lumenCloudItems.identifier)
    }

    static func write(_ item: CloudClipboardItem, to pasteboard: NSPasteboard = .general) {
        guard !item.payload.isEmpty, let data = try? JSONEncoder().encode(item) else { return }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data, forType: pasteboardType)
        pasteboard.clearContents()
        pasteboard.writeObjects([pasteboardItem])
    }

    static func write(
        _ payload: CloudDragPayload,
        mode: CloudOperationMode = .copy,
        to pasteboard: NSPasteboard = .general
    ) {
        write(CloudClipboardItem(payload: payload, mode: mode), to: pasteboard)
    }

    static func read(from pasteboard: NSPasteboard = .general) -> CloudClipboardItem? {
        guard let data = pasteboard.data(forType: pasteboardType) else { return nil }
        if let item = try? JSONDecoder().decode(CloudClipboardItem.self, from: data),
           !item.payload.isEmpty
        {
            return item
        }
        if let payload = try? JSONDecoder().decode(CloudDragPayload.self, from: data),
           !payload.isEmpty
        {
            return CloudClipboardItem(payload: payload, mode: .copy)
        }
        return nil
    }

    static func clear(from pasteboard: NSPasteboard = .general) {
        guard read(from: pasteboard) != nil else { return }
        pasteboard.clearContents()
    }
}

extension UTType {
    static let lumenCloudItems = UTType(exportedAs: "studio.lumen.oss.cloud-items")
}

enum CloudObjectOperationError: LocalizedError, Sendable, Equatable {
    case invalidPrefix
    case destinationInsideSource
    case keyOutsideSource(String)
    case unchangedDestination(String)
    case duplicateDestination(String)
    case destinationExists(String)
    case incompleteListing
    case emptySource
    case sourceCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidPrefix:
            "文件夹路径无效"
        case .destinationInsideSource:
            "不能把文件夹移动或复制到它自己里面"
        case .keyOutsideSource:
            "云端对象不在要整理的文件夹内"
        case .unchangedDestination:
            "项目已经在这个位置"
        case .duplicateDestination:
            "多个项目会产生同一个目标名称"
        case .destinationExists(let key):
            "目标已存在：\(PathTemplate.lastComponent(key))"
        case .incompleteListing:
            "文件夹没有完整列出，已取消操作以避免遗漏"
        case .emptySource:
            "源文件夹不存在或为空"
        case .sourceCleanupFailed(let key):
            "目标已复制完成，但未能删除源对象：\(key)"
        }
    }
}

enum CloudObjectOperation {
    static func planPrefix(
        source: String,
        destination: String,
        keys: [String]
    ) throws -> [CloudObjectMapping] {
        guard source.hasSuffix("/"), destination.hasSuffix("/"),
              !source.isEmpty, !destination.isEmpty
        else {
            throw CloudObjectOperationError.invalidPrefix
        }
        guard source != destination else {
            throw CloudObjectOperationError.unchangedDestination(source)
        }
        guard !destination.hasPrefix(source) else {
            throw CloudObjectOperationError.destinationInsideSource
        }

        return try keys.map { key in
            guard key == source || key.hasPrefix(source) else {
                throw CloudObjectOperationError.keyOutsideSource(key)
            }
            let relative = String(key.dropFirst(source.count))
            return CloudObjectMapping(
                sourceKey: key,
                destinationKey: destination + relative
            )
        }
    }

    static func staysInPlace(
        objectKeys: [String],
        folderPrefixes: [String],
        destinationPrefix: String
    ) -> Bool {
        let objectsStay = objectKeys.allSatisfy { key in
            PathTemplate.join(destinationPrefix, key: PathTemplate.lastComponent(key)) == key
        }
        let foldersStay = folderPrefixes.allSatisfy { prefix in
            PathTemplate.join(destinationPrefix, key: PathTemplate.lastComponent(prefix)) + "/" == prefix
        }
        return (!objectKeys.isEmpty || !folderPrefixes.isEmpty) && objectsStay && foldersStay
    }

    static func copyDestination(
        source: String,
        destinationPrefix: String,
        isFolder: Bool,
        reserved: Set<String>
    ) -> String {
        let leaf = PathTemplate.lastComponent(source)
        var destination = PathTemplate.join(destinationPrefix, key: leaf)
        if isFolder { destination += "/" }
        if destination == source || reserved.contains(destination) {
            return TransferConflictPlanner.availableKey(
                for: destination,
                existing: reserved.union([source])
            )
        }
        return destination
    }

    static func validate(_ mappings: [CloudObjectMapping]) throws {
        var destinations = Set<String>()
        for mapping in mappings {
            guard mapping.sourceKey != mapping.destinationKey else {
                throw CloudObjectOperationError.unchangedDestination(mapping.sourceKey)
            }
            guard destinations.insert(mapping.destinationKey).inserted else {
                throw CloudObjectOperationError.duplicateDestination(mapping.destinationKey)
            }
        }
    }
}
