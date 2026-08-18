#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import Ossuno

@MainActor
@Suite(.serialized)
struct GridInteractionProbeTests {
    @Test func gridFolderSingleClickSelects() throws {
        let harness = makeHarness()
        defer { harness.close() }
        let folderKey = "campaigns/2026-autumn/品牌规范/"

        try harness.click(at: harness.center(ofMarker: "ossuno.folder:\(folderKey)"), count: 1)

        #expect(harness.model.browser.selectedKeys == [folderKey], "single click should select the folder, got \(harness.model.browser.selectedKeys)")
    }

    @Test func gridFolderDoubleClickOpens() throws {
        let harness = makeHarness()
        defer { harness.close() }
        let folderKey = "campaigns/2026-autumn/品牌规范/"

        try harness.click(at: harness.center(ofMarker: "ossuno.folder:\(folderKey)"), count: 1)
        try harness.click(at: harness.center(ofMarker: "ossuno.folder:\(folderKey)"), count: 2)

        #expect(
            harness.model.browser.prefix == folderKey,
            "double click should open the folder, got \(harness.model.browser.prefix)"
        )
    }

    @Test func gridFileSingleClickSelects() throws {
        let harness = makeHarness()
        defer { harness.close() }
        let fileKey = "campaigns/2026-autumn/官网文案.txt"

        try harness.click(at: harness.center(ofMarker: "ossuno.file:\(fileKey)"), count: 1)

        #expect(harness.model.browser.selectedKeys == [fileKey], "single click should select the file, got \(harness.model.browser.selectedKeys)")
    }

    @Test func gridCommandClickTogglesSelection() throws {
        let harness = makeHarness()
        defer { harness.close() }
        let folderKey = "campaigns/2026-autumn/品牌规范/"
        let initial = harness.model.browser.selectedKeys

        try harness.click(at: harness.center(ofMarker: "ossuno.folder:\(folderKey)"), count: 1, modifierFlags: [.command])

        #expect(harness.model.browser.selectedKeys.contains(folderKey), "command click should toggle the folder on")
        #expect(harness.model.browser.selectedKeys.isSuperset(of: initial), "command click should keep prior selection")

        try harness.click(at: harness.center(ofMarker: "ossuno.folder:\(folderKey)"), count: 1, modifierFlags: [.command])
        #expect(!harness.model.browser.selectedKeys.contains(folderKey), "second command click should toggle the folder off")
    }

    @Test func gridEmptyClickClearsSelection() throws {
        let harness = makeHarness()
        defer { harness.close() }
        #expect(!harness.model.browser.selectedKeys.isEmpty)

        let point = try harness.center(ofMarker: "ossuno.folder:campaigns/2026-autumn/品牌规范/")
        // Click far below all cells, on the empty background.
        let empty = CGPoint(x: point.x, y: point.y - 420)
        try harness.click(at: empty, count: 1)

        #expect(harness.model.browser.selectedKeys.isEmpty, "empty click should clear the selection")
    }

    @Test func listFolderSingleClickSelects() throws {
        let harness = makeHarness(mode: .list)
        defer { harness.close() }
        let folderKey = "campaigns/2026-autumn/品牌规范/"
        let row = harness.rowIndex(for: folderKey)

        let point = try harness.centerOfTableRow(row)
        try harness.click(at: point, count: 1)

        #expect(harness.model.browser.selectedKeys == [folderKey], "list single click should select the folder row, got \(harness.model.browser.selectedKeys)")
    }

    @Test func listFolderDoubleClickOpens() throws {
        let harness = makeHarness(mode: .list)
        defer { harness.close() }
        let folderKey = "campaigns/2026-autumn/品牌规范/"
        let row = harness.rowIndex(for: folderKey)

        let point = try harness.centerOfTableRow(row)
        try harness.click(at: point, count: 1)
        try harness.click(at: point, count: 2)

        #expect(
            harness.model.browser.prefix == folderKey,
            "list double click should open the folder, got \(harness.model.browser.prefix)"
        )
    }

    // MARK: - Policy unit tests

    @Test func policySelectsOnSingleClickInGrid() {
        let action = BrowserPointerPolicy.action(
            kind: .left, clickCount: 1, hit: .folder("art/"),
            looksLikeItemControl: false, modifiers: [],
            selectOnSingleClick: true
        )
        #expect(action == .select("art/", []))
    }

    @Test func policyOpensOnDoubleClick() {
        #expect(
            BrowserPointerPolicy.action(
                kind: .left, clickCount: 2, hit: .file("cover.png"),
                looksLikeItemControl: false, modifiers: [],
                selectOnSingleClick: false
            ) == .selectAndOpen("cover.png")
        )
        #expect(
            BrowserPointerPolicy.action(
                kind: .left, clickCount: 2, hit: .folder("art/"),
                looksLikeItemControl: false, modifiers: [],
                selectOnSingleClick: true
            ) == .selectAndOpen("art/")
        )
    }

    @Test func policySelectsPlainSingleClicksEvenInList() {
        // List mode must never depend on the table's internal selection
        // machinery for the plain click → highlight path.
        #expect(
            BrowserPointerPolicy.action(
                kind: .left, clickCount: 1, hit: .folder("art/"),
                looksLikeItemControl: false, modifiers: [],
                selectOnSingleClick: false
            ) == .select("art/", [])
        )
        // Modifier clicks stay native in list mode to avoid double-toggling.
        #expect(
            BrowserPointerPolicy.action(
                kind: .left, clickCount: 1, hit: .folder("art/"),
                looksLikeItemControl: false, modifiers: [.toggle],
                selectOnSingleClick: false
            ) == .passThrough
        )
    }

    @Test func policyClearsSelectionOnEmptyClick() {
        #expect(
            BrowserPointerPolicy.action(
                kind: .left, clickCount: 1, hit: .empty,
                looksLikeItemControl: false, modifiers: [],
                selectOnSingleClick: true
            ) == .clearSelection
        )
    }

    @Test func policyIgnoresControlsAndModifiedEmptyClicks() {
        #expect(
            BrowserPointerPolicy.action(
                kind: .left, clickCount: 1, hit: .file("a.txt"),
                looksLikeItemControl: true, modifiers: [],
                selectOnSingleClick: true
            ) == .passThrough
        )
        #expect(
            BrowserPointerPolicy.action(
                kind: .left, clickCount: 1, hit: .empty,
                looksLikeItemControl: false, modifiers: [.toggle],
                selectOnSingleClick: true
            ) == .passThrough
        )
    }

    @Test func policyStillShowsMenusOnRightClick() {
        #expect(
            BrowserPointerPolicy.action(
                kind: .right, clickCount: 1, hit: .folder("art/"),
                looksLikeItemControl: false, modifiers: [],
                selectOnSingleClick: false
            ) == .showMenu(.folder("art/"))
        )
        #expect(
            BrowserPointerPolicy.action(
                kind: .right, clickCount: 1, hit: .empty,
                looksLikeItemControl: true, modifiers: [],
                selectOnSingleClick: false
            ) == .passThrough
        )
    }

    // MARK: - Harness

    private func makeHarness(mode: BrowserViewMode = .grid) -> Harness {
        let model = ScreenshotDemo.makeModel(for: .browser)
        model.browser.viewMode = mode
        let harness = Harness(model: model)
        harness.present()
        // Allow layout, then run the loop so SwiftUI settles.
        for _ in 0..<20 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return harness
    }

    @MainActor
    final class Harness {
        let model: AppModel
        let window: NSWindow
        private var hosting: NSView?

        init(model: AppModel) {
            self.model = model
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
        }

        func present() {
            let root = RootView()
                .environment(model)
            let host = NSHostingView(rootView: root)
            hosting = host
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        func close() {
            window.orderOut(nil)
        }

        func center(ofMarker id: String) throws -> CGPoint {
            guard let view = findView(withIdentifier: id, in: window.contentView) else {
                throw HarnessError.markerNotFound(id)
            }
            let rect = view.bounds
            let centerInView = NSPoint(x: rect.midX, y: rect.midY)
            let windowPoint = view.convert(centerInView, to: nil)
            return windowPoint
        }

        func rowIndex(for key: String) -> Int {
            let folders = model.browser.visibleFolders
            let objects = model.browser.visibleObjects
            let all = folders.map(\.prefix) + objects.map(\.key)
            return all.firstIndex(of: key) ?? -1
        }

        func centerOfTableRow(_ row: Int) throws -> CGPoint {
            guard let table = findTableView(in: window.contentView) else {
                throw HarnessError.tableNotFound
            }
            guard row >= 0, row < table.numberOfRows else {
                throw HarnessError.rowOutOfRange(row)
            }
            table.scrollRowToVisible(row)
            for _ in 0..<10 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            window.layoutIfNeeded()
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: true) else {
                throw HarnessError.rowViewMissing(row)
            }
            let point = NSPoint(x: rowView.bounds.midX, y: rowView.bounds.midY)
            let visible = rowView.visibleRect
            let target = NSPoint(x: min(max(point.x, visible.minX + 4), visible.maxX - 4),
                                 y: min(max(point.y, visible.minY + 2), visible.maxY - 2))
            return rowView.convert(target, to: nil)
        }

        func click(at windowPoint: CGPoint, count: Int, modifierFlags: NSEvent.ModifierFlags = []) throws {
            for clickIndex in 1...count {
                guard let down = NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: windowPoint,
                    modifierFlags: modifierFlags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: clickIndex,
                    pressure: 1
                ) else { throw HarnessError.eventCreationFailed }
                guard let up = NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: windowPoint,
                    modifierFlags: modifierFlags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: clickIndex,
                    pressure: 0
                ) else { throw HarnessError.eventCreationFailed }
                // Route through NSApp so local event monitors (the click surface) see it.
                NSApp.sendEvent(down)
                NSApp.sendEvent(up)
            }
            for _ in 0..<20 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
        }

        private func findView(withIdentifier id: String, in root: NSView?) -> NSView? {
            guard let root else { return nil }
            if root.identifier?.rawValue == id { return root }
            for child in root.subviews {
                if let found = findView(withIdentifier: id, in: child) {
                    return found
                }
            }
            return nil
        }

        private func findTableView(in root: NSView?) -> NSTableView? {
            guard let root else { return nil }
            var tables: [NSTableView] = []
            collectTables(in: root, into: &tables)
            // The browser table has the most columns (名称/大小/种类/修改时间);
            // the sidebar List's underlying table has only one.
            return tables.max { $0.numberOfColumns < $1.numberOfColumns }
        }

        private func collectTables(in root: NSView?, into result: inout [NSTableView]) {
            guard let root else { return }
            if let table = root as? NSTableView { result.append(table) }
            for child in root.subviews {
                collectTables(in: child, into: &result)
            }
        }
    }

    enum HarnessError: Error {
        case markerNotFound(String)
        case eventCreationFailed
        case tableNotFound
        case rowOutOfRange(Int)
        case rowViewMissing(Int)
    }
}
#endif
