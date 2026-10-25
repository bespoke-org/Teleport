import AppKit
import SwiftUI

@MainActor
final class SettingsClickAwayScope {
    fileprivate let regions = NSHashTable<NSView>.weakObjects()

    func contains(_ event: NSEvent) -> Bool {
        // Non-clipping AppKit views can report a visibleRect larger than their bounds.
        regions.allObjects.contains { view in
            view.window === event.window && !view.isHiddenOrHasHiddenAncestor
                && view.bounds.intersection(view.visibleRect).contains(view.convert(event.locationInWindow, from: nil))
        }
    }
}

/// Marks a region where a click should preserve the associated selection or focus.
struct SettingsClickAwayRegion: NSViewRepresentable {
    let scope: SettingsClickAwayScope

    func makeNSView(context: Context) -> RegionView { RegionView() }

    func updateNSView(_ view: RegionView, context: Context) { view.scope = scope }

    static func dismantleNSView(_ view: RegionView, coordinator: ()) { view.scope = nil }

    final class RegionView: NSView {
        var scope: SettingsClickAwayScope? {
            didSet {
                oldValue?.regions.remove(self)
                scope?.regions.add(self)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Observes clicks without consuming them or competing with row controls and dragging.
struct SettingsClickAwayMonitor: NSViewRepresentable {
    let scope: SettingsClickAwayScope
    let isActive: Bool
    let onClickAway: () -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.scope = scope
        view.isActive = isActive
        view.onClickAway = onClickAway
        view.updateMonitoring()
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stopMonitoring() }

    final class MonitorView: NSView {
        var scope: SettingsClickAwayScope?
        var isActive = false
        var onClickAway: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitoring()
        }

        func updateMonitoring() {
            guard isActive, window != nil else {
                stopMonitoring()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.handleClick(event)
                return event
            }
        }

        func handleClick(_ event: NSEvent) {
            guard isActive, let window, event.window === window,
                  let scope, !scope.contains(event) else { return }
            onClickAway?()
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
