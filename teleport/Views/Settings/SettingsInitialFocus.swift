import AppKit
import SwiftUI

/// AppKit restores its field editor when a retained Settings window reopens.
/// Clear that automatic focus once per opening, without disturbing app switching.
struct SettingsInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) {}

    final class ObserverView: NSView {
        private var needsInitialFocus = true

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            needsInitialFocus = true
            guard let window else { return }
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowBecameKey), name: NSWindow.didBecomeKeyNotification, object: window
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: window
            )
            if window.isKeyWindow { windowBecameKey() }
        }

        @objc private func windowBecameKey() {
            guard needsInitialFocus, let window else { return }
            needsInitialFocus = false
            DispatchQueue.main.async { [weak window] in
                guard let window, window.isKeyWindow else { return }
                window.makeFirstResponder(nil)
            }
        }

        @objc private func windowWillClose() { needsInitialFocus = true }
    }
}
