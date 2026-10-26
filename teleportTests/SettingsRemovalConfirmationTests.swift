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

        for (index, title) in ["Remove portal?", "Remove subscription?", "Uninstall Teleport's privileged helper?"].enumerated() {
            state.title = title
            state.isPresented = true
            try await settle()
            var sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertFalse(sheet.preventsApplicationTerminationWhenModal)
            let cancel = try XCTUnwrap(button("Cancel", in: sheet.contentView!))
            cancel.performClick(nil)
            try await settle()
            XCTAssertFalse(state.isPresented)
            XCTAssertEqual(state.removedTitles.count, index)

            state.isPresented = true
            try await settle()
            sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertFalse(sheet.preventsApplicationTerminationWhenModal)
            let remove = try XCTUnwrap(button(state.actionTitle, in: sheet.contentView!))
            remove.performClick(nil)
            try await settle()
            XCTAssertFalse(state.isPresented)
            XCTAssertEqual(state.removedTitles.last, title)
        }
        XCTAssertEqual(state.removedTitles, ["Remove portal?", "Remove subscription?", "Uninstall Teleport's privileged helper?"])
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

    func testQuitReachesApplicationDelegateWithHelperUninstallSheetOpen() async throws {
        let app = NSApplication.shared
        let previousDelegate = app.delegate
        let probe = TerminationProbe()
        app.delegate = probe
        defer { app.delegate = previousDelegate }
        let state = RemovalState()
        state.title = "Uninstall Teleport's privileged helper?"
        let window = NSWindow(contentViewController: NSHostingController(rootView: RemovalFixture(state: state)))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        state.isPresented = true
        try await settle()
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(sheet.preventsApplicationTerminationWhenModal)
        XCTAssertNotNil(button("Uninstall", in: sheet.contentView!))

        app.terminate(nil)
        try await settle()
        XCTAssertEqual(probe.requests, 1)
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
    var actionTitle: String { title.hasPrefix("Uninstall") ? "Uninstall" : "Remove" }
}

private struct RemovalFixture: View {
    @ObservedObject var state: RemovalState

    var body: some View {
        Text("Portals").frame(width: 700, height: 400)
            .background(SettingsRemovalConfirmation(isPresented: $state.isPresented, title: state.title,
                                                    message: "Removes the saved item", actionTitle: state.actionTitle) { [title = state.title] in
                state.removedTitles.append(title)
            })
    }
}

@MainActor
private final class TerminationProbe: NSObject, NSApplicationDelegate {
    var requests = 0
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requests += 1
        return .terminateCancel // Exercise Quit without terminating the test process.
    }
}
