import AppKit
import SwiftUI

@MainActor
final class FinderRenameCoordinator: NSObject, NSTextFieldDelegate {
    private var onTextChange: (String) -> Void
    private var onCommit: () -> Void
    private var onCancel: () -> Void
    private var initialSelection = NSRange(location: 0, length: 0)
    private var didFocus = false

    init(
        initialSelection: NSRange = NSRange(location: 0, length: 0),
        onTextChange: @escaping (String) -> Void = { _ in },
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialSelection = initialSelection
        self.onTextChange = onTextChange
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func update(
        initialSelection: NSRange,
        onTextChange: @escaping (String) -> Void,
        onCommit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initialSelection = initialSelection
        self.onTextChange = onTextChange
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    func handleCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel()
            return true
        default:
            return false
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        handleCommand(commandSelector)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        onTextChange(field.stringValue)
    }

    func focus(_ field: NSTextField) {
        guard !didFocus,
              let window = field.window,
              window.makeFirstResponder(field)
        else { return }
        didFocus = true
        guard let editor = field.currentEditor() as? NSTextView else { return }
        let length = (field.stringValue as NSString).length
        let location = min(max(0, initialSelection.location), length)
        let selectedLength = min(max(0, initialSelection.length), length - location)
        editor.selectedRange = NSRange(location: location, length: selectedLength)
    }
}

struct FinderRenameField: NSViewRepresentable {
    @Binding var text: String
    let initialSelection: NSRange
    let alignment: NSTextAlignment
    let isCommitting: Bool
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> FinderRenameCoordinator {
        FinderRenameCoordinator(
            initialSelection: initialSelection,
            onTextChange: { text = $0 },
            onCommit: onCommit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> FinderRenameTextField {
        let field = FinderRenameTextField()
        field.delegate = context.coordinator
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.controlSize = .small
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.onMoveToWindow = { [weak field, weak coordinator = context.coordinator] in
            guard let field else { return }
            coordinator?.focus(field)
        }
        return field
    }

    func updateNSView(_ field: FinderRenameTextField, context: Context) {
        context.coordinator.update(
            initialSelection: initialSelection,
            onTextChange: { text = $0 },
            onCommit: onCommit,
            onCancel: onCancel
        )
        if field.stringValue != text {
            field.stringValue = text
        }
        field.alignment = alignment
        field.isEditable = !isCommitting
        field.isSelectable = true
        context.coordinator.focus(field)
    }
}

@MainActor
final class FinderRenameTextField: NSTextField {
    var onMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onMoveToWindow?()
    }
}
