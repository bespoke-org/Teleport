import Foundation
import XCTest

private final class SessionTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<Result>(_ operation: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return operation(&value)
    }
    var current: Value { withValue { $0 } }
}

private enum SessionTestFailure: Error { case injected }

/// No subprocesses, file IO, system networking or sleeps. Each effect can be
/// parked after entering, so another request/event can be delivered precisely.
private final class SessionTestEffects: @unchecked Sendable {
    struct State {
        var events: [String] = []
        var active = 0
        var maxActive = 0
        var failAt: String?
    }
    let state = SessionTestBox(State())
    func effect(_ name: String, entered: DispatchSemaphore? = nil, release: DispatchSemaphore? = nil) throws {
        let fail = state.withValue {
            $0.active += 1
            $0.maxActive = max($0.maxActive, $0.active)
            $0.events.append(name)
            return $0.failAt == name
        }
        defer { state.withValue { $0.active -= 1 } }
        entered?.signal()
        if let release, release.wait(timeout: .now() + 10) != .success { throw SessionTestFailure.injected }
        if fail { throw SessionTestFailure.injected }
    }
    func cleanup(_ name: String, entered: DispatchSemaphore? = nil,
                 release: DispatchSemaphore? = nil) -> HelperTUNSessionExecutor.Cleanup {
        .init(tunnelInterfaceName: "utun8", outboundInterface: "en0") {
            try self.effect(name, entered: entered, release: release)
        }
    }
}

final class HelperTUNSessionExecutorTests: XCTestCase {
    func testHappyPathAndRepeatedStop() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        let session = UUID()
        XCTAssertNil(owner.snapshot)
        try owner.start(sessionID: session, cleanup: effects.cleanup("cleanup A")) { token in
            XCTAssertEqual(token.sessionID, session)
            XCTAssertEqual(owner.snapshot?.phase, .starting)
            for stage in ["terminate managed", "terminate legacy", "config", "script", "watch"] {
                try effects.effect(stage)
            }
            return 41
        }
        XCTAssertEqual(owner.snapshot?.phase, .running)
        XCTAssertEqual(owner.snapshot?.pid, 41)
        try owner.stop(sessionID: session, fallback: effects.cleanup("unused fallback"))
        try owner.stop(sessionID: session, fallback: effects.cleanup("unused fallback"))
        XCTAssertEqual(owner.snapshot?.phase, .idle)
        XCTAssertNil(owner.snapshot?.token)
        XCTAssertEqual(effects.state.current.events, ["terminate managed", "terminate legacy", "config", "script", "watch", "cleanup A"])
        XCTAssertEqual(effects.state.current.maxActive, 1)
    }

    func testStaleExitBeforeAndAfterReplacementWithSessionAndPIDReuse() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        let id = UUID()
        try owner.start(sessionID: id, cleanup: effects.cleanup("cleanup A")) { _ in 41 }
        let old = try XCTUnwrap(owner.snapshot?.token)
        owner.unexpectedExit(token: old, pid: 41)
        owner.waitForPendingEvents()
        XCTAssertEqual(owner.snapshot?.phase, .idle)
        try owner.start(sessionID: id, cleanup: effects.cleanup("cleanup B")) { _ in 41 }
        let current = owner.snapshot
        XCTAssertNotEqual(current?.token, old)
        owner.unexpectedExit(token: old, pid: 41)
        owner.waitForPendingEvents()
        XCTAssertEqual(owner.snapshot, current)
        XCTAssertEqual(effects.state.current.events, ["cleanup A"])
    }

    func testStaleExitDeliveredWhileNewStartIsBlocked() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        let id = UUID()
        try owner.start(sessionID: id, cleanup: effects.cleanup("cleanup A")) { _ in 41 }
        let old = try XCTUnwrap(owner.snapshot?.token)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let errors = SessionTestBox(0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                try owner.start(sessionID: id, cleanup: effects.cleanup("cleanup B")) { _ in
                    try effects.effect("start B", entered: entered, release: release)
                    return 41
                }
            } catch { errors.withValue { $0 += 1 } }
        }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(owner.snapshot?.phase, .starting) // no sync IO-queue wait
        owner.unexpectedExit(token: old, pid: 41)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        owner.waitForPendingEvents()
        XCTAssertEqual(errors.current, 0)
        XCTAssertEqual(owner.snapshot?.phase, .running)
        XCTAssertEqual(effects.state.current.events, ["cleanup A", "start B"])
        XCTAssertEqual(effects.state.current.maxActive, 1)
    }

    func testCleanupAlreadyRunningSerializesNewStartAndSnapshotDoesNotBlock() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let requested = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let errors = SessionTestBox(0)
        try owner.start(sessionID: UUID(), cleanup: effects.cleanup("cleanup A", entered: entered, release: release)) { _ in 41 }
        let old = try XCTUnwrap(owner.snapshot?.token)
        owner.unexpectedExit(token: old, pid: 41)
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        defer { release.signal() }
        DispatchQueue.global().async {
            requested.signal()
            defer { done.signal() }
            do {
                try owner.start(sessionID: UUID(), cleanup: effects.cleanup("cleanup B")) { _ in
                    try effects.effect("start B")
                    return 42
                }
            } catch { errors.withValue { $0 += 1 } }
        }
        XCTAssertEqual(requested.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(owner.snapshot?.phase, .stopping)
        XCTAssertEqual(effects.state.current.events, ["cleanup A"])
        owner.unexpectedExit(token: old, pid: 41)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        owner.waitForPendingEvents()
        XCTAssertEqual(errors.current, 0)
        XCTAssertEqual(effects.state.current.events, ["cleanup A", "start B"])
        XCTAssertEqual(effects.state.current.maxActive, 1)
        XCTAssertEqual(owner.snapshot?.pid, 42)
    }

    func testManualStopRacingExitHasOneTeardown() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let id = UUID(), errors = SessionTestBox(0)
        try owner.start(sessionID: id, cleanup: effects.cleanup("cleanup", entered: entered, release: release)) { _ in 41 }
        let token = try XCTUnwrap(owner.snapshot?.token)
        DispatchQueue.global().async {
            defer { done.signal() }
            do { try owner.stop(sessionID: id, fallback: effects.cleanup("unused")) }
            catch { errors.withValue { $0 += 1 } }
        }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        owner.unexpectedExit(token: token, pid: 41)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        owner.waitForPendingEvents()
        XCTAssertEqual(errors.current, 0)
        XCTAssertEqual(effects.state.current.events, ["cleanup"])
        XCTAssertEqual(effects.state.current.maxActive, 1)
        XCTAssertEqual(owner.snapshot?.phase, .idle)
    }

    func testExitDuringStartAndDuplicateIngress() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        try owner.start(sessionID: UUID(), cleanup: effects.cleanup("cleanup")) { token in
            owner.unexpectedExit(token: token, pid: 41)
            owner.unexpectedExit(token: token, pid: 41)
            XCTAssertEqual(owner.snapshot?.phase, .starting)
            return 41
        }
        owner.waitForPendingEvents()
        XCTAssertEqual(effects.state.current.events, ["cleanup"])
        XCTAssertEqual(owner.snapshot?.phase, .idle)
    }

    func testMismatchedPIDAndUnknownGenerationDoNothing() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        let id = UUID()
        try owner.start(sessionID: id, cleanup: effects.cleanup("cleanup")) { _ in 41 }
        let current = try XCTUnwrap(owner.snapshot)
        owner.unexpectedExit(token: try XCTUnwrap(current.token), pid: 42)
        owner.waitForPendingEvents()
        owner.unexpectedExit(token: .init(sessionID: id, generation: UUID()), pid: 41)
        owner.waitForPendingEvents()
        XCTAssertEqual(owner.snapshot, current)
        XCTAssertTrue(effects.state.current.events.isEmpty)
    }

    func testStartRollsBackOnlyAfterPreparation() throws {
        let stages = ["prepare", "terminate managed", "terminate legacy", "config", "script", "watch"]
        for failed in stages {
            let owner = HelperTUNSessionExecutor()
            let effects = SessionTestEffects()
            effects.state.withValue { $0.failAt = failed }
            let id = UUID()
            XCTAssertThrowsError(try owner.start(sessionID: id, cleanup: effects.cleanup("cleanup"), prepare: {
                for stage in stages.prefix(4) { try effects.effect(stage) }
            }) { _ in
                for stage in stages.suffix(2) { try effects.effect(stage) }
                return 41
            })
            try owner.stop(sessionID: id, fallback: nil) // No previous root-owned state.
            XCTAssertEqual(owner.snapshot?.phase ?? .idle, .idle, failed)
            XCTAssertEqual(effects.state.current.events.filter { $0 == "cleanup" }.count,
                           stages.suffix(2).contains(failed) ? 1 : 0, failed)
            XCTAssertEqual(effects.state.current.maxActive, 1)
        }
    }

    func testEveryCleanupStageFailureRetainsContextBlocksNewMutationsAndStopRetries() throws {
        let stages = ["cancel", "prepare", "terminate managed", "terminate legacy", "stop script"]
        for failed in stages {
            let owner = HelperTUNSessionExecutor()
            let effects = SessionTestEffects()
            let id = UUID()
            let cleanup = HelperTUNSessionExecutor.Cleanup(tunnelInterfaceName: "utun8", outboundInterface: "en0") {
                for stage in stages { try effects.effect(stage) }
            }
            try owner.start(sessionID: id, cleanup: cleanup) { _ in 41 }
            let token = owner.snapshot?.token
            effects.state.withValue { $0.failAt = failed }
            XCTAssertThrowsError(try owner.stop(sessionID: id, fallback: effects.cleanup("unused")))
            XCTAssertEqual(owner.snapshot?.phase, .cleanupFailed)
            XCTAssertEqual(owner.snapshot?.token, token)
            XCTAssertEqual(owner.snapshot?.outboundInterface, "en0")
            XCTAssertThrowsError(try owner.start(sessionID: UUID(), cleanup: effects.cleanup("new cleanup")) { _ in
                try effects.effect("NEW CONFIG MUST NOT RUN")
                return 42
            })
            XCTAssertEqual(owner.snapshot?.token, token)
            XCTAssertFalse(effects.state.current.events.contains("NEW CONFIG MUST NOT RUN"))
            effects.state.withValue { $0.failAt = nil }
            try owner.stop(sessionID: id, fallback: effects.cleanup("unused"))
            XCTAssertEqual(owner.snapshot?.phase, .idle)
            XCTAssertFalse(effects.state.current.events.contains("unused"))
            XCTAssertEqual(effects.state.current.maxActive, 1)
        }
    }

    func testFailedStartAndFailedRollbackRetainOriginalContext() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        effects.state.withValue { $0.failAt = "cleanup" }
        let token = SessionTestBox<HelperTUNSessionExecutor.RunToken?>(nil)
        XCTAssertThrowsError(try owner.start(sessionID: UUID(), cleanup: effects.cleanup("cleanup")) { current in
            token.withValue { $0 = current }
            owner.unexpectedExit(token: current, pid: 41)
            throw SessionTestFailure.injected
        })
        owner.waitForPendingEvents()
        XCTAssertEqual(owner.snapshot?.phase, .cleanupFailed)
        XCTAssertEqual(owner.snapshot?.token, token.current)
        XCTAssertEqual(effects.state.current.events, ["cleanup"])
        effects.state.withValue { $0.failAt = nil }
        try owner.stop(sessionID: UUID(), fallback: effects.cleanup("unused"))
        XCTAssertEqual(owner.snapshot?.phase, .idle)
    }

    func testUnexpectedExitCleanupFailureIsVisibleAndRetryable() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        try owner.start(sessionID: UUID(), cleanup: effects.cleanup("cleanup")) { _ in 41 }
        let token = try XCTUnwrap(owner.snapshot?.token)
        effects.state.withValue { $0.failAt = "cleanup" }
        owner.unexpectedExit(token: token, pid: 41)
        owner.waitForPendingEvents()
        XCTAssertEqual(owner.snapshot?.phase, .cleanupFailed)
        XCTAssertEqual(owner.snapshot?.token, token)
        effects.state.withValue { $0.failAt = nil }
        try owner.stop(sessionID: token.sessionID, fallback: effects.cleanup("unused"))
        XCTAssertEqual(effects.state.current.events, ["cleanup", "cleanup"])
        XCTAssertEqual(owner.snapshot?.phase, .idle)
    }

    func testHelperRestartFallbackAndRetryUseOriginalInputs() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        effects.state.withValue { $0.failAt = "persisted cleanup" }
        XCTAssertThrowsError(try owner.stop(sessionID: UUID(), fallback: effects.cleanup("persisted cleanup")))
        XCTAssertEqual(owner.snapshot?.phase, .cleanupFailed)
        effects.state.withValue { $0.failAt = nil }
        try owner.stop(sessionID: UUID(), fallback: effects.cleanup("wrong new inputs"))
        XCTAssertEqual(effects.state.current.events, ["persisted cleanup", "persisted cleanup"])
        XCTAssertEqual(owner.snapshot?.phase, .idle)
    }

    func testNilPIDPreservesSuccessfulStartWithoutInventingWatchEvidence() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        try owner.start(sessionID: UUID(), cleanup: effects.cleanup("cleanup")) { _ in nil }
        XCTAssertEqual(owner.snapshot?.phase, .running)
        XCTAssertNil(owner.snapshot?.pid)
        try owner.stop(sessionID: UUID(), fallback: effects.cleanup("unused"))
        XCTAssertEqual(effects.state.current.events, ["cleanup"])
    }

    #if canImport(Darwin)
    func testStagingFailurePreservesPublishedConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let active = root.appendingPathComponent("xray-tun-config.json")
        try Data("old".utf8).write(to: active)
        let staged = active.appendingPathExtension("pending")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
        XCTAssertThrowsError(try XrayTunController.stageConfig(Data("new".utf8), at: staged))
        XCTAssertEqual(try Data(contentsOf: active), Data("old".utf8))
    }

    func testFacadeAndDispatcherReadSnapshotWhileEffectsAreBlocked() async throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        let controller = XrayTunController(sessionExecutor: owner)
        let dispatcher = HelperCommandDispatcher(executor: controller)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0), errors = SessionTestBox(0)
        DispatchQueue.global().async {
            defer { done.signal() }
            do {
                try owner.start(sessionID: UUID(), cleanup: effects.cleanup("cleanup")) { _ in
                    try effects.effect("start", entered: entered, release: release)
                    return 41
                }
            } catch { errors.withValue { $0 += 1 } }
        }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(try controller.status(request: StatusRequest()).phase, .starting)
        let request = TUNHelperRequestEnvelope(revision: TUNHelperProtocol.revision,
            requestID: UUID(), sessionID: nil, payload: StatusRequest())
        let data = try TUNHelperCodec.encodeRequest(request)
        let result = await dispatcher.dispatch(command: .status, requestData: data)
        let response: TUNHelperResponseEnvelope<StatusResponse> = try TUNHelperCodec.decodeResponse(result)
        XCTAssertEqual(response.payload?.phase, .starting)
        let replay = await dispatcher.dispatch(command: .status, requestData: data)
        XCTAssertEqual(result, replay)
        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(errors.current, 0)
    }

    func testFacadeReportsCleanupFailureAndRetryWithoutDiskFallback() throws {
        let owner = HelperTUNSessionExecutor()
        let effects = SessionTestEffects()
        let controller = XrayTunController(sessionExecutor: owner)
        let session = UUID()
        try owner.start(sessionID: session, cleanup: effects.cleanup("cleanup")) { _ in 41 }
        XCTAssertEqual(try controller.status(request: StatusRequest()).phase, .running)
        effects.state.withValue { $0.failAt = "cleanup" }
        XCTAssertThrowsError(try owner.stop(sessionID: session, fallback: effects.cleanup("unused")))
        let failed = try controller.status(request: StatusRequest())
        XCTAssertEqual(failed.phase, .failed)
        XCTAssertNotNil(failed.summary)
        XCTAssertEqual(failed.tunnelInterfaceName, "utun8")
        effects.state.withValue { $0.failAt = nil }
        try owner.stop(sessionID: session, fallback: effects.cleanup("unused"))
        let idle = try controller.status(request: StatusRequest())
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertNil(idle.tunnelInterfaceName)
        XCTAssertNil(idle.summary)
    }
    #endif
}
