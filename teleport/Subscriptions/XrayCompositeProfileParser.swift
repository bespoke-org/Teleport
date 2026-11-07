import CoreFoundation
import Foundation

/// Imports a group selected by one catch-all balancer. Teleport still owns DNS,
/// inbounds and direct/block routing; selective routing between proxy members
/// and chained outbounds are rejected rather than silently flattened.
nonisolated struct XrayCompositeProfileParser {
    private typealias V = XrayProfileValidation

    func parse(_ profile: [String: Any]) throws -> ConnectionConfiguration {
        let section = "Balancer/observatory profile"
        try V.keys(profile, ["remarks", "outbounds", "inbounds", "dns", "log", "routing", "policy", "stats", "api", "burstObservatory"], section)
        for key in ["policy", "stats", "api"] {
            if let value = profile[key] { _ = try V.object(value, section) }
        }
        guard let outbounds = profile["outbounds"] as? [[String: Any]], !outbounds.isEmpty else { throw V.reject(section) }
        var tags = Set<String>()
        var localTags = Set<String>()
        var members: [XrayProfileMember] = []
        for outbound in outbounds {
            let tag = try V.string(outbound["tag"], section)
            guard tags.insert(tag).inserted else { throw V.reject("duplicate outbound tags") }
            if ["freedom", "blackhole"].contains(outbound["protocol"] as? String ?? "") {
                localTags.insert(tag)
                continue
            }
            // Every member goes through the existing strict endpoint parser.
            let configuration = try XraySubscriptionProfileParser().parseConfiguration(["outbounds": [outbound]])
            members.append(XrayProfileMember(tag: tag, configuration: configuration))
        }
        guard let first = members.first, members.count <= 64 else { throw V.reject(section) }
        let memberTags = members.map(\.tag)
        let routing = try V.object(profile["routing"], section)
        try V.keys(routing, ["domainStrategy", "domainMatcher", "rules", "balancers"], section)
        guard let balancers = routing["balancers"] as? [[String: Any]], balancers.count == 1 else { throw V.reject(section) }
        var balancer = balancers[0]
        try V.keys(balancer, ["tag", "selector", "fallbackTag", "strategy"], section)
        let balancerTag = try V.string(balancer["tag"], section)
        let selected = try selectedTags(balancer["selector"], from: memberTags)
        if let fallback = balancer["fallbackTag"] {
            guard let tag = fallback as? String, memberTags.contains(tag) else { throw V.reject("balancer fallback reference") }
        }
        var strategy = try V.object(balancer["strategy"], section)
        try V.keys(strategy, ["type", "settings"], section)
        guard let kind = strategy["type"] as? String, ["leastLoad", "leastPing", "random", "roundRobin"].contains(kind) else { throw V.reject(section) }
        if let value = strategy["settings"] {
            guard kind == "leastLoad" else { throw V.reject("balancer strategy settings") }
            var settings = try V.object(value, section)
            try V.keys(settings, ["expected", "maxRTT", "tolerance", "baselines", "costs"], section)
            if let expected = settings["expected"] { _ = try V.number(expected, section, max: Double(members.count)) }
            if let tolerance = settings["tolerance"] { _ = try V.number(tolerance, section, max: 1, integer: false) }
            if let duration = settings["maxRTT"] { try V.duration(duration, section) }
            if let value = settings["baselines"] {
                guard let durations = value as? [String] else { throw V.reject(section) }
                for duration in durations { try V.duration(duration, section) }
            }
            if let value = settings["costs"] {
                guard let costs = value as? [[String: Any]] else { throw V.reject(section) }
                var expanded: [[String: Any]] = []
                for cost in costs {
                    try V.keys(cost, ["match", "value", "regexp"], section)
                    let match = try V.string(cost["match"], section)
                    if let flag = cost["regexp"] {
                        guard let flag = flag as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw V.reject(section) }
                        // Literal regexes have identical Go and Swift substring
                        // semantics. Do not reinterpret other Go regex syntax.
                        if flag.boolValue, match.rangeOfCharacter(from: CharacterSet(charactersIn: ".\\+*?[^]$(){}|")) != nil {
                            throw V.reject("non-literal regular-expression balancer costs")
                        }
                    }
                    let weight = try V.number(cost["value"], section, integer: false)
                    guard weight > 0 else { throw V.reject("automatic balancer cost weights") }
                    let matching = memberTags.filter { $0.contains(match) }
                    expanded += matching.map { ["match": $0, "value": weight, "regexp": false] }
                }
                settings["costs"] = expanded
            }
            strategy["settings"] = settings
        }
        balancer["strategy"] = strategy
        // Expand provider prefixes now so unrelated groups can never match later.
        balancer["selector"] = selected
        let observer = try parseObserver(profile["burstObservatory"], memberTags: memberTags, selected: selected)

        guard let rules = routing["rules"] as? [[String: Any]], let last = rules.last,
              last["balancerTag"] as? String == balancerTag,
              Set(last.keys).isSubset(of: ["type", "network", "balancerTag"]),
              last["network"] == nil || last["network"] as? String == "tcp,udp",
              last["type"] == nil || last["type"] as? String == "field" else {
            throw V.reject("balancer catch-all routing")
        }
        for rule in rules.dropLast() {
            guard rule["balancerTag"] == nil, let tag = rule["outboundTag"] as? String,
                  localTags.contains(tag) else { throw V.reject("selective routing between proxy outbounds") }
        }
        var configuration = first.configuration
        configuration.composite = XrayCompositeProfile(members: members, balancer: try XrayJSONObject(balancer), burstObservatory: try XrayJSONObject(observer))
        configuration.xhttpExtra = nil
        configuration.outboundMux = nil
        var saved: [String: Any] = [
            "outbounds": outbounds.filter { !localTags.contains($0["tag"] as? String ?? "") },
            "routing": ["balancers": balancers, "rules": [["type": "field", "network": "tcp,udp", "balancerTag": balancerTag]]],
            "burstObservatory": profile["burstObservatory"]!,
        ]
        if let remarks = profile["remarks"] {
            guard let remarks = remarks as? String else { throw V.reject(section) }
            saved["remarks"] = remarks
        }
        configuration.rawLink = String(decoding: try JSONSerialization.data(withJSONObject: saved, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        return configuration.withDisplayName(profile["remarks"] as? String ?? "Auto")
    }

    private func selectedTags(_ value: Any?, from tags: [String]) throws -> [String] {
        guard let selectors = value as? [String], !selectors.isEmpty, selectors.allSatisfy({ !$0.isEmpty }) else {
            throw V.reject("balancer/observatory selectors")
        }
        let selected = tags.filter { tag in selectors.contains { tag.hasPrefix($0) } }
        guard !selected.isEmpty else { throw V.reject("unresolved balancer/observatory selectors") }
        return selected
    }

    private func parseObserver(_ value: Any?, memberTags: [String], selected: [String]) throws -> [String: Any] {
        let section = "Balancer/observatory settings"
        var observer = try V.object(value, section)
        try V.keys(observer, ["subjectSelector", "pingConfig"], section)
        let observed = try selectedTags(observer["subjectSelector"], from: memberTags)
        guard Set(selected).isSubset(of: Set(observed)) else { throw V.reject("unobserved balancer members") }
        observer["subjectSelector"] = observed
        let ping = try V.object(observer["pingConfig"], section)
        try V.keys(ping, ["destination", "connectivity", "interval", "sampling", "timeout", "httpMethod"], section)
        for key in ["destination", "connectivity"] {
            if let value = ping[key] {
                guard let string = value as? String else { throw V.reject(section) }
                if !string.isEmpty {
                    guard let url = URLComponents(string: string), ["https", "http"].contains(url.scheme),
                          url.host != nil, url.user == nil, url.password == nil else { throw V.reject(section) }
                }
            }
        }
        // Connectivity checks bypass the outbounds in Xray and cannot be safely
        // bound to our physical interface. Liberty leaves this field empty.
        guard (ping["connectivity"] as? String ?? "").isEmpty else { throw V.reject("direct observatory connectivity probes") }
        for key in ["interval", "timeout"] { if let value = ping[key] { try V.duration(value, section) } }
        if let value = ping["sampling"] { _ = try V.number(value, section, max: 100) }
        if let value = ping["httpMethod"] { guard let method = value as? String, ["", "HEAD", "GET"].contains(method) else { throw V.reject(section) } }
        return observer
    }
}
