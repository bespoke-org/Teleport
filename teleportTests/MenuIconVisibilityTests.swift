import AppKit
import XCTest

@MainActor
final class MenuIconVisibilityTests: XCTestCase {
    func testKeepsIconsVisibleWhenItemsAreRebuiltOrImagesArriveLate() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Menu image visibility is macOS 27+") }
        let fixture = Fixture()
        defer { fixture.window.close() }
        let original = item("Update")
        fixture.menu.addItem(original)
        fixture.beginTracking()
        XCTAssertEqual(visibility(original), 1)

        // SwiftUI replaces native items during a live view update.
        fixture.menu.removeAllItems()
        let replacement = item("Update")
        fixture.menu.addItem(replacement)
        let lateImage = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        fixture.menu.addItem(lateImage)
        lateImage.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        await settle()
        XCTAssertEqual(visibility(replacement), 1)
        XCTAssertEqual(visibility(lateImage), 1)

        // Image visibility can be reset at the end of the same update.
        replacement.isEnabled = false
        replacement.setValue(0, forKey: "preferredImageVisibility")
        await settle()
        XCTAssertEqual(visibility(replacement), 1)
    }

    func testLazilyPopulatedSubmenusKeepIconsVisible() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Menu image visibility is macOS 27+") }
        let fixture = Fixture()
        defer { fixture.window.close() }
        let share = item("Share")
        let submenu = NSMenu()
        share.submenu = submenu
        fixture.menu.addItem(share)
        fixture.beginTracking()
        let copy = item("Copy URL")
        submenu.addItem(copy)
        await settle()
        XCTAssertEqual(visibility(copy), 1)
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: submenu)
        let qr = item("Show QR code")
        submenu.addItem(qr)
        await settle()
        XCTAssertEqual(visibility(qr), 1, "Closing a submenu must not stop observing its open parent")
    }

    func testDoesNotAffectUnrelatedMenusOrDetachedControls() async throws {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Menu image visibility is macOS 27+") }
        let fixture = Fixture()
        defer { fixture.window.close() }
        fixture.beginTracking()
        let unrelated = NSMenu()
        let other = item("Other")
        unrelated.addItem(other)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: unrelated)
        await settle()
        XCTAssertEqual(visibility(other), 0)

        fixture.observer.removeFromSuperview()
        let detached = item("Detached")
        fixture.menu.addItem(detached)
        await settle()
        XCTAssertEqual(visibility(detached), 0)
    }

    private func item(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        return item
    }

    private func visibility(_ item: NSMenuItem) -> Int? {
        item.value(forKey: "preferredImageVisibility") as? Int
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    private final class Fixture {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let menu = NSMenu()
        let observer = MenuIconVisibility.ObserverView()

        init() {
            window.isReleasedWhenClosed = false
            let button = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 30, height: 24), pullsDown: true)
            button.menu = menu
            window.contentView!.addSubview(button)
            window.contentView!.addSubview(observer)
        }

        func beginTracking() {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        }
    }
}
