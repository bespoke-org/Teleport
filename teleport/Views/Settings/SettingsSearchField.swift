import AppKit
import SwiftUI

/// The field editor consumes arrow keys before SwiftUI key handlers. Handle its
/// native commands so search results can be selected without losing text focus.
struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let focusRequest: Int
    let onMove: (MoveCommandDirection) -> Void
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderAttributedString = NSAttributedString(
            string: "Search Settings",
            attributes: [.foregroundColor: NSColor.tertiaryLabelColor]
        )
        field.setAccessibilityLabel("Search Settings")
        field.setAccessibilityIdentifier("settingsSearch")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SettingsSearchField
        var lastFocusRequest = 0
        init(_ parent: SettingsSearchField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) { parent.isFocused = true }
        func controlTextDidEndEditing(_ notification: Notification) { parent.isFocused = false }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(.down)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(.up)
            case #selector(NSResponder.insertNewline(_:)):
                control.window?.makeFirstResponder(nil)
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                textView.string = ""
                (control as? NSTextField)?.stringValue = ""
                parent.text = ""
            default: return false
            }
            return true
        }
    }
}
