import Foundation

/// A deliberately bounded subset of Xray's FinalMask. These masks only wrap the
/// existing TCP connection; they cannot introduce another endpoint or dialer.
nonisolated enum FinalMaskConfiguration {
    static func parse(_ text: String?, transport: ConnectionTransport, security: ConnectionSecurity) throws -> XrayJSONObject? {
        guard let text else { return nil }
        guard text.utf8.count <= 65_536,
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
            throw ConfigurationError.invalidFinalMask
        }
        return try validate(value, transport: transport, security: security)
    }

    static func validate(_ value: Any, transport: ConnectionTransport, security: ConnectionSecurity) throws -> XrayJSONObject {
        do {
            guard [.tcp, .raw].contains(transport), [.tls, .reality].contains(security) else {
                throw ConfigurationError.invalidFinalMask
            }
            let section = "FinalMask settings"
            let object = try XrayProfileValidation.object(value, section)
            try XrayProfileValidation.keys(object, ["tcp"], section)
            if let tcp = object["tcp"] {
                guard let masks = tcp as? [[String: Any]] else { throw ConfigurationError.invalidFinalMask }
                for mask in masks {
                    try XrayProfileValidation.keys(mask, ["type", "settings"], section)
                    guard mask["type"] as? String == "fragment" else { throw ConfigurationError.invalidFinalMask }
                    let settings = try XrayProfileValidation.object(mask["settings"], section)
                    try XrayProfileValidation.keys(settings, ["packets", "length", "delay", "lengths", "delays", "maxSplit"], section)
                    if let packets = settings["packets"] {
                        let packets = try XrayProfileValidation.string(packets, section)
                        if packets.lowercased() != "tlshello" {
                            guard try XrayProfileValidation.range(packets, section).lowerBound > 0 else {
                                throw ConfigurationError.invalidFinalMask
                            }
                        }
                    }
                    let lengths = try ranges(settings, single: "length", plural: "lengths")
                    // Xray requires the final length range to start above zero.
                    // A zero there would let its fragment loop stop making progress.
                    guard let last = lengths.last, last.lowerBound > 0 else { throw ConfigurationError.invalidFinalMask }
                    _ = try ranges(settings, single: "delay", plural: "delays")
                    if let maxSplit = settings["maxSplit"] { try XrayProfileValidation.range(maxSplit, section) }
                }
            }
            return try XrayJSONObject(object)
        } catch {
            // Never surface a provider's mask contents or credentials in errors.
            throw ConfigurationError.invalidFinalMask
        }
    }

    private static func ranges(_ settings: [String: Any], single: String, plural: String) throws -> [ClosedRange<Int32>] {
        if let values = settings[plural] {
            guard settings[single] == nil, let values = values as? [Any], !values.isEmpty else {
                throw ConfigurationError.invalidFinalMask
            }
            return try values.map { try XrayProfileValidation.range($0, "FinalMask settings") }
        }
        if let value = settings[single] { return [try XrayProfileValidation.range(value, "FinalMask settings")] }
        return []
    }
}
