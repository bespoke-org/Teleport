import AppKit
import SwiftUI

/// Keep one native field mounted so entering, saving and cancelling an edit
/// all use the same text baseline and layout measurements.
struct RoutingProfileNameField: NSViewRepresentable {
    let name: String
    let isEditable: Bool
    var requestsFocus = false
    var onFocus: () -> Void = {}
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NameTextField {
        let field = NameTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title2).pointSize, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel("Profile name")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NameTextField, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isEditing { field.stringValue = name }
        field.isEditable = isEditable
        field.isSelectable = true
        field.toolTip = isEditable ? "Rename profile" : nil
        field.wantsNameFocus = isEditable && requestsFocus
        field.onFocus = onFocus
        field.focusIfReady()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NameTextField, context: Context) -> NSSize? {
        NSSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: nsView.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ field: NameTextField, coordinator: Coordinator) {
        coordinator.commit(field)
    }

    final class NameTextField: NSTextField {
        var wantsNameFocus = false
        var onFocus: () -> Void = {}
        private var focusScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusIfReady()
        }

        func focusIfReady() {
            guard wantsNameFocus, !focusScheduled, window != nil else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.wantsNameFocus, let window = self.window,
                      window.makeFirstResponder(self) else { return }
                self.selectText(nil)
                self.wantsNameFocus = false
                self.onFocus()
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RoutingProfileNameField
        var isEditing = false
        private var originalName = ""

        init(_ parent: RoutingProfileNameField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            originalName = parent.name
            isEditing = true
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { commit(field) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch command {
            case #selector(NSResponder.cancelOperation(_:)):
                field.stringValue = isEditing ? originalName : parent.name
                isEditing = false
                field.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                field.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }

        func commit(_ field: NSTextField) {
            guard isEditing else { return }
            isEditing = false
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { field.stringValue = parent.name }
            else { parent.onCommit(name) }
        }
    }
}
