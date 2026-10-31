import Foundation
import SystemConfiguration

nonisolated protocol ProxyPreferencesObserving: AnyObject {}

nonisolated protocol ProxyPreferencesAccess: AnyObject {
    func read() throws -> ProxyInventory
    /// Apply must compare this inventory under the preferences lock before writing.
    /// Even an empty patch applies preferences to finish an interrupted apply.
    func transaction(_ body: (ProxyInventory, ([ProxyMutation]) throws -> Void) throws -> Void) throws
    func observe(_ changed: @escaping @Sendable () -> Void) -> (any ProxyPreferencesObserving)?
}

nonisolated final class SystemProxyPreferences: ProxyPreferencesAccess {
    func read() throws -> ProxyInventory {
        guard let preferences = SCPreferencesCreate(nil, "dev.x.teleport.proxy.read" as CFString, nil) else {
            throw SystemProxyError.preferencesUnavailable
        }
        return try inventory(preferences)
    }

    func transaction(_ body: (ProxyInventory, ([ProxyMutation]) throws -> Void) throws -> Void) throws {
        guard let preferences = SCPreferencesCreate(nil, "dev.x.teleport.proxy" as CFString, nil) else {
            throw SystemProxyError.preferencesUnavailable
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !SCPreferencesLock(preferences, false) {
            let status = SCError()
            guard status == kSCStatusPrefsBusy, ProcessInfo.processInfo.systemUptime < deadline else {
                throw SystemProxyError.preferencesFailed("lock", status)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { SCPreferencesUnlock(preferences) }
        SCPreferencesSynchronize(preferences)
        try body(inventory(preferences)) { mutations in
            for mutation in mutations {
                guard let service = SCNetworkServiceCopy(preferences, mutation.serviceID as CFString),
                    let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
                else {
                    throw SystemProxyError.preferencesUnavailable
                }
                var dictionary = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] ?? [:]
                for key in mutation.removed { dictionary.removeValue(forKey: key) }
                for (key, value) in mutation.values { dictionary[key] = value.foundationValue }
                guard SCNetworkProtocolSetConfiguration(proxies, dictionary as CFDictionary) else {
                    throw SystemProxyError.preferencesFailed("stage", SCError())
                }
            }
            if !mutations.isEmpty, !SCPreferencesCommitChanges(preferences) {
                throw SystemProxyError.preferencesFailed("save", SCError())
            }
            // A failed apply can follow a successful commit. The caller keeps its
            // journal until this succeeds, including when recovery has no diff.
            guard SCPreferencesApplyChanges(preferences) else {
                throw SystemProxyError.preferencesFailed("apply", SCError())
            }
            SCPreferencesSynchronize(preferences)
            let verified = try self.inventory(preferences)
            for mutation in mutations {
                guard let values = verified.services[mutation.serviceID]?.values,
                    mutation.values.allSatisfy({ values[$0.key] == $0.value }),
                    mutation.removed.allSatisfy({ values[$0] == nil })
                else {
                    throw SystemProxyError.preferencesFailed("verify", 0)
                }
            }
        }
    }

    private func inventory(_ preferences: SCPreferences) throws -> ProxyInventory {
        guard let location = SCNetworkSetCopyCurrent(preferences),
            let locationID = SCNetworkSetGetSetID(location) as String?,
            let currentServices = SCNetworkSetCopyServices(location) as? [SCNetworkService],
            let allServices = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService]
        else {
            throw SystemProxyError.preferencesUnavailable
        }
        let eligible = Set(
            currentServices.filter { SCNetworkServiceGetEnabled($0) }.compactMap {
                SCNetworkServiceGetServiceID($0) as String?
            })
        var services: [String: ProxyServiceConfiguration] = [:]
        for service in allServices {
            guard let id = SCNetworkServiceGetServiceID(service) as String?,
                let proxies = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
            else { continue }
            let name = SCNetworkServiceGetName(service) as String? ?? id
            let dictionary = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] ?? [:]
            var values: ProxyValues = [:]
            for key in ProxyGroup.allCases.flatMap(\.keys) {
                guard let value = dictionary[key] else { continue }
                if let number = value as? NSNumber {
                    values[key] = .number(number.intValue)
                } else if let string = value as? String {
                    values[key] = .string(string)
                } else if let strings = value as? [String] {
                    values[key] = .strings(strings)
                } else {
                    throw SystemProxyError.preferencesUnavailable
                }
            }
            let credentialGroups = Set(
                [ProxyGroup.http, .https, .socks].filter { group in
                    dictionary.keys.contains { $0.hasPrefix(group.prefix!) && $0.localizedCaseInsensitiveContains("password") }
                })
            services[id] = ProxyServiceConfiguration(id: id, name: name, values: values, credentialGroups: credentialGroups)
        }
        // An enabled service with no proxies protocol is not a proxy target, e.g.
        // a service belonging to a network extension with its own configuration.
        return ProxyInventory(locationID: locationID, eligibleServiceIDs: eligible.intersection(services.keys), services: services)
    }

    func observe(_ changed: @escaping @Sendable () -> Void) -> (any ProxyPreferencesObserving)? {
        PreferencesObservation(changed: changed)
    }
}

nonisolated private final class PreferencesObservation: ProxyPreferencesObserving {
    private let preferences: SCPreferences
    private let queue = DispatchQueue(label: "dev.x.teleport.proxy.preferences")

    private final class Callback {
        let changed: @Sendable () -> Void
        init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
    }

    init?(changed: @escaping @Sendable () -> Void) {
        guard let preferences = SCPreferencesCreate(nil, "dev.x.teleport.proxy.observe" as CFString, nil) else { return nil }
        self.preferences = preferences
        let callback = Callback(changed)
        var context = SCPreferencesContext(
            version: 0,
            info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                _ = Unmanaged<Callback>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                Unmanaged<Callback>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        guard
            SCPreferencesSetCallback(
                preferences,
                { _, _, info in
                    if let info { Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().changed() }
                }, &context), SCPreferencesSetDispatchQueue(preferences, queue)
        else { return nil }
    }

    deinit {
        SCPreferencesSetDispatchQueue(preferences, nil)
        SCPreferencesSetCallback(preferences, nil, nil)
    }
}
