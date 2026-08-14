import Foundation
import Observation

enum BrowserViewMode: String, CaseIterable, Identifiable {
    case grid
    case list
    var id: String { rawValue }
    var title: String { self == .grid ? "网格" : "列表" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
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

    func selectAllVisible() {
        selectedKeys = visibleKeys
    }

    func invertVisibleSelection() {
        selectedKeys = visibleKeys.subtracting(selectedKeys)
    }

    var primarySelection: OSSObject? {
        if let first = selectedKeys.first {
            return objects.first(where: { $0.key == first })
        }
        return nil
    }

    func reset() {
        prefix = ""
        folders = []
        objects = []
        selectedKeys = []
        errorMessage = nil
        isLoading = false
        backStack = []
        forwardStack = []
    }

    func navigate(to newPrefix: String, record: Bool = true) {
        guard newPrefix != prefix else {
            selectedKeys = []
            return
        }
        if record {
            backStack.append(prefix)
            forwardStack.removeAll()
        }
        prefix = newPrefix
        selectedKeys = []
    }

    func goBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        forwardStack.append(prefix)
        prefix = previous
        selectedKeys = []
        return true
    }

    func goForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(prefix)
        prefix = next
        selectedKeys = []
        return true
    }

    func apply(_ listing: ObjectListing, imagesOnly: Bool) {
        self.imagesOnly = imagesOnly
        folders = listing.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        objects = listing.objects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let visibleIDs = Set(visibleObjects.map(\.key)).union(visibleFolders.map(\.prefix))
        selectedKeys = selectedKeys.intersection(visibleIDs)
        lastRefresh = .now
        errorMessage = nil
    }

    private func filtered<T>(_ items: [T], name: KeyPath<T, String>) -> [T] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0[keyPath: name].localizedCaseInsensitiveContains(query) }
    }
}
