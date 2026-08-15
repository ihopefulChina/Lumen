import Foundation

enum TransferConflictResolution: Equatable, Sendable {
    case useOriginal
    case skip
    case renamed(String)
    case ask
}

enum TransferConflictPlanner {
    static func plan(
        keys: [String],
        existing: Set<String>,
        policy: TransferConflictPolicy
    ) -> [TransferConflictResolution] {
        var reserved = existing
        return keys.map { key in
            guard reserved.contains(key) else {
                reserved.insert(key)
                return .useOriginal
            }
            switch policy {
            case .ask:
                return .ask
            case .replace:
                reserved.insert(key)
                return .useOriginal
            case .skip:
                return .skip
            case .keepBoth:
                let renamed = availableKey(for: key, existing: reserved)
                reserved.insert(renamed)
                return .renamed(renamed)
            }
        }
    }

    static func availableKey(for key: String, existing: Set<String>) -> String {
        guard existing.contains(key) else { return key }
        let isFolder = key.hasSuffix("/")
        let trimmed = isFolder ? String(key.dropLast()) : key
        let parent = PathTemplate.parentPrefix(trimmed)
        let leaf = PathTemplate.lastComponent(trimmed)
        let stem: String
        let suffix: String
        if isFolder {
            stem = leaf
            suffix = ""
        } else {
            let ns = leaf as NSString
            let ext = ns.pathExtension
            stem = ns.deletingPathExtension
            suffix = ext.isEmpty ? "" : ".\(ext)"
        }
        var number = 2
        while true {
            var candidate = PathTemplate.join(parent, key: "\(stem) \(number)\(suffix)")
            if isFolder { candidate += "/" }
            if !existing.contains(candidate) { return candidate }
            number += 1
        }
    }
}
