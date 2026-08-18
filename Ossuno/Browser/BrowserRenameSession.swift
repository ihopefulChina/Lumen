import Foundation

enum BrowserRenameKind: Sendable, Equatable {
    case object
    case folder
}

struct BrowserRenameSession: Sendable, Equatable {
    let key: String
    let originalName: String
    let kind: BrowserRenameKind
    let initialSelection: NSRange
    var draft: String
    var isCommitting = false

    init(key: String, name: String, kind: BrowserRenameKind) {
        self.key = key
        self.originalName = name
        self.kind = kind
        self.initialSelection = Self.selectionRange(for: name, kind: kind)
        self.draft = name
    }

    private static func selectionRange(for name: String, kind: BrowserRenameKind) -> NSRange {
        let value = name as NSString
        guard kind == .object, !value.pathExtension.isEmpty else {
            return NSRange(location: 0, length: value.length)
        }
        return NSRange(location: 0, length: (value.deletingPathExtension as NSString).length)
    }
}
