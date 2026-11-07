import AppKit
import SwiftUI
import XCTest

@MainActor
final class SettingsErrorPresentationTests: XCTestCase {
    func testActionFailureDoesNotReplaceOrDuplicateConnectionFailure() {
        let connection = ConnectionFailure(summary: "Cannot connect", details: "Connection diagnostic")
        XCTAssertNil(SettingsIssue.resolve(message: nil, details: nil, connection: nil))
        let displayedConnection = SettingsIssue.resolve(message: connection.summary, details: connection.details, connection: connection)
        XCTAssertEqual(displayedConnection?.kind, .connection)
        XCTAssertEqual(displayedConnection?.failure, connection)
        let action = SettingsIssue.resolve(message: "Invalid portal", details: "Parse diagnostic", connection: connection)
        XCTAssertEqual(action?.kind, .action)
        XCTAssertEqual(action?.failure.details, "Parse diagnostic")
        XCTAssertEqual(SettingsIssue.resolve(message: nil, details: nil, connection: connection), displayedConnection)
        XCTAssertEqual(SettingsIssue.resolve(message: connection.summary, details: "Different diagnostic", connection: connection)?.kind, .action)
    }

    func testDetailsCloseWithoutAcknowledgingAndDismissLatestFailure() async throws {
        _ = NSApplication.shared
        let model = ErrorFixtureModel()
        let host = NSHostingController(rootView: ErrorFixture(model: model))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.makeKeyAndOrderFront(nil)
        await awaitUIUpdate("Error indicator is presented") { window.isVisible && host.view.window != nil }
        let existing = Set(NSApp.windows.map(\.windowNumber))
        try click(in: window)
        await awaitUIUpdate("Error details finish layout") {
            NSApp.windows.contains { !existing.contains($0.windowNumber) && $0.isVisible && $0.frame.height > 100 }
        }
        let popover = try XCTUnwrap(NSApp.windows.first { !existing.contains($0.windowNumber) && $0.isVisible })
        XCTAssertGreaterThan(popover.frame.height, 100)
        XCTAssertLessThan(popover.frame.height, 300, "Short errors must not leave a large empty panel")
        try key("\u{1b}", code: 53, in: popover)
        await awaitUIUpdate("Escape closes error details") { !popover.isVisible }
        XCTAssertFalse(popover.isVisible)
        XCTAssertNotNil(model.issue, "Closing details must keep the error discoverable")
        XCTAssertTrue(model.dismissed.isEmpty)

        window.makeKeyAndOrderFront(nil)
        try click(in: window)
        await awaitUIUpdate("Error details reopen") {
            NSApp.windows.contains { !existing.contains($0.windowNumber) && $0.isVisible && $0.frame.height > 100 }
        }
        model.issue = SettingsIssue(kind: .action, failure: ConnectionFailure(summary: "New failure", details: "Fresh details"))
        await awaitUIUpdate("Updated error details are rendered") {
            NSApp.windows.contains {
                !existing.contains($0.windowNumber) && $0.isVisible && self.containsText("New failure", in: $0)
            }
        }
        let latest = try XCTUnwrap(NSApp.windows.first {
            !existing.contains($0.windowNumber) && $0.isVisible && containsText("New failure", in: $0)
        })
        // The footer is fixed within the popover: Dismiss is its trailing button.
        try click(in: latest, at: NSPoint(x: latest.frame.width - 55, y: 38))
        await awaitUIUpdate("Dismiss acknowledges the new error and closes details") { model.issue == nil && !latest.isVisible }
        XCTAssertEqual(model.dismissed.map(\.failure.summary), ["New failure"])
        XCTAssertNil(model.issue)
        XCTAssertFalse(latest.isVisible)
    }

    private func containsText(_ text: String, in element: Any) -> Bool {
        guard let accessible = element as? NSAccessibilityProtocol else { return false }
        if accessible.accessibilityValue() as? String == text || accessible.accessibilityLabel() == text {
            return true
        }
        return (accessible.accessibilityChildren() ?? []).contains { containsText(text, in: $0) }
    }

    private func click(in window: NSWindow, at point: NSPoint = NSPoint(x: 180, y: 80)) throws {
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        window.sendEvent(try event(.leftMouseDown))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(up) }
    }

    private func key(_ text: String, code: UInt16, in window: NSWindow) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text,
            isARepeat: false, keyCode: code)))
    }
}

@MainActor
private final class ErrorFixtureModel: ObservableObject {
    @Published var issue: SettingsIssue? = SettingsIssue(kind: .connection, failure: ConnectionFailure(summary: "Cannot connect", details: "Diagnostic"))
    var dismissed: [SettingsIssue] = []
}

private struct ErrorFixture: View {
    @ObservedObject var model: ErrorFixtureModel
    var body: some View {
        SettingsErrorControl(issue: model.issue, onDismiss: { model.dismissed.append($0); model.issue = nil }, onOpenLogs: {})
            .frame(width: 360, height: 160)
    }
}
