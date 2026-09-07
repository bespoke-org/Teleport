import Foundation

/// Captures the pieces of macOS networking state that Teleport mutates, so the log
/// shows what the machine actually looked like on either side of a change rather
/// than only what Teleport intended to do.
///
/// macOS has no iptables: what Teleport touches is the kernel routing table
/// (`route`/`netstat`), the resolver configuration (`scutil --dns`), the packet
/// filter (`pfctl`, root only) and the SystemConfiguration proxy settings
/// (`networksetup`). Those are the four things captured here.
///
/// Off by default — each capture spawns several processes and adds a few KB to the
/// log, which is worth it while diagnosing a problem and not worth it otherwise.
nonisolated enum SystemStateDump {
    static let subsystem = "state"

    /// User default read by the app; `defaults write dev.x.teleport
    /// TeleportDiagnosticsStateDumps -bool YES` works as well as the Settings toggle.
    static let defaultsKey = "TeleportDiagnosticsStateDumps"

    /// The root helper has no user defaults of its own, so the app's choice reaches
    /// it as a marker file it writes when a session starts.
    static var markerFileURL: URL {
        URL(fileURLWithPath: PrivilegedHelperConstants.helperStateDirectoryPath, isDirectory: true)
            .appendingPathComponent("diagnostics-state-dumps")
    }

    static var isEnabled: Bool {
        if getuid() == 0 {
            return FileManager.default.fileExists(atPath: markerFileURL.path)
        }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }

    static func setMarker(_ enabled: Bool) {
        if enabled {
            FileManager.default.createFile(atPath: markerFileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? FileManager.default.removeItem(at: markerFileURL)
        }
    }

    /// Writes a labelled snapshot to the log. `label` should say where in a sequence
    /// this is ("before enabling system proxy", "after tunnel start"), because the
    /// point of a dump is the diff between two of them.
    static func capture(_ label: String, log: TeleportLog = .shared) {
        guard isEnabled else { return }

        for probe in probes() {
            guard let output = run(probe.executablePath, probe.arguments) else { continue }
            log.dump(subsystem, "\(label): \(probe.title)", output)
        }
    }

    private struct Probe {
        let title: String
        let executablePath: String
        let arguments: [String]
    }

    private static func probes() -> [Probe] {
        var probes: [Probe] = [
            Probe(title: "routes inet", executablePath: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"]),
            Probe(title: "routes inet6", executablePath: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet6"]),
            Probe(title: "resolvers", executablePath: "/usr/sbin/scutil", arguments: ["--dns"]),
            Probe(title: "interfaces", executablePath: "/sbin/ifconfig", arguments: ["-a"])
        ]

        if getuid() == 0 {
            // pfctl needs root, so these only ever produce output inside the helper.
            probes.append(Probe(title: "pf rules", executablePath: "/sbin/pfctl", arguments: ["-s", "rules"]))
            probes.append(Probe(title: "pf nat", executablePath: "/sbin/pfctl", arguments: ["-s", "nat"]))
        } else {
            // networksetup reads SystemConfiguration as the logged-in user; running it
            // from the root helper would report a different preference session.
            probes.append(Probe(title: "network services", executablePath: "/usr/sbin/networksetup", arguments: ["-listallnetworkservices"]))
        }

        return probes
    }

    /// Proxy settings are dumped per service rather than as one command, because
    /// `networksetup` has no "show every proxy" form.
    static func captureProxySettings(_ label: String, services: [String], log: TeleportLog = .shared) {
        guard isEnabled else { return }

        var text = ""
        for service in services {
            for arguments in [["-getwebproxy", service], ["-getsecurewebproxy", service], ["-getsocksfirewallproxy", service]] {
                guard let output = run("/usr/sbin/networksetup", arguments) else { continue }
                text += "\(service) \(arguments[0]):\n"
                for outputLine in output.split(separator: "\n") {
                    text += "  \(outputLine)\n"
                }
            }
        }
        log.dump(subsystem, "\(label): proxy settings", text.isEmpty ? "<no services>" : text)
    }

    private static func run(_ executablePath: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }

        // Read before waiting: a probe that fills the pipe buffer would otherwise
        // block forever with the parent waiting on a child that cannot write.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return String(decoding: data, as: UTF8.self) + "\n<probe timed out>"
        }

        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "<empty>" : output
    }
}
