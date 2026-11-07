import AppKit

/// Dismisses the menu panel together with its native status-item tracking session.
@MainActor
final class MenuBarPresentation {
    weak var window: NSWindow?

    func dismiss() {
        // SwiftUI can render the label offscreen, so its view's window is not a
        // reliable way to find the status item. Teleport owns one status item.
        let statusItem = Self.statusItem(in: NSApplication.shared.windows)
        // On macOS 27 the session owns both the highlight and the panel lifecycle.
        // Closing the window directly leaves that session tracking the status item.
        if #available(macOS 27.0, *), let statusItem {
            let getSession = NSSelectorFromString("expandedInterfaceSession")
            let cancel = NSSelectorFromString("cancel")
            if statusItem.responds(to: getSession),
               let session = statusItem.perform(getSession)?.takeUnretainedValue() as? NSObject,
               session.responds(to: cancel) {
                session.perform(cancel)
                return
            }
        }

        // Older SwiftUI versions toggle their presentation through the button.
        if window?.isVisible == true, let button = statusItem?.button {
            button.performClick(nil)
        }
        window?.close()
        statusItem?.button?.highlight(false)
    }

    static func statusItem(in windows: [NSWindow]) -> NSStatusItem? {
        let items = windows.compactMap { MenuBarContextMenuController.statusItem(for: $0) }
        return items.count == 1 ? items.first : nil
    }

}
