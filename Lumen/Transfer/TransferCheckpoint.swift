import Foundation

struct MultipartCompletedPart: Codable, Equatable, Hashable, Sendable {
    var number: Int
    var etag: String
}

struct MultipartUploadCheckpoint: Codable, Equatable, Sendable {
    var bucketName: String
    var objectKey: String
    var sourceSize: Int64
    var sourceModifiedAt: Date
    var partSize: Int64
    var uploadID: String
    var completedParts: [MultipartCompletedPart]
}

struct RangeDownloadCheckpoint: Codable, Equatable, Sendable {
    var bucketName: String
    var objectKey: String
    var expectedSize: Int64
    var etag: String?
    var chunkSize: Int64
    var completedBytes: Int64
    var partialFileName: String
}

enum TransferCheckpoint: Codable, Equatable, Sendable {
    case upload(MultipartUploadCheckpoint)
    case download(RangeDownloadCheckpoint)
}

enum TransferConflictPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case replace
    case skip
    case keepBoth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "每次询问"
        case .replace: "替换"
        case .skip: "跳过"
        case .keepBoth: "保留两者"
        }
    }
}

struct TransferSpeedLimit: RawRepresentable, Codable, Hashable, Sendable {
    var rawValue: Int64

    static let unlimited = TransferSpeedLimit(rawValue: 0)

    static func megabytesPerSecond(_ value: Int64) -> TransferSpeedLimit {
        TransferSpeedLimit(rawValue: max(0, value) * 1_024 * 1_024)
    }

    var bytesPerSecond: Int64? { rawValue > 0 ? rawValue : nil }

    var title: String {
        guard rawValue > 0 else { return "不限速" }
        return "\(rawValue / 1_024 / 1_024) MB/s"
    }
}

enum DownloadLocation: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case downloads

    var id: String { rawValue }
    var title: String { self == .ask ? "每次询问" : "下载文件夹" }
}

enum SignedLinkLifetime: Int, Codable, CaseIterable, Identifiable, Sendable {
    case fifteenMinutes = 900
    case oneHour = 3_600
    case oneDay = 86_400
    case sevenDays = 604_800

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .fifteenMinutes: "15 分钟"
        case .oneHour: "1 小时"
        case .oneDay: "1 天"
        case .sevenDays: "7 天"
        }
    }
}
