import Foundation
import Observation

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case grid
    case list
    var id: String { rawValue }
    var title: String { self == .grid ? "网格" : "列表" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

struct BrowserSelectionModifiers: OptionSet, Sendable {
    let rawValue: Int

    static let toggle = BrowserSelectionModifiers(rawValue: 1 << 0)
    static let extendRange = BrowserSelectionModifiers(rawValue: 1 << 1)
}

enum BrowserSelectionDirection: Sendable {
    case previous
    case next
}

@MainActor
@Observable
final class BrowserModel {
    var prefix = ""
    var folders: [OSSFolder] = []
    var objects: [OSSObject] = []
    var selectedKeys: Set<String> = [] {
        didSet { selectionEpoch += 1 }
    }
    var selectionEpoch = 0
    var selectionAnchorKey: String?
    var focusedKey: String?
    var viewMode: BrowserViewMode = .grid
    var searchText = ""
    var isLoading = false
    var errorMessage: String?
    var dropTargets: Set<String> = []

    var isDropTargeted: Bool { !dropTargets.isEmpty }

    var activeDropPrefix: String? {
        dropTargets.max(by: { $0.count < $1.count })
    }

    func setDropTarget(_ prefix: String, active: Bool) {
        if active {
            dropTargets.insert(prefix)
        } else {
            dropTargets.remove(prefix)
        }
    }
    var lastRefresh: Date?
    var backStack: [String] = []
    var forwardStack: [String] = []

    var imagesOnly = true
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    var visibleFolders: [OSSFolder] {
        filtered(folders, name: \.name)
    }

    var visibleObjects: [OSSObject] {
        let source = imagesOnly ? objects.filter(\.isSupported) : objects
        return filtered(source, name: \.name)
    }

    var selectedObjects: [OSSObject] {
        objects.filter { selectedKeys.contains($0.key) }
    }

    var selectedFolders: [OSSFolder] {
        folders.filter { selectedKeys.contains($0.prefix) }
    }

    var visibleKeys: Set<String> {
        Set(visibleFolders.map(\.prefix)).union(visibleObjects.map(\.key))
    }

    var orderedVisibleKeys: [String] {
        visibleFolders.map(\.prefix) + visibleObjects.map(\.key)
    }

    func selectAllVisible() {
        selectedKeys = visibleKeys
    }

    func invertVisibleSelection() {
        selectedKeys = visibleKeys.subtracting(selectedKeys)
    }

    var primarySelection: OSSObject? {
        visibleObjects.first(where: { selectedKeys.contains($0.key) })
    }

    func select(key: String, modifiers: BrowserSelectionModifiers) {
        let ordered = orderedVisibleKeys
        guard let targetIndex = ordered.firstIndex(of: key) else { return }

        if modifiers.contains(.extendRange) {
            let anchor = selectionAnchorKey ?? focusedKey ?? key
            let anchorIndex = ordered.firstIndex(of: anchor) ?? targetIndex
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            let rangeKeys = Set(range.map { ordered[$0] })
            if modifiers.contains(.toggle) {
                selectedKeys.formUnion(rangeKeys)
            } else {
                selectedKeys = rangeKeys
            }
            selectionAnchorKey = anchor
            focusedKey = key
            return
        }

        if modifiers.contains(.toggle) {
            if selectedKeys.contains(key) {
                selectedKeys.remove(key)
            } else {
                selectedKeys.insert(key)
            }
            focusedKey = key
            selectionAnchorKey = selectedKeys.contains(key)
                ? key
                : ordered.first(where: { selectedKeys.contains($0) })
            return
        }

        selectedKeys = [key]
        selectionAnchorKey = key
        focusedKey = key
    }

    func moveSelection(_ direction: BrowserSelectionDirection, extending: Bool) {
        let ordered = orderedVisibleKeys
        guard !ordered.isEmpty else { return }
        let current = focusedKey.flatMap { ordered.firstIndex(of: $0) }
            ?? ordered.firstIndex(where: { selectedKeys.contains($0) })
            ?? (direction == .next ? -1 : ordered.count)
        let targetIndex: Int
        switch direction {
        case .previous:
            targetIndex = max(0, current - 1)
        case .next:
            targetIndex = min(ordered.count - 1, current + 1)
        }
        select(
            key: ordered[targetIndex],
            modifiers: extending ? [.extendRange] : []
        )
    }

    func clearSelection() {
        selectedKeys = []
        selectionAnchorKey = nil
        focusedKey = nil
    }

    func reset() {
        prefix = ""
        folders = []
        objects = []
        clearSelection()
        errorMessage = nil
        isLoading = false
        backStack = []
        forwardStack = []
    }

    func navigate(to newPrefix: String, record: Bool = true) {
        guard newPrefix != prefix else {
            clearSelection()
            return
        }
        if record {
            backStack.append(prefix)
            forwardStack.removeAll()
        }
        prefix = newPrefix
        clearSelection()
    }

    func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        forwardStack.append(prefix)
        prefix = previous
        clearSelection()
        return true
    }

    func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(prefix)
        prefix = next
        clearSelection()
        return true
    }

    func apply(_ listing: ObjectListing, imagesOnly: Bool) {
        self.imagesOnly = imagesOnly
        folders = listing.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        objects = listing.objects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let visibleIDs = Set(visibleObjects.map(\.key)).union(visibleFolders.map(\.prefix))
        selectedKeys = selectedKeys.intersection(visibleIDs)
        if let focusedKey, !visibleIDs.contains(focusedKey) {
            self.focusedKey = nil
        }
        if let selectionAnchorKey, !visibleIDs.contains(selectionAnchorKey) {
            self.selectionAnchorKey = nil
        }
        lastRefresh = .now
        errorMessage = nil
    }

    private func filtered<T>(_ items: [T], name: KeyPath<T, String>) -> [T] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0[keyPath: name].localizedCaseInsensitiveContains(query) }
    }
}
