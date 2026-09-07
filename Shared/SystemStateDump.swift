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

    /// Only the start request carries the flag. Stop follows whatever the marker
    /// says, so a session started with dumps on is dumped at both ends even if the
    /// toggle was flipped in between — the pair is what makes a dump useful.
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
    ///
    /// Runs synchronously on the caller's thread — in the app that is the main
    /// actor, so with dumps on, connect and disconnect stall for the time it takes
    /// to spawn the probes, a few hundred milliseconds. Deliberate: the capture has
    /// to land between the two states it brackets, which moving it off-thread would
    /// not guarantee.
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
        // Nothing reads stderr, so it must not be a pipe: a probe that fills an
        // unread pipe blocks on the write, never closes stdout, and the read below
        // would wait on it forever.
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        guard (try? process.run()) != nil else { return nil }

        // The read happens on its own thread so the deadline applies to the whole
        // probe. Reading inline would block until the child closed stdout, which a
        // hung child never does — and this runs inside the helper's start handler,
        // so a hung probe would be a hung connect.
        let collected = OutputBox()
        let reader = Thread {
            collected.data = pipe.fileHandleForReading.readDataToEndOfFile()
        }
        reader.start()

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            // Reap the child; otherwise it stays a zombie for the life of this process.
            process.waitUntilExit()
        }
        // Termination closes the child's stdout, so the reader finishes either way.
        collected.wait()

        let output = String(decoding: collected.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut {
            return output + "\n<probe timed out after \(Int(timeout))s>"
        }
        return output.isEmpty ? "<empty>" : output
    }

    /// Hands the reader thread's output back to the caller. `@unchecked` because the
    /// semaphore orders the two accesses: the reader writes, signals, and only then
    /// does the caller read.
    private final class OutputBox: @unchecked Sendable {
        var data = Data() { didSet { done.signal() } }
        private let done = DispatchSemaphore(value: 0)
        func wait() { done.wait() }
    }
}
