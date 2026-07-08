import Foundation
import Network

final class SplitTunnelGeodataMatcher {
    private struct GeositeDomain {
        let type: Int
        let value: String
        let attributes: Set<String>
    }

    private struct GeoIPEntry {
        let ranges: [(address: [UInt8], prefixLength: Int)]
        let reverseMatch: Bool
    }

    private let service: GeodataUpdateService
    private let bundle: Bundle
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.x.teleport.split-tunnel-geodata-matcher", qos: .utility)
    private var geositeCache: [String: [GeositeDomain]]?
    private var geoipCache: [String: GeoIPEntry]?
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

    private func cachedGeosite() -> [String: [GeositeDomain]] {
        lock.lock()
        defer { lock.unlock() }
        return geositeCache ?? [:]
    }

    private func cachedGeoIP() -> [String: GeoIPEntry] {
        lock.lock()
        defer { lock.unlock() }
        return geoipCache ?? [:]
    }

    private func loadGeosite() throws -> [String: [GeositeDomain]] {
        let url = try service.resolvedAssetDirectoryURL(bundle: bundle).appendingPathComponent(GeodataKind.geosite.fileName)
        return try parseGeositeList(Data(contentsOf: url))
    }

    private func loadGeoIP() throws -> [String: GeoIPEntry] {
        let url = try service.resolvedAssetDirectoryURL(bundle: bundle).appendingPathComponent(GeodataKind.geoip.fileName)
        return try parseGeoIPList(Data(contentsOf: url))
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

    private func geositeDomainMatches(_ domain: GeositeDomain, candidate: String) -> Bool {
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

    private func parseGeositeList(_ data: Data) throws -> [String: [GeositeDomain]] {
        var reader = ProtobufReader(data)
        var result: [String: [GeositeDomain]] = [:]
        while let field = try reader.nextField() {
            guard field.number == 1, field.wireType == 2 else {
                try reader.skip(field)
                continue
            }
            var siteReader = try ProtobufReader(reader.readLengthDelimited())
            var code = ""
            var domains: [GeositeDomain] = []
            while let siteField = try siteReader.nextField() {
                switch (siteField.number, siteField.wireType) {
                case (1, 2):
                    code = try siteReader.readString().lowercased()
                case (2, 2):
                    domains.append(try parseGeositeDomain(siteReader.readLengthDelimited()))
                default:
                    try siteReader.skip(siteField)
                }
            }
            if !code.isEmpty { result[code] = domains }
        }
        return result
    }

    private func parseGeositeDomain(_ data: Data) throws -> GeositeDomain {
        var reader = ProtobufReader(data)
        var type = 0
        var value = ""
        var attributes: Set<String> = []
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 0):
                type = Int(try reader.readVarint())
            case (2, 2):
                value = try reader.readString()
            case (3, 2):
                if let attribute = try parseGeositeAttribute(reader.readLengthDelimited()) {
                    attributes.insert(attribute)
                }
            default:
                try reader.skip(field)
            }
        }
        return GeositeDomain(type: type, value: value, attributes: attributes)
    }

    private func parseGeositeAttribute(_ data: Data) throws -> String? {
        var reader = ProtobufReader(data)
        while let field = try reader.nextField() {
            if field.number == 1, field.wireType == 2 {
                return try reader.readString().lowercased()
            }
            try reader.skip(field)
        }
        return nil
    }

    private func parseGeoIPList(_ data: Data) throws -> [String: GeoIPEntry] {
        var reader = ProtobufReader(data)
        var result: [String: GeoIPEntry] = [:]
        while let field = try reader.nextField() {
            guard field.number == 1, field.wireType == 2 else {
                try reader.skip(field)
                continue
            }
            let parsed = try parseGeoIP(reader.readLengthDelimited())
            if !parsed.code.isEmpty {
                result[parsed.code] = GeoIPEntry(ranges: parsed.ranges, reverseMatch: parsed.reverseMatch)
            }
        }
        return result
    }

    private func parseGeoIP(_ data: Data) throws -> (code: String, ranges: [(address: [UInt8], prefixLength: Int)], reverseMatch: Bool) {
        var reader = ProtobufReader(data)
        var code = ""
        var ranges: [(address: [UInt8], prefixLength: Int)] = []
        var reverseMatch = false
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 2):
                code = try reader.readString().lowercased()
            case (2, 2):
                if let range = try parseCIDR(reader.readLengthDelimited()) {
                    ranges.append(range)
                }
            case (3, 0):
                reverseMatch = try reader.readVarint() != 0
            default:
                try reader.skip(field)
            }
        }
        return (code, ranges, reverseMatch)
    }

    private func parseCIDR(_ data: Data) throws -> (address: [UInt8], prefixLength: Int)? {
        var reader = ProtobufReader(data)
        var address: [UInt8] = []
        var prefixLength: Int?
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 2):
                address = [UInt8](try reader.readLengthDelimited())
            case (2, 0):
                prefixLength = Int(try reader.readVarint())
            default:
                try reader.skip(field)
            }
        }
        guard !address.isEmpty else { return nil }
        return (address, prefixLength ?? address.count * 8)
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

private struct ProtobufReader {
    struct Field {
        let number: Int
        let wireType: Int
    }

    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func nextField() throws -> Field? {
        guard offset < bytes.count else { return nil }
        let key = try readVarint()
        return Field(number: Int(key >> 3), wireType: Int(key & 0x7))
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count, shift < 64 {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw ProtobufError.malformed
    }

    mutating func readLengthDelimited() throws -> Data {
        let length = Int(try readVarint())
        guard length >= 0, offset + length <= bytes.count else { throw ProtobufError.malformed }
        let start = offset
        offset += length
        return Data(bytes[start ..< offset])
    }

    mutating func readString() throws -> String {
        guard let string = String(data: try readLengthDelimited(), encoding: .utf8) else {
            throw ProtobufError.malformed
        }
        return string
    }

    mutating func skip(_ field: Field) throws {
        switch field.wireType {
        case 0:
            _ = try readVarint()
        case 1:
            try advance(8)
        case 2:
            _ = try readLengthDelimited()
        case 5:
            try advance(4)
        default:
            throw ProtobufError.unsupportedWireType
        }
    }

    private mutating func advance(_ count: Int) throws {
        guard count >= 0, offset + count <= bytes.count else { throw ProtobufError.malformed }
        offset += count
    }
}

private enum ProtobufError: Error {
    case malformed
    case unsupportedWireType
}
