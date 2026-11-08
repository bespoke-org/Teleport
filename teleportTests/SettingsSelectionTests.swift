import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsSelectionTests: XCTestCase {
    func testSubscriptionHierarchyNavigatesWithoutSelectingAndHandlesEmptyGroups() async throws {
        _ = NSApplication.shared
        var selected: String?
        var opens = 0
        let options = [
            GlassSelectionOption(id: "manual", title: "Manual"),
            GlassSelectionOption(id: "provider", title: "Provider", children:
                (0..<1000).map { GlassSelectionOption(id: "portal-\($0)", title: "Portal \($0)") }),
            GlassSelectionOption(id: "empty", title: "Empty subscription", children: [])
        ]
        let host = NSHostingController(rootView:
            GlassSelectionPicker(options: options, selectedID: "portal-899", onSelect: { selected = $0 }, onOpen: {
                opens += 1
                return options
            }) { Text("Choose portal").frame(width: 200, height: 40) }
                .keyboardShortcut("p", modifiers: .command)
                .frame(width: 360, height: 160)
        )
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        let existing = Set(NSApp.windows.map(\.windowNumber))
        try await openPicker(in: window, expectedOpens: 1, opens: { opens })
        await awaitUIUpdate("Hierarchy is presented") {
            NSApp.windows.contains { !existing.contains($0.windowNumber) && $0.isVisible && $0.frame.height > 100 }
        }
        let popover = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
        let size = popover.frame.size
        try key("\r", code: 36, in: popover)
        await awaitUIUpdate("Enter opens the selected portal's subscription")
        XCTAssertNil(selected, "Entering a subscription must not select or connect a portal")
        XCTAssertTrue(popover.isVisible)
        XCTAssertEqual(popover.frame.size, size)
        try key("\u{F701}", code: 125, in: popover)
        await awaitUIUpdate("Next portal is highlighted")
        try key("\r", code: 36, in: popover)
        await awaitUIUpdate("Selecting a child closes the picker") { selected == "portal-900" && !popover.isVisible }

        selected = nil
        try await openPicker(in: window, expectedOpens: 2, opens: { opens })
        await awaitUIUpdate("Root hierarchy is restored") {
            NSApp.windows.contains { !existing.contains($0.windowNumber) && $0.isVisible && $0.frame.height > 100 }
        }
        let reopened = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
        try key("\u{F701}", code: 125, in: reopened)
        await awaitUIUpdate("Empty subscription is highlighted")
        try key("\u{F703}", code: 124, in: reopened)
        await awaitUIUpdate("Right opens an empty subscription")
        try key("\r", code: 36, in: reopened)
        XCTAssertNil(selected)
        XCTAssertTrue(reopened.isVisible)
        XCTAssertEqual(reopened.frame.size, size)
        try key("\u{F702}", code: 123, in: reopened)
        await awaitUIUpdate("Left returns to subscriptions")
        try key("\u{F700}", code: 126, in: reopened)
        await awaitUIUpdate("Provider is highlighted")
        try key("\u{F700}", code: 126, in: reopened)
        await awaitUIUpdate("Standalone portal is highlighted")
        try key("\r", code: 36, in: reopened)
        await awaitUIUpdate("Standalone selection still works") { selected == "manual" && !reopened.isVisible }
    }

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
            }.buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: .command)
                .frame(width: 360, height: 160)
        )
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        await awaitUIUpdate("Picker window is presented") { window.isVisible && host.view.window != nil }
        let existing = Set(NSApp.windows.map(\.windowNumber))

        try await openPicker(in: window, expectedOpens: 1, opens: { opens })
        await awaitUIUpdate("First selection popover has laid out its rows") {
            NSApp.windows.contains { !existing.contains($0.windowNumber) && $0.isVisible && $0.frame.height > 100 }
        }
        let first = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
        XCTAssertGreaterThan(first.frame.height, 100, "The first activation must show rows, not an empty glass strip")
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
        try await openPicker(in: window, expectedOpens: 2, opens: { opens })
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
        try await openPicker(in: window, expectedOpens: 3, opens: { opens })
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

    // Hostless xctest is not a reliably active application. Use a shortcut on
    // the real SwiftUI button rather than a first mouse click that AppKit may
    // consume for activation. Wait for registration, dispatch once, then observe
    // onOpen so a missing action fails here instead of as a missing popover.
    private func openPicker(in window: NSWindow, expectedOpens: Int, opens: @escaping () -> Int) async throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "p",
            charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        var accepted = false
        await awaitUIUpdate("Rendered picker accepts its action and captures fresh options") {
            if !accepted { accepted = window.performKeyEquivalent(with: event) }
            return accepted && opens() == expectedOpens
        }
        XCTAssertEqual(opens(), expectedOpens)
    }

    private func click(in window: NSWindow, at point: NSPoint) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        window.sendEvent(try event(.leftMouseDown))
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(pending)
        }
    }

    private func key(_ text: String, code: UInt16, in window: NSWindow) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)))
    }
}
