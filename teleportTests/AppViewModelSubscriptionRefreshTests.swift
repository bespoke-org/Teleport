import Combine
import Foundation
import XCTest

@MainActor
final class AppViewModelSubscriptionRefreshTests: XCTestCase {
    func testOlderRefreshCannotOverwriteNewerResult() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 2 }
        let newer = ControlledSubscriptionClient.link.replacingOccurrences(of: "#Test", with: "#Newer")
        await fixture.client.succeed(links: [newer], requestIndex: 1)
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        await fixture.client.succeed()
        // Allow the superseded response to finish processing.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.model.importedConnections(for: fixture.sourceID).map(\.displayName), ["Newer"])
        XCTAssertNil(fixture.model.lastError)
    }

    func testDeletedSubscriptionIgnoresPendingRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        fixture.model.removeSubscription(id: fixture.sourceID)
        await fixture.client.succeed()
        // Include the deferred save's debounce window: an older snapshot must
        // not restore the deleted source on disk after the synchronous removal.
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(fixture.model.subscriptionSources.isEmpty)
        XCTAssertTrue(fixture.model.savedConnections.isEmpty)
        XCTAssertTrue(fixture.model.refreshingSubscriptionIDs.isEmpty)
        XCTAssertNil(fixture.model.lastError)
        XCTAssertTrue(fixture.store.load().subscriptionSources.isEmpty)
    }

    func testRefreshWritesConfigurationOffMainThread() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        fixture.manager.resetWriteThreads()
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        await waitUntil { !fixture.manager.writeThreads.isEmpty }
        XCTAssertFalse(fixture.manager.writeThreads.contains(true), "Subscription refresh must not perform disk writes on the UI thread")
    }

    func testRefreshKeepsMainActorResponsiveWhileProcessingPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }

        // Repeated entries keep the resulting catalog small while exercising
        // decoding, parsing and deduplication of a substantial response.
        let heartbeat = Task { @MainActor in
            var longestPause: Duration = .zero
            while !fixture.model.refreshingSubscriptionIDs.isEmpty {
                let start = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(5))
                longestPause = max(longestPause, start.duration(to: .now))
            }
            return longestPause
        }
        await Task.yield()
        await fixture.client.succeed(links: Array(repeating: ControlledSubscriptionClient.link, count: 50_000))
        let longestPause = try await heartbeat.value
        print("Subscription refresh longest main actor pause: \(longestPause)")
        XCTAssertLessThan(longestPause, .milliseconds(150), "Subscription processing must leave the UI responsive")
        XCTAssertEqual(fixture.model.importedConnections(for: fixture.sourceID).count, 1)
        XCTAssertNil(fixture.model.lastError)
    }

    func testManualRefreshCanDownloadActiveSubscription() async throws {
        let fixture = try Fixture(connected: true)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        XCTAssertNil(fixture.model.lastError, "Refreshing the portal list must not require disconnecting")
        guard fixture.model.lastError == nil else { return }
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertTrue(fixture.model.isConnected)
        XCTAssertNil(fixture.model.lastError)
        XCTAssertNil(fixture.model.subscriptionSources.first?.lastError)
    }

    func testOriginalOrderSurvivesSortChangesRefreshAndPersistence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        XCTAssertEqual(fixture.model.subscriptionConnectionSort, .original)
        let links = ["Zulu", "Alpha", "Bravo"].enumerated().map { index, name in
            "vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:\(10 + index)?security=none&type=tcp#\(name)"
        }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.succeed(links: links)
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }

        let original = fixture.model.importedConnections(for: fixture.sourceID)
        XCTAssertEqual(original.map(\.displayName), ["Zulu", "Alpha", "Bravo"])
        XCTAssertEqual(fixture.model.selectedConnectionID, original[0].id)
        XCTAssertEqual(fixture.model.importedConnectionPickerItems(for: fixture.sourceID).map(\.id), original.map(\.id))
        fixture.model.selectSubscriptionConnectionSort(.name)
        XCTAssertEqual(fixture.model.importedConnections(for: fixture.sourceID).map(\.displayName), ["Alpha", "Bravo", "Zulu"])
        fixture.model.selectSubscriptionConnectionSort(.latency)
        fixture.model.selectSubscriptionConnectionSort(.original)
        XCTAssertEqual(fixture.model.importedConnections(for: fixture.sourceID).map(\.id), original.map(\.id))

        fixture.model.renameConnection(id: original[0].id, to: "My portal")
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 2 }
        await fixture.client.succeed(links: [links[2], links[0], links[1]])
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }

        let reorderedIDs = [original[2].id, original[0].id, original[1].id]
        XCTAssertEqual(fixture.model.importedConnections(for: fixture.sourceID).map(\.id), reorderedIDs)
        XCTAssertEqual(fixture.model.importedConnectionPickerItemsBySourceID[fixture.sourceID]?.map(\.id), reorderedIDs)
        XCTAssertEqual(fixture.model.selectedConnectionID, original[0].id)
        XCTAssertEqual(fixture.model.importedConnections(for: fixture.sourceID)[1].customName, "My portal")
        await waitUntil {
            let snapshot = fixture.store.load()
            return snapshot.subscriptionConnectionSort == .original && snapshot.savedConnections.map(\.id) == reorderedIDs
        }
    }

    func testScheduledRefreshUpdatesActiveSubscriptionWithoutDuplicateDownloads() async throws {
        let fixture = try Fixture(connected: true)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        let selected = fixture.model.selectedConnectionID
        fixture.model.performScheduledSubscriptionRefreshes()
        fixture.model.performScheduledSubscriptionRefreshes()
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertNil(fixture.model.lastError)
        XCTAssertNil(fixture.model.subscriptionSources.first?.lastError)
        XCTAssertNotEqual(fixture.model.subscriptionSources.first?.lastRefreshedAt, .distantPast)
        XCTAssertEqual(fixture.model.selectedConnectionID, selected)
        XCTAssertTrue(fixture.model.isConnected)
        XCTAssertEqual(fixture.provider.connectRequests.count, 0)
        XCTAssertEqual(fixture.provider.disconnectCount, 0)
    }

    func testBackgroundResultArrivingAfterConnectUpdatesCatalogWithoutReconnect() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        let selected = fixture.model.selectedConnectionID
        let previousRefresh = fixture.model.subscriptionSources.first?.lastRefreshedAt
        fixture.model.performScheduledSubscriptionRefreshes()
        await waitUntil { await fixture.client.requestCount == 1 }
        fixture.provider.publishConnected()
        await waitUntil { fixture.model.isConnected }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertNil(fixture.model.lastError)
        XCTAssertNil(fixture.model.subscriptionSources.first?.lastError)
        XCTAssertEqual(fixture.model.selectedConnectionID, selected)
        XCTAssertNotEqual(fixture.model.subscriptionSources.first?.lastRefreshedAt, previousRefresh)
        XCTAssertEqual(fixture.provider.connectRequests.count, 0)
        XCTAssertEqual(fixture.provider.disconnectCount, 0)
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

    func testManualRefreshReportsNetworkFailureWithoutDroppingActiveSession() async throws {
        let fixture = try Fixture(connected: true)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        let connections = fixture.model.savedConnections
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.fail()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertEqual(fixture.model.lastError, fixture.model.subscriptionSources.first?.lastError)
        XCTAssertNotNil(fixture.model.lastError)
        XCTAssertEqual(fixture.model.savedConnections, connections)
        XCTAssertTrue(fixture.model.isConnected)
        XCTAssertEqual(fixture.provider.disconnectCount, 0)
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

    func testManualRefreshResultAfterConnectAppliesWithoutError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.canConnect }
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        fixture.provider.publishConnected()
        await waitUntil { fixture.model.isConnected }
        await fixture.client.succeed()
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertNil(fixture.model.lastError)
        XCTAssertTrue(fixture.model.isConnected)
        XCTAssertNotEqual(fixture.model.subscriptionSources.first?.lastRefreshedAt, .distantPast)
    }

    func testRemovedActivePortalStaysSelectedOnlyUntilDisconnect() async throws {
        let fixture = try Fixture(connected: true, includesManualPortal: true)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        let active = try XCTUnwrap(fixture.model.selectedConnection)
        let replacement = ControlledSubscriptionClient.link.replacingOccurrences(of: ":9?", with: ":10?").replacingOccurrences(of: "#Test", with: "#Replacement")
        fixture.model.refreshSubscription(id: fixture.sourceID)
        await waitUntil { await fixture.client.requestCount == 1 }
        await fixture.client.succeed(links: [replacement])
        await waitUntil { fixture.model.refreshingSubscriptionIDs.isEmpty }
        XCTAssertEqual(fixture.model.importedConnections(for: fixture.sourceID).map(\.displayName), ["Replacement"])
        XCTAssertEqual(fixture.model.selectedConnectionID, active.id)
        XCTAssertEqual(fixture.model.selectedConfiguration, active.configuration)
        XCTAssertTrue(fixture.model.isConnected)
        XCTAssertEqual(fixture.provider.connectRequests.count, 0)
        XCTAssertEqual(fixture.provider.disconnectCount, 0)
        await waitUntil {
            fixture.store.load().savedConnections.first(where: { $0.source?.subscriptionSourceID == fixture.sourceID })?.configuration.port == 10
        }
        let snapshot = fixture.store.load()
        XCTAssertEqual(snapshot.savedConnections.filter { $0.source != nil }.map(\.displayName), ["Replacement"])
        XCTAssertEqual(snapshot.selectedConnectionID, snapshot.savedConnections.first { $0.source != nil }?.id)
        fixture.model.removeSubscription(id: fixture.sourceID)
        XCTAssertEqual(fixture.model.subscriptionSources.count, 1, "Removing the source must still protect the running session")
        fixture.model.disconnect()
        await waitUntil { fixture.model.canConnect && !fixture.model.isOperationPending }
        XCTAssertEqual(fixture.model.selectedConnection?.displayName, "Replacement")
        fixture.model.connect()
        await waitUntil { fixture.model.isConnected && !fixture.model.isOperationPending }
        XCTAssertEqual(fixture.provider.connectRequests.last?.configuration.port, 10)
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
    let manager: SubscriptionTestFileManager

    init(connected: Bool = false, unfetched: Bool = false, activeSource: Bool = true, includesManualPortal: Bool = false) throws {
        manager = SubscriptionTestFileManager(root: root)
        let log = TeleportLog(directoryURL: root, fileName: "test.log")
        store = ConfigurationStore(fileManager: manager, keychainService: "dev.x.teleport.subscription-test-\(UUID())",
                                   keychainAccount: "snapshot", log: log)
        let configuration = try ConnectionLinkParser().parse(ControlledSubscriptionClient.link)
        let connection = SavedConnection(
            id: UUID(), configuration: configuration, savedAt: Date(),
            source: activeSource ? .init(subscriptionSourceID: sourceID, subscriptionEntryID: configuration.rawLink) : nil,
            healthCheck: .init(state: .reachable, checkedAt: Date(), latencyMilliseconds: 1,
                               latencyKind: .tcpConnect, failureSummary: nil)
        )
        let source = SubscriptionSource(
            id: sourceID, urlString: "https://subscription.example/test", title: "Test",
            savedAt: .distantPast, autoUpdateIntervalMinutes: 1,
            lastRefreshedAt: unfetched ? nil : .distantPast
        )
        var connections = [connection]
        if includesManualPortal {
            connections.append(SavedConnection(id: UUID(), configuration: configuration.withDisplayName("Manual"), savedAt: Date()))
        }
        try store.save(AppSnapshot(savedConnections: connections, subscriptionSources: [source],
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
    private let lock = NSLock()
    private var mainThreadWrites: [Bool] = []
    var writeThreads: [Bool] { lock.withLock { mainThreadWrites } }
    func resetWriteThreads() { lock.withLock { mainThreadWrites = [] } }
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        lock.withLock { mainThreadWrites.append(Thread.isMainThread) }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

private actor ControlledSubscriptionClient {
    static let link = "vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:9?security=none&type=tcp#Test"
    private(set) var requestCount = 0
    private var continuations: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    func fetch() async throws -> (Data, URLResponse) {
        let requestIndex = requestCount
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuations[requestIndex] = $0 }
    }
    func succeed(links: [String] = [ControlledSubscriptionClient.link], requestIndex: Int? = nil) {
        let response = HTTPURLResponse(url: URL(string: "https://subscription.example/test")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!
        guard let index = requestIndex ?? continuations.keys.min() else { return }
        continuations.removeValue(forKey: index)?.resume(returning: (Data(links.joined(separator: "\n").utf8), response))
    }
    func fail() {
        guard let index = continuations.keys.min() else { return }
        continuations.removeValue(forKey: index)?.resume(throwing: SubscriptionError.networkFailure("Test download failed"))
    }
}

private final class SubscriptionTestProvider: ConnectionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ConnectionState
    private var requests: [ConnectionRequest] = []
    private var disconnects = 0
    var connectRequests: [ConnectionRequest] { lock.withLock { requests } }
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
        lock.withLock { requests.append(request) }
        publishConnected()
    }
    func disconnect() async throws {
        lock.withLock { disconnects += 1 }
        publishIdle()
    }
}
