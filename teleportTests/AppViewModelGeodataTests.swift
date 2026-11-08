import Combine
import Foundation
import XCTest

@MainActor
final class AppViewModelGeodataTests: XCTestCase {
    func testConnectingBundledProfileRemovesLeftoverCustomFilesBeforeStartingProvider() async throws {
        // SplitTunnelProfile defines nil source URLs as bundled data. Existing
        // custom files take precedence on disk and must be removed before Xray starts.
        let fixture = try Fixture(initiallyConnected: false, geodataSettings: .init())
        defer { fixture.cleanUp() }
        let model = fixture.model
        await waitUntil { model.canConnect }
        XCTAssertEqual(model.selectedProfileGeodataSources, GeodataSources())
        // The selected profile is bundled even though the previous session left
        // global runtime files behind. Profile-isolated UI no longer reports
        // those files as an error for this profile; startup must still clear them.
        XCTAssertTrue(fixture.service.hasCustomGeodata(for: .geosite))
        XCTAssertTrue(fixture.service.hasCustomGeodata(for: .geoip))
        model.connect()
        await waitUntil { fixture.provider.connectCount == 1 && !model.isOperationPending }
        XCTAssertFalse(fixture.provider.startedWithCustomGeodata)
        XCTAssertFalse(model.hasCustomGeodata(kind: .geosite))
        XCTAssertFalse(model.hasCustomGeodata(kind: .geoip))
        XCTAssertNil(model.geodataProfileError)
        XCTAssertNil(model.lastError)
    }

    func testSharedCacheRefreshDoesNotDisableActiveProfileAutomaticUpdates() async throws {
        let fixture = try Fixture(sharedProfile: true)
        defer { fixture.cleanUp() }
        await waitUntil { fixture.model.isConnected }
        await waitUntil { await fixture.service.gate.count == 2 }
        await fixture.service.gate.succeed(.geosite)
        await fixture.service.gate.succeed(.geoip)
        await waitUntil { fixture.model.updatingSelectedProfileGeodataKinds.isEmpty }
        fixture.model.performScheduledGeodataUpdateIfNeeded()
        XCTAssertEqual(fixture.model.updatingGeodataKinds, [.geosite, .geoip],
                       "A newer shared cache must not permanently block activation of the active source")
        guard !fixture.model.updatingGeodataKinds.isEmpty else { return }
        await waitUntil { await fixture.service.gate.count == 4 }
        await fixture.service.gate.succeed(.geosite, occurrence: 1)
        await fixture.service.gate.succeed(.geoip, occurrence: 1)
        await waitUntil { fixture.model.updatingGeodataKinds.isEmpty }
    }

    func testTwoSuccessfulUpdatesReconnectOnceAfterBothFinish() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        model.applyGeodataSources(geositeURLString: "https://new.example/geosite.dat",
                                  geoipURLString: "https://new.example/geoip.dat")
        XCTAssertEqual(model.updatingGeodataKinds, [.geosite, .geoip])
        await waitUntil { await fixture.service.gate.count == 2 }
        await fixture.service.gate.succeed(.geosite)
        await waitUntil { model.updatingGeodataKinds == [.geoip] }
        XCTAssertEqual(fixture.provider.connectCount, 0)
        XCTAssertEqual(model.geodataSettings.geositeURLString, "https://new.example/geosite.dat")
        await fixture.service.gate.succeed(.geoip)
        await waitUntil { model.updatingGeodataKinds.isEmpty && fixture.provider.connectCount == 1 }
        XCTAssertEqual(model.geodataSettings.geoipURLString, "https://new.example/geoip.dat")
        XCTAssertNil(model.geodataSettings.geositeLastError)
        XCTAssertNil(model.geodataSettings.geoipLastError)
        XCTAssertEqual(fixture.service.activationCount, 2)

        // A later batch gets its own single completion, even for the same sources.
        model.applyGeodataSources(geositeURLString: "https://new.example/geosite.dat",
                                  geoipURLString: "https://new.example/geoip.dat", forceDownload: true)
        await waitUntil { await fixture.service.gate.count == 4 }
        await fixture.service.gate.succeed(.geoip, occurrence: 1)
        await waitUntil { model.updatingGeodataKinds == [.geosite] }
        XCTAssertEqual(fixture.provider.connectCount, 1)
        await fixture.service.gate.succeed(.geosite, occurrence: 1)
        await waitUntil { model.updatingGeodataKinds.isEmpty && fixture.provider.connectCount == 2 }
    }

    func testPartialFailurePreservesFailedSourceAndPreventsConnectingWithIncompleteProfile() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.model.applyGeodataSources(geositeURLString: "https://new.example/geosite.dat",
                                          geoipURLString: "https://new.example/geoip.dat")
        await waitUntil { await fixture.service.gate.count == 2 }
        await fixture.service.gate.succeed(.geosite)
        await waitUntil { fixture.model.updatingGeodataKinds == [.geoip] }
        XCTAssertEqual(fixture.provider.connectCount, 0)
        await fixture.service.gate.fail(.geoip)
        await waitUntil { fixture.model.updatingGeodataKinds.isEmpty }
        XCTAssertEqual(fixture.model.geodataSettings.geoipURLString, "https://old.example/geoip.dat")
        XCTAssertNotNil(fixture.model.geodataSettings.geoipLastError)
        XCTAssertNotNil(fixture.model.geodataProfileError)
        fixture.model.connect()
        await waitUntil { await fixture.service.gate.count == 4 }
        await fixture.service.gate.succeed(.geosite, occurrence: 1)
        await fixture.service.gate.fail(.geoip, occurrence: 1)
        await waitUntil { !fixture.model.isOperationPending }
        XCTAssertTrue(fixture.model.lastError?.contains("GeoIP") == true)
        XCTAssertEqual(fixture.provider.connectCount, 0)
        XCTAssertEqual(fixture.service.activationCount, 2, "Only Geosite succeeded, once per attempt")
    }

    func testCancelAllDiscardsLateResultsWithoutPublishingOrReconnecting() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let previous = fixture.model.geodataSettings
        fixture.model.applyGeodataSources(geositeURLString: "https://new.example/geosite.dat",
                                          geoipURLString: "https://new.example/geoip.dat")
        await waitUntil { await fixture.service.gate.count == 2 }
        fixture.model.cancelGeodataUpdates()
        XCTAssertTrue(fixture.model.updatingGeodataKinds.isEmpty)
        // The fake deliberately returns data even after cancellation.
        await fixture.service.gate.succeed(.geosite)
        await fixture.service.gate.succeed(.geoip)
        await waitUntil { fixture.service.discardCount == 2 }
        XCTAssertEqual(fixture.model.geodataSettings, previous)
        XCTAssertEqual(fixture.service.activationCount, 0)
        XCTAssertEqual(fixture.provider.connectCount, 0)
    }

    func testCancellationAfterPartialSuccessCompletesBatchOnce() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.model.applyGeodataSources(geositeURLString: "https://new.example/geosite.dat",
                                          geoipURLString: "https://new.example/geoip.dat")
        await waitUntil { await fixture.service.gate.count == 2 }
        await fixture.service.gate.succeed(.geosite)
        await waitUntil { fixture.model.updatingGeodataKinds == [.geoip] }
        fixture.model.cancelGeodataUpdate(kind: .geoip)
        await waitUntil { fixture.model.updatingGeodataKinds.isEmpty }
        await fixture.service.gate.succeed(.geoip)
        await waitUntil { fixture.service.discardCount == 2 }
        XCTAssertTrue(fixture.model.updatingGeodataKinds.isEmpty)
        XCTAssertEqual(fixture.provider.connectCount, 0)
        XCTAssertNotNil(fixture.model.geodataProfileError)
        XCTAssertEqual(fixture.model.geodataSettings.geoipURLString, "https://old.example/geoip.dat")
        XCTAssertNil(fixture.model.geodataSettings.geoipLastError)
    }

    func testSupersessionKeepsBatchOpenAndRejectsLateOldResult() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.model.applyGeodataSources(geositeURLString: "https://new.example/geosite.dat",
                                          geoipURLString: "https://new.example/geoip.dat")
        await waitUntil { await fixture.service.gate.count == 2 }
        await fixture.service.gate.succeed(.geosite)
        await waitUntil { fixture.model.updatingGeodataKinds == [.geoip] }
        fixture.model.setGeoipURL("https://replacement.example/geoip.dat")
        fixture.model.updateGeodataNow(kind: .geoip)
        await waitUntil { await fixture.service.gate.count == 3 }
        XCTAssertEqual(fixture.provider.connectCount, 0, "Replacing the last pending job must not finish its batch")
        await fixture.service.gate.succeed(.geoip, occurrence: 1)
        await waitUntil { fixture.model.updatingGeodataKinds.isEmpty && fixture.provider.connectCount == 1 }
        await fixture.service.gate.succeed(.geoip, occurrence: 0)
        await waitUntil { fixture.service.discardCount == 3 }
        XCTAssertEqual(fixture.model.geodataSettings.geoipURLString, "https://replacement.example/geoip.dat")
        XCTAssertEqual(fixture.model.selectedProfileGeodataSources.geoipURLString, "https://replacement.example/geoip.dat")
        XCTAssertNil(fixture.model.geodataProfileError)
        XCTAssertEqual(fixture.service.activationCount, 2)
        XCTAssertEqual(fixture.provider.connectCount, 1)
    }

    func testUnchangedDataAndFailedChecksDoNotReconnect() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.model.applyGeodataSources(geositeURLString: "https://new.example/geosite.dat",
                                          geoipURLString: "https://new.example/geoip.dat")
        await waitUntil { await fixture.service.gate.count == 2 }
        await fixture.service.gate.succeed(.geosite, changed: false)
        await fixture.service.gate.fail(.geoip)
        await waitUntil { fixture.model.updatingGeodataKinds.isEmpty }
        XCTAssertEqual(fixture.provider.connectCount, 0)
    }

    func testBundledResetCompletesAsOneBatchAndClearsSourceMetadata() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.model.applyGeodataSources(geositeURLString: nil, geoipURLString: nil)
        await waitUntil { fixture.model.updatingGeodataKinds.isEmpty && fixture.provider.connectCount == 1 }
        XCTAssertNil(fixture.model.geodataSettings.geositeURLString)
        XCTAssertNil(fixture.model.geodataSettings.geoipURLString)
        XCTAssertNil(fixture.model.geodataSettings.geositeLastUpdatedAt)
        XCTAssertNil(fixture.model.geodataSettings.geoipLastUpdatedAt)
        XCTAssertFalse(fixture.model.hasCustomGeodata(kind: .geosite))
        XCTAssertFalse(fixture.model.hasCustomGeodata(kind: .geoip))
    }

    func testServiceCancellationCompletesItsJobWithoutAnErrorOrReconnect() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        fixture.model.updateGeodataNow(kind: .geosite)
        await waitUntil { await fixture.service.gate.count == 1 }
        await fixture.service.gate.cancel(.geosite)
        await waitUntil { fixture.model.updatingGeodataKinds.isEmpty }
        XCTAssertNil(fixture.model.geodataSettings.geositeLastError)
        XCTAssertEqual(fixture.provider.connectCount, 0)
    }

    private func makeFixture() async throws -> Fixture {
        let fixture = try Fixture()
        await waitUntil { fixture.model.isConnected }
        return fixture
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for controlled geodata work")
    }
}

@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let service = ControlledGeodataService()
    let provider: GeodataTestProvider
    let model: AppViewModel
    let store: ConfigurationStore

    init(sharedProfile: Bool = false, initiallyConnected: Bool = true,
         geodataSettings: GeodataSourceSettings = .init(geositeURLString: "https://old.example/geosite.dat",
                                                       geoipURLString: "https://old.example/geoip.dat")) throws {
        provider = GeodataTestProvider(initiallyConnected: initiallyConnected, geodata: service)
        let manager = GeodataTestFileManager(root: root)
        let log = TeleportLog(directoryURL: root, fileName: "test.log")
        store = ConfigurationStore(fileManager: manager, keychainService: "dev.x.teleport.geodata-test-\(UUID())",
                                   keychainAccount: "snapshot", log: log)
        let configuration = try ConnectionLinkParser().parse(
            "vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:9?security=none&type=tcp#Test"
        )
        let connection = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date(), healthCheck: .init(
            state: .reachable, checkedAt: Date(), latencyMilliseconds: 1, latencyKind: .tcpConnect, failureSummary: nil
        ))
        let sources = GeodataSources(geositeURLString: geodataSettings.geositeURLString, geoipURLString: geodataSettings.geoipURLString)
        let activeProfile = SplitTunnelProfile(name: "Default", geodataSources: sources,
                                              geodataUpdateIntervalMinutes: sharedProfile ? 1 : nil)
        let profiles = sharedProfile ? [activeProfile, SplitTunnelProfile(name: "Shared", geodataSources: sources,
                                                                         geodataUpdateIntervalMinutes: 1)] : [activeProfile]
        try store.save(AppSnapshot(savedConnections: [connection], selectedConnectionID: connection.id,
                                   proxyEndpoint: .default, connectionMode: .tun, splitTunnelProfiles: profiles,
                                   selectedSplitTunnelProfileID: activeProfile.id, isSplitTunnelEnabled: true,
                                   isLeakGuardEnabled: false, geodataSettings: geodataSettings))
        let provider = self.provider
        model = AppViewModel(parser: ConnectionLinkParser(), store: store,
                             connectionProviderFactory: .init(systemProxyProvider: { provider }, tunProvider: { provider }),
                             leakGuard: LeakGuardService(isEnabled: false, log: log),
                             subscriptionClient: SubscriptionClient(), healthProbeService: ConnectionHealthProbeService(),
                             systemProxyService: SystemProxyService(fileManager: manager, log: log),
                             geodataUpdateCoordinator: GeodataUpdateCoordinator(service: service), log: log)
    }

    func cleanUp() {
        model.handleAppTermination {}
        store.deleteStoredDataForTesting()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class GeodataTestFileManager: FileManager {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

private final class ControlledGeodataService: GeodataUpdateServicing, @unchecked Sendable {
    let gate = PreparationGate()
    private let lock = NSLock()
    private var activations = 0
    private var discards = 0
    private var storedKinds: Set<GeodataKind> = [.geosite, .geoip]
    var activationCount: Int { lock.withLock { activations } }
    var discardCount: Int { lock.withLock { discards } }

    func cacheCurrentDownload(for kind: GeodataKind, source: URL?, updatedAt: Date?) throws {}
    func prepareUpdate(kind: GeodataKind, from source: URL, useCache: Bool) async throws -> GeodataUpdateService.PreparedUpdate {
        try await gate.prepare(kind)
    }
    func activate(_ update: GeodataUpdateService.PreparedUpdate, for kind: GeodataKind) throws {
        lock.withLock { activations += 1; storedKinds.insert(kind) }
    }
    func discard(_ update: GeodataUpdateService.PreparedUpdate) { lock.withLock { discards += 1 } }
    func hasCustomGeodata(for kind: GeodataKind) -> Bool { lock.withLock { storedKinds.contains(kind) } }
    func removeCustomGeodata(for kind: GeodataKind) throws { _ = lock.withLock { storedKinds.remove(kind) } }
}

private actor PreparationGate {
    struct Pending {
        let kind: GeodataKind
        var continuation: CheckedContinuation<GeodataUpdateService.PreparedUpdate, Error>?
    }
    private var pending: [Pending] = []
    var count: Int { pending.count }
    func prepare(_ kind: GeodataKind) async throws -> GeodataUpdateService.PreparedUpdate {
        try await withCheckedThrowingContinuation { pending.append(Pending(kind: kind, continuation: $0)) }
    }
    func succeed(_ kind: GeodataKind, occurrence: Int = 0, changed: Bool = true) {
        complete(kind, occurrence: occurrence, result: .success(.init(
            stagedURL: URL(fileURLWithPath: "/tmp/\(UUID()).pending"), updatedAt: Date(), changed: changed
        )))
    }
    func cancel(_ kind: GeodataKind) { complete(kind, occurrence: 0, result: .failure(CancellationError())) }
    func fail(_ kind: GeodataKind, occurrence: Int = 0) { complete(kind, occurrence: occurrence, result: .failure(GeodataUpdateError.invalidResponse)) }
    private func complete(_ kind: GeodataKind, occurrence: Int, result: Result<GeodataUpdateService.PreparedUpdate, Error>) {
        let indices = pending.indices.filter { pending[$0].kind == kind }
        guard indices.indices.contains(occurrence) else { XCTFail("Request did not start"); return }
        let index = indices[occurrence]
        pending[index].continuation?.resume(with: result)
        pending[index].continuation = nil
    }
}

private final class GeodataTestProvider: ConnectionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var connects = 0
    private let state = ConnectionState.connected(.init(id: UUID(), mode: .tun, connectedAt: Date()))
    private let initialState: ConnectionState
    private let geodata: ControlledGeodataService
    private var connectedWithCustomGeodata = false
    private let updates = AsyncStream<ConnectionState>.makeStream()
    var connectCount: Int { lock.withLock { connects } }
    var startedWithCustomGeodata: Bool { lock.withLock { connectedWithCustomGeodata } }
    init(initiallyConnected: Bool, geodata: ControlledGeodataService) {
        initialState = initiallyConnected ? state : .idle
        self.geodata = geodata
    }
    func currentState() async -> ConnectionState { initialState }
    func stateUpdates() -> AsyncStream<ConnectionState> { updates.continuation.yield(initialState); return updates.stream }
    func connect(_ request: ConnectionRequest) async throws {
        let hasCustomGeodata = geodata.hasCustomGeodata(for: .geosite) || geodata.hasCustomGeodata(for: .geoip)
        lock.withLock { connects += 1; connectedWithCustomGeodata = hasCustomGeodata }
        updates.continuation.yield(state)
    }
    func disconnect() async throws { updates.continuation.yield(.idle); updates.continuation.finish() }
}
