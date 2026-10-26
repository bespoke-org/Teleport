import AppKit
import SwiftUI
import XCTest

@MainActor
final class MenuBarContextMenuTests: XCTestCase {
    func testMenuContainsSidebarPagesThenSeparatorAndQuit() async {
        _ = NSApplication.shared
        var didQuit = false
        let controller = MenuBarContextMenuController(onQuit: { didQuit = true })
        defer { controller.stop() }
        let menu = controller.makeMenu()
        let sections = SettingsSection.sidebarSections
        XCTAssertEqual(menu.items.map(\.title), sections.map { $0 == .general ? "Settings" : $0.title } + ["", "Quit Teleport"])
        XCTAssertTrue(menu.items[sections.count].isSeparatorItem)
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")

        for (index, section) in sections.enumerated() {
            XCTAssertNotNil(menu.items[index].image)
            let selected = expectation(description: "Open \(section.title)")
            controller.start { destination in
                XCTAssertEqual(destination, section)
                selected.fulfill()
            }
            menu.performActionForItem(at: index)
            await fulfillment(of: [selected], timeout: 1)
        }
        menu.performActionForItem(at: sections.count + 1)
        XCTAssertTrue(didQuit)
    }

    func testNativeMenuIsAttachedDuringTrackingAndPrimaryActionIsPreserved() {
        _ = NSApplication.shared
        let controller = MenuBarContextMenuController()
        defer { controller.stop() }
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        let button = statusItem.button!
        button.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        XCTAssertTrue(MenuBarContextMenuController.statusItem(for: button) === statusItem)
        let previousMenu = NSMenu(title: "Previous menu")
        statusItem.menu = previousMenu
        let originalTarget = button.target
        let originalAction = button.action
        var sawMenu = false
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let trackingMenu = notification.object as? NSMenu,
                      let menu = controller.activeMenu else { return }
                sawMenu = true
                let check: @MainActor @Sendable () -> Void = {
                    XCTAssertTrue(MenuBarContextMenuController.statusItem(for: button)?.menu === menu)
                    trackingMenu.cancelTracking()
                    menu.cancelTracking()
                }
                let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                    MainActor.assumeIsolated { check() }
                }
                RunLoop.main.add(timer, forMode: .common)
                RunLoop.main.add(timer, forMode: .eventTracking)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        controller.showMenu(for: button)
        XCTAssertTrue(sawMenu)
        XCTAssertNil(controller.activeMenu)
        XCTAssertTrue(statusItem.menu === previousMenu)
        XCTAssertTrue(button.target === originalTarget)
        XCTAssertEqual(button.action, originalAction)
    }

    func testOnlySecondaryClicksInsideStatusIconAreHandled() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try XCTUnwrap(item.button)
        let window = try XCTUnwrap(button.window)
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        XCTAssertTrue(MenuBarContextMenuController.statusButton(for: event(.rightMouseDown, in: window, at: center)) === button)
        XCTAssertTrue(MenuBarContextMenuController.statusButton(for: event(.leftMouseDown, in: window, at: center, modifiers: .control)) === button)
        XCTAssertNil(MenuBarContextMenuController.statusButton(for: event(.leftMouseDown, in: window, at: center)))
        XCTAssertNil(MenuBarContextMenuController.statusButton(for: event(.rightMouseDown, in: window, at: NSPoint(x: -100, y: -100))))
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        XCTAssertNil(MenuBarContextMenuController.statusButton(for: event(.rightMouseDown, in: other, at: NSPoint(x: 50, y: 50))))
    }

    private func event(_ type: NSEvent.EventType, in window: NSWindow, at point: NSPoint,
                       modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                          clickCount: 1, pressure: 1)!
    }
}
