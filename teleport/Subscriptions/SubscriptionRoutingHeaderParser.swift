import Foundation
import CoreFoundation

enum SubscriptionRoutingImport {
    case off
    case profile(SplitTunnelProfile, activate: Bool)

    /// A subscription owns one imported profile. Refreshes keep its identity;
    /// equally named manual profiles and profiles from other providers survive.
    func apply(
        to profiles: inout [SplitTunnelProfile],
        sourceID: UUID,
        selectedProfileID: inout UUID?,
        isEnabled: inout Bool
    ) {
        switch self {
        case .off:
            isEnabled = false
        case let .profile(imported, activate):
            var profile = imported
            profile.subscriptionSourceID = sourceID
            if let index = profiles.firstIndex(where: { $0.subscriptionSourceID == sourceID }) {
                let previous = profiles[index]
                profile = SplitTunnelProfile(
                    id: previous.id, name: imported.name,
                    rules: imported.rules.map { rule in
                        var rule = rule
                        if let existing = previous.rules.first(where: {
                            $0.kind == rule.kind && $0.value == rule.value && $0.action == rule.action
                        }) {
                            rule = SplitTunnelRule(
                                id: existing.id, value: rule.value, kind: rule.kind, action: rule.action,
                                isEnabled: existing.isEnabled, connectionID: existing.connectionID
                            )
                        }
                        return rule
                    },
                    defaultAction: imported.defaultAction,
                    subscriptionSourceID: sourceID
                )
                profiles[index] = profile
            } else {
                profiles.append(profile)
            }
            if activate {
                selectedProfileID = profile.id
                isEnabled = true
            }
        }
    }
}

struct SubscriptionRoutingHeaderResult {
    let routing: SubscriptionRoutingImport?
    let warning: String?
}

/// Happ/INCY's HTTP `routing` header contains a base64 JSON profile, optionally
/// wrapped in `<scheme>://routing/{add,onadd}/`. It is separate from the body:
/// a bad routing header must not prevent importing otherwise valid servers.
struct SubscriptionRoutingHeaderParser {
    func parse(_ header: String?) -> SubscriptionRoutingHeaderResult {
        guard let header, !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SubscriptionRoutingHeaderResult(routing: nil, warning: nil)
        }
        do {
            return try decode(header.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return SubscriptionRoutingHeaderResult(
                routing: nil,
                warning: "Routing header was not imported: invalid or unsupported routing rules. Existing profiles were kept."
            )
        }
    }

    private func decode(_ header: String) throws -> SubscriptionRoutingHeaderResult {
        var payload = header
        var activate = true
        if let range = header.range(of: "://routing/", options: .caseInsensitive) {
            payload = String(header[range.upperBound...])
            if payload.lowercased() == "off" {
                return SubscriptionRoutingHeaderResult(routing: .off, warning: nil)
            }
            if payload.hasPrefix("onadd/") {
                payload.removeFirst("onadd/".count)
            } else if payload.hasPrefix("add/") {
                payload.removeFirst("add/".count)
                activate = false
            } else {
                throw InvalidProfile.invalid
            }
        } else if header.lowercased() == "off" {
            return SubscriptionRoutingHeaderResult(routing: .off, warning: nil)
        }

        payload = (payload.removingPercentEncoding ?? payload)
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InvalidProfile.invalid
        }
        var fields: [String: Any] = [:]
        for (key, value) in object {
            let key = key.lowercased()
            guard fields[key] == nil else { throw InvalidProfile.invalid }
            fields[key] = value
        }

        let name = try string(fields["name"]) ?? "Default"
        let globalProxy = try boolean(fields["globalproxy"], default: true)
        let order = (try string(fields["routeorder"]) ?? "block-direct-proxy")
            .lowercased().components(separatedBy: "-")
        guard order.count == 3, Set(order) == Set(["block", "direct", "proxy"]) else {
            throw InvalidProfile.invalid
        }
        var rules: [SplitTunnelRule] = []
        for actionName in order {
            guard let action = SplitTunnelRuleAction(rawValue: actionName) else { throw InvalidProfile.invalid }
            for suffix in ["sites", "ip"] {
                let key = actionName + suffix
                guard let value = fields[key] else { continue }
                guard let values = value as? [String] else { throw InvalidProfile.invalid }
                for rawValue in values {
                    var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Teleport stores Xray's domain: matching as a bare domain.
                    if value.lowercased().hasPrefix("domain:") {
                        value.removeFirst("domain:".count)
                    }
                    guard case let .success(classified) = SplitTunnelRuleClassifier.classify(value),
                          suffix == "sites"
                            ? [.domain, .geosite].contains(classified.kind)
                            : [.ip, .geoip].contains(classified.kind) else {
                        throw InvalidProfile.invalid
                    }
                    if !rules.contains(where: {
                        $0.kind == classified.kind && $0.value == classified.value && $0.action == action
                    }) {
                        rules.append(SplitTunnelRule(value: classified.value, kind: classified.kind, action: action))
                    }
                }
            }
        }

        // Teleport owns DNS and its geodata sources globally. Report settings
        // we cannot transfer instead of silently promising a complete import.
        let ignoredSettings = [
            "remotedns", "remotednstype", "remotednsdomain", "remotednsip",
            "domesticdns", "domesticdnstype", "domesticdnsdomain", "domesticdnsip",
            "dnshosts", "geoipurl", "geositeurl"
        ].filter { key in
            guard let value = fields[key] else { return false }
            if let text = value as? String { return !text.isEmpty }
            if let dictionary = value as? [String: Any] { return !dictionary.isEmpty }
            return true
        }
        let hasOtherSettings = try boolean(fields["fakedns"], default: false)
            || boolean(fields["usechunkfiles"], default: false)
            || (string(fields["domainstrategy"]).map { $0.lowercased() != "asis" } ?? false)
        let warning = ignoredSettings.isEmpty && !hasOtherSettings ? nil
            : "Routing rules imported. Profile DNS, geodata URLs, FakeDNS, chunk files and DomainStrategy are not imported; Teleport uses its own settings."
        return SubscriptionRoutingHeaderResult(
            routing: .profile(SplitTunnelProfile(name: name, rules: rules, defaultAction: globalProxy ? .proxy : .direct), activate: activate),
            warning: warning
        )
    }

    private func string(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        guard let text = value as? String else { throw InvalidProfile.invalid }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func boolean(_ value: Any?, default fallback: Bool) throws -> Bool {
        guard let value else { return fallback }
        if let text = value as? String {
            switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "": return fallback
            case "true": return true
            case "false": return false
            default: throw InvalidProfile.invalid
            }
        }
        // JSON numbers must not be treated as booleans by NSNumber bridging.
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        throw InvalidProfile.invalid
    }

    private enum InvalidProfile: Error { case invalid }
}
