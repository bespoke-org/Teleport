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
        let previousMenu = NSMenu(title: "Previous menu")
        statusItem.menu = previousMenu
        let originalTarget = button.target
        let originalAction = button.action
        var sawMenu = false
        let checkAttachedMenu: @MainActor @Sendable () -> Void = {
            XCTAssertTrue(statusItem.menu === controller.activeMenu)
        }
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let trackingMenu = notification.object as? NSMenu,
                      let menu = controller.activeMenu else { return }
                sawMenu = true
                let check: @MainActor @Sendable () -> Void = {
                    checkAttachedMenu()
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
        controller.showMenu(for: statusItem)
        XCTAssertTrue(sawMenu)
        XCTAssertNil(controller.activeMenu)
        XCTAssertTrue(statusItem.menu === previousMenu)
        XCTAssertTrue(button.target === originalTarget)
        XCTAssertEqual(button.action, originalAction)
    }
}
