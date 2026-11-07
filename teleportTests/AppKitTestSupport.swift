import AppKit
import CoreFoundation
import XCTest

/// Evaluate after AppKit and SwiftUI have processed the current batch of events.
/// The timeout is a failure bound, never an assumed layout/animation duration.
@MainActor
func awaitUIUpdate(
    _ description: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    until condition: @escaping @MainActor () -> Bool = { true }
) async {
    let observed = XCTestExpectation(description: description)
    var completed = false
    let observer = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max
    ) { _, _ in
        MainActor.assumeIsolated {
            guard !completed, condition() else { return }
            completed = true
            observed.fulfill()
        }
    }!
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    CFRunLoopWakeUp(CFRunLoopGetMain())
    let result = await XCTWaiter.fulfillment(of: [observed], timeout: timeout)
    XCTAssertEqual(result, .completed, description, file: file, line: line)
}

@MainActor
final class AppKitWaitTests: XCTestCase {
    func testObservesDeferredWindowPresentationAndDismissal() async {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        DispatchQueue.main.async { window.orderFront(nil) }
        await awaitUIUpdate("Window becomes visible") { window.isVisible }
        DispatchQueue.main.async { window.orderOut(nil) }
        await awaitUIUpdate("Window finishes dismissal") { !window.isVisible }
    }
}
