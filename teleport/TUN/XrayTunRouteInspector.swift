import Darwin
import Foundation

/// Read-only adapter around macOS routing tools. These observations are taken
/// before the helper mutates routes and are therefore best-effort snapshots,
/// not reservations or guarantees about the later network topology.
nonisolated struct XrayTunRouteInspector: Sendable {
    private let runCommand: @Sendable (String, [String]) -> String?

    init(runCommand: @escaping @Sendable (String, [String]) -> String? = {
        Self.commandOutput(executable: $0, arguments: $1)
    }) {
        self.runCommand = runCommand
    }

    /// The reachable numeric address of one server and the physical interface
    /// that reaches it.
    func protectedRoute(for host: String, resolvedAddresses: [String]? = nil) throws -> (address: String, interface: String) {
        let resolvedAddresses = resolvedAddresses ?? self.resolvedAddresses(for: host)
        guard !resolvedAddresses.isEmpty else {
            throw XrayTunConnectionError.proxyAddressResolutionFailed(host)
        }
        guard let route = resolvedAddresses.lazy.compactMap({ address -> (String, String)? in
            guard let interface = self.outboundInterface(for: address) else { return nil }
            return (address, interface)
        }).first else {
            // Do not infer IPv6-only from an empty DNS result. This diagnosis
            // requires actual IPv6 answers and no returned IPv4 alternative.
            if resolvedAddresses.allSatisfy({ address in
                var value = in6_addr()
                return address.withCString { inet_pton(AF_INET6, $0, &value) } == 1
            }) {
                throw XrayTunConnectionError.proxyIPv6RouteUnavailable(host)
            }
            throw XrayTunConnectionError.proxyRouteUnavailable(host)
        }
        return route
    }

    func outboundInterface(for host: String) -> String? {
        routeInterface(for: host)
    }

    func resolvedAddresses(for host: String) -> [String] {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return [host] }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return [host.lowercased()] }

        guard let output = runCommand(
            "/usr/bin/dscacheutil",
            ["-q", "host", "-a", "name", host]
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
        existingVPNDefaultRouteInterfaces().first
    }

    func existingVPNDefaultRouteInterfaces() -> [String] {
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
            runCommand(
                "/sbin/route",
                ["-n", "get"] + probe.familyArguments + [probe.address]
            )
        }
        return outputs.compactMap { Self.detectedVPNInterface(inRouteLookups: [$0]) }
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
        guard let output = runCommand("/sbin/route", ["-n", "get"] + familyArguments + [host]) else {
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

    private static func commandOutput(executable: String, arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // `dscacheutil` waits about a minute on a resolver that does not answer,
        // and every connection operation — disconnect and quit included — queues
        // behind the connect that is waiting here.
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            // Reap the child; otherwise it stays a zombie for the life of this process.
            process.waitUntilExit()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
