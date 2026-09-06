import Foundation
import Network

enum SplitTunnelRuleValidationError: LocalizedError, Equatable {
    case emptyValue
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .emptyValue: return "Enter a domain, IP/CIDR, geosite, or geoip value."
        case .invalidValue: return "Enter a valid domain, IP address, CIDR range, geosite:category, or geoip:category."
        }
    }
}

enum SplitTunnelRuleClassifier {
    static func classify(_ rawValue: String) -> Result<(kind: SplitTunnelRuleKind, value: String), SplitTunnelRuleValidationError> {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyValue) }

        if isGeodataToken(trimmed, prefix: "geosite:") {
            // Categories are lowercase keys in geosite.dat; normalize so what we
            // store, generate, and display all match Xray's lookup.
            return .success((.geosite, trimmed.lowercased()))
        }

        if isGeodataToken(trimmed, prefix: "geoip:") {
            // Categories are lowercase keys in geoip.dat; normalize so what we
            // store, generate, and display all match Xray's lookup.
            return .success((.geoip, trimmed.lowercased()))
        }

        if isIPOrCIDR(trimmed) {
            return .success((.ip, trimmed))
        }

        if isValidDomainValue(trimmed) {
            // Store domains lowercased so the tester, the generated Xray `domain`
            // rule, and Xray's own (lowercase) SNI/Host matching all agree.
            return .success((.domain, trimmed.lowercased()))
        }

        return .failure(.invalidValue)
    }

    /// Matches `geosite:<category>`/`geoip:<category>` with optional `@attr`
    /// suffixes, e.g. `geosite:google`, `geoip:private`, `geosite:google@ads`.
    private static func isGeodataToken(_ value: String, prefix: String) -> Bool {
        guard value.lowercased().hasPrefix(prefix) else { return false }
        let category = value.dropFirst(prefix.count)
        guard !category.isEmpty, category.count <= 128 else { return false }

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_@.")
        guard category.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Must start with an actual category name, not an attribute separator.
        guard category.first != "@", category.first != "." else { return false }
        return true
    }

    static func isIPLiteral(_ value: String) -> Bool {
        IPv4Address(value) != nil || IPv6Address(value) != nil
    }

    private static func isIPOrCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        let addressPart = String(parts[0])
        guard isIPLiteral(addressPart) else { return false }

        if parts.count == 2 {
            guard let prefixLength = Int(parts[1]) else { return false }
            let maxPrefix = addressPart.contains(":") ? 128 : 32
            guard prefixLength >= 0, prefixLength <= maxPrefix else { return false }
        }
        return true
    }

    private static func isValidDomainValue(_ value: String) -> Bool {
        var hostValue = value
        if hostValue.hasPrefix("full:") {
            hostValue = String(hostValue.dropFirst("full:".count))
        }
        guard !hostValue.isEmpty, hostValue.count <= 253 else { return false }
        guard !hostValue.hasPrefix("."), !hostValue.hasSuffix("."), !hostValue.contains("..") else { return false }

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        let labels = hostValue.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard !label.isEmpty,
                  label.count <= 63,
                  label.first != "-",
                  label.last != "-",
                  label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                return false
            }
        }
        return true
    }
}

/// Shared first-match-wins evaluator used by both tunnel routing-rule generation
/// and the Settings rule tester, so the two can never disagree about a result.
enum SplitTunnelRuleMatcher {
    static func firstMatch(for candidate: String, in rules: [SplitTunnelRule], geodataMatcher: SplitTunnelGeodataMatcher? = nil) -> SplitTunnelRule? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for rule in rules where rule.isEnabled {
            switch rule.kind {
            case .domain:
                if domainRuleMatches(rule.value, candidate: trimmed) { return rule }
            case .ip:
                if ipRuleMatches(rule.value, candidate: trimmed) { return rule }
            case .geosite:
                if geodataMatcher?.geositeRuleMatches(rule.value, candidate: trimmed) == true { return rule }
            case .geoip:
                if geodataMatcher?.geoipRuleMatches(rule.value, candidate: trimmed) == true { return rule }
            }
        }
        return nil
    }

    private static func domainRuleMatches(_ ruleValue: String, candidate: String) -> Bool {
        guard !SplitTunnelRuleClassifier.isIPLiteral(candidate) else { return false }
        let candidateLower = candidate.lowercased()

        var matchValue = ruleValue.lowercased()
        var requiresExactMatch = false
        if matchValue.hasPrefix("full:") {
            requiresExactMatch = true
            matchValue = String(matchValue.dropFirst("full:".count))
        }

        if requiresExactMatch {
            return candidateLower == matchValue
        }
        return candidateLower == matchValue || candidateLower.hasSuffix("." + matchValue)
    }

    private static func ipRuleMatches(_ ruleValue: String, candidate: String) -> Bool {
        guard let candidateData = addressData(candidate) else { return false }

        let parts = ruleValue.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let ruleAddressData = addressData(String(parts[0])), ruleAddressData.count == candidateData.count else {
            return false
        }

        let prefixLength: Int
        if parts.count == 2, let parsedPrefix = Int(parts[1]) {
            prefixLength = parsedPrefix
        } else {
            prefixLength = ruleAddressData.count * 8
        }

        return matchesPrefix(candidateData, ruleAddressData, prefixLength: prefixLength)
    }

    private static func addressData(_ value: String) -> [UInt8]? {
        if let v4 = IPv4Address(value) { return [UInt8](v4.rawValue) }
        if let v6 = IPv6Address(value) { return [UInt8](v6.rawValue) }
        return nil
    }

    private static func matchesPrefix(_ candidate: [UInt8], _ ruleAddress: [UInt8], prefixLength: Int) -> Bool {
        guard prefixLength >= 0, prefixLength <= candidate.count * 8 else { return false }
        let fullBytes = prefixLength / 8
        let remainingBits = prefixLength % 8

        if fullBytes > 0, Array(candidate.prefix(fullBytes)) != Array(ruleAddress.prefix(fullBytes)) {
            return false
        }
        if remainingBits > 0 {
            let mask = UInt8.max << (8 - remainingBits)
            if (candidate[fullBytes] & mask) != (ruleAddress[fullBytes] & mask) {
                return false
            }
        }
        return true
    }
}
