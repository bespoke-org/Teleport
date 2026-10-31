import Foundation

nonisolated extension ProxyGroup {
    func target(from original: ProxyValues, mode: ConnectionMode, endpoint: ProxyEndpoint) -> ProxyValues {
        var result = original
        if let prefix {
            result["\(prefix)Enable"] = .number(mode == .systemProxy ? 1 : 0)
            if mode == .systemProxy {
                result["\(prefix)Proxy"] = .string(endpoint.host)
                result["\(prefix)Port"] = .number(self == .socks ? endpoint.socksPort : endpoint.httpPort)
            }
        } else {
            switch self {
            case .pac: result["ProxyAutoConfigEnable"] = .number(0)
            case .wpad: result["ProxyAutoDiscoveryEnable"] = .number(0)
            case .bypass:
                result["ExceptionsList"] = .strings(["localhost", "127.0.0.0/8", "::1"])
                // CFNetwork on macOS 27 treats presence, including numeric zero,
                // as enabled. Absence disables simple-hostname exclusion.
                result.removeValue(forKey: "ExcludeSimpleHostnames")
            default: break
            }
        }
        return result
    }
}

nonisolated extension ProxyServiceConfiguration {
    func rejectUnsafeAuthentication(mode: ConnectionMode) throws {
        for group in [ProxyGroup.http, .https, .socks] where isAuthenticated(group) {
            let enabled = values["\(group.prefix!)Enable"] != nil && values["\(group.prefix!)Enable"] != .number(0)
            if mode == .systemProxy || enabled { throw SystemProxyError.authenticatedProxyCannotBePreserved }
        }
    }
}

nonisolated extension ProxyMutation {
    mutating func restore(_ record: ProxyGroupRecord) {
        for key in Set(record.original.keys).union(record.applied.keys) where record.original[key] != record.applied[key] {
            if let value = record.original[key] { values[key] = value } else { removed.insert(key) }
        }
    }
}

nonisolated struct ProxyGroupRecord: Codable, Equatable, Sendable {
    let group: ProxyGroup
    let original: ProxyValues
    let applied: ProxyValues
    var hasCredentialMetadata = false
    var relinquished = false
}

nonisolated struct ProxyServiceRecord: Codable, Sendable {
    let sessionID: UUID
    let serviceID: String
    let serviceName: String
    var groups: [ProxyGroupRecord]
}

nonisolated struct ProxySessionRecord: Codable, Sendable {
    let id: UUID
    let mode: ConnectionMode
    let locationID: String
    let eligibleServiceIDs: Set<String>
}

nonisolated struct ProxyJournal: Codable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var session: ProxySessionRecord?
    var services: [ProxyServiceRecord] = []
}
