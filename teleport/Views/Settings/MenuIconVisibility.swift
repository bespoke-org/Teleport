import AppKit
import SwiftUI

/// macOS 27 hides menu images by default, independently of SwiftUI's label style.
struct MenuIconVisibility: NSViewRepresentable {
    static func showImageIfSupported(on item: NSMenuItem) {
        // This public macOS 27 property is absent from older build SDKs. Use its
        // Objective-C accessor so those builds also show icons when run on 27.
        // NSMenuItem.ImageVisibility.visible has the raw value 1.
        guard #available(macOS 27.0, *),
              item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else { return }
        item.setValue(1, forKey: "preferredImageVisibility")
    }

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ nsView: ObserverView, context: Context) {}
    static func dismantleNSView(_ nsView: ObserverView, coordinator: ()) {
        nsView.stopObserving()
    }

    final class ObserverView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil, #available(macOS 27.0, *) else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu,
                          self.owns(menu) else { return }
                    func showImages(in menu: NSMenu) {
                        for item in menu.items {
                            if item.image != nil { MenuIconVisibility.showImageIfSupported(on: item) }
                            if let submenu = item.submenu { showImages(in: submenu) }
                        }
                    }
                    showImages(in: menu)
                }
            }
        }

        private func owns(_ menu: NSMenu) -> Bool {
            func buttons(in view: NSView) -> [NSPopUpButton] {
                if let button = view as? NSPopUpButton { return [button] }
                return view.subviews.flatMap { buttons(in: $0) }
            }
            var rootMenu = menu
            while let parent = rootMenu.supermenu { rootMenu = parent }
            var ancestor = superview
            while let view = ancestor {
                let candidates = buttons(in: view)
                if !candidates.isEmpty { return candidates.contains { $0.menu === rootMenu } }
                ancestor = view.superview
            }
            return false
        }

        func stopObserving() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
        }
    }
}
