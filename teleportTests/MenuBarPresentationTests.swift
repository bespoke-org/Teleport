import AppKit
import XCTest

@MainActor
final class MenuBarPresentationTests: XCTestCase {
    func testFindsStatusItemInApplicationWindows() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        XCTAssertNotNil(item.button?.window)
        XCTAssertTrue(MenuBarPresentation.statusItem(in: NSApplication.shared.windows) === item)

    }

    func testDismissClosesOnlyTheCapturedPanel() {
        _ = NSApplication.shared
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
                            styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                styleMask: .titled, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        settings.isReleasedWhenClosed = false
        defer { panel.close(); settings.close() }
        panel.orderFront(nil)
        settings.makeKeyAndOrderFront(nil)
        let presentation = MenuBarPresentation()
        presentation.window = panel
        presentation.dismiss()
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(settings.isVisible)
    }
}
