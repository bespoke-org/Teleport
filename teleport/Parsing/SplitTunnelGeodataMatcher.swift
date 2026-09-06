import Foundation
import Network

final class SplitTunnelGeodataMatcher {
    private let service: GeodataUpdateService
    private let bundle: Bundle
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.x.teleport.split-tunnel-geodata-matcher", qos: .utility)
    private var geositeCache: [String: [GeodataFormat.GeositeDomain]]?
    private var geoipCache: [String: GeodataFormat.GeoIPEntry]?
    private var isLoading = false
    private var pendingCompletions: [() -> Void] = []

    init(service: GeodataUpdateService = GeodataUpdateService(), bundle: Bundle = .main) {
        self.service = service
        self.bundle = bundle
    }

    func geositeRuleMatches(_ ruleValue: String, candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !SplitTunnelRuleClassifier.isIPLiteral(trimmed) else { return false }
        guard let token = geodataToken(ruleValue, prefix: "geosite:") else { return false }
        guard let domains = cachedGeosite()[token.category], !domains.isEmpty else { return false }

        let host = trimmed.lowercased()
        return domains.contains { domain in
            if let attribute = token.attribute, !domain.attributes.contains(attribute) {
                return false
            }
            return geositeDomainMatches(domain, candidate: host)
        }
    }

    func geoipRuleMatches(_ ruleValue: String, candidate: String) -> Bool {
        guard let candidateData = addressData(candidate) else { return false }
        guard let token = geodataToken(ruleValue, prefix: "geoip:"), token.attribute == nil else { return false }
        guard let entry = cachedGeoIP()[token.category] else { return false }

        let contains = entry.ranges.contains { range in
            range.address.count == candidateData.count && matchesPrefix(candidateData, range.address, prefixLength: range.prefixLength)
        }
        return entry.reverseMatch ? !contains : contains
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return geositeCache != nil && geoipCache != nil
    }

    func prepare(completion: (() -> Void)? = nil) {
        lock.lock()
        if geositeCache != nil, geoipCache != nil {
            lock.unlock()
            completion?()
            return
        }
        if let completion {
            pendingCompletions.append(completion)
        }
        guard !isLoading else {
            lock.unlock()
            return
        }
        isLoading = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let parsedGeosite = try? self.loadGeosite()
            let parsedGeoIP = try? self.loadGeoIP()

            self.lock.lock()
            if let parsedGeosite { self.geositeCache = parsedGeosite }
            if let parsedGeoIP { self.geoipCache = parsedGeoIP }
            self.isLoading = false
            let completions = self.pendingCompletions
            self.pendingCompletions.removeAll()
            self.lock.unlock()

            DispatchQueue.main.async {
                completions.forEach { $0() }
            }
        }
    }

    func prepareSynchronously() throws {
        let parsedGeosite = try loadGeosite()
        let parsedGeoIP = try loadGeoIP()
        lock.lock()
        geositeCache = parsedGeosite
        geoipCache = parsedGeoIP
        isLoading = false
        pendingCompletions.removeAll()
        lock.unlock()
    }

    func resetCache() {
        lock.lock()
        defer { lock.unlock() }
        geositeCache = nil
        geoipCache = nil
    }

    private func cachedGeosite() -> [String: [GeodataFormat.GeositeDomain]] {
        lock.lock()
        defer { lock.unlock() }
        return geositeCache ?? [:]
    }

    private func cachedGeoIP() -> [String: GeodataFormat.GeoIPEntry] {
        lock.lock()
        defer { lock.unlock() }
        return geoipCache ?? [:]
    }

    private func loadGeosite() throws -> [String: [GeodataFormat.GeositeDomain]] {
        let url = try service.resolvedAssetDirectoryURL(bundle: bundle).appendingPathComponent(GeodataKind.geosite.fileName)
        return try GeodataFormat.parseGeositeList(Data(contentsOf: url))
    }

    private func loadGeoIP() throws -> [String: GeodataFormat.GeoIPEntry] {
        let url = try service.resolvedAssetDirectoryURL(bundle: bundle).appendingPathComponent(GeodataKind.geoip.fileName)
        return try GeodataFormat.parseGeoIPList(Data(contentsOf: url))
    }

    private func geodataToken(_ value: String, prefix: String) -> (category: String, attribute: String?)? {
        let lower = value.lowercased()
        guard lower.hasPrefix(prefix) else { return nil }
        let body = String(lower.dropFirst(prefix.count))
        let parts = body.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let category = parts.first, !category.isEmpty else { return nil }
        let attribute = parts.count == 2 && !parts[1].isEmpty ? parts[1] : nil
        return (category, attribute)
    }

    private func geositeDomainMatches(_ domain: GeodataFormat.GeositeDomain, candidate: String) -> Bool {
        let value = domain.value.lowercased()
        switch domain.type {
        case 0: // Plain
            return candidate.contains(value)
        case 1: // Regex
            return (try? NSRegularExpression(pattern: value))?.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)) != nil
        case 2: // Domain
            return candidate == value || candidate.hasSuffix("." + value)
        case 3: // Full
            return candidate == value
        default:
            return false
        }
    }

    private func addressData(_ value: String) -> [UInt8]? {
        if let v4 = IPv4Address(value) { return [UInt8](v4.rawValue) }
        if let v6 = IPv6Address(value) { return [UInt8](v6.rawValue) }
        return nil
    }

    private func matchesPrefix(_ candidate: [UInt8], _ ruleAddress: [UInt8], prefixLength: Int) -> Bool {
        guard prefixLength >= 0, prefixLength <= candidate.count * 8 else { return false }
        let fullBytes = prefixLength / 8
        let remainingBits = prefixLength % 8
        if fullBytes > 0, Array(candidate.prefix(fullBytes)) != Array(ruleAddress.prefix(fullBytes)) { return false }
        if remainingBits > 0 {
            let mask = UInt8(0xFF << (8 - remainingBits))
            if (candidate[fullBytes] & mask) != (ruleAddress[fullBytes] & mask) { return false }
        }
        return true
    }
}

