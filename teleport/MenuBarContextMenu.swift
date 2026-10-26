import AppKit
import SwiftUI

struct MenuBarContextMenu: ViewModifier {
    @Binding var navigation: SettingsNavigation
    @Environment(\.openWindow) private var openWindow
    @State private var controller = MenuBarContextMenuController()

    func body(content: Content) -> some View {
        content
            .onAppear {
                controller.start { section in
                    navigation.select(section)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "settings")
                }
            }
            .onDisappear { controller.stop() }
    }
}

/// Adds a native menu without replacing the SwiftUI menu bar window.
@MainActor
final class MenuBarContextMenuController: NSObject {
    private var eventMonitor: Any?
    private(set) var activeMenu: NSMenu?
    private var onSelect: ((SettingsSection) -> Void)?
    private let onQuit: @MainActor () -> Void

    init(onQuit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.onQuit = onQuit
        super.init()
    }

    func start(onSelect: @escaping (SettingsSection) -> Void) {
        self.onSelect = onSelect
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, let button = Self.statusButton(for: event) else { return event }
            self.showMenu(for: button)
            return nil
        }
    }

    func stop() {
        activeMenu?.cancelTracking()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        onSelect = nil
    }

    func showMenu(for button: NSStatusBarButton) {
        guard activeMenu == nil else { return }
        let menu = makeMenu()
        activeMenu = menu
        defer { activeMenu = nil }

        if let statusItem = Self.statusItem(for: button) {
            if #available(macOS 27.0, *) {
                // Suspend SwiftUI's window presentation while AppKit tracks the menu.
                let delegate = statusItem.expandedInterfaceDelegate
                statusItem.expandedInterfaceSession?.cancel()
                statusItem.expandedInterfaceDelegate = nil
                defer { statusItem.expandedInterfaceDelegate = delegate }
                showNativeMenu(menu, for: statusItem)
            } else {
                showNativeMenu(menu, for: statusItem)
            }
            return
        }

        // Keep the menu usable if AppKit changes its status-window implementation.
        let anchor = NSPoint(x: button.bounds.minX,
                             y: button.isFlipped ? button.bounds.maxY : button.bounds.minY)
        button.highlight(true)
        defer { button.highlight(false) }
        menu.popUp(positioning: nil, at: anchor, in: button)
    }

    private func showNativeMenu(_ menu: NSMenu, for statusItem: NSStatusItem) {
        let previousMenu = statusItem.menu
        statusItem.menu = menu
        defer { statusItem.menu = previousMenu }
        statusItem.button?.performClick(nil)
    }

    static func statusItem(for button: NSStatusBarButton) -> NSStatusItem? {
        // SwiftUI does not expose its NSStatusItem. Guard this AppKit lookup and
        // verify ownership before temporarily assigning the native menu.
        let selector = NSSelectorFromString("statusItem")
        guard let window = button.window, window.responds(to: selector),
              let item = window.perform(selector)?.takeUnretainedValue() as? NSStatusItem,
              item.button === button else { return nil }
        return item
    }

    static func statusButton(for event: NSEvent) -> NSStatusBarButton? {
        guard event.type == .rightMouseDown ||
                (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
              let content = event.window?.contentView else { return nil }
        return statusButton(in: content, at: event.locationInWindow)
    }

    private static func statusButton(in view: NSView, at location: NSPoint) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton,
           button.bounds.contains(button.convert(location, from: nil)) {
            return button
        }
        return view.subviews.lazy.compactMap { statusButton(in: $0, at: location) }.first
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        for section in SettingsSection.sidebarSections {
            let title = section == .general ? "Settings" : section.title
            let item = NSMenuItem(title: title, action: #selector(selectSection(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: section.systemImage, accessibilityDescription: nil)
            item.target = self
            item.representedObject = section.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Teleport", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func selectSection(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let section = SettingsSection(rawValue: rawValue) else { return }
        DispatchQueue.main.async { [weak self] in self?.onSelect?(section) }
    }

    @objc private func quit(_ sender: NSMenuItem) { onQuit() }
}
