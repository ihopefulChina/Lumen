import AppKit
import Foundation
import Testing
@testable import Lumen

@MainActor
struct BrowserMenuHitTests {
    @Test func parsesFolderAndFileIdentifiers() {
        #expect(BrowserMenuHit.parseIdentifier("lumen.folder:art/") == .folder("art/"))
        #expect(BrowserMenuHit.parseIdentifier("lumen.file:cover.png") == .file("cover.png"))
        #expect(BrowserMenuHit.parseIdentifier("lumen.folder:") == nil)
        #expect(BrowserMenuHit.parseIdentifier("other") == nil)
        #expect(BrowserMenuHit.parseIdentifier(nil) == nil)
    }

    @Test func tableIDsUseTrailingSlashForFolders() {
        #expect(BrowserMenuHit.fromTableID("art/") == .folder("art/"))
        #expect(BrowserMenuHit.fromTableID("cover.png") == .file("cover.png"))
    }

    @Test func cellSizedRejectsTinyAndHugeFrames() {
        #expect(BrowserMenuHitResolver.isCellSized(CGSize(width: 120, height: 140)))
        #expect(!BrowserMenuHitResolver.isCellSized(CGSize(width: 8, height: 140)))
        #expect(!BrowserMenuHitResolver.isCellSized(CGSize(width: 800, height: 600)))
        #expect(BrowserMenuHitResolver.isHuge(CGSize(width: 800, height: 600)))
        #expect(!BrowserMenuHitResolver.isHuge(CGSize(width: 120, height: 140)))
    }

    @Test func registryPicksTheSmallestContainingCell() {
        let window = makeWindow()
        let grid = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let cell = NSView(frame: NSRect(x: 20, y: 400, width: 120, height: 140))
        let other = NSView(frame: NSRect(x: 160, y: 400, width: 120, height: 140))
        window.contentView?.addSubview(grid)
        grid.addSubview(cell)
        grid.addSubview(other)

        let registry = BrowserItemHitRegistry()
        registry.register(grid, id: "lumen.folder:wrong/")
        registry.register(cell, id: "lumen.folder:art/")
        registry.register(other, id: "lumen.folder:refs/")

        #expect(registry.hit(at: NSPoint(x: 50, y: 450), in: window) == .folder("art/"))
        #expect(registry.hit(at: NSPoint(x: 200, y: 450), in: window) == .folder("refs/"))
        #expect(registry.hit(at: NSPoint(x: 400, y: 100), in: window) == nil)
    }

    @Test func descendantSearchFindsMarkerBehindAButton() {
        let cell = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 140))
        let button = NSButton(frame: NSRect(x: 10, y: 40, width: 100, height: 80))
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 140))
        marker.identifier = NSUserInterfaceItemIdentifier("lumen.folder:art/")
        cell.addSubview(marker)
        cell.addSubview(button)

        #expect(BrowserMenuHitResolver.findItemHit(startingAt: button) == .folder("art/"))
    }

    @Test func resolveUsesRegistryBeforeFallingBackToEmpty() {
        let window = makeWindow()
        let cell = NSView(frame: NSRect(x: 20, y: 400, width: 120, height: 140))
        window.contentView?.addSubview(cell)
        let registry = BrowserItemHitRegistry()
        registry.register(cell, id: "lumen.file:cover.png")

        let hit = BrowserMenuHitResolver.resolve(
            hitView: window.contentView,
            windowPoint: NSPoint(x: 50, y: 450),
            window: window,
            tableItemIDs: [],
            registry: registry
        )
        #expect(hit == .file("cover.png"))
    }

    @Test func resolveUsesTableRowWhenTheClickMissesIdentifiers() {
        let window = makeWindow()
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        window.contentView?.addSubview(table)

        let hit = BrowserMenuHitResolver.resolve(
            hitView: table,
            windowPoint: NSPoint(x: 20, y: 20),
            window: window,
            tableItemIDs: ["art/", "cover.png"],
            registry: BrowserItemHitRegistry()
        )
        #expect(hit == .empty)
    }

    @Test func tableSelectionMapsVisibleIDsToRowIndexes() {
        let rows = BrowserTableSelection.rowIndexes(
            itemIDs: ["art/", "cover.png", "notes.txt"],
            selected: ["cover.png", "art/"],
            rowCount: 3
        )
        #expect(rows.contains(0))
        #expect(rows.contains(1))
        #expect(!rows.contains(2))
    }

    @Test func tableSelectionIgnoresRowsTheTableHasNotMaterialized() {
        let rows = BrowserTableSelection.rowIndexes(
            itemIDs: ["art/", "cover.png"],
            selected: ["art/", "cover.png"],
            rowCount: 1
        )
        #expect(rows == IndexSet(integer: 0))
    }

    @Test func pointerPolicyUnifiesGridAndListClicks() {
        #expect(
            BrowserPointerPolicy.action(
                kind: .right,
                clickCount: 1,
                hit: .folder("art/"),
                looksLikeItemControl: false,
                modifiers: [],
                selectOnSingleClick: false
            ) == .showMenu(.folder("art/"))
        )
        #expect(
            BrowserPointerPolicy.action(
                kind: .right,
                clickCount: 1,
                hit: .empty,
                looksLikeItemControl: false,
                modifiers: [],
                selectOnSingleClick: false
            ) == .showMenu(.empty)
        )
        #expect(
            BrowserPointerPolicy.action(
                kind: .right,
                clickCount: 1,
                hit: .empty,
                looksLikeItemControl: true,
                modifiers: [],
                selectOnSingleClick: false
            ) == .passThrough
        )
        #expect(
            BrowserPointerPolicy.action(
                kind: .left,
                clickCount: 1,
                hit: .empty,
                looksLikeItemControl: false,
                modifiers: [.toggle],
                selectOnSingleClick: true
            ) == .passThrough
        )
        #expect(
            BrowserPointerPolicy.action(
                kind: .left,
                clickCount: 2,
                hit: .folder("art/"),
                looksLikeItemControl: true,
                modifiers: [],
                selectOnSingleClick: false
            ) == .passThrough
        )
    }

    @Test func buttonsLookLikeItemControlsAndTablesDoNot() {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        #expect(BrowserMenuHitResolver.looksLikeItemControl(startingAt: button))
        #expect(!BrowserMenuHitResolver.looksLikeItemControl(startingAt: table))
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}
