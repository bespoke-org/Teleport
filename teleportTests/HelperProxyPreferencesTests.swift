import Foundation
import Synchronization
import XCTest

final class HelperProxyPreferencesTests: XCTestCase {
    func testRepeatedTransactionsAndRecoveryUseHelperCommands() throws {
        let transport = ProxyTransport()
        let installs = Mutex(0)
        let preferences = HelperProxyPreferences(client: PrivilegedHelperClient(transport: transport), ensureInstalled: {
            installs.withLock { $0 += 1 }
        })
        for value in [1, 0, 1, 0] {
            try preferences.transaction { _, apply in
                try apply([ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(value)])])
            }
        }
        XCTAssertEqual(transport.commands, Array(repeating: [.readProxyPreferences, .applyProxyPreferences], count: 4).flatMap { $0 })
        XCTAssertEqual(transport.inventory.services["wifi"]?.values["HTTPEnable"], .number(0))
        // Each transaction checks installation, whose manifest/status fast path
        // skips approval for the same build. No network authorization is involved.
        XCTAssertEqual(installs.withLock { $0 }, 4)
    }

    func testRejectedCompareRequiresExplicitReconnect() throws {
        let transport = ProxyTransport(rejectWrite: true)
        let preferences = HelperProxyPreferences(client: PrivilegedHelperClient(transport: transport), ensureInstalled: {})
        XCTAssertThrowsError(try preferences.transaction { _, apply in
            try apply([ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(1)])])
        }) { error in
            XCTAssertTrue((error as? ConnectionFailure)?.requiresExplicitReconnect == true)
        }
        XCTAssertEqual(transport.inventory.services["wifi"]?.values["HTTPEnable"], .number(0))
    }

    func testLostWriteReplyIsNotReplayedAndRecoveryReadsHelperFirst() throws {
        let transport = ProxyTransport(loseFirstWriteReply: true)
        let preferences = HelperProxyPreferences(client: PrivilegedHelperClient(transport: transport), ensureInstalled: {})
        XCTAssertThrowsError(try preferences.transaction { _, apply in
            try apply([ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(1)])])
        })
        try preferences.transaction { inventory, apply in
            XCTAssertEqual(inventory.services["wifi"]?.values["HTTPEnable"], .number(1))
            try apply([ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(0)])])
        }
        XCTAssertEqual(transport.commands, [.readProxyPreferences, .applyProxyPreferences, .readProxyPreferences, .applyProxyPreferences])
        XCTAssertEqual(transport.inventory.services["wifi"]?.values["HTTPEnable"], .number(0))
    }

    func testDeniedInstallationDoesNotSendMutationsOrRunJournalBody() throws {
        let transport = ProxyTransport()
        let preferences = HelperProxyPreferences(client: PrivilegedHelperClient(transport: transport), ensureInstalled: {
            throw PrivilegedShellError.commandFailed("User canceled")
        })
        XCTAssertThrowsError(try preferences.transaction { _, _ in XCTFail("Must not start transaction") })
        XCTAssertTrue(transport.commands.isEmpty)
    }

    func testNewProtocolRequiresHelperUpgrade() async throws {
        let transport = ProxyTransport(oldRevision: true)
        do {
            _ = try await PrivilegedHelperClient(transport: transport).readProxyPreferences()
            XCTFail("Expected incompatible helper")
        } catch let error as PrivilegedHelperClientError {
            guard case .incompatibleService = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    private final class ProxyTransport: TUNHelperTransport, @unchecked Sendable {
        private struct State {
            var commands: [TUNHelperCommand] = []
            var transactionID = UUID()
            var inventory = ProxyInventory(locationID: "home", eligibleServiceIDs: ["wifi"], services: [
                "wifi": ProxyServiceConfiguration(id: "wifi", name: "Wi-Fi", values: ["HTTPEnable": .number(0)])])
            var writes = 0
        }
        private let state = Mutex(State())
        private let rejectWrite: Bool
        private let loseFirstWriteReply: Bool
        private let oldRevision: Bool
        var commands: [TUNHelperCommand] { state.withLock { $0.commands } }
        var inventory: ProxyInventory { state.withLock { $0.inventory } }

        init(rejectWrite: Bool = false, loseFirstWriteReply: Bool = false, oldRevision: Bool = false) {
            self.rejectWrite = rejectWrite
            self.loseFirstWriteReply = loseFirstWriteReply
            self.oldRevision = oldRevision
        }

        func send(command: TUNHelperCommand, requestData: Data, timeout: TimeInterval) async throws -> Data {
            try state.withLock { state in
                state.commands.append(command)
                switch command {
                case .readProxyPreferences:
                    let request: TUNHelperRequestEnvelope<ReadProxyPreferencesRequest> = try TUNHelperCodec.decodeRequest(requestData)
                    state.transactionID = UUID()
                    return try JSONEncoder().encode(TUNHelperResponseEnvelope(
                        revision: oldRevision ? TUNHelperProtocol.revision - 1 : TUNHelperProtocol.revision,
                        requestID: request.requestID, sessionID: nil,
                        payload: ProxyPreferencesSnapshot(transactionID: state.transactionID, inventory: state.inventory), failure: nil))
                case .applyProxyPreferences:
                    let request: TUNHelperRequestEnvelope<ApplyProxyPreferencesRequest> = try TUNHelperCodec.decodeRequest(requestData)
                    XCTAssertEqual(request.payload.transactionID, state.transactionID)
                    XCTAssertEqual(request.payload.expected, state.inventory)
                    state.writes += 1
                    if !rejectWrite {
                        for mutation in request.payload.mutations {
                            for (key, value) in mutation.values { state.inventory.services[mutation.serviceID]?.values[key] = value }
                            for key in mutation.removed { state.inventory.services[mutation.serviceID]?.values.removeValue(forKey: key) }
                        }
                    }
                    if loseFirstWriteReply, state.writes == 1 { throw TUNHelperTransportError.interrupted }
                    return try TUNHelperCodec.encodeResponse(TUNHelperResponseEnvelope(
                        revision: TUNHelperProtocol.revision, requestID: request.requestID, sessionID: nil,
                        payload: ApplyProxyPreferencesResponse(applied: !rejectWrite), failure: nil))
                default:
                    XCTFail("Unexpected helper command")
                    throw TUNHelperTransportError.invalidResponse("Unexpected command")
                }
            }
        }
        func invalidate() {}
    }
}
