import Darwin
import Foundation

/// Read-only adapter around macOS routing tools. These observations are taken
/// before the helper mutates routes and are therefore best-effort snapshots,
/// not reservations or guarantees about the later network topology.
nonisolated struct XrayTunRouteInspector: Sendable {
    func outboundInterface(for host: String) -> String? {
        routeInterface(for: host)
    }

    func resolvedAddresses(for host: String) -> [String] {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return [host] }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return [host.lowercased()] }

        guard let output = Self.commandOutput(
            executable: "/usr/bin/dscacheutil",
            arguments: ["-q", "host", "-a", "name", host]
        ) else {
            return []
        }
        return Self.resolvedAddresses(in: output)
    }

    static func resolvedAddresses(in output: String) -> [String] {
        var seen: Set<String> = []
        return output
            .split(separator: "\n")
            .compactMap { line -> String? in
                let components = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard components.count == 2,
                      (components[0] == "ip_address" || components[0] == "ipv6_address"),
                      seen.insert(components[1]).inserted else {
                    return nil
                }
                return components[1]
            }
    }

    func existingVPNDefaultRouteInterface() -> String? {
        // macOS commonly publishes interface-scoped IPv6 `default` entries for
        // system utun devices even when they are not usable as a global route.
        // Ask the kernel which route it would actually select for addresses in
        // both halves of each address family instead of treating every table row
        // as traffic interception.
        let probes: [(familyArguments: [String], address: String)] = [
            ([], "1.1.1.1"),
            ([], "129.0.0.1"),
            (["-inet6"], "2606:4700:4700::1111"),
            (["-inet6"], "9000::1")
        ]
        let outputs = probes.compactMap { probe in
            Self.commandOutput(
                executable: "/sbin/route",
                arguments: ["-n", "get"] + probe.familyArguments + [probe.address]
            )
        }
        return Self.detectedVPNInterface(inRouteLookups: outputs)
    }

    static func detectedVPNInterface(inRouteLookups outputs: [String]) -> String? {
        for output in outputs {
            for line in output.split(separator: "\n") {
                let components = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard components.first == "interface:",
                      let interface = components.last,
                      interface.hasPrefix("utun") else {
                    continue
                }
                return interface
            }
        }
        return nil
    }

    func routeInterface(for host: String) -> String? {
        // `route get` does not infer the family from an IPv6 literal; without
        // `-inet6` it reports "bad address" and the lookup silently fails.
        var ipv6 = in6_addr()
        let familyArguments = host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 ? ["-inet6"] : []
        guard let output = Self.commandOutput(executable: "/sbin/route", arguments: ["-n", "get"] + familyArguments + [host]) else {
            return nil
        }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("interface:") }?
            .split(separator: " ")
            .last
            .map(String.init)
    }

    func ipv4Address(for interfaceName: String) -> String? {
        guard !interfaceName.isEmpty, interfaceName != "auto" else { return nil }
        return NetworkInterfaceInventory.ipv4Address(of: interfaceName)
    }

    func hasGlobalIPv6(on interfaceName: String) -> Bool {
        guard !interfaceName.isEmpty, interfaceName != "auto" else { return false }
        return NetworkInterfaceInventory.hasGlobalIPv6Address(interfaceName)
    }

    /// A preference, not a reservation. The name is chosen here and the TUN is
    /// created by Xray moments later in the helper, so another process can take
    /// it in between. That is tolerated rather than prevented: the helper's start
    /// script checks whether the requested name came up and otherwise finds the
    /// utun Xray actually created, and every route it installs names that one.
    func nextAvailableTunnelInterfaceName() -> String {
        let existingIndexes = existingTunnelInterfaceIndexes()
        let startIndex = 10
        let endIndex = 199
        for index in startIndex ... endIndex where !existingIndexes.contains(index) {
            return "utun\(index)"
        }
        return "utun\(endIndex + 1)"
    }

    private func existingTunnelInterfaceIndexes() -> Set<Int> {
        Set(NetworkInterfaceInventory.interfaceNames().compactMap { name -> Int? in
            guard name.hasPrefix("utun") else { return nil }
            return Int(name.dropFirst(4))
        })
    }

    private static func commandOutput(executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
