import AppKit
import SwiftUI

/// A native removal alert that lets Quit reach the application's connection cleanup.
struct SettingsRemovalConfirmation: NSViewRepresentable {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let onRemove: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.onAttach = { [weak coordinator = context.coordinator] view in
            coordinator?.update(in: view)
        }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(in: view)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        view.onAttach = nil
        coordinator.invalidate()
    }

    final class AnchorView: NSView {
        var onAttach: ((AnchorView) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onAttach?(self)
        }
    }

    final class Coordinator {
        var parent: SettingsRemovalConfirmation
        private var alert: NSAlert?
        private var isDismantled = false

        init(_ parent: SettingsRemovalConfirmation) { self.parent = parent }

        func update(in view: AnchorView) {
            // Present after SwiftUI finishes updating the containing window.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view, !self.isDismantled else { return }
                guard self.parent.isPresented, let window = view.window else {
                    self.dismiss()
                    return
                }
                guard self.alert == nil else { return }
                let alert = NSAlert()
                alert.messageText = self.parent.title
                alert.informativeText = self.parent.message
                alert.addButton(withTitle: "Remove").hasDestructiveAction = true
                alert.addButton(withTitle: "Cancel")
                alert.window.preventsApplicationTerminationWhenModal = false
                self.alert = alert
                let onRemove = self.parent.onRemove
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard let self, self.alert === alert else { return }
                    self.alert = nil
                    self.parent.isPresented = false
                    if response == .alertFirstButtonReturn { onRemove() }
                }
            }
        }

        func dismiss() {
            guard let alert else { return }
            self.alert = nil
            alert.window.sheetParent?.endSheet(alert.window, returnCode: .abort)
        }

        func invalidate() {
            isDismantled = true
            dismiss()
        }
    }
}
