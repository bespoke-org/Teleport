import AppKit
import SwiftUI
import XCTest

@MainActor
final class PortalsSearchControlTests: XCTestCase {
    func testCommandFRefocusesExistingQueryAfterClickAway() async throws {
        let state = SearchState()
        let window = makeWindow(state)
        defer { window.close() }
        try await settle()

        for _ in 0..<3 {
            XCTAssertTrue(window.performKeyEquivalent(with: commandF(in: window)))
            try await settle()
            let field = try XCTUnwrap(searchField(in: window.contentView!.superview!))
            let editor = try XCTUnwrap(field.currentEditor())
            XCTAssertTrue(window.firstResponder === editor)
            editor.insertText("Paris")
            try await settle()
            XCTAssertEqual(state.query, "Paris")

            clickAway(in: window)
            try await settle()
            XCTAssertNil(field.currentEditor())
            XCTAssertEqual(state.query, "Paris", "Click-away preserves a nonempty query")
            XCTAssertNotNil(searchField(in: window.contentView!.superview!))
            // An ordinary binding update must not steal focus back.
            state.query = "London"
            try await settle()
            XCTAssertNil(field.currentEditor())
        }
    }

    func testEscapeAndEmptyClickAwayCollapseSearchAndAllowReopening() async throws {
        let state = SearchState()
        state.query = "Saved query"
        let window = makeWindow(state)
        defer { window.close() }
        try await settle()
        let field = try XCTUnwrap(searchField(in: window.contentView!.superview!))
        XCTAssertEqual(field.stringValue, "Saved query")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await settle()
        XCTAssertEqual(state.query, "")
        XCTAssertNil(searchField(in: window.contentView!.superview!))

        XCTAssertTrue(window.performKeyEquivalent(with: commandF(in: window)))
        try await settle()
        XCTAssertNotNil(searchField(in: window.contentView!.superview!)?.currentEditor())
        clickAway(in: window)
        try await settle()
        XCTAssertNil(searchField(in: window.contentView!.superview!))
        XCTAssertTrue(window.performKeyEquivalent(with: commandF(in: window)))
        try await settle()
        XCTAssertNotNil(searchField(in: window.contentView!.superview!)?.currentEditor())
    }

    private func makeWindow(_ state: SearchState) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentViewController: NSHostingController(rootView: SearchFixture(state: state)))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func commandF(in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "f",
                        charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
    }

    private func clickAway(in window: NSWindow) {
        let point = NSPoint(x: 20, y: 20)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.compactMap { searchField(in: $0) }.first
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
}

@MainActor
private final class SearchState: ObservableObject {
    @Published var query = ""
}

private struct SearchFixture: View {
    @ObservedObject var state: SearchState

    var body: some View {
        Color.clear.frame(width: 700, height: 400)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { PortalsSearchControl(query: $state.query) }
            }
    }
}
