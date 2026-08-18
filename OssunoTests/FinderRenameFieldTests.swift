import AppKit
import Testing
@testable import Ossuno

@MainActor
struct FinderRenameFieldTests {
    @Test func renameCoordinatorRoutesReturnToCommit() {
        var commits = 0
        let coordinator = FinderRenameCoordinator(
            onCommit: { commits += 1 },
            onCancel: {}
        )

        let handled = coordinator.handleCommand(#selector(NSResponder.insertNewline(_:)))

        #expect(handled)
        #expect(commits == 1)
    }

    @Test func renameCoordinatorRoutesEscapeToCancel() {
        var cancellations = 0
        let coordinator = FinderRenameCoordinator(
            onCommit: {},
            onCancel: { cancellations += 1 }
        )

        let handled = coordinator.handleCommand(#selector(NSResponder.cancelOperation(_:)))

        #expect(handled)
        #expect(cancellations == 1)
    }

    @Test func renameCoordinatorLeavesEditingCommandsToAppKit() {
        var commits = 0
        var cancellations = 0
        let coordinator = FinderRenameCoordinator(
            onCommit: { commits += 1 },
            onCancel: { cancellations += 1 }
        )

        let handled = coordinator.handleCommand(#selector(NSResponder.moveLeft(_:)))

        #expect(!handled)
        #expect(commits == 0)
        #expect(cancellations == 0)
    }

    @Test func renameCoordinatorAppliesTheInitialSelectionOnFirstFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
        field.stringValue = "photo.final.png"
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView?.addSubview(field)
        let coordinator = FinderRenameCoordinator(
            initialSelection: NSRange(location: 0, length: 11),
            onCommit: {},
            onCancel: {}
        )

        coordinator.focus(field)

        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange == NSRange(location: 0, length: 11))
        window.orderOut(nil)
    }
}
