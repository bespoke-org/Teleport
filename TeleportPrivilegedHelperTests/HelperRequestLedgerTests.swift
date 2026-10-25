import Foundation
import XCTest

private final class MutableTestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

final class HelperRequestLedgerTests: XCTestCase {
    func testLookupLifecycleAndConflicts() throws {
        let clock = MutableTestClock(now: Date(timeIntervalSince1970: 1_000))
        var ledger = HelperRequestLedger(maximumEntries: 2, maximumAge: 600, now: { clock.now })
        let requestID = UUID()
        let fingerprint = HelperRequestFingerprint(command: .startSession, payload: Data("a".utf8))
        let conflictingFingerprint = HelperRequestFingerprint(command: .startSession, payload: Data("b".utf8))
        let conflictingCommandFingerprint = HelperRequestFingerprint(command: .stopSession, payload: Data("a".utf8))
        let responseData = Data("response".utf8)

        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: fingerprint) == .unknown)
        try ledger.begin(requestID: requestID, fingerprint: fingerprint)
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: fingerprint) == .inProgress)
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: conflictingFingerprint) == .conflict)
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: conflictingCommandFingerprint) == .conflict)

        ledger.complete(requestID: requestID, fingerprint: fingerprint, responseData: responseData)
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: fingerprint) == .completed(responseData))
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: conflictingFingerprint) == .conflict)
    }

    func testCountEvictsOldestCompletedEntry() throws {
        let clock = MutableTestClock(now: Date(timeIntervalSince1970: 1_000))
        var ledger = HelperRequestLedger(maximumEntries: 2, maximumAge: 600, now: { clock.now })
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let first = HelperRequestFingerprint(command: .status, payload: Data("first".utf8))
        let second = HelperRequestFingerprint(command: .status, payload: Data("second".utf8))
        let third = HelperRequestFingerprint(command: .status, payload: Data("third".utf8))

        try ledger.begin(requestID: firstID, fingerprint: first)
        ledger.complete(requestID: firstID, fingerprint: first, responseData: Data("one".utf8))
        clock.now.addTimeInterval(1)
        try ledger.begin(requestID: secondID, fingerprint: second)
        ledger.complete(requestID: secondID, fingerprint: second, responseData: Data("two".utf8))
        clock.now.addTimeInterval(1)
        try ledger.begin(requestID: thirdID, fingerprint: third)
        ledger.complete(requestID: thirdID, fingerprint: third, responseData: Data("three".utf8))

        XCTAssert(ledger.lookup(requestID: firstID, fingerprint: first) == .unknown)
        XCTAssert(ledger.lookup(requestID: secondID, fingerprint: second) == .completed(Data("two".utf8)))
        XCTAssert(ledger.lookup(requestID: thirdID, fingerprint: third) == .completed(Data("three".utf8)))
    }

    func testAgeEvictsExpiredEntries() throws {
        let clock = MutableTestClock(now: Date(timeIntervalSince1970: 1_000))
        var ledger = HelperRequestLedger(maximumEntries: 2, maximumAge: 600, now: { clock.now })
        let requestID = UUID()
        let fingerprint = HelperRequestFingerprint(command: .readDiagnostics, payload: Data("old".utf8))

        try ledger.begin(requestID: requestID, fingerprint: fingerprint)
        ledger.complete(requestID: requestID, fingerprint: fingerprint, responseData: Data("result".utf8))
        clock.now.addTimeInterval(601)

        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: fingerprint) == .unknown)
    }

    func testInProgressEntriesAgeOnlyAfterCompletion() throws {
        let clock = MutableTestClock(now: Date(timeIntervalSince1970: 1_000))
        var ledger = HelperRequestLedger(maximumEntries: 2, maximumAge: 600, now: { clock.now })
        let requestID = UUID()
        let fingerprint = HelperRequestFingerprint(command: .startSession, payload: Data("slow".utf8))
        let conflict = HelperRequestFingerprint(command: .startSession, payload: Data("different".utf8))
        let response = Data("result".utf8)

        try ledger.begin(requestID: requestID, fingerprint: fingerprint)
        clock.now.addTimeInterval(601)
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: fingerprint) == .inProgress)
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: conflict) == .conflict)

        ledger.complete(requestID: requestID, fingerprint: fingerprint, responseData: response)
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: fingerprint) == .completed(response))
        clock.now.addTimeInterval(600)
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: fingerprint) == .completed(response))
        clock.now.addTimeInterval(1)
        XCTAssert(ledger.lookup(requestID: requestID, fingerprint: fingerprint) == .unknown)
    }

    func testCapacityPreservesInProgressEntries() throws {
        let clock = MutableTestClock(now: Date(timeIntervalSince1970: 1_000))
        var ledger = HelperRequestLedger(maximumEntries: 2, maximumAge: 600, now: { clock.now })
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let first = HelperRequestFingerprint(command: .startSession, payload: Data("first".utf8))
        let second = HelperRequestFingerprint(command: .stopSession, payload: Data("second".utf8))
        let third = HelperRequestFingerprint(command: .status, payload: Data("third".utf8))

        try ledger.begin(requestID: firstID, fingerprint: first)
        try ledger.begin(requestID: secondID, fingerprint: second)

        do {
            try ledger.begin(requestID: thirdID, fingerprint: third)
            XCTFail("A full ledger containing only in-progress requests must reject new work")
        } catch HelperRequestLedgerError.capacityExceeded {
            // Expected: active entries cannot be evicted to admit another request.
        }

        XCTAssert(ledger.lookup(requestID: firstID, fingerprint: first) == .inProgress)
        XCTAssert(ledger.lookup(requestID: secondID, fingerprint: second) == .inProgress)
        XCTAssert(ledger.lookup(requestID: thirdID, fingerprint: third) == .unknown)
    }
}
