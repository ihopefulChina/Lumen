import Foundation

enum BucketSearchScope: String, CaseIterable, Identifiable, Sendable {
    case folder
    case bucket

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "当前文件夹"
        case .bucket: "当前 Bucket"
        }
    }
}

enum BucketSearchKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case any
    case images
    case videos
    case documents
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "所有类型"
        case .images: "图片"
        case .videos: "视频"
        case .documents: "文档"
        case .other: "其他"
        }
    }

    func matches(_ object: OSSObject) -> Bool {
        let ext = (object.key as NSString).pathExtension.lowercased()
        switch self {
        case .any:
            return true
        case .images:
            return ImageKind.isImage(key: object.key)
        case .videos:
            return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
        case .documents:
            return ["txt", "md", "json", "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "rtf"].contains(ext)
        case .other:
            return !Self.images.matches(object)
                && !Self.videos.matches(object)
                && !Self.documents.matches(object)
        }
    }
}

enum BucketSearchDateRange: Hashable, Sendable {
    case any
    case lastDays(Int)
    case between(Date, Date)

    func contains(_ date: Date?, now: Date) -> Bool {
        switch self {
        case .any:
            return true
        case .lastDays(let days):
            guard let date else { return false }
            return date >= now.addingTimeInterval(-Double(max(0, days)) * 86_400)
                && date <= now
        case .between(let start, let end):
            guard let date else { return false }
            let bounds = start <= end ? (start, end) : (end, start)
            return date >= bounds.0 && date <= bounds.1
        }
    }
}

struct BucketSearchFilter: Hashable, Sendable {
    var kind: BucketSearchKind
    var minimumSize: Int64?
    var maximumSize: Int64?
    var modified: BucketSearchDateRange

    static let all = BucketSearchFilter(
        kind: .any,
        minimumSize: nil,
        maximumSize: nil,
        modified: .any
    )

    static let largeObjects = BucketSearchFilter(
        kind: .any,
        minimumSize: 100 * 1_024 * 1_024,
        maximumSize: nil,
        modified: .any
    )

    static func recentObjects(days: Int) -> BucketSearchFilter {
        BucketSearchFilter(
            kind: .any,
            minimumSize: nil,
            maximumSize: nil,
            modified: .lastDays(days)
        )
    }

    func matches(_ object: OSSObject, now: Date) -> Bool {
        guard kind.matches(object), modified.contains(object.lastModified, now: now) else {
            return false
        }
        if let minimumSize, object.size < minimumSize { return false }
        if let maximumSize, object.size > maximumSize { return false }
        return true
    }
}

struct BucketSearchQuery: Hashable, Sendable {
    var accountID: UUID
    var bucketName: String
    var text: String
    var filter: BucketSearchFilter

    func matches(_ object: OSSObject, now: Date = .now) -> Bool {
        guard !object.isFolderPlaceholder, filter.matches(object, now: now) else {
            return false
        }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return object.key.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            range: nil,
            locale: .current
        ) != nil
    }
}

struct BucketSearchProgress: Equatable, Sendable {
    var scanned: Int
    var matched: Int
    var pages: Int
}

struct BucketSearchSnapshot: Equatable, Sendable {
    var query: BucketSearchQuery
    var objects: [OSSObject]
    var progress: BucketSearchProgress
    var isIncomplete: Bool
}

enum SmartLocation: String, CaseIterable, Identifiable, Sendable {
    case recent
    case large
    case deleted
    case failedTransfers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "最近修改"
        case .large: "大文件"
        case .deleted: "已删除"
        case .failedTransfers: "失败的传输"
        }
    }
}
