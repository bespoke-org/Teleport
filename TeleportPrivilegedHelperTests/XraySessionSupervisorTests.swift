import Foundation
import XCTest

/// Only children launched by this fixture. No helper installation or real Xray.
final class XraySessionSupervisorTests: XCTestCase {
    func testRewatchOfSamePIDDoesNotDeliverCancelledWatch() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let supervisor = XraySessionSupervisor()
        let obsolete = expectation(description: "cancelled callback")
        obsolete.isInverted = true
        let exit = expectation(description: "current callback")
        exit.assertForOverFulfill = true
        supervisor.watch(pid: child.processIdentifier) { _ in obsolete.fulfill() }
        supervisor.cancel()
        supervisor.watch(pid: child.processIdentifier) { pid in
            XCTAssertEqual(pid, child.processIdentifier)
            exit.fulfill()
        }
        child.terminate()
        wait(for: [exit], timeout: 10)
        XCTAssertNil(supervisor.watchedProcessID)
        supervisor.cancel()
        // The positive current-watch delivery is the barrier, not a sleep-based
        // race attempt; the inverted expectation is checked at that barrier.
        wait(for: [obsolete], timeout: 0)
    }

    func testAlreadyReapedChildDeliversExactlyOnce() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        let supervisor = XraySessionSupervisor()
        let exit = expectation(description: "reaped child fallback")
        exit.assertForOverFulfill = true
        supervisor.watch(pid: child.processIdentifier) { _ in exit.fulfill() }
        wait(for: [exit], timeout: 10)
        XCTAssertNil(supervisor.watchedProcessID)
        supervisor.cancel()
    }
}
