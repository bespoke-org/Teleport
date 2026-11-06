import Combine
import Foundation
import XCTest

@MainActor
final class AppViewModelSubscriptionRefreshTests: XCTestCase {
    func testScheduledRefreshSkipsActiveSubscriptionWithoutError() async throws {
        let fixture = try Fixture(connected: true)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        let original = fixture.model.savedConnections

        fixture.model.performScheduledSubscriptionRefreshes()
        fixture.model.performScheduledSubscriptionRefreshes()

        XCTAssertNil(fixture.model.lastError)
        XCTAssertNil(fixture.model.subscriptionSources.first?.lastError)
        XCTAssertTrue(fixture.model.refreshingSubscriptionIDs.isEmpty)
        XCTAssertEqual(fixture.model.savedConnections, original)
        let count = await fixture.client.requestCount
        XCTAssertEqual(count, 0)
    }

    func testBackgroundResultArrivingAfterConnectIsDiscardedWithoutErrorAndRetriesLater() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        let original = fixture.model.savedConnections
        let previousRefresh = fixture.model.subscriptionSources.first?.lastRefreshedAt
        fixture.model.performScheduledSubscriptionRefreshes()
        await waitUntil { await fixture.client.requestCount == 1 }

        fixture.provider.publishConnected()
        await waitUntil { fixture.model.isConnected }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }

        XCTAssertNil(fixture.model.lastError)
        XCTAssertNil(fixture.model.subscriptionSources.first?.lastError)
        XCTAssertEqual(fixture.model.savedConnections, original)
        XCTAssertEqual(fixture.model.subscriptionSources.first?.lastRefreshedAt, previousRefresh)

        fixture.provider.publishIdle()
        await waitUntil { fixture.model.canConnect }
        fixture.model.performScheduledSubscriptionRefreshes()
        await waitUntil { await fixture.client.requestCount == 2 }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertNotEqual(fixture.model.subscriptionSources.first?.lastRefreshedAt, previousRefresh)
        XCTAssertNil(fixture.model.lastError)
    }

    func testBackgroundFailureStaysOnSubscriptionAndPreservesUnrelatedError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        fixture.model.updateSubscriptionSettings(id: fixture.sourceID, customName: "Test", urlString: "invalid",
                                                autoUpdateIntervalMinutes: 1, filterDuplicateImports: true)
        let previousError = try XCTUnwrap(fixture.model.lastError)

        fixture.model.performScheduledSubscriptionRefreshes()
        await waitUntil { await fixture.client.requestCount == 1 }
        XCTAssertEqual(fixture.model.lastError, previousError)
        await fixture.client.fail()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }

        XCTAssertEqual(fixture.model.lastError, previousError)
        XCTAssertNotNil(fixture.model.subscriptionSources.first?.lastError)
        XCTAssertNil(fixture.model.connectionError)
    }

    func testManualRefreshStillReportsActiveSubscriptionAndNetworkErrors() async throws {
        let fixture = try Fixture(connected: true)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        XCTAssertEqual(fixture.model.lastError, "Disconnect before refreshing the active subscription")
        fixture.provider.publishIdle()
        await waitUntil { fixture.model.canConnect }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.fail()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertEqual(fixture.model.lastError, fixture.model.subscriptionSources.first?.lastError)
        XCTAssertNotNil(fixture.model.lastError)
    }

    func testStartupRefreshFailureDoesNotPublishGlobalError() async throws {
        let fixture = try Fixture(unfetched: true)
        defer { fixture.cleanUp() }
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.fail()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertNil(fixture.model.lastError)
        XCTAssertNotNil(fixture.model.subscriptionSources.first?.lastError)
    }

    func testSuccessfulBackgroundRefreshPreservesUnrelatedError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        fixture.model.updateSubscriptionSettings(id: fixture.sourceID, customName: "Test", urlString: "invalid",
                                                autoUpdateIntervalMinutes: 1, filterDuplicateImports: true)
        let previousError = try XCTUnwrap(fixture.model.lastError)
        fixture.model.performScheduledSubscriptionRefreshes()
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertEqual(fixture.model.lastError, previousError)
        XCTAssertNil(fixture.model.subscriptionSources.first?.lastError)
        XCTAssertNotEqual(fixture.model.subscriptionSources.first?.lastRefreshedAt, .distantPast)
    }

    func testInactiveSubscriptionStillRefreshesWhileConnected() async throws {
        let fixture = try Fixture(connected: true, activeSource: false)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        let selected = fixture.model.selectedConnectionID
        fixture.model.performScheduledSubscriptionRefreshes()
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertTrue(fixture.model.isConnected)
        XCTAssertEqual(fixture.model.selectedConnectionID, selected)
        XCTAssertEqual(fixture.model.importedConnections(for: fixture.sourceID).count, 1)
        XCTAssertNil(fixture.model.lastError)
    }

    func testManualRefreshResultAfterConnectStillReportsBlockedUpdate() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        let original = fixture.model.savedConnections
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        fixture.provider.publishConnected()
        await waitUntil { fixture.model.isConnected }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertEqual(fixture.model.lastError, "Disconnect before refreshing the active subscription")
        XCTAssertEqual(fixture.model.savedConnections, original)
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

    init(connected: Bool = false, unfetched: Bool = false, activeSource: Bool = true) throws {
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
        try store.save(AppSnapshot(savedConnections: [connection], subscriptionSources: [source],
                                   selectedConnectionID: connection.id, proxyEndpoint: .default, connectionMode: .tun))
        provider = SubscriptionTestProvider(connected: connected)
        let provider = self.provider
        model = AppViewModel(parser: ConnectionLinkParser(), store: store,
                             connectionProviderFactory: .init(systemProxyProvider: { provider }, tunProvider: { provider }),
                             leakGuard: LeakGuardService(isEnabled: false, log: log), subscriptionClient: SubscriptionClient(loadResponse: { [client] _ in try await client.fetch() }),
                             healthProbeService: ConnectionHealthProbeService(),
                             systemProxyService: SystemProxyService(fileManager: manager, log: log), log: log)
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
    func succeed() {
        let response = HTTPURLResponse(url: URL(string: "https://subscription.example/test")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        continuation?.resume(returning: (Data(Self.link.utf8), response))
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
    func connect(_ request: ConnectionRequest) async throws { publishConnected() }
    func disconnect() async throws { publishIdle() }
}
