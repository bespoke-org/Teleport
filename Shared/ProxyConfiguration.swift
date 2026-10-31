import Foundation

/// Only the documented proxy fields we inspect. Unknown dictionary keys stay in
/// SystemConfiguration and are never copied into a recovery file.
nonisolated enum ProxyValue: Codable, Equatable, Sendable {
    case number(Int)
    case string(String)
    case strings([String])

    var foundationValue: Any {
        switch self {
        case .number(let value): return value
        case .string(let value): return value
        case .strings(let value): return value
        }
    }
}

typealias ProxyValues = [String: ProxyValue]

nonisolated enum ProxyGroup: String, Codable, CaseIterable, Sendable {
    case http, https, socks, pac, wpad, bypass

    var prefix: String? {
        switch self {
        case .http: return "HTTP"
        case .https: return "HTTPS"
        case .socks: return "SOCKS"
        default: return nil
        }
    }

    var keys: [String] {
        if let prefix {
            return ["\(prefix)Enable", "\(prefix)Proxy", "\(prefix)Port", "\(prefix)User", "\(prefix)ProxyAuthenticated"]
        }
        switch self {
        case .pac: return ["ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "ProxyAutoConfigJavaScript"]
        case .wpad: return ["ProxyAutoDiscoveryEnable"]
        case .bypass: return ["ExceptionsList", "ExcludeSimpleHostnames"]
        default: return []
        }
    }

    var label: String {
        switch self {
        case .http: return "HTTP proxy"
        case .https: return "HTTPS proxy"
        case .socks: return "SOCKS proxy"
        case .pac: return "automatic proxy configuration"
        case .wpad: return "proxy auto-discovery"
        case .bypass: return "proxy bypass exceptions"
        }
    }

    func values(in configuration: ProxyValues) -> ProxyValues {
        configuration.filter { keys.contains($0.key) }
    }
}

nonisolated struct ProxyServiceConfiguration: Codable, Equatable, Sendable {
    let id: String
    let name: String
    var values: ProxyValues
    /// Detect password-bearing metadata by key presence; never read its value.
    var credentialGroups: Set<ProxyGroup> = []

    func isAuthenticated(_ group: ProxyGroup) -> Bool {
        guard let prefix = group.prefix else { return false }
        if credentialGroups.contains(group) { return true }
        if case .string(let user) = values["\(prefix)User"], !user.isEmpty { return true }
        if case .number(let flag) = values["\(prefix)ProxyAuthenticated"], flag != 0 { return true }
        return false
    }
}

nonisolated struct ProxyInventory: Codable, Equatable, Sendable {
    let locationID: String
    let eligibleServiceIDs: Set<String>
    var services: [String: ProxyServiceConfiguration]
}

/// Patches are deliberately limited to keys owned by a particular operation.
nonisolated struct ProxyMutation: Codable, Equatable, Sendable {
    let serviceID: String
    var values: ProxyValues = [:]
    var removed: Set<String> = []
}

nonisolated enum SystemProxyError: LocalizedError {
    case authenticatedProxyCannotBePreserved
    case preferencesUnavailable
    case preferencesChanged
    case preferencesFailed(String, Int32)
    case anotherInstance
    case invalidJournal
    case legacyJournal
    case unresolvedService
    case noServices

    var errorDescription: String? {
        switch self {
        case .authenticatedProxyCannotBePreserved:
            return
                "Existing authenticated proxy settings cannot be safely preserved. Disable enabled authenticated proxies before using TUN mode, or remove their configuration before using System Proxy mode. Teleport does not restore proxy passwords."
        case .preferencesUnavailable: return "Failed to read the system proxy settings."
        case .preferencesChanged:
            return "System proxy settings changed before Teleport could update them. The external changes were preserved. Reconnect when ready."
        case .preferencesFailed(let operation, let status):
            return "Could not \(operation) system proxy preferences (\(status)). Saved recovery records were retained."
        case .anotherInstance: return "Another Teleport instance owns proxy settings. Disconnect or quit that instance first."
        case .invalidJournal:
            return "The proxy recovery file is corrupt or unsupported. It was preserved; resolve it before connecting. See the proxy recovery documentation."
        case .legacyJournal:
            return
                "A proxy recovery file from an older Teleport version needs manual review. It lacks stable service IDs, so automatic restoration could overwrite another service. See the proxy recovery documentation."
        case .unresolvedService: return "A network service still has unresolved proxy recovery records. Restore it before starting another connection."
        case .noServices: return "No enabled network services with proxy settings are available."
        }
    }
}

nonisolated extension ApplyProxyPreferencesRequest {
    /// Bound and allowlist the privileged operation even for an approved client.
    func validateMutations() throws {
        let keys = Set(ProxyGroup.allCases.flatMap(\.keys))
        guard expected.services.count <= 256, mutations.count <= 256,
              expected.eligibleServiceIDs.isSubset(of: Set(expected.services.keys)),
              Set(mutations.map(\.serviceID)).count == mutations.count else {
            throw invalidMutation()
        }
        for mutation in mutations {
            guard !mutation.serviceID.isEmpty, mutation.serviceID.utf8.count <= 256,
                  expected.services[mutation.serviceID]?.id == mutation.serviceID,
                  Set(mutation.values.keys).union(mutation.removed).isSubset(of: keys),
                  Set(mutation.values.keys).isDisjoint(with: mutation.removed) else {
                throw invalidMutation()
            }
            for (key, value) in mutation.values {
                switch (key, value) {
                case ("ExceptionsList", .strings): break
                case (_, .number) where key.hasSuffix("Enable") || key.hasSuffix("Port")
                    || key.hasSuffix("Authenticated") || key == "ExcludeSimpleHostnames": break
                case (_, .string) where key.hasSuffix("Proxy") || key.hasSuffix("User")
                    || key == "ProxyAutoConfigURLString" || key == "ProxyAutoConfigJavaScript": break
                default: throw invalidMutation()
                }
            }
        }
    }

    /// Compare each changed group as a unit, including authentication metadata.
    /// Unrelated fields, including TUN bypass exceptions, do not veto a write.
    func matches(_ live: ProxyInventory) -> Bool {
        guard live.locationID == expected.locationID,
              live.eligibleServiceIDs == expected.eligibleServiceIDs else { return false }
        for mutation in mutations {
            guard let before = expected.services[mutation.serviceID],
                  let now = live.services[mutation.serviceID] else { return false }
            let changed = Set(mutation.values.keys).union(mutation.removed)
            for group in ProxyGroup.allCases where !changed.isDisjoint(with: group.keys) {
                guard group.values(in: before.values) == group.values(in: now.values),
                      before.credentialGroups.contains(group) == now.credentialGroups.contains(group) else { return false }
            }
        }
        return true
    }

    private func invalidMutation() -> TUNHelperProtocolFailure {
        TUNHelperProtocolFailure(code: .malformedPayload, summary: "The proxy update contains unsupported fields or services",
                                 details: nil, retryDisposition: .never)
    }
}
