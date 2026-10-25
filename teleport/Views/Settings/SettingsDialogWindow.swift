import AppKit
import SwiftUI

/// Settings dialogs must not prevent Quit from reaching the app's connection cleanup.
struct SettingsDialogWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> ObserverView { ObserverView() }

    func updateNSView(_ nsView: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.preventsApplicationTerminationWhenModal = false
        }
    }
}
