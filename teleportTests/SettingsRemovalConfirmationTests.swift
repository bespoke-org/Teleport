import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsRemovalConfirmationTests: XCTestCase {
    private var registeredApplicationIcon: NSImage?

    override func setUp() {
        super.setUp()
        // NSAlert's nib resolves this named image during init, before its icon can
        // be set. Avoid asking the runner's IconServices agent for xctest's icon:
        // that synchronous lookup can hang when the agent has crashed.
        let icon = NSImage(size: NSSize(width: 32, height: 32))
        if icon.setName(NSImage.applicationIconName) {
            registeredApplicationIcon = icon
        }
    }

    override func tearDown() {
        // Only remove our registration; a pre-existing cached icon is left alone.
        registeredApplicationIcon?.setName(nil)
        registeredApplicationIcon = nil
        super.tearDown()
    }

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
            await awaitUIUpdate("Removal sheet appears") { window.attachedSheet != nil }
            var sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertFalse(sheet.preventsApplicationTerminationWhenModal)
            let cancel = try XCTUnwrap(button("Cancel", in: sheet.contentView!))
            cancel.performClick(nil)
            await awaitUIUpdate("Cancel dismisses the sheet") { window.attachedSheet == nil && !state.isPresented }
            XCTAssertFalse(state.isPresented)
            XCTAssertEqual(state.removedTitles.count, index)

            state.isPresented = true
            await awaitUIUpdate("Removal sheet reopens") { window.attachedSheet != nil }
            sheet = try XCTUnwrap(window.attachedSheet)
            XCTAssertFalse(sheet.preventsApplicationTerminationWhenModal)
            let remove = try XCTUnwrap(button(state.actionTitle, in: sheet.contentView!))
            remove.performClick(nil)
            await awaitUIUpdate("Confirmation dismisses the sheet") { window.attachedSheet == nil && !state.isPresented }
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
        await awaitUIUpdate("Removal sheet appears") { window.attachedSheet != nil }
        XCTAssertNotNil(window.attachedSheet)
        state.isPresented = false
        await awaitUIUpdate("Removal sheet closes") { window.attachedSheet == nil }
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
        await awaitUIUpdate("Uninstall sheet appears") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(sheet.preventsApplicationTerminationWhenModal)
        XCTAssertNotNil(button("Uninstall", in: sheet.contentView!))

        app.terminate(nil)
        await awaitUIUpdate("Quit reaches the application delegate") { probe.requests > 0 }
        XCTAssertEqual(probe.requests, 1)
        XCTAssertTrue(state.removedTitles.isEmpty)
    }

    private func button(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.compactMap { button(title, in: $0) }.first
    }
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
