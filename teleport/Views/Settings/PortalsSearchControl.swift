import AppKit
import SwiftUI

/// A persistent native field avoids NSSearchToolbarItem's page-entry animation.
struct PortalsSearchControl: NSViewRepresentable {
    @Binding var query: String
    let isActive: Bool
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search portals"
        field.setAccessibilityLabel("Search portals")
        field.controlSize = .large
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
        field.isEnabled = isActive
        if !isActive, field.currentEditor() != nil {
            field.window?.makeFirstResponder(nil)
        }
        guard coordinator.lastFocusRequest != focusRequest else { return }
        coordinator.lastFocusRequest = focusRequest
        guard isActive else { return }
        DispatchQueue.main.async { [weak field, weak coordinator] in
            guard let field, let coordinator, coordinator.parent.isActive,
                  coordinator.parent.focusRequest == focusRequest else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSearchField, context: Context) -> CGSize? {
        CGSize(width: 240, height: 36)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PortalsSearchControl
        var lastFocusRequest: Int

        init(_ parent: PortalsSearchControl) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.query = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.query = ""
            control.stringValue = ""
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}
