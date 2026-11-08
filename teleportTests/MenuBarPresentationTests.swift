import AppKit
import XCTest

@MainActor
final class MenuBarPresentationTests: XCTestCase {
    func testFindsStatusItemAmongUnrelatedWindows() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let window = try XCTUnwrap(item.button?.window)
        let unrelated = makeWindow()
        defer { unrelated.close() }
        XCTAssertTrue(NSApplication.shared.windows.contains { $0 === window })
        // AppKit may retain removed status-item windows from earlier tests.
        // Only these windows belong to this fixture; ambiguity is tested below.
        XCTAssertTrue(MenuBarPresentation.statusItem(in: [unrelated, window]) === item)
    }

    func testRejectsMissingOrAmbiguousStatusItems() throws {
        _ = NSApplication.shared
        let unrelated = makeWindow()
        defer { unrelated.close() }
        XCTAssertNil(MenuBarPresentation.statusItem(in: []))
        XCTAssertNil(MenuBarPresentation.statusItem(in: [unrelated]))

        let first = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let second = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer {
            NSStatusBar.system.removeStatusItem(first)
            NSStatusBar.system.removeStatusItem(second)
        }
        let firstWindow = try XCTUnwrap(first.button?.window)
        let secondWindow = try XCTUnwrap(second.button?.window)
        XCTAssertNil(MenuBarPresentation.statusItem(in: [firstWindow, unrelated, secondWindow]))
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

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
