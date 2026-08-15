import Foundation

struct OSSObjectVersion: Identifiable, Equatable, Hashable, Sendable {
    var key: String
    var versionID: String
    var isLatest: Bool
    var lastModified: Date?
    var etag: String
    var size: Int64
    var storageClass: String

    var id: String { "version:\(key):\(versionID)" }
}

struct OSSDeleteMarkerVersion: Identifiable, Equatable, Hashable, Sendable {
    var key: String
    var versionID: String
    var isLatest: Bool
    var lastModified: Date?

    var id: String { "delete:\(key):\(versionID)" }
}

struct OSSVersionPage: Equatable, Sendable {
    var versions: [OSSObjectVersion]
    var deleteMarkers: [OSSDeleteMarkerVersion]
    var isTruncated: Bool
    var nextKeyMarker: String?
    var nextVersionIDMarker: String?
}

struct OSSVersionListing: Equatable, Sendable {
    var versions: [OSSObjectVersion]
    var deleteMarkers: [OSSDeleteMarkerVersion]
    var incomplete: Bool
}

struct VersionHistoryRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case version, deleteMarker }

    var id: String
    var key: String
    var versionID: String
    var kind: Kind
    var isCurrent: Bool
    var lastModified: Date?
    var size: Int64?
    var storageClass: String?

    static func rows(
        versions: [OSSObjectVersion],
        deleteMarkers: [OSSDeleteMarkerVersion]
    ) -> [VersionHistoryRow] {
        let versionRows = versions.map {
            VersionHistoryRow(
                id: $0.id,
                key: $0.key,
                versionID: $0.versionID,
                kind: .version,
                isCurrent: $0.isLatest,
                lastModified: $0.lastModified,
                size: $0.size,
                storageClass: $0.storageClass
            )
        }
        let markerRows = deleteMarkers.map {
            VersionHistoryRow(
                id: $0.id,
                key: $0.key,
                versionID: $0.versionID,
                kind: .deleteMarker,
                isCurrent: $0.isLatest,
                lastModified: $0.lastModified,
                size: nil,
                storageClass: nil
            )
        }
        return (versionRows + markerRows).sorted {
            ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast)
        }
    }
}
