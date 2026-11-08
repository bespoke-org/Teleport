import AppKit
import SwiftUI

/// macOS 27 hides menu images by default, independently of SwiftUI's label style.
struct MenuIconVisibility: NSViewRepresentable {
    static func showImageIfSupported(on item: NSMenuItem) {
        // This public macOS 27 property is absent from older build SDKs. Use its
        // Objective-C accessor so those builds also show icons when run on 27.
        // NSMenuItem.ImageVisibility.visible has the raw value 1.
        guard #available(macOS 27.0, *),
              item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")),
              item.value(forKey: "preferredImageVisibility") as? Int != 1 else { return }
        item.setValue(1, forKey: "preferredImageVisibility")
    }

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.scheduleRefresh()
    }
    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class ObserverView: NSView {
        private var observers: [NSObjectProtocol] = []
        private weak var trackedMenu: NSMenu?
        private var refreshScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil, #available(macOS 27.0, *) else { return }
            for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
                         NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] notification in
                    MainActor.assumeIsolated { self?.menuChanged(notification) }
                })
            }
        }

        private func menuChanged(_ notification: Notification) {
            guard let menu = notification.object as? NSMenu else { return }
            if notification.name == NSMenu.didBeginTrackingNotification {
                guard owns(menu) else { return }
                trackedMenu = rootMenu(of: menu)
                showImages(in: menu)
                scheduleRefresh()
            } else if notification.name == NSMenu.didEndTrackingNotification {
                if menu === trackedMenu { trackedMenu = nil }
            } else if rootMenu(of: menu) === trackedMenu {
                scheduleRefresh()
            }
        }

        func scheduleRefresh() {
            guard trackedMenu != nil, !refreshScheduled else { return }
            refreshScheduled = true
            // SwiftUI can replace items or reset their image preference during
            // an update. Apply it after that update, including during menu tracking.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                guard let menu = self.trackedMenu else { return }
                self.showImages(in: menu)
            }
        }

        private func showImages(in menu: NSMenu) {
            for item in menu.items {
                if item.image != nil { MenuIconVisibility.showImageIfSupported(on: item) }
                if let submenu = item.submenu { showImages(in: submenu) }
            }
        }

        private func rootMenu(of menu: NSMenu) -> NSMenu {
            var root = menu
            while let parent = root.supermenu { root = parent }
            return root
        }

        private func owns(_ menu: NSMenu) -> Bool {
            func buttons(in view: NSView) -> [NSPopUpButton] {
                if let button = view as? NSPopUpButton { return [button] }
                return view.subviews.flatMap { buttons(in: $0) }
            }
            let rootMenu = rootMenu(of: menu)
            var ancestor = superview
            while let view = ancestor {
                let candidates = buttons(in: view)
                if !candidates.isEmpty { return candidates.contains { $0.menu === rootMenu } }
                ancestor = view.superview
            }
            return false
        }

        func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            trackedMenu = nil
        }
    }
}
