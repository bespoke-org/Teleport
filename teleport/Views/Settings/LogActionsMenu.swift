import AppKit
import SwiftUI

/// Keep the open menu independent of live log refreshes and make its entire
/// toolbar circle clickable, rather than only the ellipsis's intrinsic bounds.
struct LogActionsMenu: NSViewRepresentable {
    struct Item {
        let title: String
        let symbol: String
        var isEnabled = true
        let action: () -> Void
    }

    let items: [Item]

    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("More actions")
        button.items = items
        button.target = button
        button.action = #selector(MenuButton.openMenu)
        return button
    }

    func updateNSView(_ button: MenuButton, context: Context) {
        button.items = items
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuButton, context: Context) -> CGSize? {
        CGSize(width: 36, height: 36)
    }

    final class MenuButton: NSButton {
        var items: [Item] = []
        override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 36) }
        override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for item in items {
                let menuItem = NSMenuItem(title: item.title, action: #selector(runItem(_:)), keyEquivalent: "")
                menuItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
                if #available(macOS 27.0, *) { menuItem.preferredImageVisibility = .visible }
                menuItem.isEnabled = item.isEnabled
                menuItem.target = self
                // Capture the action for this menu opening. A live refresh may
                // replace `items`, but must not change the action under the pointer.
                menuItem.representedObject = Action(item.action)
                menu.addItem(menuItem)
            }
            return menu
        }

        @objc func openMenu() {
            let point = NSPoint(x: 0, y: isFlipped ? bounds.maxY : bounds.minY)
            makeMenu().popUp(positioning: nil, at: point, in: self)
        }

        @objc private func runItem(_ sender: NSMenuItem) {
            (sender.representedObject as? Action)?.perform()
        }
    }

    private final class Action: NSObject {
        let perform: () -> Void
        init(_ perform: @escaping () -> Void) { self.perform = perform }
    }
}
