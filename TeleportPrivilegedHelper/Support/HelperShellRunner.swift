import Foundation

struct HelperShellRunner: Sendable {
    /// `label` names the script in the error the client sees and in helper.log.
    func run(_ script: String, label: String = "shell command") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let stdout = BoundedOutputCollector(maxBytes: maxCapturedShellOutputBytes)
        let stderr = BoundedOutputCollector(maxBytes: maxCapturedShellOutputBytes)
        drain(outputPipe, into: stdout)
        drain(errorPipe, into: stderr)
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            stopDraining(outputPipe, into: stdout)
            stopDraining(errorPipe, into: stderr)
            throw error
        }

        stopDraining(outputPipe, into: stdout)
        stopDraining(errorPipe, into: stderr)

        guard process.terminationStatus == 0 else {
            // Captured output can contain root logs or configuration details. It
            // goes to helper.log, which the app reads through bounded diagnostics,
            // and not into the error that crosses to the client.
            let status = process.terminationStatus
            let stderrTail = stderr.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutTail = stdout.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let output = [stderrTail, stdoutTail].filter { !$0.isEmpty }.joined(separator: "\n")
            TeleportLog.shared.error("helper", "\(label) exited with status \(status)\(output.isEmpty ? "" : ": \(output.suffix(2000))")")
            throw HelperError(failureSummary(output: output, label: label, status: status))
        }
    }

    /// Only extract known failure categories and tightly bounded category names.
    /// Shell output can contain credentials and root-owned configuration data.
    private func failureSummary(output: String, label: String, status: Int32) -> String {
        let lower = output.lowercased()
        if lower.contains("permission denied") || lower.contains("operation not permitted") {
            return "macOS denied the helper access to a file or network setting. Reinstall Teleport's helper with administrator approval, then reconnect."
        }
        if lower.contains("no space left on device") || lower.contains("disk quota exceeded") {
            return "The disk is full, so the helper cannot save the tunnel configuration. Free disk space and reconnect."
        }
        if lower.contains("address already in use") {
            let pattern = #"(?:127\.0\.0\.1|\[::1\]|0\.0\.0\.0|\[::\]):([0-9]{1,5})(?![0-9])"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
               let range = Range(match.range(at: 1), in: output),
               let port = Int(output[range]), (1...65535).contains(port) {
                return "Local proxy port \(port) is already in use. Close the conflicting app, or change that port in Settings → Nerd Shit."
            }
            return "A local proxy port is already in use. Close the conflicting app, or change Teleport's local proxy ports in Settings → Nerd Shit."
        }
        guard label == "tunnel start script" else {
            return "The helper could not finish removing the tunnel's routes or state files (exit status \(status)). Disconnect other VPN apps and retry Disconnect. If this repeats, restart your Mac to clear the remaining network state."
        }
        for (file, name) in [("geosite.dat", "Geosite"), ("geoip.dat", "GeoIP")] {
            let escapedFile = NSRegularExpression.escapedPattern(for: file)
            let patterns = [
                "(?i)list not found in " + escapedFile + #":\s*([a-z0-9_@.!-]{1,128})(?=\s|$|>)"#,
                #"(?i)failed to (?:check|load) code ([a-z0-9_@.!-]{1,128}) from "# + escapedFile
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
                   let range = Range(match.range(at: 1), in: output) {
                    return "\(name) category ‘\(output[range])’ is missing or unreadable. Download the subscription's geodata in Settings → Tunnel, or change the routing rule to use a category available in the selected dataset."
                }
            }
            if lower.contains("failed to load " + name.lowercased()) || lower.contains("failed to open file: " + file) {
                return "Xray could not load the selected \(name) data. Open Settings → Tunnel and download the profile again, or choose another source."
            }
        }
        if lower.contains("failed to start:") {
            if lower.contains("invalid uuid") {
                return "The portal's VLESS user ID is invalid. Refresh its subscription or edit the portal's user ID before connecting again."
            }
            if lower.contains("public key") && (lower.contains("invalid") || lower.contains("empty")) {
                return "The portal's REALITY public key is invalid or missing. Refresh its subscription or correct the public key in the portal settings."
            }
            if lower.contains("failed to build routing") || lower.contains("invalid field rule") {
                return "Xray rejected a rule in the tunnel profile. Check the destinations and outgoing portals in Settings → Tunnel, or restore the subscription's profile."
            }
            return "Xray rejected the portal configuration. Refresh the subscription or reimport the portal; if you customized its tunnel profile, restore the subscription's profile and try again."
        }
        if lower.contains("macos did not create a tun interface") {
            return "Xray started, but macOS did not create a tunnel interface. Disconnect other VPN apps and try again. If this repeats, restart your Mac or use System Proxy mode."
        }
        if lower.contains("could not install") && lower.contains("default route") {
            return "macOS could not install Teleport's tunnel routes. Disconnect other VPN apps and reconnect. If the conflict remains, use System Proxy mode."
        }
        if lower.contains("did not route") || lower.contains("could not keep the proxy server route") {
            return "Another network route is overriding Teleport's tunnel. Disconnect other VPN apps and reconnect, or use System Proxy mode."
        }
        if lower.contains("teleport_failure_stage=protect-server-routes") {
            return "Teleport could not keep the proxy server reachable outside the tunnel. Reconnect to Wi-Fi or Ethernet and disconnect other VPN apps before retrying."
        }
        if lower.contains("teleport_failure_stage=prepare-files") {
            return "The helper could not prepare its tunnel files. Check free disk space and reinstall Teleport's helper with administrator approval before retrying."
        }
        return "The helper stopped while preparing the tunnel (exit status \(status)). Disconnect other VPN apps and reconnect. If this repeats, reinstall Teleport's helper."
    }

    private func drain(_ pipe: Pipe, into collector: BoundedOutputCollector) {
        pipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if data.isEmpty {
                fileHandle.readabilityHandler = nil
            } else {
                collector.append(data)
            }
        }
    }

    private func stopDraining(_ pipe: Pipe, into collector: BoundedOutputCollector) {
        let fileHandle = pipe.fileHandleForReading
        fileHandle.readabilityHandler = nil
        try? pipe.fileHandleForWriting.close()
        collector.append(fileHandle.readDataToEndOfFile())
    }
}

private final class BoundedOutputCollector {
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(maxBytes: Int) {
        self.maxBytes = max(1, maxBytes)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        data.append(chunk)
        if data.count > maxBytes {
            data = Data(data.suffix(maxBytes))
            truncated = true
        }
    }

    func text() -> String {
        lock.lock()
        let capturedData = data
        let wasTruncated = truncated
        lock.unlock()

        var output = String(decoding: capturedData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if wasTruncated {
            output = "[output truncated to last \(maxBytes) bytes]\n" + output
        }
        return output
    }
}
