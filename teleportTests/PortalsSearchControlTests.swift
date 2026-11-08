import AppKit
import SwiftUI
import XCTest

@MainActor
final class PortalsSearchControlTests: XCTestCase {
    func testNativeSearchRefocusesExistingQueryAfterEndingInteraction() async throws {
        let state = SearchState()
        let window = makeWindow(state)
        defer { window.close() }
        try await settle()

        for _ in 0..<3 {
            state.focusRequest += 1
            try await settle()
            let field = try XCTUnwrap(searchField(in: window.contentView!.superview!))
            let editor = try XCTUnwrap(field.currentEditor())
            XCTAssertTrue(window.firstResponder === editor)
            editor.selectAll(nil)
            editor.insertText("Paris")
            try await settle()
            XCTAssertEqual(state.query, "Paris")

            window.makeFirstResponder(nil)
            try await settle()
            XCTAssertNil(field.currentEditor())
            XCTAssertEqual(state.query, "Paris", "Ending native search preserves a nonempty query")
            XCTAssertNotNil(searchField(in: window.contentView!.superview!))
            // An ordinary binding update must not steal focus back.
            state.query = "London"
            try await settle()
            XCTAssertNil(field.currentEditor())
        }
    }

    func testEscapeAndEndingEmptySearchAllowReopening() async throws {
        let state = SearchState()
        state.query = "Saved query"
        let window = makeWindow(state)
        defer { window.close() }
        try await settle()
        state.focusRequest += 1
        try await settle()
        let field = try XCTUnwrap(searchField(in: window.contentView!.superview!))
        XCTAssertEqual(field.stringValue, "Saved query")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await settle()
        XCTAssertEqual(state.query, "")
        XCTAssertNil(searchField(in: window.contentView!.superview!)?.currentEditor())

        state.focusRequest += 1
        try await settle()
        XCTAssertNotNil(searchField(in: window.contentView!.superview!)?.currentEditor())
        window.makeFirstResponder(nil)
        try await settle()
        XCTAssertNil(searchField(in: window.contentView!.superview!)?.currentEditor())
        state.focusRequest += 1
        try await settle()
        XCTAssertNotNil(searchField(in: window.contentView!.superview!)?.currentEditor())
    }

    func testFocusKeepsSearchWidthInAConstrainedToolbar() async throws {
        let state = SearchState()
        let window = makeWindow(state)
        defer { window.close() }
        window.title = "Search"
        window.setContentSize(NSSize(width: 500, height: 400))
        try await settle()
        let field = try XCTUnwrap(searchField(in: window.contentView!.superview!))
        let restingFrame = field.convert(field.bounds, to: nil)
        state.focusRequest += 1
        try await settle()
        XCTAssertNotNil(field.currentEditor())
        XCTAssertEqual(field.convert(field.bounds, to: nil), restingFrame,
                       "Focus must not expand a slightly compressed native search field")
        window.makeFirstResponder(nil)
        try await settle()
        XCTAssertEqual(field.convert(field.bounds, to: nil), restingFrame)
    }

    private func makeWindow(_ state: SearchState) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentViewController: NSHostingController(rootView: SearchFixture(state: state)))
        window.setContentSize(NSSize(width: 700, height: 400))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.compactMap { searchField(in: $0) }.first
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
}

@MainActor
private final class SearchState: ObservableObject {
    @Published var portals = PortalsState()
    @Published var focusRequest = 0
    @Published var isActive = true
    var query: String {
        get { portals.query }
        set { portals.query = newValue }
    }
}

private struct SearchFixture: View {
    @ObservedObject var state: SearchState

    var body: some View {
        Color.clear.frame(minWidth: 320, idealWidth: 700, maxWidth: .infinity, minHeight: 400)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    PortalsSearchControl(query: $state.portals.query,
                                         isActive: state.isActive, focusRequest: state.focusRequest)
                        .frame(width: 240, height: 36)
                }
            }
    }
}
