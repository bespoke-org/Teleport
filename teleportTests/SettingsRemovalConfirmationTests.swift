import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsRemovalConfirmationTests: XCTestCase {
    func testRemovalAlertsAllowTerminationAndOnlyRemoveAfterConfirmation() async throws {
        _ = NSApplication.shared
        let state = RemovalState()
        let window = NSWindow(contentViewController: NSHostingController(rootView: RemovalFixture(state: state)))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        for title in ["Remove portal?", "Remove subscription?"] {
            state.title = title
            state.isPresented = true
            try await settle()
            var sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertFalse(sheet.preventsApplicationTerminationWhenModal)
            let cancel = try XCTUnwrap(button("Cancel", in: sheet.contentView!))
            cancel.performClick(nil)
            try await settle()
            XCTAssertFalse(state.isPresented)
            XCTAssertEqual(state.removedTitles.count, title == "Remove portal?" ? 0 : 1)

            state.isPresented = true
            try await settle()
            sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertFalse(sheet.preventsApplicationTerminationWhenModal)
            let remove = try XCTUnwrap(button("Remove", in: sheet.contentView!))
            remove.performClick(nil)
            try await settle()
            XCTAssertFalse(state.isPresented)
            XCTAssertEqual(state.removedTitles.last, title)
        }
        XCTAssertEqual(state.removedTitles, ["Remove portal?", "Remove subscription?"])
    }

    func testDismissingPresentationDoesNotRemove() async throws {
        _ = NSApplication.shared
        let state = RemovalState()
        let window = NSWindow(contentViewController: NSHostingController(rootView: RemovalFixture(state: state)))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        state.isPresented = true
        try await settle()
        XCTAssertNotNil(window.attachedSheet)
        state.isPresented = false
        try await settle()
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(state.removedTitles.isEmpty)
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.compactMap { button(title, in: $0) }.first
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
}

@MainActor
private final class RemovalState: ObservableObject {
    @Published var isPresented = false
    @Published var title = "Remove portal?"
    var removedTitles: [String] = []
}

private struct RemovalFixture: View {
    @ObservedObject var state: RemovalState

    var body: some View {
        Text("Portals").frame(width: 700, height: 400)
            .background(SettingsRemovalConfirmation(isPresented: $state.isPresented, title: state.title,
                                                    message: "Removes the saved item") { [title = state.title] in
                state.removedTitles.append(title)
            })
    }
}
