import Combine
import Foundation
import XCTest

@MainActor
final class ActiveSubscriptionGeodataTests: XCTestCase {
    func testManualRefreshResultAfterConnectImportsInheritedProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        fixture.provider.publishConnected()
        await waitUntil { fixture.model.isConnected }
        let payload = try JSONSerialization.data(withJSONObject: [
            "Name": "Subscription rules", "ProxySites": ["example.com"],
            "Geositeurl": "https://data.example/geosite.dat", "Geoipurl": "https://data.example/geoip.dat"
        ]).base64EncodedString()
        await fixture.client.succeed(header: "happ://routing/onadd/" + payload)
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        let imported = try XCTUnwrap(fixture.model.providerTunnelProfile(for: fixture.sourceID))
        XCTAssertEqual(imported.rules.count, 1)
        XCTAssertEqual(imported.geodataSources?.geositeURLString, "https://data.example/geosite.dat")
        XCTAssertEqual(imported.geodataSources?.geoipURLString, "https://data.example/geoip.dat")
        XCTAssertNil(fixture.model.lastError)
        XCTAssertTrue(fixture.model.isConnected)
        XCTAssertEqual(fixture.provider.connectCount, 0)
        XCTAssertEqual(fixture.provider.disconnectCount, 0)
    }

    func testRefreshRetainsRemovedActivePortalUntilDisconnectInBothModes() async throws {
        for mode in ConnectionMode.allCases {
            let fixture = try Fixture(connected: true, mode: mode)
            defer { fixture.cleanUp() }
            await waitUntil { fixture.model.isConnected }
            let previous = try XCTUnwrap(fixture.model.selectedConnection)
            fixture.model.refreshSubscription(id: fixture.sourceID)
            await waitUntil { await fixture.client.requestCount == 1 }
            let newLink = ControlledSubscriptionClient.link.replacingOccurrences(of: ":9?", with: ":10?")
            await fixture.client.succeed(link: newLink)
            await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
            var updated = try XCTUnwrap(fixture.model.importedConnections(for: fixture.sourceID).first)
            XCTAssertNotEqual(updated.id, previous.id)
            XCTAssertEqual(updated.configuration.port, 10)
            fixture.model.refreshSubscription(id: fixture.sourceID)
            await waitUntil { await fixture.client.requestCount == 2 }
            await fixture.client.succeed(link: newLink.replacingOccurrences(of: ":10?", with: ":11?"))
            await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
            updated = try XCTUnwrap(fixture.model.importedConnections(for: fixture.sourceID).first)
            XCTAssertEqual(updated.configuration.port, 11)
            XCTAssertEqual(fixture.model.selectedConnectionID, previous.id)
            XCTAssertEqual(fixture.model.selectedConfiguration, previous.configuration)
            XCTAssertTrue(fixture.model.isConnected)
            XCTAssertEqual(fixture.provider.connectCount, 0)
            XCTAssertEqual(fixture.provider.disconnectCount, 0)
            await waitUntil { fixture.store.load().selectedConnectionID == updated.id }
            let persisted = fixture.store.load()
            XCTAssertEqual(persisted.selectedConnectionID, updated.id)
            XCTAssertFalse(persisted.savedConnections.contains { $0.id == previous.id })
            fixture.provider.publishIdle()
            await waitUntil { fixture.model.canConnect }
            XCTAssertEqual(fixture.model.selectedConnectionID, updated.id)
            XCTAssertEqual(fixture.model.selectedConfiguration, updated.configuration)
        }
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for subscription refresh", file: file, line: line)
    }
}

@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-refresh-\(UUID())")
    let sourceID = UUID()
    let client = ControlledSubscriptionClient()
    let provider: SubscriptionTestProvider
    let model: AppViewModel
    let store: ConfigurationStore

    init(connected: Bool = false, unfetched: Bool = false, activeSource: Bool = true, mode: ConnectionMode = .tun, inherited: Bool = false) throws {
        let manager = SubscriptionTestFileManager(root: root)
        let log = TeleportLog(directoryURL: root, fileName: "test.log")
        store = ConfigurationStore(fileManager: manager, keychainService: "dev.x.teleport.subscription-test-\(UUID())",
                                   keychainAccount: "snapshot", log: log)
        let configuration = try ConnectionLinkParser().parse(ControlledSubscriptionClient.link)
        let connection = SavedConnection(
            id: UUID(), configuration: configuration, savedAt: Date(),
            source: activeSource ? .init(subscriptionSourceID: sourceID, subscriptionEntryID: configuration.duplicateFilterIdentity) : nil,
            healthCheck: .init(state: .reachable, checkedAt: Date(), latencyMilliseconds: 1,
                               latencyKind: .tcpConnect, failureSummary: nil)
        )
        let source = SubscriptionSource(
            id: sourceID, urlString: "https://subscription.example/test", title: "Test",
            savedAt: .distantPast, autoUpdateIntervalMinutes: 1,
            lastRefreshedAt: unfetched ? nil : .distantPast
        )
        let profiles = inherited ? [SplitTunnelProfile(name: "Original rules", rules: [
            SplitTunnelRule(value: "original.example", kind: .domain, action: .proxy)
        ], subscriptionSourceID: sourceID)] : []
        try store.save(AppSnapshot(savedConnections: [connection], subscriptionSources: [source],
                                   selectedConnectionID: connection.id, proxyEndpoint: .default, connectionMode: mode,
                                   splitTunnelProfiles: profiles, selectedSplitTunnelProfileID: profiles.first?.id,
                                   isSplitTunnelEnabled: true, tunnelAssignments: inherited ? [] : nil))
        provider = SubscriptionTestProvider(connected: connected)
        let provider = self.provider
        model = AppViewModel(parser: ConnectionLinkParser(), store: store,
                             connectionProviderFactory: .init(systemProxyProvider: { provider }, tunProvider: { provider }),
                             leakGuard: LeakGuardService(isEnabled: false, log: log), subscriptionClient: SubscriptionClient(loadResponse: { [client] _ in try await client.fetch() }),
                             healthProbeService: ConnectionHealthProbeService(),
                             systemProxyService: SystemProxyService(fileManager: manager, log: log),
                             geodataUpdateCoordinator: GeodataUpdateCoordinator(service: SubscriptionCacheService()), log: log)
    }

    func cleanUp() {
        model.handleAppTermination {}
        store.deleteStoredDataForTesting()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SubscriptionTestFileManager: FileManager {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

private actor ControlledSubscriptionClient {
    static let link = "vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:9?security=none&type=tcp#Test"
    private(set) var requestCount = 0
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    func fetch() async throws -> (Data, URLResponse) {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func succeed(link: String = ControlledSubscriptionClient.link, header: String? = nil) {
        let response = HTTPURLResponse(url: URL(string: "https://subscription.example/test")!,
                                       statusCode: 200, httpVersion: nil, headerFields: header.map { ["routing": $0] })!
        continuation?.resume(returning: (Data(link.utf8), response))
        continuation = nil
    }
    func fail() {
        continuation?.resume(throwing: SubscriptionError.networkFailure("Test download failed"))
        continuation = nil
    }
}

private final class SubscriptionTestProvider: ConnectionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ConnectionState
    private var request: ConnectionRequest?
    var lastRequest: ConnectionRequest? { lock.withLock { request } }
    private var connects = 0
    private var disconnects = 0
    var connectCount: Int { lock.withLock { connects } }
    var disconnectCount: Int { lock.withLock { disconnects } }
    private let updates = AsyncStream<ConnectionState>.makeStream()
    init(connected: Bool) {
        state = connected ? .connected(.init(id: UUID(), mode: .tun, connectedAt: Date())) : .idle
    }
    func currentState() async -> ConnectionState { lock.withLock { state } }
    func stateUpdates() -> AsyncStream<ConnectionState> {
        updates.continuation.yield(lock.withLock { state })
        return updates.stream
    }
    func publishConnected() { publish(.connected(.init(id: UUID(), mode: .tun, connectedAt: Date()))) }
    func publishIdle() { publish(.idle) }
    private func publish(_ value: ConnectionState) {
        lock.withLock { state = value }
        updates.continuation.yield(value)
    }
    func connect(_ request: ConnectionRequest) async throws {
        lock.withLock { connects += 1; self.request = request }
        publishConnected()
    }
    func disconnect() async throws {
        lock.withLock { disconnects += 1 }
        publishIdle()
    }
}

private struct SubscriptionCacheService: GeodataUpdateServicing {
    func cacheCurrentDownload(for kind: GeodataKind, source: URL?, updatedAt: Date?) throws {}
    func prepareUpdate(kind: GeodataKind, from source: URL, useCache: Bool) async throws -> GeodataUpdateService.PreparedUpdate {
        .init(stagedURL: URL(fileURLWithPath: "/unused"), updatedAt: Date(), changed: true)
    }
    func activate(_ update: GeodataUpdateService.PreparedUpdate, for kind: GeodataKind) throws {
        XCTFail("An active subscription refresh must cache without activating geodata")
    }
    func discard(_ update: GeodataUpdateService.PreparedUpdate) {}
    func hasCustomGeodata(for kind: GeodataKind) -> Bool { false }
    func removeCustomGeodata(for kind: GeodataKind) throws {}
}
