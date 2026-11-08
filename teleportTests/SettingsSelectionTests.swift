import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsSelectionTests: XCTestCase {
    func testPopoverFirstOpenSelectionRefreshAndEscape() async throws {
        _ = NSApplication.shared
        var selected: String?
        var opens = 0
        var options = [
            GlassSelectionOption(id: "proxy", title: "Proxy"),
            GlassSelectionOption(id: "direct", title: "Direct"),
            GlassSelectionOption(id: "block", title: "Block")
        ]
        let host = NSHostingController(rootView:
            GlassSelectionPicker(options: [], selectedID: "proxy", onSelect: { selected = $0 }, onOpen: {
                opens += 1
                return options
            }) {
                Text("Choose route").frame(width: 200, height: 40).contentShape(Rectangle())
            }.buttonStyle(.plain).frame(width: 360, height: 160)
        )
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        await awaitUIUpdate("Picker window is presented") { window.isVisible && host.view.window != nil }
        let existing = Set(NSApp.windows.map(\.windowNumber))

        try click(in: window)
        await awaitUIUpdate("First selection popover has laid out its rows") {
            NSApp.windows.contains { !existing.contains($0.windowNumber) && $0.isVisible && $0.frame.height > 100 }
        }
        print("[DEBUG-selection] opens=\(opens) active=\(NSApp.isActive) key=\(window.isKeyWindow) host=\(host.view.frame) windows=\(NSApp.windows.map { "\($0.windowNumber):\($0.isVisible):\($0.frame):existing=\(existing.contains($0.windowNumber))" })")
        let first = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
        XCTAssertGreaterThan(first.frame.height, 100, "The first click must show rows, not an empty glass strip")
        XCTAssertEqual(opens, 1)
        try key("\u{F701}", code: 125, in: first)
        await awaitUIUpdate("Keyboard highlight is applied")
        try key("\r", code: 36, in: first)
        await awaitUIUpdate("First selection closes the popover") { selected == "direct" && !first.isVisible }
        XCTAssertEqual(selected, "direct")
        XCTAssertFalse(first.isVisible)

        options = [
            GlassSelectionOption(id: "fresh", title: "Fresh portal"),
            GlassSelectionOption(id: "missing", title: "Unavailable", isEnabled: false),
            GlassSelectionOption(id: "last", title: "Last portal")
        ]
        window.makeKeyAndOrderFront(nil)
        try click(in: window)
        await awaitUIUpdate("Selection popover is presented") {
            NSApp.windows.contains { !existing.contains($0.windowNumber) && $0.isVisible && $0.frame.height > 100 }
        }
        let second = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
        XCTAssertEqual(opens, 2, "Each open must refresh the snapshot")
        XCTAssertGreaterThan(second.frame.height, 100)
        try key("\u{F701}", code: 125, in: second)
        await awaitUIUpdate("Keyboard highlight is applied")
        try key("\r", code: 36, in: second)
        await awaitUIUpdate("Fresh selection closes the popover") { selected == "last" && !second.isVisible }
        XCTAssertEqual(selected, "last", "Keyboard navigation skips unavailable options")
        XCTAssertFalse(second.isVisible)

        window.makeKeyAndOrderFront(nil)
        try click(in: window)
        await awaitUIUpdate("Selection popover is presented") {
            NSApp.windows.contains { !existing.contains($0.windowNumber) && $0.isVisible && $0.frame.height > 100 }
        }
        let third = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
        try key("\u{1b}", code: 53, in: third)
        await awaitUIUpdate("Escape closes the popover") { !third.isVisible }
        XCTAssertFalse(third.isVisible)
        XCTAssertEqual(selected, "last", "Escape dismisses without changing selection")
    }

    func testShortChoicesHaveEqualVisibleSegmentWidthsAndSelectOnClick() async throws {
        _ = NSApplication.shared
        var selected = 0
        let choice = Binding(get: { selected }, set: { selected = $0 })
        let host = NSHostingController(rootView: VStack(spacing: 16) {
            SettingsSegmentedPicker(title: "Connection mode", selection: choice, choices: [
                SettingsChoice(value: 0, title: "System Proxy"), SettingsChoice(value: 1, title: "TUN")
            ]).frame(width: 220, height: 28)
            SettingsSegmentedPicker(title: "Portal order", selection: .constant(0), choices: [
                SettingsChoice(value: 0, title: "Name"), SettingsChoice(value: 1, title: "Latency")
            ]).frame(width: 220, height: 28)
        }.padding(20))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        await awaitUIUpdate("Segmented controls are laid out") { window.isVisible && host.view.window != nil }
        func controls(_ view: NSView) -> [NSSegmentedControl] {
            if let control = view as? NSSegmentedControl { return [control] }
            return view.subviews.flatMap(controls)
        }
        let segments = controls(host.view)
        XCTAssertEqual(segments.count, 2)
        let mode = try XCTUnwrap(segments.first { $0.label(forSegment: 0) == "System Proxy" })
        let order = try XCTUnwrap(segments.first { $0.label(forSegment: 0) == "Name" })
        XCTAssertEqual(mode.frame.width, order.frame.width, accuracy: 0.5)
        XCTAssertEqual(mode.frame.height, order.frame.height, accuracy: 0.5)
        for index in 0..<2 {
            XCTAssertEqual(mode.width(forSegment: index), order.width(forSegment: index), accuracy: 0.5)
        }
        let point = mode.convert(NSPoint(x: mode.bounds.width * 0.75, y: mode.bounds.midY), to: nil)
        try click(in: window, at: point)
        XCTAssertEqual(selected, 1)
    }

    private func click(in window: NSWindow, at point: NSPoint = NSPoint(x: 180, y: 80)) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        window.sendEvent(try event(.leftMouseDown))
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            // The down event goes straight to the fixture window. Deliver its
            // matching up there too, even when the hostless app is inactive.
            window.sendEvent(pending)
        }
    }

    private func key(_ text: String, code: UInt16, in window: NSWindow) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)))
    }
}
