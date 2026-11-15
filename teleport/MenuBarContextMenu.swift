import AppKit

/// Native secondary-click menu for the app-owned status item.
@MainActor
final class MenuBarContextMenuController: NSObject {
    private(set) var activeMenu: NSMenu?
    private var onSelect: ((SettingsSection) -> Void)?
    private let onQuit: @MainActor () -> Void

    init(onQuit: @escaping @MainActor () -> Void = { NSApplication.shared.terminate(nil) }) {
        self.onQuit = onQuit
        super.init()
    }

    func start(onSelect: @escaping (SettingsSection) -> Void) {
        self.onSelect = onSelect
    }

    func stop() {
        activeMenu?.cancelTracking()
        onSelect = nil
    }

    func showMenu(for statusItem: NSStatusItem) {
        guard activeMenu == nil else { return }
        let menu = makeMenu()
        activeMenu = menu
        let previousMenu = statusItem.menu
        statusItem.menu = menu
        defer {
            statusItem.menu = previousMenu
            activeMenu = nil
        }
        statusItem.button?.performClick(nil)
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
