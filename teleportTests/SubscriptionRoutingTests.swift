import Foundation
import XCTest

final class SubscriptionRoutingTests: XCTestCase {
    private let server = "vless://123e4567-e89b-12d3-a456-426614174000@vpn.example.com:443?security=tls#Server"

    func testHTTPHeadersImportServersAndRoutingTogether() throws {
        let header = try link([
            "Name": "Provider routes", "GlobalProxy": "false",
            "RouteOrder": "block-proxy-direct",
            "BlockSites": ["geosite:category-ads-all"],
            "ProxySites": ["domain:Video.Example", "full:login.example"],
            "DirectSites": ["geosite:ru"], "DirectIp": ["10.0.0.0/8", "geoip:private"]
        ])
        let response = try fetchResult(header: header, body: Data(server.utf8).base64EncodedData())
        let servers = try SubscriptionImportProcessor.importEntries(
            candidates: response.candidates, parser: ConnectionLinkParser(),
            sourceID: UUID(), filterDuplicateImports: true
        )
        XCTAssertEqual(servers.importedEntries.count, 1)
        let (profile, activate) = try profile(from: response.routing)
        XCTAssertEqual(profile.name, "Provider routes")
        XCTAssertEqual(profile.defaultAction, .direct)
        XCTAssertTrue(activate)
        XCTAssertNil(response.routingWarning)
        XCTAssertEqual(profile.rules.map(\.action), [.block, .proxy, .proxy, .direct, .direct, .direct])
        XCTAssertEqual(profile.rules.map(\.kind), [.geosite, .domain, .domain, .geosite, .ip, .geoip])
        XCTAssertEqual(profile.rules[1].value, "video.example")
        XCTAssertEqual(SplitTunnelRuleMatcher.firstMatch(for: "cdn.video.example", in: profile.rules)?.action, .proxy)
        XCTAssertEqual(SplitTunnelRuleMatcher.firstMatch(for: "10.1.2.3", in: profile.rules)?.action, .direct)

        // Imported rules reach the actual TUN configuration, including the
        // default outbound and the order used for conflicting matches.
        let data = try XrayConfigurationWriter(proxyEndpoint: .default).tunnelConfigData(
            for: servers.importedEntries[0].configuration, interfaceName: "utun9",
            splitTunnelRules: profile.rules, defaultAction: profile.defaultAction
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rules = try XCTUnwrap((json["routing"] as? [String: Any])?["rules"] as? [[String: Any]])
        let importedRules = rules.filter { $0["domain"] != nil || $0["ip"] != nil }
        XCTAssertTrue(importedRules.contains { $0["domain"] as? [String] == ["domain:video.example"] && $0["outboundTag"] as? String == "proxy" })
        XCTAssertTrue(importedRules.contains { $0["ip"] as? [String] == ["10.0.0.0/8"] && $0["outboundTag"] as? String == "direct" })
    }

    func testHeaderFormatsAndCommands() throws {
        let payload = try encoded(["Name": "Routes"])
        for prefix in ["happ://routing/onadd/", "incy://routing/onadd/", "://routing/onadd/", "://routing/", ""] {
            let result = SubscriptionRoutingHeaderParser().parse(prefix + payload)
            if prefix == "://routing/" {
                // A deep link must specify its command, unlike raw base64.
                XCTAssertNil(result.routing)
                XCTAssertNotNil(result.warning)
                continue
            }
            let (_, activate) = try profile(from: result.routing)
            XCTAssertTrue(activate)
        }
        let (_, activate) = try profile(from: SubscriptionRoutingHeaderParser().parse("incy://routing/add/" + payload).routing)
        XCTAssertFalse(activate)
        for header in ["off", "happ://routing/off", "incy://routing/off", "://routing/off"] {
            guard case .off = SubscriptionRoutingHeaderParser().parse(header).routing else {
                return XCTFail("Expected off for \(header)")
            }
        }
    }

    func testCaseInsensitiveFieldsAndBooleanValues() throws {
        let (profile, _) = try profile(from: SubscriptionRoutingHeaderParser().parse(try link([
            "name": "Lowercase", "globalproxy": false,
            "directsites": ["Example.COM", "example.com"], "directip": ["2001:db8::/32"]
        ])).routing)
        XCTAssertEqual(profile.name, "Lowercase")
        XCTAssertEqual(profile.defaultAction, .direct)
        XCTAssertEqual(profile.rules.count, 2)
        XCTAssertEqual(profile.rules[0].value, "example.com")
        let (defaults, _) = try self.profile(from: SubscriptionRoutingHeaderParser().parse(try encoded([:])).routing)
        XCTAssertEqual(defaults.name, "Default")
        XCTAssertEqual(defaults.defaultAction, .proxy)
    }

    func testURLSafeBase64WithoutPaddingAndPercentEscaping() throws {
        let payload = try encoded(["Name": "Правила 👋", "DirectSites": ["example.com"]])
        for encoded in [
            payload.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""),
            payload.replacingOccurrences(of: "=", with: "%3D")
        ] {
            let (profile, _) = try profile(from: SubscriptionRoutingHeaderParser().parse("happ://routing/onadd/" + encoded).routing)
            XCTAssertEqual(profile.name, "Правила 👋")
        }
    }

    func testRuleOrderPreservesFirstMatchPriority() throws {
        for order in ["proxy-direct-block", "direct-proxy-block", "block-direct-proxy"] {
            let (profile, _) = try profile(from: SubscriptionRoutingHeaderParser().parse(try link([
                "RouteOrder": order, "ProxySites": ["example.com"],
                "DirectSites": ["example.com"], "BlockSites": ["example.com"]
            ])).routing)
            XCTAssertEqual(SplitTunnelRuleMatcher.firstMatch(for: "example.com", in: profile.rules)?.action.rawValue,
                           order.components(separatedBy: "-").first)
        }
    }

    func testInvalidRoutingKeepsServersImportable() throws {
        let invalidHeaders = try [
            "%%%", "happ://routing/onadd/not-base64", "happ://routing/unknown/data",
            encoded(["DirectSites": ["regexp:.*"]]), encoded(["DirectSites": ["10.0.0.1"]]),
            encoded(["DirectIp": ["example.com"]]), encoded(["DirectIp": ["10.0.0.1/99"]]),
            encoded(["DirectSites": "example.com"]), encoded(["GlobalProxy": 1]),
            encoded(["RouteOrder": "proxy-proxy-block"]), encoded(["Name": 42]),
            encoded(["Name": "A", "name": "B"])
        ]
        for header in invalidHeaders {
            let fetched = try fetchResult(header: header)
            XCTAssertNil(fetched.routing)
            XCTAssertNotNil(fetched.routingWarning)
            let servers = try SubscriptionImportProcessor.importEntries(
                candidates: fetched.candidates, parser: ConnectionLinkParser(), sourceID: UUID(), filterDuplicateImports: true
            )
            XCTAssertEqual(servers.importedEntries.count, 1)
        }
    }

    func testMissingHeaderLeavesRoutingUntouched() throws {
        for header in [nil, "", "  "] as [String?] {
            let fetched = try fetchResult(header: header)
            XCTAssertNil(fetched.routing)
            XCTAssertNil(fetched.routingWarning)
        }
    }

    func testUnsupportedProfileSettingsAreReported() throws {
        let fetched = try fetchResult(header: link([
            "DirectSites": ["example.com"], "RemoteDNSType": "DoH",
            "Geositeurl": "https://provider.example/geosite.dat", "DomainStrategy": "IPIfNonMatch"
        ]))
        let (profile, _) = try profile(from: fetched.routing)
        XCTAssertEqual(profile.rules.count, 1)
        XCTAssertNotNil(fetched.routingWarning)
    }

    func testRefreshUpdatesOnlyOwningSubscriptionAndPreservesIdentity() throws {
        let sourceID = UUID()
        let otherSourceID = UUID()
        let manual = SplitTunnelProfile(name: "Same name")
        let other = SplitTunnelProfile(name: "Same name", subscriptionSourceID: otherSourceID)
        var profiles = [manual, other]
        var selected: UUID? = manual.id
        var enabled = false
        let first = try XCTUnwrap(SubscriptionRoutingHeaderParser().parse(try link([
            "Name": "Same name", "DirectSites": ["example.com"]
        ])).routing)
        first.apply(to: &profiles, sourceID: sourceID, selectedProfileID: &selected, isEnabled: &enabled)
        let importedID = profiles[2].id
        let ruleID = profiles[2].rules[0].id
        XCTAssertEqual(selected, importedID)
        XCTAssertTrue(enabled)

        let update = try XCTUnwrap(SubscriptionRoutingHeaderParser().parse(try link([
            "Name": "Renamed", "GlobalProxy": false, "DirectSites": ["example.com", "new.example"]
        ])).routing)
        update.apply(to: &profiles, sourceID: sourceID, selectedProfileID: &selected, isEnabled: &enabled)
        XCTAssertEqual(profiles.count, 3)
        XCTAssertEqual(Array(profiles.prefix(2)), [manual, other])
        XCTAssertEqual(profiles[2].id, importedID)
        XCTAssertEqual(profiles[2].rules[0].id, ruleID)
        XCTAssertEqual(profiles[2].rules.count, 2)
        XCTAssertEqual(profiles[2].name, "Renamed")
        XCTAssertEqual(profiles[2].defaultAction, .direct)
    }

    func testAddDoesNotActivateAndOffKeepsProfileAndSelection() throws {
        let manual = SplitTunnelProfile(name: "Manual")
        var profiles = [manual]
        var selected: UUID? = manual.id
        var enabled = true
        let added = try XCTUnwrap(SubscriptionRoutingHeaderParser().parse(try link(["Name": "Added"], command: "add")).routing)
        added.apply(to: &profiles, sourceID: UUID(), selectedProfileID: &selected, isEnabled: &enabled)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(selected, manual.id)
        XCTAssertTrue(enabled)
        SubscriptionRoutingImport.off.apply(to: &profiles, sourceID: UUID(), selectedProfileID: &selected, isEnabled: &enabled)
        XCTAssertFalse(enabled)
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(selected, manual.id)
    }

    func testProfileOwnershipPersistsAndOlderProfilesDecode() throws {
        let profile = SplitTunnelProfile(name: "Imported", subscriptionSourceID: UUID())
        XCTAssertEqual(try JSONDecoder().decode(SplitTunnelProfile.self, from: JSONEncoder().encode(profile)), profile)
        let old = Data("{\"id\":\"\(UUID().uuidString)\",\"name\":\"Manual\",\"rules\":[]}".utf8)
        let decoded = try JSONDecoder().decode(SplitTunnelProfile.self, from: old)
        XCTAssertNil(decoded.subscriptionSourceID)
        XCTAssertEqual(decoded.defaultAction, .proxy)
    }

    @MainActor
    func testEditingURLCaseDuringRefreshFinishesImport() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.cleanUp() }
        let viewModel = fixture.viewModel
        viewModel.refreshSubscription(id: fixture.source.id)
        await waitUntil { await fixture.loader.requestCount == 1 }
        viewModel.updateSubscriptionSettings(
            id: fixture.source.id, customName: "Renamed",
            urlString: "https://PROVIDER.invalid/sub", autoUpdateIntervalMinutes: nil,
            filterDuplicateImports: true
        )
        await fixture.loader.complete(index: 0, header: try link(["Name": "Imported"]))
        await waitUntil { !viewModel.isRefreshingSubscription(fixture.source.id) }
        XCTAssertEqual(viewModel.splitTunnelProfiles.last?.name, "Imported")
        XCTAssertNotNil(viewModel.subscriptionSources.first?.lastRefreshedAt)
    }

    @MainActor
    func testSupersededRefreshCannotFinishOrFailNewerRefresh() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.cleanUp() }
        let viewModel = fixture.viewModel
        viewModel.refreshSubscription(id: fixture.source.id)
        await waitUntil { await fixture.loader.requestCount == 1 }
        viewModel.updateSubscriptionSettings(
            id: fixture.source.id, customName: "Changed URL",
            urlString: "https://other.invalid/sub", autoUpdateIntervalMinutes: nil,
            filterDuplicateImports: true
        )
        await waitUntil { await fixture.loader.requestCount == 2 }
        await fixture.loader.fail(index: 0)
        // Wait for the old fetch's catch/defer to have run before checking the
        // newer request. It must retain the loading state and remain error-free.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(viewModel.isRefreshingSubscription(fixture.source.id))
        XCTAssertNil(viewModel.subscriptionSources.first?.lastError)
        await fixture.loader.complete(index: 1, header: try link(["Name": "Current"]))
        await waitUntil { !viewModel.isRefreshingSubscription(fixture.source.id) }
        XCTAssertEqual(viewModel.splitTunnelProfiles.last?.name, "Current")
    }

    func testRefreshKeepsLocalRuleSettings() throws {
        let sourceID = UUID()
        let rule = SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy,
                                   isEnabled: false, connectionID: UUID())
        var profiles = [SplitTunnelProfile(name: "Imported", rules: [rule], subscriptionSourceID: sourceID)]
        var selected: UUID? = profiles[0].id
        var enabled = true
        let update = try XCTUnwrap(SubscriptionRoutingHeaderParser().parse(try link([
            "ProxySites": ["example.com", "new.example"]
        ])).routing)
        update.apply(to: &profiles, sourceID: sourceID, selectedProfileID: &selected, isEnabled: &enabled)
        XCTAssertEqual(profiles[0].rules[0], rule)
        XCTAssertTrue(profiles[0].rules[1].isEnabled)
        XCTAssertNil(profiles[0].rules[1].connectionID)
    }

    @MainActor
    func testImportDuringTUNStartupWaitsUntilNextConnection() async throws {
        for header in [try link(["Name": "Imported", "DirectSites": ["example.com"]]), "off"] {
            let fixture = try ViewModelFixture()
            defer { fixture.cleanUp() }
            let viewModel = fixture.viewModel
            await waitUntil { viewModel.canConnect }
            await fixture.provider.blockNextConnection()
            viewModel.connect()
            await waitUntil { await fixture.provider.requests.count == 1 }
            viewModel.refreshSubscription(id: fixture.source.id)
            await waitUntil { await fixture.loader.requestCount == 1 }
            await fixture.loader.complete(index: 0, header: header)
            await waitUntil { !viewModel.isRefreshingSubscription(fixture.source.id) }
            await fixture.provider.finishConnection()
            await waitUntil { viewModel.isConnected && !viewModel.isOperationPending }
            try await Task.sleep(for: .milliseconds(800))
            let initialRequests = await fixture.provider.requests
            XCTAssertEqual(initialRequests.count, 1, "HTTP routing must not restart an in-flight TUN")

            viewModel.connect()
            await waitUntil { viewModel.isConnected && !viewModel.isOperationPending }
            let requests = await fixture.provider.requests
            XCTAssertEqual(requests.last?.splitTunnelPolicy.rules, viewModel.isSplitTunnelEnabled ? viewModel.splitTunnelRules : [])
            XCTAssertEqual(requests.last?.splitTunnelPolicy.defaultAction, .proxy)
            viewModel.disconnect()
            await waitUntil { viewModel.connectionState == .idle && !viewModel.isOperationPending }
        }
    }

    @MainActor
    func testImportCancelsQueuedLiveApplyButLaterManualEditsStillApply() async throws {
        let fixture = try ViewModelFixture()
        defer { fixture.cleanUp() }
        let viewModel = fixture.viewModel
        await waitUntil { viewModel.canConnect }
        viewModel.connect()
        await waitUntil { viewModel.isConnected && !viewModel.isOperationPending }
        viewModel.setSplitTunnelDefaultAction(.direct) // Queues the 0.7s live apply.
        viewModel.refreshSubscription(id: fixture.source.id)
        await waitUntil { await fixture.loader.requestCount == 1 }
        await fixture.loader.complete(index: 0, header: try link([
            "Name": "Imported", "GlobalProxy": false, "DirectSites": ["example.com"]
        ]))
        await waitUntil { !viewModel.isRefreshingSubscription(fixture.source.id) }
        try await Task.sleep(for: .milliseconds(800))
        let requestsBeforeEdit = await fixture.provider.requests
        XCTAssertEqual(requestsBeforeEdit.count, 1, "An earlier work item must not apply imported routing")
        viewModel.setSplitTunnelDefaultAction(.proxy)
        await waitUntil { await fixture.provider.requests.count == 2 && !viewModel.isOperationPending }
        let requests = await fixture.provider.requests
        XCTAssertEqual(requests.last?.splitTunnelPolicy.rules, viewModel.splitTunnelRules)
        viewModel.disconnect()
        await waitUntil { viewModel.connectionState == .idle && !viewModel.isOperationPending }
    }

    @MainActor
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for asynchronous operation", file: file, line: line)
    }

    @MainActor
    private final class ViewModelFixture {
        let root: URL
        let store: ConfigurationStore
        let source = SubscriptionSource(id: UUID(), urlString: "https://provider.invalid/sub", title: "Provider",
                                        savedAt: Date(), lastRefreshedAt: Date())
        let loader = ResponseLoader()
        let provider = RecordingProvider()
        let viewModel: AppViewModel

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-routing-\(UUID().uuidString)")
            let fileManager = TempFileManager(root: root)
            let log = TeleportLog(directoryURL: root, fileName: "test.log")
            store = ConfigurationStore(fileManager: fileManager, keychainService: "dev.x.teleport.routing-tests",
                                       keychainAccount: UUID().uuidString, log: log)
            let connection = SavedConnection(id: UUID(), configuration: try ConnectionLinkParser().parse(
                "vless://123e4567-e89b-12d3-a456-426614174000@server.invalid:443?security=tls#Manual"
            ), savedAt: Date())
            let profile = SplitTunnelProfile(name: "Manual", rules: [
                SplitTunnelRule(value: "original.example", kind: .domain, action: .direct)
            ])
            try store.save(AppSnapshot(savedConnections: [connection], subscriptionSources: [source],
                                       selectedConnectionID: connection.id, proxyEndpoint: .default,
                                       splitTunnelProfiles: [profile], isSplitTunnelEnabled: true))
            let provider = provider
            let loader = loader
            viewModel = AppViewModel(
                parser: ConnectionLinkParser(), store: store,
                connectionProviderFactory: ConnectionProviderFactory(systemProxyProvider: { provider }, tunProvider: { provider }),
                leakGuard: LeakGuardService(isEnabled: false, log: log),
                subscriptionClient: SubscriptionClient(loadResponse: { try await loader.load($0) }),
                healthProbeService: ConnectionHealthProbeService(),
                systemProxyService: SystemProxyService(fileManager: fileManager, log: log), log: log
            )
        }

        func cleanUp() {
            store.deleteStoredDataForTesting()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class TempFileManager: FileManager {
        let root: URL
        init(root: URL) { self.root = root; super.init() }
        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
        }
    }

    private actor ResponseLoader {
        var requestCount = 0
        private var pending: [Int: (URL, CheckedContinuation<(Data, URLResponse), Error>)] = [:]

        func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
            try await withCheckedThrowingContinuation { continuation in
                pending[requestCount] = (request.url!, continuation)
                requestCount += 1
            }
        }

        func complete(index: Int, header: String) {
            guard let (url, continuation) = pending.removeValue(forKey: index) else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Routing": header])!
            let body = Data("vless://123e4567-e89b-12d3-a456-426614174000@imported.invalid:443?security=tls#Imported".utf8)
            continuation.resume(returning: (body, response))
        }

        func fail(index: Int) {
            pending.removeValue(forKey: index)?.1.resume(throwing: URLError(.timedOut))
        }
    }

    private final class RecordingProvider: ConnectionProvider, @unchecked Sendable {
        private let recording = ProviderRecording()
        var requests: [ConnectionRequest] { get async { await recording.requests } }
        func currentState() async -> ConnectionState { recording.state.current() }
        func stateUpdates() -> AsyncStream<ConnectionState> { recording.state.stream() }
        func blockNextConnection() async { await recording.blockNextConnection() }
        func connect(_ request: ConnectionRequest) async throws { await recording.connect(request) }
        func finishConnection() async { await recording.finishConnection() }
        func disconnect() async throws { recording.state.update(.idle) }
    }

    private actor ProviderRecording {
        nonisolated let state = ConnectionStateStore(initialState: .idle)
        var requests: [ConnectionRequest] = []
        private var blocksNextConnection = false
        private var pending: CheckedContinuation<Void, Never>?
        func blockNextConnection() { blocksNextConnection = true }
        func connect(_ request: ConnectionRequest) async {
            requests.append(request)
            state.update(.connecting)
            if blocksNextConnection {
                blocksNextConnection = false
                await withCheckedContinuation { pending = $0 }
            }
            state.update(.connected(ConnectionSession(id: UUID(), mode: .tun, connectedAt: Date())))
        }
        func finishConnection() { pending?.resume(); pending = nil }
    }

    private func fetchResult(header: String?, body: Data? = nil) throws -> SubscriptionFetchResult {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://provider.example/sub")!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: header.map { ["RoUtInG": $0] }
        ))
        return try SubscriptionFetchResult(data: body ?? Data(server.utf8), response: response)
    }

    private func profile(from routing: SubscriptionRoutingImport?) throws -> (SplitTunnelProfile, Bool) {
        guard case let .profile(profile, activate) = routing else {
            XCTFail("Expected routing profile")
            throw NSError(domain: "SubscriptionRoutingTests", code: 1)
        }
        return (profile, activate)
    }

    private func encoded(_ fields: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]).base64EncodedString()
    }

    private func link(_ fields: [String: Any], command: String = "onadd") throws -> String {
        "happ://routing/\(command)/" + (try encoded(fields))
    }
}
