import Foundation

/// Reads the Xray `geosite.dat` / `geoip.dat` protobuf payloads.
///
/// Kept apart from `SplitTunnelGeodataMatcher` so the reader that decides routing at
/// run time is also the one that vets a download before it is stored and handed to
/// the root helper: whatever would fail later has to fail here instead.
nonisolated enum GeodataFormat {
    struct GeositeDomain {
        let type: Int
        let value: String
        let attributes: Set<String>
    }

    struct GeoIPEntry {
        let ranges: [(address: [UInt8], prefixLength: Int)]
        let reverseMatch: Bool
    }


    /// Rejects a payload that the run-time reader could not use: an HTML error page,
    /// a truncated transfer, or a file of the other kind. Requiring real content —
    /// a domain with a value, a country with a range — is what catches the
    /// cross-kind case, since each file's records skip cleanly as the other's and
    /// would otherwise parse to a dictionary full of empty entries.
    ///
    /// This is a robustness check, not an authenticity one. A well-formed but
    /// hostile file parses perfectly and can route traffic anywhere; only trusting
    /// the source protects against that.
    static func validate(_ data: Data, kind: GeodataKind) throws {
        switch kind {
        case .geosite:
            let parsed = try parseGeositeList(data)
            guard parsed.values.contains(where: { domains in domains.contains { !$0.value.isEmpty } }) else {
                throw GeodataUpdateError.unreadablePayload(kind)
            }
        case .geoip:
            let parsed = try parseGeoIPList(data)
            guard parsed.values.contains(where: { !$0.ranges.isEmpty }) else {
                throw GeodataUpdateError.unreadablePayload(kind)
            }
        }
    }

    static func parseGeositeList(_ data: Data) throws -> [String: [GeositeDomain]] {
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

    private static func parseGeositeDomain(_ data: Data) throws -> GeositeDomain {
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

    private static func parseGeositeAttribute(_ data: Data) throws -> String? {
        var reader = ProtobufReader(data)
        while let field = try reader.nextField() {
            if field.number == 1, field.wireType == 2 {
                return try reader.readString().lowercased()
            }
            try reader.skip(field)
        }
        return nil
    }

    static func parseGeoIPList(_ data: Data) throws -> [String: GeoIPEntry] {
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

    private static func parseGeoIP(_ data: Data) throws -> (code: String, ranges: [(address: [UInt8], prefixLength: Int)], reverseMatch: Bool) {
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

    private static func parseCIDR(_ data: Data) throws -> (address: [UInt8], prefixLength: Int)? {
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
