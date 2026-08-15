import Foundation

enum TransferKind: String, Codable, Sendable {
    case upload
    case download
}

enum TransferStatus: String, Codable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled
}

struct TransferJob: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var kind: TransferKind
    var status: TransferStatus
    var title: String
    var objectKey: String
    var localURL: URL?
    var transferred: Int64
    var total: Int64
    var errorMessage: String?
    var publicURL: URL?
    var finishedAt: Date?
    var integrityVerified = false

    var progress: Double {
        guard total > 0 else { return status == .completed ? 1 : 0 }
        return min(1, Double(transferred) / Double(total))
    }

    var isActive: Bool {
        status == .queued || status == .running
    }

    var isResumable: Bool {
        status == .paused || status == .failed
    }
}
