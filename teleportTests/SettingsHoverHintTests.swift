import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsHoverHintTests: XCTestCase {
    func testPointerHintAppearsWithoutClickAndPreservesFocusAndLayout() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: Image(systemName: "exclamationmark.triangle")
            .frame(width: 24, height: 24)
            .background(SettingsHoverHint(message: "Preview only. Split routing is off.")))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        let field = NSTextField(frame: NSRect(x: 20, y: 40, width: 200, height: 24))
        field.stringValue = "example.com"
        root.addSubview(field)
        host.frame = NSRect(x: 300, y: 40, width: 24, height: 24)
        root.addSubview(host)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        await awaitUIUpdate("Warning is attached") { host.window != nil }
        func hints(_ view: NSView) -> [SettingsHoverHint.HintView] {
            (view as? SettingsHoverHint.HintView).map { [$0] } ?? view.subviews.flatMap(hints)
        }
        let hint = try XCTUnwrap(hints(host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())
        let originalFrame = host.frame
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: NSPoint(x: 312, y: 52), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                trackingNumber: 0, userData: nil))
        }
        hint.mouseEntered(with: try event(.mouseEntered))
        let panel = try XCTUnwrap(hint.hintWindow)
        XCTAssertTrue(panel.isVisible, "Hover must show help immediately, without a click or tooltip delay")
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(host.frame, originalFrame)
        hint.mouseExited(with: try event(.mouseExited))
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(hint.hintWindow)
        hint.mouseEntered(with: try event(.mouseEntered))
        let second = try XCTUnwrap(hint.hintWindow)
        host.removeFromSuperview()
        XCTAssertFalse(second.isVisible, "Removing the warning also removes its hint")
    }
}
