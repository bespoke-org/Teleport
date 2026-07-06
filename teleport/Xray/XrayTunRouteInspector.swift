import Foundation

struct XrayTunRouteInspector: Sendable {
    func outboundInterface(for host: String) -> String? {
        routeInterface(for: host)
    }

    /// The physical interface carrying the default route right now, before the
    /// tunnel is installed. Used as a robust fallback so split-tunnel "direct"
    /// traffic can always be bound to a real uplink instead of looping into the TUN.
    func defaultRouteInterface() -> String? {
        routeInterface(for: "default")
    }

    func existingVPNDefaultRouteInterface() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-rn", "-f", "inet"]

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
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output
            .split(separator: "\n")
            .map { $0.split(separator: " ").map(String.init) }
            .first { columns in
                columns.first == "default" && columns.last?.hasPrefix("utun") == true
            }?
            .last
    }

    func routeInterface(for host: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", "get", host]

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
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix("interface:") }?
            .split(separator: " ")
            .last
            .map(String.init)
    }

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = ["-l"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }
        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Set(output
            .split(separator: " ")
            .compactMap { name -> Int? in
                guard name.hasPrefix("utun") else { return nil }
                return Int(name.dropFirst(4))
            })
    }
}
