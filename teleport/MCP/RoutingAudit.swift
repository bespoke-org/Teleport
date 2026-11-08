import Foundation
import Network

/// Conservative set containment: regex inclusion is only proven for identical
/// expressions or an exact hostname. Unproven coverage never suggests removal.
nonisolated struct RoutingAudit {
    let sites: [String: [GeodataFormat.GeositeDomain]]
    let ips: [String: GeodataFormat.GeoIPEntry]

    init(directory: URL) throws {
        sites = try GeodataFormat.parseGeositeList(Data(contentsOf: directory.appendingPathComponent("geosite.dat")))
        ips = try GeodataFormat.parseGeoIPList(Data(contentsOf: directory.appendingPathComponent("geoip.dat")))
    }

    init(service: GeodataUpdateService, sources: GeodataSources?, bundle: Bundle = .main) throws {
        guard let sources else {
            try self.init(directory: service.resolvedAssetDirectoryURL(bundle: bundle))
            return
        }
        func data(_ kind: GeodataKind) throws -> Data {
            var bytes = try Data(contentsOf: service.profileFileURL(for: kind, sources: sources, bundle: bundle))
            let custom = kind == .geosite ? sources.geositeURLString : sources.geoipURLString
            if custom != nil, let bundled = bundle.url(forResource: kind.rawValue, withExtension: "dat") {
                bytes = try GeodataFormat.addingMissingCategories(from: Data(contentsOf: bundled), to: bytes)
            }
            return bytes
        }
        self.init(sites: try GeodataFormat.parseGeositeList(data(.geosite)),
                  ips: try GeodataFormat.parseGeoIPList(data(.geoip)))
    }

    init(sites: [String: [GeodataFormat.GeositeDomain]], ips: [String: GeodataFormat.GeoIPEntry]) {
        self.sites = sites
        self.ips = ips
    }

    private func domains(_ rule: SplitTunnelRule) -> [GeodataFormat.GeositeDomain]? {
        switch rule.kind {
        case .domain:
            return [.init(type: rule.value.hasPrefix("full:") ? 3 : 2,
                          value: rule.value.hasPrefix("full:") ? String(rule.value.dropFirst(5)) : rule.value, attributes: [])]
        case .geosite:
            let parts = rule.value.dropFirst(8).split(separator: "@", maxSplits: 1).map(String.init)
            guard let name = parts.first, let entries = sites[name] else { return nil }
            return parts.count == 2 ? entries.filter { $0.attributes.contains(parts[1]) } : entries
        default: return nil
        }
    }

    private func ranges(_ rule: SplitTunnelRule) -> [NetworkRange]? {
        switch rule.kind {
        case .ip: return NetworkRange(rule.value).map { [$0] }
        case .geoip:
            guard let entry = ips[String(rule.value.dropFirst(6))], !entry.reverseMatch else { return nil }
            return entry.ranges.compactMap { NetworkRange(address: $0.address, prefix: $0.prefixLength) }
        default: return nil
        }
    }

    func missingCategory(_ rule: SplitTunnelRule) -> Bool {
        if rule.kind == .geosite { return domains(rule)?.isEmpty != false }
        if rule.kind == .geoip { return ips[String(rule.value.dropFirst(6))] == nil }
        return false
    }

    func covers(_ broad: SplitTunnelRule, _ narrow: SplitTunnelRule) -> Bool {
        guard !missingCategory(broad), !missingCategory(narrow) else { return false }
        if broad.kind == narrow.kind, broad.value == narrow.value { return true }
        if let left = domains(broad), let right = domains(narrow), !right.isEmpty {
            let index = DomainCoverage(left)
            return right.allSatisfy { index.covers($0) }
        }
        if let left = ranges(broad), let right = ranges(narrow), !right.isEmpty {
            let index = NetworkRange.merged(left)
            return right.allSatisfy { range in
                (0...range.prefix).contains { prefix in index.contains(NetworkRange(address: range.address, prefix: prefix)!) }
            }
        }
        return false
    }

    func findings(rules: [SplitTunnelRule], connectionIDs: Set<UUID>, defaultConnectionID: UUID?) -> [[String: Any]] {
        var findings: [[String: Any]] = []
        var removableIDs = Set<UUID>()
        let deadline = Date().addingTimeInterval(5)
        func route(_ rule: SplitTunnelRule) -> String {
            rule.action == .proxy ? "proxy:" + ((rule.connectionID ?? defaultConnectionID)?.uuidString ?? "default") : rule.action.rawValue
        }
        for (index, rule) in rules.enumerated() where rule.isEnabled {
            if let id = rule.connectionID, rule.action == .proxy, !connectionIDs.contains(id) {
                findings.append(["ruleID": rule.id.uuidString, "kind": "missing_connection", "removable": false])
            }
            if missingCategory(rule) {
                findings.append(["ruleID": rule.id.uuidString, "kind": "missing_category", "value": rule.value, "removable": false])
                continue
            }
            for (otherIndex, other) in rules.enumerated() where other.isEnabled && index != otherIndex && !removableIDs.contains(other.id) {
                if Date() > deadline || Task.isCancelled {
                    findings.append(["kind": "audit_incomplete", "removable": false, "reason": "Work limit reached; remaining rules were not checked"])
                    return findings
                }
                // A later covering rule is safe only if intervening enabled rules
                // all route identically. An earlier rule always wins.
                let earlier = otherIndex < index
                let sameRoute = route(rule) == route(other)
                let safeLater = otherIndex > index && sameRoute && rules[(index + 1)..<otherIndex].filter(\.isEnabled).allSatisfy { route($0) == route(rule) }
                guard earlier || safeLater, covers(other, rule) else { continue }
                findings.append(["ruleID": rule.id.uuidString, "value": rule.value,
                                 "coveredByRuleID": other.id.uuidString, "coveredByValue": other.value,
                                 "kind": earlier && !sameRoute ? "shadowed_by_different_route" : "redundant",
                                 // Removing a differently routed domain can also alter DNS routing.
                                 "removable": sameRoute,
                                 "basis": "current_geodata_and_rule_order"])
                if sameRoute { removableIDs.insert(rule.id) }
                break
            }
        }
        return findings
    }

    func firstMatch(destination: String, rules: [SplitTunnelRule]) -> SplitTunnelRule? {
        let isIP = SplitTunnelRuleClassifier.isIPLiteral(destination)
        let candidate = SplitTunnelRule(value: isIP ? destination : "full:" + destination.lowercased(), kind: isIP ? .ip : .domain, action: .proxy)
        return rules.first { rule in
            guard rule.isEnabled else { return false }
            if rule.kind == .geoip, let entry = ips[String(rule.value.dropFirst(6))], entry.reverseMatch, let target = NetworkRange(destination) {
                return !entry.ranges.compactMap { NetworkRange(address: $0.address, prefix: $0.prefixLength) }.contains { $0.contains(target) }
            }
            return covers(rule, candidate)
        }
    }
}

nonisolated private struct DomainCoverage {
    let suffixes: Set<String>
    let exact: Set<String>
    let plain: [String]
    let regex: [String]
    init(_ entries: [GeodataFormat.GeositeDomain]) {
        suffixes = Set(entries.filter { $0.type == 2 }.map(\.value))
        exact = Set(entries.filter { $0.type == 3 }.map(\.value))
        plain = entries.filter { $0.type == 0 }.map(\.value)
        regex = entries.filter { $0.type == 1 }.map(\.value)
    }
    func covers(_ domain: GeodataFormat.GeositeDomain) -> Bool {
        let value = domain.value
        if domain.type == 1 { return regex.contains(value) }
        if domain.type == 3, exact.contains(value) { return true }
        if domain.type == 2 || domain.type == 3 {
            let labels = value.split(separator: ".")
            if labels.indices.contains(where: { suffixes.contains(labels[$0...].joined(separator: ".")) }) { return true }
        }
        if plain.contains(where: { value.contains($0) }) { return true }
        if domain.type == 3 {
            return regex.contains { pattern in
                (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
            }
        }
        return false
    }
}

nonisolated private struct NetworkRange: Hashable {
    let address: [UInt8]
    let prefix: Int
    init?(address: [UInt8], prefix: Int) {
        guard [4, 16].contains(address.count), (0...address.count * 8).contains(prefix) else { return nil }
        self.prefix = prefix
        self.address = address.enumerated().map { index, byte in
            let bits = min(8, max(0, prefix - index * 8))
            return bits == 0 ? 0 : byte & (UInt8.max << (8 - bits))
        }
    }
    init?(_ text: String) {
        let parts = text.split(separator: "/")
        guard let first = parts.first else { return nil }
        let bytes = IPv4Address(String(first)).map { [UInt8]($0.rawValue) } ?? IPv6Address(String(first)).map { [UInt8]($0.rawValue) }
        guard let bytes else { return nil }
        self.init(address: bytes, prefix: parts.count == 2 ? Int(parts[1]) ?? -1 : bytes.count * 8)
    }
    func contains(_ other: Self) -> Bool {
        address.count == other.address.count && prefix <= other.prefix && NetworkRange(address: other.address, prefix: prefix) == self
    }
    static func merged(_ ranges: [Self]) -> Set<Self> {
        var result = Set(ranges)
        for depth in stride(from: 128, through: 1, by: -1) {
            for range in result.filter({ $0.prefix == depth }) {
                var sibling = range.address
                sibling[(depth - 1) / 8] ^= UInt8(1 << (7 - (depth - 1) % 8))
                let other = Self(address: sibling, prefix: depth)!
                if result.contains(other) {
                    result.remove(range); result.remove(other)
                    result.insert(Self(address: range.address, prefix: depth - 1)!)
                }
            }
        }
        return result
    }
}
