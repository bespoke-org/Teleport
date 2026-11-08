import Foundation
import XCTest

@MainActor
final class MCPTests: XCTestCase {
    func testProtocolRequiresHandshakeAndNeverExecutesNotifications() throws {
        var calls = 0
        let session = MCPProtocolSession { _ in calls += 1; return Data("{}".utf8) }
        func request(_ value: [String: Any]) throws -> [String: Any]? {
            try session.respond(to: JSONSerialization.data(withJSONObject: value)).map {
                try JSONSerialization.jsonObject(with: $0) as! [String: Any]
            }
        }
        XCTAssertNotNil(try request(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])?["error"])
        let initialized = try request(["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "unknown", "clientInfo": ["name": "test", "version": "1"], "capabilities": [:]]])
        XCTAssertEqual((initialized?["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        XCTAssertNil(try request(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertNotNil(try request(["jsonrpc": "2.0", "id": "list", "method": "tools/list"])?["result"])
        XCTAssertNil(try request(["jsonrpc": "2.0", "method": "tools/call", "params": ["name": "get_routing"]]))
        XCTAssertEqual(calls, 0)
        _ = try request(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "get_routing"]])
        XCTAssertEqual(calls, 1)
    }

    func testSchemaRejectsCoercedBooleansUnknownFieldsAndInvalidIntervals() throws {
        let tool = try XCTUnwrap(MCPTools.definitions.first { $0["name"] as? String == "update_subscription" })
        let schema = tool["inputSchema"] as! [String: Any]
        var args: [String: Any] = ["subscriptionID": UUID().uuidString, "expectedRevision": "revision", "name": "Name", "autoUpdateIntervalMinutes": NSNull(), "filterDuplicateImports": true]
        XCTAssertNoThrow(try MCPTools.validate(args, schema: schema))
        args["filterDuplicateImports"] = 1
        XCTAssertThrowsError(try MCPTools.validate(args, schema: schema))
        args["filterDuplicateImports"] = true
        args["autoUpdateIntervalMinutes"] = 0
        XCTAssertThrowsError(try MCPTools.validate(args, schema: schema))
        args["autoUpdateIntervalMinutes"] = 5
        args["unknown"] = "field"
        XCTAssertThrowsError(try MCPTools.validate(args, schema: schema))
        XCTAssertTrue(MCPTools.isMutation("update_subscription"))
        XCTAssertFalse(MCPTools.isMutation("get_routing"))
    }

    func testAuditProvesGeoIPCoverageAcrossAdjacentNetworks() {
        let audit = RoutingAudit(sites: [:], ips: [
            "telegram": .init(ranges: [([91,108,0,0], 22), ([0x20,1] + Array(repeating: 0, count: 14), 32)], reverseMatch: false),
            "blocked": .init(ranges: [([91,108,0,0], 23), ([91,108,2,0], 23), ([0x20,1] + Array(repeating: 0, count: 14), 32)], reverseMatch: false)
        ])
        let narrow = SplitTunnelRule(value: "geoip:telegram", kind: .geoip, action: .proxy)
        let broad = SplitTunnelRule(value: "geoip:blocked", kind: .geoip, action: .proxy)
        let findings = audit.findings(rules: [narrow, broad], connectionIDs: [], defaultConnectionID: nil)
        XCTAssertEqual(findings.first?["ruleID"] as? String, narrow.id.uuidString)
        XCTAssertEqual(findings.first?["removable"] as? Bool, true)
        let differentRoute = SplitTunnelRule(value: "other.example", kind: .domain, action: .direct)
        XCTAssertFalse(audit.findings(rules: [narrow, differentRoute, broad], connectionIDs: [], defaultConnectionID: nil).contains { $0["ruleID"] as? String == narrow.id.uuidString })
    }

    func testAuditDoesNotSuggestRemovingEveryEquivalentRule() {
        let audit = RoutingAudit(sites: [:], ips: [:])
        let rules = (0..<3).map { _ in SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy) }
        let findings = audit.findings(rules: rules, connectionIDs: [], defaultConnectionID: nil)
        XCTAssertEqual(findings.filter { $0["removable"] as? Bool == true }.count, 2)
    }

    func testAuditPreservesUniqueDomainsFullSemanticsAndConnectionTargets() {
        let audit = RoutingAudit(sites: [
            "blocked": [.init(type: 2, value: "claude.ai", attributes: [])],
            "anthropic": [.init(type: 2, value: "claude.ai", attributes: []), .init(type: 2, value: "claude.com", attributes: [])]
        ], ips: [:])
        let blocked = SplitTunnelRule(value: "geosite:blocked", kind: .geosite, action: .proxy)
        let anthropic = SplitTunnelRule(value: "geosite:anthropic", kind: .geosite, action: .proxy)
        XCTAssertFalse(audit.covers(blocked, anthropic))
        let exact = SplitTunnelRule(value: "full:example.com", kind: .domain, action: .proxy)
        let suffix = SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy)
        XCTAssertFalse(audit.covers(exact, suffix))
        XCTAssertTrue(audit.covers(suffix, exact))
        let connection = UUID()
        var other = suffix
        other = .init(value: suffix.value, kind: .domain, action: .proxy, connectionID: connection)
        XCTAssertEqual(audit.findings(rules: [other, suffix], connectionIDs: [connection], defaultConnectionID: UUID()).first?["removable"] as? Bool, false)
        XCTAssertEqual(audit.firstMatch(destination: "api.claude.com", rules: [blocked, anthropic])?.id, anthropic.id)
        XCTAssertNil(audit.firstMatch(destination: "notexample.com", rules: [suffix]))
    }

    func testDryRunRevisionAndAtomicProfileUpdate() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        let service = fixture.service
        let original = fixture.model.selectedSplitTunnelProfile!
        let ruleID = UUID()
        var args: [String: Any] = ["expectedRevision": service.revision, "profileID": original.id.uuidString, "name": "Edited", "defaultAction": "direct",
                                  "rules": [["id": ruleID.uuidString, "value": "EXAMPLE.COM", "action": "proxy", "isEnabled": true]]]
        let preview = try await fixture.call("update_routing_profile", args)
        XCTAssertEqual(preview["dryRun"] as? Bool, true)
        XCTAssertEqual(fixture.model.selectedSplitTunnelProfile, original)
        args["dryRun"] = false
        let result = try await fixture.call("update_routing_profile", args)
        XCTAssertEqual(result["status"] as? String, "accepted")
        XCTAssertEqual(fixture.model.splitTunnelRules.first?.id, ruleID)
        XCTAssertEqual(fixture.model.splitTunnelRules.first?.value, "example.com")
        XCTAssertEqual(fixture.model.splitTunnelDefaultAction, .direct)
        await fixture.assertFailure("update_routing_profile", args)
        XCTAssertEqual(fixture.model.splitTunnelRules.count, 1)
        args["expectedRevision"] = service.revision
        args["rules"] = [["id": UUID().uuidString, "value": "invalid://rule", "action": "proxy", "isEnabled": true]]
        await fixture.assertFailure("update_routing_profile", args)
        XCTAssertEqual(fixture.model.splitTunnelRules.first?.id, ruleID)
    }

    func testReadOnlyAndDisabledAccessRejectChangesOnAppSide() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        fixture.access = .readOnly
        _ = try await fixture.call("get_routing")
        await fixture.assertFailure("manage_routing_profile", ["operation": "create", "name": "Denied", "expectedRevision": fixture.service.revision, "dryRun": false])
        XCTAssertEqual(fixture.model.splitTunnelProfiles.count, 1)
        fixture.access = .off
        await fixture.assertFailure("get_subscriptions")
    }

    func testSubscriptionMetadataRedactsSecretsAndUpdatesWithoutReturningURL() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        let state = try await fixture.call("get_subscriptions")
        let json = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        XCTAssertFalse(json.contains("secret-token"))
        XCTAssertFalse(json.contains("private-key"))
        let args: [String: Any] = ["expectedRevision": fixture.service.revision, "subscriptionID": fixture.sourceID.uuidString, "name": "Renamed", "autoUpdateIntervalMinutes": 30, "filterDuplicateImports": false, "dryRun": false]
        _ = try await fixture.call("update_subscription", args)
        XCTAssertEqual(fixture.model.subscriptionSources.first?.title, "Renamed")
        XCTAssertEqual(fixture.model.subscriptionSources.first?.autoUpdateIntervalMinutes, 30)
        XCTAssertEqual(fixture.model.subscriptionSources.first?.urlString, "https://example.test/secret-token")
        let connection = fixture.model.savedConnections[0]
        _ = fixture.model.addSplitTunnelRule(value: "internal.example", action: .proxy, connectionID: connection.id)
        await fixture.assertFailure("remove_subscription", ["expectedRevision": fixture.service.revision, "subscriptionID": fixture.sourceID.uuidString, "dryRun": false])
        XCTAssertEqual(fixture.model.subscriptionSources.count, 1)
    }

    func testLiveRoutingRequiresExplicitReconnectAndActiveSubscriptionCannotRefresh() async throws {
        let fixture = try MCPFixture(connected: true)
        defer { fixture.cleanUp() }
        let deadline = Date().addingTimeInterval(3)
        while !fixture.model.isConnected && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(fixture.model.isConnected)
        let args: [String: Any] = ["operation": "set_enabled", "enabled": !fixture.model.isSplitTunnelEnabled, "expectedRevision": fixture.service.revision]
        let preview = try await fixture.call("manage_routing_profile", args)
        XCTAssertEqual(preview["mayReconnect"] as? Bool, true)
        let before = fixture.model.isSplitTunnelEnabled
        await fixture.assertFailure("manage_routing_profile", args.merging(["dryRun": false]) { _, new in new })
        XCTAssertEqual(fixture.model.isSplitTunnelEnabled, before)
        await fixture.assertFailure("refresh_subscription", ["subscriptionID": fixture.sourceID.uuidString, "expectedRevision": fixture.service.revision, "dryRun": false])
        XCTAssertTrue(fixture.model.refreshingSubscriptionIDs.isEmpty)
    }

    func testRefreshReturnsAcceptedThenPublishesFailureWithoutSecretErrorText() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        let result = try await fixture.call("refresh_subscription", ["subscriptionID": fixture.sourceID.uuidString, "expectedRevision": fixture.service.revision, "dryRun": false])
        XCTAssertEqual(result["status"] as? String, "accepted")
        let deadline = Date().addingTimeInterval(3)
        while !fixture.model.refreshingSubscriptionIDs.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(fixture.model.refreshingSubscriptionIDs.isEmpty)
        let state = try await fixture.call("get_subscriptions")
        let sources = try XCTUnwrap(state["subscriptions"] as? [[String: Any]])
        XCTAssertEqual(sources.first?["hasError"] as? Bool, true)
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self).contains("Offline fixture"))
    }

    func testProviderProfileIsReadOnlyUntilCustomized() async throws {
        let fixture = try MCPFixture(providerProfile: true)
        defer { fixture.cleanUp() }
        let provider = try XCTUnwrap(fixture.model.selectedSplitTunnelProfile)
        XCTAssertEqual(provider.subscriptionSourceID, fixture.sourceID)
        await fixture.assertFailure("update_routing_profile", ["profileID": provider.id.uuidString, "name": "Changed", "defaultAction": "direct", "rules": [], "expectedRevision": fixture.service.revision, "dryRun": false])
        await fixture.assertFailure("manage_routing_profile", ["operation": "rename", "profileID": provider.id.uuidString, "name": "Changed", "expectedRevision": fixture.service.revision, "dryRun": false])
        await fixture.assertFailure("manage_routing_profile", ["operation": "set_enabled", "enabled": false, "expectedRevision": fixture.service.revision, "dryRun": false])
        XCTAssertEqual(fixture.model.selectedSplitTunnelProfile, provider)
        _ = try await fixture.call("manage_routing_profile", ["operation": "customize", "expectedRevision": fixture.service.revision, "dryRun": false])
        XCTAssertTrue(fixture.model.canEditTunnelProfile)
        XCTAssertNotEqual(fixture.model.selectedSplitTunnelProfileID, provider.id)
        XCTAssertEqual(fixture.model.splitTunnelProfiles.first { $0.id == provider.id }, provider)
    }

    func testEditingActiveProfileFromAnotherTargetStillRequiresReconnectPermission() async throws {
        let fixture = try MCPFixture(connected: true, extraTarget: true)
        defer { fixture.cleanUp() }
        let deadline = Date().addingTimeInterval(3)
        while !fixture.model.isConnected && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let active = try XCTUnwrap(fixture.model.selectedSplitTunnelProfile)
        let staleRevision = fixture.service.revision
        _ = try await fixture.call("manage_routing_profile", ["operation": "select_target", "targetKind": "subscription", "targetID": fixture.otherSourceID.uuidString, "expectedRevision": staleRevision, "dryRun": false])
        XCTAssertNotEqual(fixture.model.selectedSplitTunnelProfileID, active.id)
        XCTAssertEqual(fixture.model.mcpConnectionProfileID, active.id)
        XCTAssertNotEqual(fixture.service.revision, staleRevision)
        await fixture.assertFailure("update_routing_profile", ["profileID": active.id.uuidString, "name": active.name, "defaultAction": "block", "rules": [], "expectedRevision": fixture.service.revision, "dryRun": false])
        XCTAssertEqual(fixture.model.splitTunnelProfiles.first { $0.id == active.id }, active)
    }

    func testDeletingInactiveProfilePreservesDeferredSubscriptionRouting() async throws {
        try await assertDeferredRoutingPreserved(operation: "delete")
    }

    func testSelectingAssignedProfilePreservesDeferredSubscriptionRouting() async throws {
        try await assertDeferredRoutingPreserved(operation: "select")
    }

    func testInheritingAlreadyInheritedProfilePreservesDeferredSubscriptionRouting() async throws {
        try await assertDeferredRoutingPreserved(operation: "inherit")
    }

    private func assertDeferredRoutingPreserved(operation: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["Name": "Updated provider", "DirectSites": ["new.example"]])
        let fixture = try MCPFixture(connected: true, providerProfile: true, extraTarget: true,
                                     routingHeader: "happ://routing/onadd/" + payload.base64EncodedString())
        defer { fixture.cleanUp() }
        let model = fixture.model
        let connectedDeadline = Date().addingTimeInterval(3)
        while !model.isConnected && Date() < connectedDeadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.mcpRoutingApplicationState["savedRulesMatchAcknowledgedPolicy"] as? Bool, true)

        model.performScheduledSubscriptionRefreshes()
        let refreshDeadline = Date().addingTimeInterval(3)
        while model.refreshingSubscriptionIDs.contains(fixture.sourceID) && Date() < refreshDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(model.subscriptionSources.first { $0.id == fixture.sourceID }?.lastError)
        XCTAssertEqual(model.selectedSplitTunnelProfile?.rules.first?.value, "new.example")
        XCTAssertEqual(model.mcpRoutingApplicationState["deferredSubscriptionChanges"] as? Bool, true)
        XCTAssertEqual(model.mcpRoutingApplicationState["savedRulesMatchAcknowledgedPolicy"] as? Bool, false)

        let inactive = try XCTUnwrap(model.personalTunnelProfiles.first { $0.name == "Other" })
        if operation == "select" { model.selectTunnelTarget(.subscription(fixture.otherSourceID)) }
        var arguments: [String: Any] = ["operation": operation, "expectedRevision": fixture.service.revision]
        if operation != "inherit" { arguments["profileID"] = inactive.id.uuidString }
        let preview = try await fixture.call("manage_routing_profile", arguments)
        XCTAssertEqual(preview["mayReconnect"] as? Bool, false)
        arguments["dryRun"] = false // Deliberately no allowReconnect.
        let result = try await fixture.call("manage_routing_profile", arguments)
        XCTAssertEqual(result["status"] as? String, "accepted")
        XCTAssertEqual(model.mcpRoutingApplicationState["deferredSubscriptionChanges"] as? Bool, true)
        if operation == "delete" { XCTAssertFalse(model.splitTunnelProfiles.contains { $0.id == inactive.id }) }

        // Also observe the provider beyond the 0.7 s live-apply debounce: an
        // accepted unrelated edit must neither discard deferral nor reconnect.
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(fixture.provider.connectCount, 0)
        XCTAssertEqual(fixture.provider.disconnectCount, 0)
        XCTAssertEqual(model.mcpRoutingApplicationState["deferredSubscriptionChanges"] as? Bool, true)
        XCTAssertEqual(model.mcpRoutingApplicationState["savedRulesMatchAcknowledgedPolicy"] as? Bool, false)
    }

    func testMCPRequestCrossesSocketAndReturnsModelState() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        let directory = "/tmp/teleport-mcp-e2e-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let service = fixture.service
        let server = try MCPLocalServer(directory: directory) { request in await service.handle(request) }
        defer { server.stop() }
        let reply = try await Task.detached {
            let session = MCPProtocolSession { try MCPLocalTransport.exchange($0, path: directory + "/socket") }
            _ = session.respond(to: Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","clientInfo":{"name":"test","version":"1"},"capabilities":{}}}"#.utf8))
            _ = session.respond(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            return try XCTUnwrap(session.respond(to: Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_subscriptions","arguments":{}}}"#.utf8)))
        }.value
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let state = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(state["revision"] as? String, service.revision)
        XCTAssertFalse(String(decoding: reply, as: UTF8.self).contains("secret-token"))
    }

    func testSocketRoundTripLockAndPrivatePermissions() async throws {
        let directory = "/tmp/teleport-mcp-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let server = try MCPLocalServer(directory: directory) { $0 }
        defer { server.stop() }
        XCTAssertThrowsError(try MCPLocalServer(directory: directory) { $0 })
        let payload = Data("{\"hello\":\"world\"}".utf8)
        let result = try await Task.detached { try MCPLocalTransport.exchange(payload, path: directory + "/socket") }.value
        XCTAssertEqual(result, payload)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
    }
}

@MainActor
private final class MCPFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-test-\(UUID())")
    let sourceID = UUID()
    let otherSourceID = UUID()
    let model: AppViewModel
    let store: ConfigurationStore
    let provider: MCPTestProvider
    var access = MCPAccess.readWrite
    lazy var service = TeleportMCPService(model: model, access: { [unowned self] in self.access }, loadAudit: { RoutingAudit(sites: [:], ips: [:]) })

    init(connected: Bool = false, providerProfile: Bool = false, extraTarget: Bool = false, routingHeader: String? = nil) throws {
        let manager = MCPTestFileManager(root: root)
        let log = TeleportLog(directoryURL: root, fileName: "test.log")
        store = ConfigurationStore(fileManager: manager, keychainService: "dev.x.teleport.mcp-test-\(UUID())", keychainAccount: "snapshot", log: log)
        let config = try ConnectionLinkParser().parse("vless://123e4567-e89b-12d3-a456-426614174000@127.0.0.1:9?security=none&type=tcp#Test")
        let connection = SavedConnection(id: UUID(), configuration: config, savedAt: Date(), source: .init(subscriptionSourceID: sourceID, subscriptionEntryID: config.duplicateFilterIdentity),
                                         healthCheck: .init(state: .reachable, checkedAt: Date(), latencyMilliseconds: 1, latencyKind: .tcpConnect, failureSummary: nil))
        let source = SubscriptionSource(id: sourceID, urlString: "https://example.test/secret-token", title: "Test", savedAt: Date(), autoUpdateIntervalMinutes: routingHeader == nil ? nil : 1,
                                        lastRefreshedAt: routingHeader == nil ? Date() : .distantPast)
        let personal = SplitTunnelProfile(name: "Personal", geodataSources: GeodataSources())
        let other = SplitTunnelProfile(name: "Other", geodataSources: GeodataSources())
        let provided = SplitTunnelProfile(name: "Provider", subscriptionSourceID: sourceID, geodataSources: GeodataSources())
        let otherSource = SubscriptionSource(id: otherSourceID, urlString: "https://other.test/sub", title: "Other", savedAt: Date(), lastRefreshedAt: Date())
        let profiles = [personal] + (providerProfile ? [provided] : []) + (extraTarget ? [other] : [])
        let assignments: [TunnelProfileAssignment] = extraTarget ? [.init(target: .subscription(sourceID), personalProfileID: providerProfile ? nil : personal.id), .init(target: .subscription(otherSourceID), personalProfileID: other.id)] : []
        try store.save(AppSnapshot(savedConnections: [connection], subscriptionSources: [source] + (extraTarget ? [otherSource] : []), selectedConnectionID: connection.id, proxyEndpoint: .default, connectionMode: .tun, splitTunnelProfiles: profiles, tunnelAssignments: assignments))
        provider = MCPTestProvider(connected: connected)
        let provider = self.provider
        let responseData = Data(config.rawLink.utf8)
        let responseURL = URL(string: source.urlString)!
        model = AppViewModel(parser: ConnectionLinkParser(), store: store,
                             connectionProviderFactory: .init(systemProxyProvider: { provider }, tunProvider: { provider }),
                             leakGuard: LeakGuardService(isEnabled: false, log: log),
                             subscriptionClient: SubscriptionClient(loadResponse: { _ in
                                 guard let routingHeader else { throw SubscriptionError.networkFailure("Offline fixture") }
                                 return (responseData, HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: ["routing": routingHeader])!)
                             }),
                             healthProbeService: ConnectionHealthProbeService(), systemProxyService: SystemProxyService(fileManager: manager, log: log),
                             geodataUpdateCoordinator: GeodataUpdateCoordinator(service: GeodataUpdateService(fileManager: manager)), log: log)
    }

    func call(_ name: String, _ args: [String: Any] = [:]) async throws -> [String: Any] {
        let data = await service.handle(try JSONSerialization.data(withJSONObject: ["name": name, "arguments": args]))
        let response = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if response["isError"] as? Bool == true { throw MCPFailure(String(decoding: data, as: UTF8.self)) }
        return response["structuredContent"] as! [String: Any]
    }
    func assertFailure(_ name: String, _ args: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await call(name, args); XCTFail("Expected failure", file: file, line: line) }
        catch {}
    }
    func cleanUp() {
        model.handleAppTermination {}
        store.deleteStoredDataForTesting()
        try? FileManager.default.removeItem(at: root)
    }
}

private final class MCPTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

private final class MCPTestProvider: ConnectionProvider, @unchecked Sendable {
    let state: ConnectionState
    private let lock = NSLock()
    private var connects = 0
    private var disconnects = 0
    var connectCount: Int { lock.withLock { connects } }
    var disconnectCount: Int { lock.withLock { disconnects } }
    init(connected: Bool) { state = connected ? .connected(.init(id: UUID(), mode: .tun, connectedAt: Date())) : .idle }
    func currentState() async -> ConnectionState { state }
    func stateUpdates() -> AsyncStream<ConnectionState> { AsyncStream { $0.yield(state); $0.finish() } }
    func connect(_ request: ConnectionRequest) async throws { lock.withLock { connects += 1 } }
    func disconnect() async throws { lock.withLock { disconnects += 1 } }
}
