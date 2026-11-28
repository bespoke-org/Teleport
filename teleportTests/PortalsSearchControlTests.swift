import AppKit
import SwiftUI
import XCTest

@MainActor
final class PortalsSearchControlTests: XCTestCase {
    func testNativeSearchRefocusesExistingQueryAfterEndingInteraction() async throws {
        let state = SearchState()
        let window = makeWindow(state)
        defer { window.close() }
        let field = try await searchField(in: window)

        for _ in 0..<3 {
            state.focusRequest += 1
            await awaitUIUpdate("Search receives focus") { field.currentEditor() != nil }
            let editor = try XCTUnwrap(field.currentEditor())
            XCTAssertTrue(window.firstResponder === editor)
            editor.selectAll(nil)
            editor.insertText("Paris")
            await awaitUIUpdate("Typing updates the query") { state.query == "Paris" }
            XCTAssertEqual(state.query, "Paris")

            window.makeFirstResponder(nil)
            await awaitUIUpdate("Editing ends") { field.currentEditor() == nil }
            XCTAssertNil(field.currentEditor())
            XCTAssertEqual(state.query, "Paris", "Ending native search preserves a nonempty query")
            XCTAssertNotNil(searchField(in: window.contentView!.superview!))
            // An ordinary binding update must not steal focus back.
            state.query = "London"
            await awaitUIUpdate("Search displays the updated binding") { field.stringValue == "London" }
            XCTAssertNil(field.currentEditor())
        }
    }

    func testEscapeAndEndingEmptySearchAllowReopening() async throws {
        let state = SearchState()
        state.query = "Saved query"
        let window = makeWindow(state)
        defer { window.close() }
        let field = try await searchField(in: window)
        state.focusRequest += 1
        await awaitUIUpdate("Saved search receives focus") { field.currentEditor() != nil }
        XCTAssertEqual(field.stringValue, "Saved query")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await awaitUIUpdate("Escape clears the query and ends editing") { state.query.isEmpty && field.currentEditor() == nil }
        XCTAssertEqual(state.query, "")
        XCTAssertNil(searchField(in: window.contentView!.superview!)?.currentEditor())

        state.focusRequest += 1
        await awaitUIUpdate("Search reopens") { field.currentEditor() != nil }
        XCTAssertNotNil(searchField(in: window.contentView!.superview!)?.currentEditor())
        window.makeFirstResponder(nil)
        await awaitUIUpdate("Editing ends") { field.currentEditor() == nil }
        XCTAssertNil(searchField(in: window.contentView!.superview!)?.currentEditor())
        state.focusRequest += 1
        await awaitUIUpdate("Search regains focus") { field.currentEditor() != nil }
        XCTAssertNotNil(searchField(in: window.contentView!.superview!)?.currentEditor())
    }

    func testFocusKeepsSearchWidthInAConstrainedToolbar() async throws {
        let state = SearchState()
        let window = makeWindow(state)
        defer { window.close() }
        window.title = "Search"
        // Below Settings' supported minimum, AppKit may move the entire
        // toolbar item into overflow instead of compressing the field.
        window.setContentSize(NSSize(width: SettingsSidebarLayout.minimumContentSize.width, height: 400))
        let field = try await searchField(in: window)
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let restingFrame = field.convert(field.bounds, to: nil)
        state.focusRequest += 1
        await awaitUIUpdate("Search receives focus") { field.currentEditor() != nil }
        XCTAssertNotNil(field.currentEditor())
        XCTAssertEqual(field.convert(field.bounds, to: nil), restingFrame,
                       "Focus must not expand a slightly compressed native search field")
        window.makeFirstResponder(nil)
        await awaitUIUpdate("Editing ends") { field.currentEditor() == nil }
        XCTAssertEqual(field.convert(field.bounds, to: nil), restingFrame)
    }

    private func makeWindow(_ state: SearchState) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentViewController: NSHostingController(rootView: SearchFixture(state: state)))
        window.setContentSize(NSSize(width: 1000, height: 400))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func searchField(in view: NSView) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        return view.subviews.compactMap { searchField(in: $0) }.first
    }

    private func searchField(in window: NSWindow) async throws -> NSSearchField {
        let toolbarContainer = try XCTUnwrap(window.contentView?.superview)
        await awaitUIUpdate("Toolbar search field is present") { self.searchField(in: toolbarContainer) != nil }
        return try XCTUnwrap(searchField(in: toolbarContainer))
    }
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
