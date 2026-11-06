import Foundation
import XCTest

@MainActor
final class AppViewModelSubscriptionTests: XCTestCase {
    func testStartupRefreshTimeoutStaysOnSubscription() async throws {
        let fixture = try Fixture(unfetched: true)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected && fixture.client.pending != nil }
        fixture.client.complete(throwing: URLError(.timedOut))
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertEqual(fixture.model.subscriptionSources.first?.lastError, URLError(.timedOut).localizedDescription)
        XCTAssertNil(fixture.model.connectionError)
        XCTAssertNil(fixture.model.lastError)
    }

    func testScheduledTimeoutDoesNotReplaceUnrelatedError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        fixture.model.reportImportFailure("Keep this manual error")
        fixture.model.performScheduledSubscriptionRefreshes()
        await waitUntil { fixture.client.pending != nil }
        XCTAssertEqual(fixture.model.lastError, "Keep this manual error")
        fixture.client.complete(throwing: URLError(.timedOut))
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertNotNil(fixture.model.subscriptionSources.first?.lastError)
        XCTAssertEqual(fixture.model.lastError, "Keep this manual error")
    }

    func testManualRefreshStillShowsTimeout() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        fixture.model.refreshSubscription(id: fixture.source.id)
        await waitUntil { fixture.client.pending != nil }
        fixture.client.complete(throwing: URLError(.timedOut))
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertEqual(fixture.model.lastError, URLError(.timedOut).localizedDescription)
    }

    func testScheduledRefreshOfActiveSubscriptionIsSilent() async throws {
        let fixture = try Fixture(activeSubscription: true)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        fixture.model.performScheduledSubscriptionRefreshes()
        XCTAssertNil(fixture.model.lastError)
        XCTAssertTrue(fixture.model.refreshingSubscriptionIDs.isEmpty)
        XCTAssertNil(fixture.client.pending)
    }

    func testAutomaticResultAfterSubscriptionBecomesActiveIsSilent() async throws {
        let fixture = try Fixture(activeSubscription: true, initiallyConnected: false)
        defer { fixture.cleanUp() }
        await Task.yield()
        fixture.model.performScheduledSubscriptionRefreshes()
        await waitUntil { fixture.client.pending != nil }
        fixture.provider.publishConnected()
        await waitUntil { fixture.model.isConnected }
        fixture.client.complete()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertEqual(fixture.model.subscriptionSources.first?.lastError, "Disconnect before refreshing the active subscription")
        XCTAssertNil(fixture.model.lastError)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out waiting for subscription refresh")
    }

    @MainActor
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = ControlledSubscriptionClient()
        let provider: SubscriptionTestProvider
        let source: SubscriptionSource
        let model: AppViewModel
        let store: ConfigurationStore

        init(unfetched: Bool = false, activeSubscription: Bool = false, initiallyConnected: Bool = true) throws {
            provider = SubscriptionTestProvider(initiallyConnected: initiallyConnected)
            source = SubscriptionSource(id: UUID(), urlString: "https://subscription.example/list", title: "Test",
                savedAt: .distantPast, autoUpdateIntervalMinutes: 360, lastRefreshedAt: unfetched ? nil : .distantPast)
            let manager = TestFileManager(root: root)
            let log = TeleportLog(directoryURL: root, fileName: "test.log")
            store = ConfigurationStore(fileManager: manager, keychainService: "dev.x.teleport.subscription-test-\(UUID())",
                                       keychainAccount: "snapshot", log: log)
            let configuration = try ConnectionLinkParser().parse("vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:9?security=none&type=tcp#Test")
            let metadata = activeSubscription ? ConnectionSourceMetadata(subscriptionSourceID: source.id, subscriptionEntryID: configuration.rawLink) : nil
            let connection = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date(), source: metadata,
                healthCheck: .init(state: .reachable, checkedAt: Date(), latencyMilliseconds: 1, latencyKind: .tcpConnect, failureSummary: nil))
            try store.save(AppSnapshot(savedConnections: [connection], subscriptionSources: [source], selectedConnectionID: connection.id,
                proxyEndpoint: .default, connectionMode: .systemProxy, isLeakGuardEnabled: false))
            let provider = self.provider
            model = AppViewModel(parser: ConnectionLinkParser(), store: store,
                connectionProviderFactory: .init(systemProxyProvider: { provider }, tunProvider: { provider }),
                leakGuard: LeakGuardService(isEnabled: false, log: log), subscriptionClient: client,
                healthProbeService: ConnectionHealthProbeService(), systemProxyService: SystemProxyService(fileManager: manager, log: log), log: log)
        }

        func cleanUp() {
            model.handleAppTermination {}
            store.deleteStoredDataForTesting()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@MainActor
private final class ControlledSubscriptionClient: SubscriptionFetching {
    var pending: CheckedContinuation<[SubscriptionCandidate], Error>?
    func fetchCandidates(from url: URL) async throws -> [SubscriptionCandidate] {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete(throwing error: Error? = nil) {
        let continuation = pending
        pending = nil
        if let error { continuation?.resume(throwing: error) }
        else {
            do {
                let candidates = try SubscriptionPayloadDecoder().decode(Data("vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:9?security=none&type=tcp#Test".utf8))
                continuation?.resume(returning: candidates)
            } catch { continuation?.resume(throwing: error) }
        }
    }
}

private final class TestFileManager: FileManager {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

private final class SubscriptionTestProvider: ConnectionProvider, @unchecked Sendable {
    private let state: ConnectionState
    private let updates = AsyncStream<ConnectionState>.makeStream()
    init(initiallyConnected: Bool) {
        state = initiallyConnected ? .connected(.init(id: UUID(), mode: .systemProxy, connectedAt: Date())) : .idle
    }
    func publishConnected() { updates.continuation.yield(.connected(.init(id: UUID(), mode: .systemProxy, connectedAt: Date()))) }
    func currentState() async -> ConnectionState { state }
    func stateUpdates() -> AsyncStream<ConnectionState> { updates.continuation.yield(state); return updates.stream }
    func connect(_ request: ConnectionRequest) async throws { publishConnected() }
    func disconnect() async throws { updates.continuation.yield(.idle); updates.continuation.finish() }
}
