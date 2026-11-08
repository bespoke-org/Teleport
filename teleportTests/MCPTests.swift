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
        _ = try await fixture.call("manage_routing_profile", ["operation": "set_enabled", "enabled": false, "expectedRevision": fixture.service.revision, "dryRun": false])
        XCTAssertFalse(fixture.model.isSplitTunnelEnabled, "The global switch is independent of editor ownership")
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

    func testBatchRoutesUseRequestedProfileGeodataWithoutChangingSelection() async throws {
        let fixture = try MCPFixture(extraTarget: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        var first = try XCTUnwrap(model.selectedSplitTunnelProfile)
        var second = try XCTUnwrap(model.personalTunnelProfiles.first { $0.id != first.id })
        first.rules = [.init(value: "geosite:test", kind: .geosite, action: .direct),
                       .init(value: "192.0.2.0/24", kind: .ip, action: .block)]
        second.rules = [.init(value: "geosite:test", kind: .geosite, action: .direct),
                        .init(value: "192.0.2.0/24", kind: .ip, action: .block)]
        model.replaceSplitTunnelProfile(first)
        model.replaceSplitTunnelProfile(second)
        let firstID = first.id
        var loaded: [UUID] = []
        fixture.auditLoader = { profile in
            loaded.append(profile.id)
            return RoutingAudit(sites: ["test": [.init(type: 2, value: profile.id == firstID ? "first.example" : "second.example", attributes: [])]], ips: [:])
        }
        fixture.access = .readOnly
        let selection = model.selectedSplitTunnelProfileID
        let revision = fixture.service.revision
        let result = try await fixture.call("explain_routes", ["destinations": ["FIRST.EXAMPLE", "second.example", "192.0.2.1", "unknown.example"],
            "profileID": second.id.uuidString])
        let routes = try XCTUnwrap(result["routes"] as? [[String: Any]])
        XCTAssertEqual(routes.compactMap { $0["action"] as? String }, ["proxy", "direct", "block", "proxy"])
        XCTAssertEqual(routes.compactMap { $0["destination"] as? String }, ["first.example", "second.example", "192.0.2.1", "unknown.example"])
        XCTAssertEqual((routes[1]["rule"] as? [String: Any])?["id"] as? String, second.rules[0].id.uuidString)
        XCTAssertEqual(routes[0]["connectionID"] as? String, model.selectedConnectionID?.uuidString)
        XCTAssertEqual(routes[0]["connectionName"] as? String, model.selectedConnection?.displayName)
        XCTAssertTrue(routes[1]["connectionID"] is NSNull)
        XCTAssertEqual(loaded, [second.id])
        XCTAssertEqual(model.selectedSplitTunnelProfileID, selection)
        XCTAssertEqual(fixture.service.revision, revision)
    }

    func testCreatingAndCopyingProfilesDoesNotAssignOrReconnect() async throws {
        let fixture = try MCPFixture(connected: true, providerProfile: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        await awaitUIUpdate("The existing session is adopted") { model.isConnected }
        let assignments = model.tunnelAssignments
        let activeID = model.mcpConnectionProfileID
        for args: [String: Any] in [["operation": "customize"], ["operation": "create", "name": "Work"]] {
            var arguments = args
            arguments["expectedRevision"] = fixture.service.revision
            let preview = try await fixture.call("manage_routing_profile", arguments)
            XCTAssertEqual(preview["mayReconnect"] as? Bool, false)
            arguments["dryRun"] = false
            _ = try await fixture.call("manage_routing_profile", arguments)
            XCTAssertEqual(model.tunnelAssignments, assignments)
            XCTAssertEqual(model.mcpConnectionProfileID, activeID)
            XCTAssertNotEqual(model.selectedSplitTunnelProfileID, activeID)
        }
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertEqual(fixture.provider.connectCount, 0)
        XCTAssertEqual(fixture.provider.disconnectCount, 0)
    }

    func testActiveProfileUpdateAppliesWhileAnotherProfileIsOpen() async throws {
        let fixture = try MCPFixture(connected: true, extraTarget: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        await awaitUIUpdate("The existing session is adopted") { model.isConnected }
        let active = try XCTUnwrap(model.selectedSplitTunnelProfile)
        let other = try XCTUnwrap(model.personalTunnelProfiles.first { $0.id != active.id })
        model.openSplitTunnelProfile(id: other.id)
        _ = try await fixture.call("update_routing_profile", ["profileID": active.id.uuidString,
            "name": active.name, "defaultAction": "block", "rules": [], "expectedRevision": fixture.service.revision,
            "dryRun": false, "allowReconnect": true])
        await awaitUIUpdate("The changed active policy reconnects") { fixture.provider.connectCount == 1 }
        XCTAssertEqual(model.selectedSplitTunnelProfileID, other.id)
        XCTAssertEqual(model.mcpConnectionProfileID, active.id)
        XCTAssertEqual(model.splitTunnelProfiles.first { $0.id == active.id }?.defaultAction, .block)
    }

    func testAssignmentRequiresConsentAndDoesNotFollowTheOpenProfile() async throws {
        let fixture = try MCPFixture(connected: true, extraTarget: true)
        defer { fixture.cleanUp() }
        let model = fixture.model
        await awaitUIUpdate("The existing session is adopted") { model.isConnected }
        _ = try await fixture.call("manage_routing_profile", ["operation": "select_target", "targetKind": "subscription",
            "targetID": fixture.sourceID.uuidString, "expectedRevision": fixture.service.revision, "dryRun": false])
        let other = try XCTUnwrap(model.personalTunnelProfiles.first { $0.name == "Other" })
        model.openSplitTunnelProfile(id: other.id)
        var args: [String: Any] = ["operation": "select", "profileID": other.id.uuidString,
            "expectedRevision": fixture.service.revision]
        let preview = try await fixture.call("manage_routing_profile", args)
        XCTAssertEqual(preview["mayReconnect"] as? Bool, true,
                       "An open profile is not necessarily assigned to the active portal")
        args["dryRun"] = false
        await fixture.assertFailure("manage_routing_profile", args)
        XCTAssertNotEqual(model.mcpConnectionProfileID, other.id)
        args["allowReconnect"] = true
        _ = try await fixture.call("manage_routing_profile", args)
        XCTAssertEqual(model.mcpConnectionProfileID, other.id)
        XCTAssertEqual(model.selectedSplitTunnelProfileID, other.id)
    }

    func testAuditLoaderReadsRequestedProfileCacheInsteadOfEditorData() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        let service = GeodataUpdateService(fileManager: MCPTestFileManager(root: fixture.root))
        func field(_ tag: UInt8, _ bytes: Data) -> Data { Data([tag, UInt8(bytes.count)]) + bytes }
        let rule = SplitTunnelRule(value: "geosite:test", kind: .geosite, action: .direct)
        for domain in ["first.example", "second.example"] {
            var profile = try XCTUnwrap(fixture.model.selectedSplitTunnelProfile)
            let siteURL = URL(string: "https://" + domain + "/geosite.dat")!
            let ipURL = URL(string: "https://" + domain + "/geoip.dat")!
            profile.geodataSources = .init(geositeURLString: siteURL.absoluteString, geoipURLString: ipURL.absoluteString)
            let domainEntry = Data([8, 2]) + field(18, Data(domain.utf8))
            let site = field(10, field(10, Data("test".utf8)) + field(18, domainEntry))
            let cidr = field(10, Data([192, 0, 2, 0])) + Data([16, 24])
            let ip = field(10, field(10, Data("test".utf8)) + field(18, cidr))
            try service.cacheDownload(.init(data: site, updatedAt: Date()), for: .geosite, source: siteURL)
            try service.cacheDownload(.init(data: ip, updatedAt: Date()), for: .geoip, source: ipURL)
            let audit = try await fixture.model.mcpLoadRoutingAudit(profile: profile)
            XCTAssertNotNil(audit.firstMatch(destination: domain, rules: [rule]))
            XCTAssertNil(audit.firstMatch(destination: domain == "first.example" ? "second.example" : "first.example", rules: [rule]))
        }
    }

    func testBatchRoutesValidateInputsAndMissingCategories() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        for destinations in [[], Array(repeating: "example.com", count: 101), ["192.0.2.0/24"], ["https://example.com"], ["full:example.com"], ["FULL:example.com"]] {
            await fixture.assertFailure("explain_routes", ["destinations": destinations])
        }
        await fixture.assertFailure("explain_routes", ["destinations": ["example.com"], "compareToProfileID": UUID().uuidString])
        var profile = try XCTUnwrap(fixture.model.selectedSplitTunnelProfile)
        profile.rules = [.init(value: "geosite:missing", kind: .geosite, action: .direct)]
        fixture.model.replaceSplitTunnelProfile(profile)
        await fixture.assertFailure("explain_routes", ["destinations": ["example.com"]])
        fixture.model.setSplitTunnelEnabled(false)
        await fixture.assertFailure("explain_routes", ["destinations": ["example.com"]])
        profile.rules = [.init(value: "example.com", kind: .domain, action: .direct)]
        fixture.model.replaceSplitTunnelProfile(profile)
        let preview = try await fixture.call("explain_routes", ["destinations": ["example.com"]])
        XCTAssertEqual((preview["routes"] as? [[String: Any]])?.first?["action"] as? String, "direct",
                       "Route analysis previews the profile even while global routing is off")
    }

    func testAnalysisRejectsStateChangesWhileLoadingGeodata() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        fixture.auditLoader = { profile in
            fixture.model.renameSplitTunnelProfile(id: profile.id, name: "Changed during load")
            return RoutingAudit(sites: [:], ips: [:])
        }
        await fixture.assertFailure("explain_routes", ["destinations": ["example.com"]])
        fixture.auditLoader = { _ in
            fixture.access = .off
            return RoutingAudit(sites: [:], ips: [:])
        }
        await fixture.assertFailure("get_geodata", ["includeCategories": true])
    }

    func testGeodataCategoriesAreSearchableAndPaginated() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        fixture.access = .readOnly
        fixture.auditLoader = { _ in RoutingAudit(sites: ["test-b": [], "test-a": [], "other": []],
                                                  ips: ["test": .init(ranges: [], reverseMatch: false)]) }
        let result = try await fixture.call("get_geodata", ["includeCategories": true, "kind": "geosite", "query": "TEST", "limit": 1])
        XCTAssertEqual(result["categories"] as? [String], ["geosite:test-a"])
        XCTAssertEqual(result["totalCategories"] as? Int, 2)
        XCTAssertEqual(result["nextOffset"] as? Int, 1)
        let next = try await fixture.call("get_geodata", ["includeCategories": true, "kind": "geosite", "query": "test", "offset": 1, "limit": 1])
        XCTAssertEqual(next["categories"] as? [String], ["geosite:test-b"])
        XCTAssertTrue(next["nextOffset"] is NSNull)
        await fixture.assertFailure("get_geodata", ["limit": 0])
        await fixture.assertFailure("get_geodata", ["offset": -1])
    }

    func testGeodataRefreshChecksConsentAndReportsRedactedFailure() async throws {
        let fixture = try MCPFixture(connected: true)
        defer { fixture.cleanUp() }
        let deadline = Date().addingTimeInterval(3)
        while !fixture.model.isConnected && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        var profile = try XCTUnwrap(fixture.model.selectedSplitTunnelProfile)
        profile.geodataSources = .init(geositeURLString: "https://data.example/private-token?key=secret")
        fixture.model.replaceSplitTunnelProfile(profile)
        let state = try await fixture.call("get_geodata")
        XCTAssertEqual((state["sources"] as? [[String: Any]])?.first?["host"] as? String, "data.example")
        XCTAssertFalse(String(describing: state).contains("private-token"))
        await fixture.assertFailure("get_geodata", ["includeCategories": true])
        var args: [String: Any] = ["expectedRevision": fixture.service.revision]
        let preview = try await fixture.call("refresh_geodata", args)
        XCTAssertEqual(preview["mayReconnect"] as? Bool, true)
        XCTAssertEqual(fixture.geodataService.requestCount, 0)
        args["dryRun"] = false
        await fixture.assertFailure("refresh_geodata", args)
        args["allowReconnect"] = true
        fixture.access = .readOnly
        await fixture.assertFailure("refresh_geodata", args)
        fixture.access = .readWrite
        args["expectedRevision"] = "stale"
        await fixture.assertFailure("refresh_geodata", args)
        XCTAssertEqual(fixture.geodataService.requestCount, 0)
        args["expectedRevision"] = fixture.service.revision
        let accepted = try await fixture.call("refresh_geodata", args)
        XCTAssertEqual(accepted["status"] as? String, "accepted")
        let finish = Date().addingTimeInterval(3)
        while !fixture.model.updatingSelectedProfileGeodataKinds.isEmpty && Date() < finish { try await Task.sleep(for: .milliseconds(5)) }
        let failed = try await fixture.call("get_geodata")
        XCTAssertEqual((failed["sources"] as? [[String: Any]])?.first?["status"] as? String, "failed")
        XCTAssertEqual(fixture.geodataService.requestCount, 1)
        XCTAssertFalse(String(describing: failed).contains("private-token"))
        XCTAssertFalse(String(describing: failed).contains("secret"))
        XCTAssertEqual(fixture.provider.connectCount, 0)
    }

    func testGeodataRefreshPublishesReadyStateAndReconnectsOnce() async throws {
        let fixture = try MCPFixture(connected: true)
        defer { fixture.cleanUp() }
        let deadline = Date().addingTimeInterval(3)
        while !fixture.model.isConnected && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        var profile = try XCTUnwrap(fixture.model.selectedSplitTunnelProfile)
        profile.geodataSources = .init(geositeURLString: "https://data.example/site.dat", geoipURLString: "https://data.example/ip.dat")
        fixture.model.replaceSplitTunnelProfile(profile)
        fixture.geodataService.succeed = true
        _ = try await fixture.call("refresh_geodata", ["expectedRevision": fixture.service.revision, "dryRun": false, "allowReconnect": true])
        let finish = Date().addingTimeInterval(3)
        while (fixture.model.updatingSelectedProfileGeodataKinds.isEmpty == false || fixture.provider.connectCount == 0) && Date() < finish {
            try await Task.sleep(for: .milliseconds(5))
        }
        let result = try await fixture.call("get_geodata")
        XCTAssertEqual((result["sources"] as? [[String: Any]])?.compactMap { $0["status"] as? String }, ["ready", "ready"])
        XCTAssertEqual(fixture.geodataService.requestCount, 2)
        XCTAssertEqual(fixture.provider.connectCount, 1)
    }

    func testBundledGeodataAndAbsentDeferredPolicyAreNotAcceptedAsUpdates() async throws {
        let fixture = try MCPFixture()
        defer { fixture.cleanUp() }
        await fixture.assertFailure("refresh_geodata", ["expectedRevision": fixture.service.revision])
        await fixture.assertFailure("apply_pending_routing", ["expectedRevision": fixture.service.revision, "dryRun": false, "allowReconnect": true])
    }

    func testApplyPendingRoutingRequiresConsentAndResumesDeferredPolicy() async throws {
        try await assertDeferredRoutingPreserved(operation: "apply_pending")
    }

    func testGeodataRefreshPreservesDeferredSubscriptionRouting() async throws {
        try await assertDeferredRoutingPreserved(operation: "refresh_geodata")
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
        var routing: [String: Any] = ["Name": "Updated provider", "DirectSites": ["new.example"]]
        if operation == "refresh_geodata" { routing["Geositeurl"] = "https://data.example/site.dat" }
        let payload = try JSONSerialization.data(withJSONObject: routing)
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

        if operation == "refresh_geodata" {
            let finishImport = Date().addingTimeInterval(3)
            while !model.updatingSelectedProfileGeodataKinds.isEmpty && Date() < finishImport { try await Task.sleep(for: .milliseconds(5)) }
            fixture.geodataService.succeed = true
            _ = try await fixture.call("refresh_geodata", ["expectedRevision": fixture.service.revision, "dryRun": false, "allowReconnect": true])
            let finishRefresh = Date().addingTimeInterval(3)
            while !model.updatingSelectedProfileGeodataKinds.isEmpty && Date() < finishRefresh { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(model.mcpRoutingApplicationState["deferredSubscriptionChanges"] as? Bool, true)
            XCTAssertEqual(fixture.provider.connectCount, 0)
            XCTAssertEqual(fixture.provider.disconnectCount, 0)
            let state = try await fixture.call("get_geodata")
            XCTAssertEqual((state["sources"] as? [[String: Any]])?.first?["status"] as? String, "ready")
            return
        }

        if operation == "apply_pending" {
            var arguments: [String: Any] = ["expectedRevision": fixture.service.revision]
            let preview = try await fixture.call("apply_pending_routing", arguments)
            XCTAssertEqual(preview["mayReconnect"] as? Bool, true)
            XCTAssertEqual(model.mcpRoutingApplicationState["deferredSubscriptionChanges"] as? Bool, true)
            arguments["dryRun"] = false
            await fixture.assertFailure("apply_pending_routing", arguments)
            XCTAssertEqual(model.mcpRoutingApplicationState["deferredSubscriptionChanges"] as? Bool, true)
            arguments["allowReconnect"] = true
            fixture.access = .readOnly
            await fixture.assertFailure("apply_pending_routing", arguments)
            fixture.access = .readWrite
            let accepted = try await fixture.call("apply_pending_routing", arguments)
            XCTAssertEqual(accepted["status"] as? String, "accepted")
            XCTAssertEqual(model.mcpRoutingApplicationState["operationPending"] as? Bool, true)
            XCTAssertEqual(model.mcpRoutingApplicationState["deferredSubscriptionChanges"] as? Bool, false)
            await fixture.assertFailure("apply_pending_routing", arguments)
            try await Task.sleep(for: .milliseconds(1000))
            XCTAssertEqual(fixture.provider.connectCount, 1)
            XCTAssertEqual(model.mcpRoutingApplicationState["liveApplyPending"] as? Bool, false)
            XCTAssertEqual(model.mcpRoutingApplicationState["savedRulesMatchAcknowledgedPolicy"] as? Bool, true)
            XCTAssertEqual(model.mcpRoutingApplicationState["savedGeodataSourcesMatchAcknowledgedPolicy"] as? Bool, true)
            return
        }

        let inactive = try XCTUnwrap(model.personalTunnelProfiles.first { $0.name == "Other" })
        if operation == "select" {
            _ = try await fixture.call("manage_routing_profile", ["operation": "select_target", "targetKind": "subscription",
                "targetID": fixture.otherSourceID.uuidString, "expectedRevision": fixture.service.revision, "dryRun": false])
        }
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
    let geodataService = MCPTestGeodataService()
    var auditLoader: (SplitTunnelProfile) async throws -> RoutingAudit = { _ in RoutingAudit(sites: [:], ips: [:]) }
    lazy var service = TeleportMCPService(model: model, access: { [unowned self] in self.access }, loadAudit: { [unowned self] in try await self.auditLoader($0) })

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
        try store.save(AppSnapshot(savedConnections: [connection], subscriptionSources: [source] + (extraTarget ? [otherSource] : []), selectedConnectionID: connection.id, proxyEndpoint: .default, connectionMode: .tun, splitTunnelProfiles: profiles, selectedSplitTunnelProfileID: providerProfile ? provided.id : personal.id, isSplitTunnelEnabled: true, tunnelAssignments: assignments))
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
                             geodataUpdateCoordinator: GeodataUpdateCoordinator(service: geodataService), log: log)
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
    private var state: ConnectionState
    private let lock = NSLock()
    private var connects = 0
    private var disconnects = 0
    private var subscribers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    var connectCount: Int { lock.withLock { connects } }
    var disconnectCount: Int { lock.withLock { disconnects } }
    init(connected: Bool) { state = connected ? .connected(.init(id: UUID(), mode: .tun, connectedAt: Date())) : .idle }
    func currentState() async -> ConnectionState { lock.withLock { state } }
    func stateUpdates() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            let initial = lock.withLock { subscribers[id] = continuation; return state }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.subscribers.removeValue(forKey: id) }
            }
        }
    }
    func connect(_ request: ConnectionRequest) async throws {
        lock.withLock { connects += 1 }
        publish(.connected(.init(id: UUID(), mode: .tun, connectedAt: Date())))
    }
    func disconnect() async throws {
        lock.withLock { disconnects += 1 }
        publish(.idle)
    }
    private func publish(_ value: ConnectionState) {
        let observers = lock.withLock { state = value; return Array(subscribers.values) }
        observers.forEach { $0.yield(value) }
    }
}

nonisolated private final class MCPTestGeodataService: GeodataUpdateServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var success = false
    private var activated = Set<GeodataKind>()
    var succeed: Bool {
        get { lock.withLock { success } }
        set { lock.withLock { success = newValue } }
    }
    var requestCount: Int { lock.withLock { requests } }
    func cacheCurrentDownload(for kind: GeodataKind, source: URL?, updatedAt: Date?) throws {}
    func prepareUpdate(kind: GeodataKind, from source: URL, useCache: Bool) async throws -> GeodataUpdateService.PreparedUpdate {
        lock.withLock { requests += 1 }
        if succeed { return .init(stagedURL: URL(fileURLWithPath: "/unused-mcp-test-staging"), updatedAt: Date(), changed: true) }
        throw GeodataUpdateError.networkFailure("Failed https://data.example/private-token?key=secret")
    }
    func activate(_ update: GeodataUpdateService.PreparedUpdate, for kind: GeodataKind) throws { _ = lock.withLock { activated.insert(kind) } }
    func discard(_ update: GeodataUpdateService.PreparedUpdate) {}
    func hasCustomGeodata(for kind: GeodataKind) -> Bool { lock.withLock { activated.contains(kind) } }
    func removeCustomGeodata(for kind: GeodataKind) throws {}
}
