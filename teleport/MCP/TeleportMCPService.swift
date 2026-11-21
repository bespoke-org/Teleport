import CryptoKit
import Foundation

@MainActor
final class TeleportMCPService {
    private let model: AppViewModel
    private let access: () -> MCPAccess
    // The legacy MCP assignment cursor is independent of the profile document
    // open in Routing. UI navigation must never change its assignment target.
    private var assignmentTarget: TunnelTarget?
    private var selectedTarget: TunnelTarget? {
        if let assignmentTarget, model.tunnelTargets.contains(assignmentTarget) { return assignmentTarget }
        return model.selectedConnection.map(TunnelTarget.init(connection:)) ?? model.tunnelTargets.first
    }
    private let loadAudit: (SplitTunnelProfile) async throws -> RoutingAudit

    init(model: AppViewModel, access: @escaping () -> MCPAccess,
         loadAudit: ((SplitTunnelProfile) async throws -> RoutingAudit)? = nil) {
        self.model = model
        self.access = access
        self.loadAudit = loadAudit ?? { try await model.mcpLoadRoutingAudit(profile: $0) }
    }

    func handle(_ data: Data) async -> Data {
        let response: [String: Any]
        do {
            guard !Task.isCancelled, access() != .off else { throw MCPFailure("MCP access is disabled") }
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = request["name"] as? String,
                  let tool = MCPTools.definitions.first(where: { $0["name"] as? String == name }),
                  let arguments = request["arguments"] as? [String: Any] else { throw MCPFailure("Invalid tool request") }
            try MCPTools.validate(arguments, schema: tool["inputSchema"] as! [String: Any])
            if MCPTools.isMutation(name) {
                guard access() == .readWrite else { throw MCPFailure("Enable Read and edit MCP access in Teleport first") }
                guard arguments["expectedRevision"] as? String == revision else { throw MCPFailure("State changed. Read it again and prepare a new change.") }
            }
            response = MCPProtocolSession.toolResult(try await execute(name, arguments))
        } catch {
            // Model/network errors can contain secret subscription URLs. Only our
            // deliberately public validation errors may cross the MCP boundary.
            response = MCPProtocolSession.toolError((error as? MCPFailure)?.message ?? "Operation failed. See Teleport for details.")
        }
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    var revision: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = (try? encoder.encode(model.splitTunnelProfiles)) ?? Data()
        data.append((try? encoder.encode(model.subscriptionSources)) ?? Data())
        data.append((try? encoder.encode(model.geodataSettings)) ?? Data())
        data.append((try? encoder.encode(model.tunnelAssignments)) ?? Data())
        data.append((try? encoder.encode(selectedTarget)) ?? Data())
        data.append((try? encoder.encode(model.mcpGeodataRevision)) ?? Data())
        data.append((try? encoder.encode(model.savedConnections)) ?? Data())
        data.append((try? JSONSerialization.data(withJSONObject: model.mcpRoutingApplicationState, options: [.sortedKeys])) ?? Data())
        data.append(Data("\(model.connectionMode.rawValue)|\(model.selectedSplitTunnelProfileID?.uuidString ?? "")|\(model.isSplitTunnelEnabled)|\(model.selectedConnectionID?.uuidString ?? "")".utf8))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let value = args[key] as? String, let id = UUID(uuidString: value) else { throw MCPFailure("Expected a UUID in \(key)") }
        return id
    }
    private func profile(_ args: [String: Any]) throws -> SplitTunnelProfile {
        let id = try uuid(args, "profileID")
        guard let profile = model.splitTunnelProfiles.first(where: { $0.id == id }) else { throw MCPFailure("Profile not found") }
        return profile
    }
    private func analysisProfile(_ args: [String: Any]) throws -> SplitTunnelProfile {
        if args["profileID"] != nil { return try profile(args) }
        guard let selected = model.selectedSplitTunnelProfile else { throw MCPFailure("Select a routing profile first") }
        return selected
    }

    private func requireGeodataReady(_ profile: SplitTunnelProfile) throws {
        for kind in GeodataKind.allCases {
            switch model.mcpGeodataStatus(kind: kind, profile: profile) {
            case .bundled, .ready: continue
            default: throw MCPFailure("Profile geodata is not ready. Inspect get_geodata and finish its download in Teleport.")
            }
        }
    }

    private func checkAnalysisRevision(_ expected: String) throws {
        guard !Task.isCancelled, access() != .off, revision == expected else {
            throw MCPFailure("State changed during analysis. Read state and retry.")
        }
    }

    private func destination(_ value: String) throws -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case let .success(classified) = SplitTunnelRuleClassifier.classify(text),
              classified.kind == .domain || (classified.kind == .ip && !text.contains("/")), !classified.value.hasPrefix("full:") else {
            throw MCPFailure("Expected a hostname or IP literal, without a URL, prefix or CIDR")
        }
        return classified.value
    }

    private func routes(_ destinations: [String], profile: SplitTunnelProfile, audit: RoutingAudit, revision expected: String) async throws -> [[String: Any]] {
        let profileEnabled = profile.subscriptionSourceID == nil || profile.isRoutingEnabled
        // Category matching can be expensive; a batch must not block the app UI.
        let matches = try await Task.detached(priority: .utility) {
            guard !profileEnabled || !profile.rules.contains(where: { $0.isEnabled && audit.missingCategory($0) }) else {
                throw MCPFailure("A referenced geodata category is missing; the route cannot be previewed reliably")
            }
            let deadline = Date().addingTimeInterval(5)
            return try destinations.map { destination -> SplitTunnelRule? in
                guard !Task.isCancelled, Date() < deadline else { throw MCPFailure("Route analysis work limit reached. Retry with fewer destinations.") }
                return profileEnabled ? audit.firstMatch(destination: destination, rules: profile.rules) : nil
            }
        }.value
        try checkAnalysisRevision(expected)
        return zip(destinations, matches).map { destination, rule in
            let action = rule?.action ?? (profileEnabled ? profile.defaultAction : .proxy)
            let connectionID = rule?.connectionID.flatMap { id in model.savedConnections.contains { $0.id == id } ? id : nil } ?? model.selectedConnectionID
            let connection = action == .proxy ? model.savedConnections.first { $0.id == connectionID } : nil
            return ["destination": destination, "action": action.rawValue, "rule": rule.map(ruleJSON) as Any? ?? NSNull(),
                    "connectionID": connection?.id.uuidString as Any? ?? NSNull(),
                    "connectionName": connection?.displayName as Any? ?? NSNull()]
        }
    }

    private func subscription(_ args: [String: Any]) throws -> SubscriptionSource {
        let id = try uuid(args, "subscriptionID")
        guard let source = model.subscriptionSources.first(where: { $0.id == id }) else { throw MCPFailure("Subscription not found") }
        return source
    }
    private func checkSubscriptionAvailable(_ source: SubscriptionSource) throws {
        guard !model.importedConnections(for: source.id).contains(where: { model.isConnectionInUse(id: $0.id) }) else {
            throw MCPFailure("Disconnect before changing or refreshing the active subscription")
        }
        guard !model.refreshingSubscriptionIDs.contains(source.id) else { throw MCPFailure("Subscription refresh is already in progress") }
    }
    private func subscriptionURL(_ value: String, excluding id: UUID? = nil) throws -> String {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { throw MCPFailure("Expected an HTTP(S) subscription URL") }
        guard !model.subscriptionSources.contains(where: { $0.id != id && $0.urlString.caseInsensitiveCompare(url.absoluteString) == .orderedSame }) else {
            throw MCPFailure("Subscription URL is already present")
        }
        return url.absoluteString
    }
    private func checkReferencesToSubscription(_ source: SubscriptionSource) throws {
        let ids = Set(model.importedConnections(for: source.id).map(\.id))
        guard !model.splitTunnelProfiles.contains(where: { $0.rules.contains(where: { $0.connectionID.map(ids.contains) == true }) }) else {
            throw MCPFailure("Routing rules reference this subscription's portals. Update those rules first.")
        }
    }
    private func apply(_ args: [String: Any], affectsRouting: Bool = false, preview: [String: Any], operation: () throws -> Void) throws -> [String: Any] {
        let reconnect = affectsRouting && model.connectionMode == .tun && model.hasActiveConnectionSession
        if args["dryRun"] as? Bool != false {
            return ["dryRun": true, "revision": revision, "mayReconnect": reconnect, "change": preview]
        }
        guard !reconnect || args["allowReconnect"] as? Bool == true else { throw MCPFailure("This change may reconnect the VPN. Preview it, then explicitly set allowReconnect:true.") }
        try operation()
        return ["status": "accepted", "revision": revision, "mayReconnect": reconnect,
                "note": "Accepted into app state. Persistence, routing application and subscription downloads may still be pending."]
    }

    private func execute(_ name: String, _ args: [String: Any]) async throws -> [String: Any] {
        switch name {
        case "get_routing":
            return ["revision": revision, "enabled": model.isSplitTunnelEnabled,
                    "selectedProfileID": model.selectedSplitTunnelProfileID?.uuidString as Any? ?? NSNull(),
                    "connected": model.isConnected, "mode": model.connectionMode.rawValue,
                    "connectionProfileID": model.mcpConnectionProfileID?.uuidString as Any? ?? NSNull(),
                    "selectedTarget": selectedTarget.map(targetJSON) as Any? ?? NSNull(),
                    "targets": model.tunnelTargets.map { target in
                        var value = targetJSON(target)
                        value["name"] = model.tunnelTargetName(target)
                        value["personalProfileID"] = model.tunnelAssignments.first { $0.target == target }?.personalProfileID?.uuidString as Any? ?? NSNull()
                        return value
                    },
                    "application": model.mcpRoutingApplicationState,
                    "profiles": model.splitTunnelProfiles.map { profile in
                        ["id": profile.id.uuidString, "name": profile.name, "defaultAction": profile.defaultAction.rawValue,
                         "enabled": profile.subscriptionSourceID == nil || profile.isRoutingEnabled, "editable": profile.subscriptionSourceID == nil,
                         "subscriptionSourceID": profile.subscriptionSourceID?.uuidString as Any? ?? NSNull(),
                         "geodata": ["geositeHost": profile.geodataSources?.geositeURLString.flatMap { URL(string: $0)?.host } as Any? ?? NSNull(),
                                     "geoipHost": profile.geodataSources?.geoipURLString.flatMap { URL(string: $0)?.host } as Any? ?? NSNull()],
                         "rules": profile.rules.map(ruleJSON)] as [String: Any]
                    }]
        case "get_connections":
            return ["revision": revision, "selectedConnectionID": model.selectedConnectionID?.uuidString as Any? ?? NSNull(),
                    "connections": model.savedConnections.map { connection in
                        ["id": connection.id.uuidString, "name": connection.displayName,
                         "subscriptionID": connection.source?.subscriptionSourceID.uuidString as Any? ?? NSNull(),
                         "inUse": model.isConnectionInUse(id: connection.id)] as [String: Any]
                    }]
        case "get_subscriptions":
            return ["revision": revision, "subscriptions": model.subscriptionSources.map { source in
                ["id": source.id.uuidString, "name": source.title, "host": URL(string: source.urlString)?.host as Any? ?? NSNull(),
                 "refreshing": model.refreshingSubscriptionIDs.contains(source.id), "hasError": source.lastError != nil,
                 "lastRefreshedAt": source.lastRefreshedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
                 "autoUpdateIntervalMinutes": source.autoUpdateIntervalMinutes as Any? ?? NSNull(),
                 "filterDuplicateImports": source.filterDuplicateImports, "lastSkippedCount": source.lastSkippedCount,
                 "portalIDs": model.importedConnections(for: source.id).map { $0.id.uuidString }] as [String: Any]
            }]
        case "explain_route", "explain_routes", "audit_routing":
            let selected = try analysisProfile(args)
            let destinations = try (args["destinations"] as? [String] ?? (args["destination"] as? String).map { [$0] } ?? []).map(destination)
            let startingRevision = revision
            try requireGeodataReady(selected)
            let audit = try await loadAudit(selected)
            try checkAnalysisRevision(startingRevision)
            if name == "audit_routing" {
                let connections = Set(model.savedConnections.map(\.id))
                let defaultConnection = model.selectedConnectionID
                let result = try await Task.detached(priority: .utility) {
                    try JSONSerialization.data(withJSONObject: audit.findings(rules: selected.rules, connectionIDs: connections, defaultConnectionID: defaultConnection))
                }.value
                try checkAnalysisRevision(startingRevision)
                return ["revision": revision, "profileID": selected.id.uuidString,
                        "findings": try JSONSerialization.jsonObject(with: result),
                        "scope": "Saved selected profile and current local geodata. Pairwise containment; regex inclusion is conservative. Different destinations may still share an IP. This does not inspect live flows."]
            }
            let routes = try await routes(destinations, profile: selected, audit: audit, revision: startingRevision)
            let scope = "Saved profile and its local geodata only; no DNS lookup, sniffing or built-in Xray rules. System proxy inbounds always use the default proxy."
            if name == "explain_route" {
                return routes[0].merging(["revision": revision, "preview": true, "scope": scope]) { a, _ in a }
            }
            return ["revision": revision, "preview": true, "profileID": selected.id.uuidString,
                    "routes": routes, "scope": scope]
        case "get_geodata":
            let selected = try analysisProfile(args)
            let startingRevision = revision
            let sources = selected.geodataSources ?? GeodataSources()
            var result: [String: Any] = ["revision": revision, "profileID": selected.id.uuidString,
                "sources": GeodataKind.allCases.map { kind -> [String: Any] in
                    let url = kind == .geosite ? sources.geositeURLString : sources.geoipURLString
                    let status: String
                    var updatedAt: Date?
                    switch model.mcpGeodataStatus(kind: kind, profile: selected) {
                    case .bundled: status = "bundled"
                    case .missing: status = "missing"
                    case .loading: status = "loading"
                    case .failed: status = "failed"
                    case let .ready(date): status = "ready"; updatedAt = date
                    }
                    return ["kind": kind.rawValue, "host": url.flatMap { URL(string: $0)?.host } as Any? ?? NSNull(),
                            "status": status, "lastUpdatedAt": updatedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
                }]
            if args["includeCategories"] as? Bool == true {
                try requireGeodataReady(selected)
                let audit = try await loadAudit(selected)
                try checkAnalysisRevision(startingRevision)
                let kind = args["kind"] as? String
                let query = (args["query"] as? String ?? "").lowercased()
                let entries = (kind == "geoip" ? [] : audit.sites.keys.map { "geosite:" + $0 })
                    + (kind == "geosite" ? [] : audit.ips.keys.map { "geoip:" + $0 })
                let matches = entries.filter { query.isEmpty || $0.lowercased().contains(query) }.sorted()
                let offset = args["offset"] as? Int ?? 0, limit = args["limit"] as? Int ?? 100
                let page = Array(matches.dropFirst(offset).prefix(limit))
                result["categories"] = page
                result["totalCategories"] = matches.count
                result["nextOffset"] = offset + page.count < matches.count ? offset + page.count : NSNull()
            }
            return result
        case "apply_pending_routing":
            try model.mcpApplyPendingRouting(dryRun: true)
            return try apply(args, affectsRouting: true, preview: ["application": model.mcpRoutingApplicationState,
                                                                  "profileID": model.mcpConnectionProfileID?.uuidString as Any? ?? NSNull()]) {
                try model.mcpApplyPendingRouting()
            }
        case "refresh_geodata":
            let selected = try analysisProfile(args)
            guard !model.isOperationPending, model.updatingGeodataKinds.isEmpty,
                  model.updatingSelectedProfileGeodataKinds.isEmpty else { throw MCPFailure("Wait for the current connection or geodata operation to finish") }
            let sources = selected.geodataSources ?? GeodataSources()
            guard sources.geositeURLString != nil || sources.geoipURLString != nil else {
                throw MCPFailure("This profile uses bundled geodata. Bundled data is updated with Teleport.")
            }
            return try apply(args, affectsRouting: true, preview: ["profileID": selected.id.uuidString,
                                                                  "operation": "refresh_existing_geodata_sources"]) {
                model.downloadSelectedProfileGeodata(forceDownload: true)
            }
        case "update_routing_profile":
            let old = try profile(args)
            guard old.subscriptionSourceID == nil else { throw MCPFailure("Provider profiles are read-only. Customize the profile first.") }
            let title = (args["name"] as! String).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 256 else { throw MCPFailure("Profile name must contain 1–256 characters") }
            var rules: [SplitTunnelRule] = []
            for item in args["rules"] as! [[String: Any]] {
                let id = try uuid(item, "id")
                guard case let .success(classified) = SplitTunnelRuleClassifier.classify(item["value"] as! String) else { throw MCPFailure("Invalid routing rule value") }
                let action = SplitTunnelRuleAction(rawValue: item["action"] as! String)!
                let connectionID = item["connectionID"] is String ? try uuid(item, "connectionID") : nil
                guard connectionID == nil || (action == .proxy && model.savedConnections.contains { $0.id == connectionID }) else { throw MCPFailure("A connectionID must name an existing proxy portal") }
                rules.append(.init(id: id, value: classified.value, kind: classified.kind, action: action, isEnabled: item["isEnabled"] as! Bool, connectionID: connectionID))
            }
            guard Set(rules.map(\.id)).count == rules.count else { throw MCPFailure("Rule IDs must be unique") }
            var updated = old
            updated.name = title; updated.rules = rules; updated.defaultAction = SplitTunnelRuleAction(rawValue: args["defaultAction"] as! String)!
            let changedPolicy = old.rules != rules || old.defaultAction != updated.defaultAction
            return try apply(args, affectsRouting: changedPolicy && old.id == model.mcpConnectionProfileID,
                             preview: ["profileID": old.id.uuidString, "before": ["name": old.name, "defaultAction": old.defaultAction.rawValue, "rules": old.rules.map(ruleJSON)],
                                       "after": ["name": title, "defaultAction": updated.defaultAction.rawValue, "rules": rules.map(ruleJSON)],
                                       "subscriptionOwned": old.subscriptionSourceID != nil]) {
                model.replaceSplitTunnelProfile(updated)
            }
        case "manage_routing_profile":
            let operation = args["operation"] as! String
            if operation == "select_target" {
                let id = try uuid(args, "targetID")
                guard let kind = args["targetKind"] as? String else { throw MCPFailure("targetKind is required") }
                let target: TunnelTarget = kind == "subscription" ? .subscription(id) : .connection(id)
                guard model.tunnelTargets.contains(target) else { throw MCPFailure("Tunnel target not found") }
                return try apply(args, preview: ["selectTarget": targetJSON(target)]) {
                    assignmentTarget = target
                    if let id = model.tunnelProfile(for: target)?.id { model.openSplitTunnelProfile(id: id) }
                }
            }
            if operation == "customize" {
                guard let profile = model.selectedSplitTunnelProfile else { throw MCPFailure("Select a routing profile first") }
                return try apply(args, preview: ["copyProfileID": profile.id.uuidString]) { _ = model.copySplitTunnelProfile(id: profile.id) }
            }
            if operation == "inherit" {
                guard let target = selectedTarget, case let .subscription(sourceID) = target,
                      let provider = model.providerTunnelProfile(for: sourceID) else { throw MCPFailure("Selected subscription has no provider profile") }
                let changesActive = model.selectedConnection.map(TunnelTarget.init(connection:)) == target
                    && model.tunnelProfile(for: target)?.id != provider.id
                return try apply(args, affectsRouting: changesActive, preview: ["inheritProviderProfile": true]) {
                    model.assignTunnelProfile(nil, to: target)
                }
            }
            if operation == "set_enabled" {
                guard let enabled = args["enabled"] as? Bool else { throw MCPFailure("enabled is required") }
                return try apply(args, affectsRouting: enabled != model.isSplitTunnelEnabled, preview: ["enabled": enabled]) { model.setSplitTunnelEnabled(enabled) }
            }
            if operation == "create" {
                guard let title = args["name"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 256 else { throw MCPFailure("name is required (1–256 characters)") }
                return try apply(args, preview: ["createAndOpen": title]) { model.addSplitTunnelProfile(name: title) }
            }
            let selected = try profile(args)
            guard selected.subscriptionSourceID == nil else { throw MCPFailure("Provider profiles are read-only. Customize the profile first.") }
            switch operation {
            case "rename":
                guard let title = args["name"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 256 else { throw MCPFailure("name is required (1–256 characters)") }
                return try apply(args, preview: ["profileID": selected.id.uuidString, "name": title]) { model.renameSplitTunnelProfile(id: selected.id, name: title) }
            case "delete":
                guard model.personalTunnelProfiles.count > 1 else { throw MCPFailure("Cannot delete the last personal profile") }
                return try apply(args, affectsRouting: selected.id == model.mcpConnectionProfileID, preview: ["deleteProfileID": selected.id.uuidString]) { model.removeSplitTunnelProfile(id: selected.id) }
            default:
                guard let target = selectedTarget else { throw MCPFailure("Select an assignment target first") }
                let changesActive = model.selectedConnection.map(TunnelTarget.init(connection:)) == target
                    && model.tunnelProfile(for: target)?.id != selected.id
                return try apply(args, affectsRouting: changesActive,
                                 preview: ["assignProfileID": selected.id.uuidString, "target": targetJSON(target)]) {
                    model.assignTunnelProfile(selected.id, to: target)
                }
            }
        case "add_subscription":
            let url = try subscriptionURL(args["url"] as! String)
            return try apply(args, preview: ["addSubscriptionHost": URL(string: url)!.host!]) {
                guard model.addConnection(from: url), model.lastError == nil else { throw MCPFailure("Subscription could not be added. See Teleport for details.") }
            }
        case "update_subscription":
            let source = try subscription(args)
            let url = try (args["url"] as? String).map { try subscriptionURL($0, excluding: source.id) } ?? source.urlString
            let changedURL = url.caseInsensitiveCompare(source.urlString) != .orderedSame
            guard !model.refreshingSubscriptionIDs.contains(source.id) else { throw MCPFailure("Wait for the subscription refresh before editing its settings") }
            if changedURL { try checkSubscriptionAvailable(source); try checkReferencesToSubscription(source) }
            return try apply(args, preview: ["subscriptionID": source.id.uuidString, "name": args["name"]!, "urlChanged": changedURL,
                                           "autoUpdateIntervalMinutes": args["autoUpdateIntervalMinutes"]!, "filterDuplicateImports": args["filterDuplicateImports"]!]) {
                model.updateSubscriptionSettings(id: source.id, customName: args["name"] as! String, urlString: url,
                                                 autoUpdateIntervalMinutes: args["autoUpdateIntervalMinutes"] as? Int,
                                                 filterDuplicateImports: args["filterDuplicateImports"] as! Bool)
                guard model.lastError == nil else { throw MCPFailure("Subscription settings could not be saved. See Teleport for details.") }
            }
        case "remove_subscription", "refresh_subscription":
            let source = try subscription(args)
            try checkSubscriptionAvailable(source)
            if name == "remove_subscription" { try checkReferencesToSubscription(source) }
            return try apply(args, preview: ["operation": name, "subscriptionID": source.id.uuidString, "portalCount": model.importedConnections(for: source.id).count]) {
                if name == "remove_subscription" { model.removeSubscription(id: source.id) }
                else { model.refreshSubscription(id: source.id) }
                guard model.lastError == nil else { throw MCPFailure("Subscription operation failed. See Teleport for details.") }
            }
        default: throw MCPFailure("Unknown tool")
        }
    }

    private func targetJSON(_ target: TunnelTarget) -> [String: Any] {
        switch target {
        case let .subscription(id): return ["kind": "subscription", "id": id.uuidString]
        case let .connection(id): return ["kind": "connection", "id": id.uuidString]
        }
    }

    private func ruleJSON(_ rule: SplitTunnelRule) -> [String: Any] {
        ["id": rule.id.uuidString, "value": rule.value, "kind": rule.kind.rawValue,
         "action": rule.action.rawValue, "isEnabled": rule.isEnabled,
         "connectionID": rule.connectionID?.uuidString as Any? ?? NSNull()]
    }
}
