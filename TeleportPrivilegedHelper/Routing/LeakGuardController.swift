import Darwin
import Foundation

/// Owns the pf ruleset that keeps traffic off the physical uplink while a VPN
/// session is meant to be carrying it, and the lease that guarantees it comes
/// back off.
///
/// The guard is the one piece of root state that can leave the machine with no
/// usable network, so nothing here is allowed to outlive the app that asked for
/// it. Three things take it down: an explicit release, the helper starting (a
/// helper that just launched is holding a guard nobody asked it to hold), and a
/// lease that the client has to keep renewing. A client that crashes renews
/// nothing, and the machine is back on the network within the lease.
///
/// `@unchecked Sendable`: every access to the engaged state goes through `lock`.
final class LeakGuardController: @unchecked Sendable {
    /// Long enough that an ordinary reconnect never races it, short enough that a
    /// crashed app is not a support call. The client renews well inside it.
    static let maximumLeaseSeconds: TimeInterval = 180

    static let subsystem = "helper"

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.x.teleport.helper.leak-guard", qos: .utility)
    private let helperStateDirectoryPath: String
    private var leaseTimer: DispatchSourceTimer?
    private var isEngaged = false

    init(helperStateDirectoryPath: String) {
        self.helperStateDirectoryPath = helperStateDirectoryPath
    }

    private var rulesPath: String { helperStateDirectoryPath + "/leak-guard.pf" }
    private var tokenPath: String { helperStateDirectoryPath + "/leak-guard.token" }

    /// Removes a guard left behind by a previous helper process. Called before the
    /// listener accepts anything: whatever asked for that guard is gone, and a
    /// machine that cannot reach the network cannot be told to fix itself.
    func releaseStaleGuard() {
        guard FileManager.default.fileExists(atPath: tokenPath) else { return }
        TeleportLog.shared.warn(Self.subsystem, "releasing a leak guard left by a previous helper process")
        release()
    }

    func engage(stage: LeakGuardRuleset.Stage, protectedHosts: [String], leaseSeconds: TimeInterval) throws {
        let rules = LeakGuardRuleset.rules(stage: stage, protectedHosts: protectedHosts)
        try writeRootOwned(rules, to: rulesPath)

        // `pfctl -E` is reference counted across everything on the machine that
        // uses pf, so the token is taken once and kept until the guard is
        // released. Enabling twice would leave pf on for whoever comes next.
        lock.lock()
        let needsEnable = !isEngaged
        lock.unlock()
        if needsEnable {
            let token = try enablePacketFilter()
            try writeRootOwned(token + "\n", to: tokenPath)
        }

        try run("/sbin/pfctl", ["-a", LeakGuardRuleset.anchorName, "-f", rulesPath])

        lock.lock()
        isEngaged = true
        lock.unlock()
        armLease(seconds: min(leaseSeconds, Self.maximumLeaseSeconds))
        TeleportLog.shared.info(Self.subsystem, "leak guard engaged (\(stageSummary(stage)), \(protectedHosts.count) protected hosts)")
    }

    /// Flushes the anchor whether or not this process believes it engaged one, so a
    /// release always leaves the machine reachable.
    func release() {
        lock.lock()
        leaseTimer?.cancel()
        leaseTimer = nil
        let wasEngaged = isEngaged
        isEngaged = false
        lock.unlock()

        try? run("/sbin/pfctl", ["-a", LeakGuardRuleset.anchorName, "-F", "all"])
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            try? run("/sbin/pfctl", ["-X", token])
        }
        unlink(tokenPath)
        unlink(rulesPath)
        if wasEngaged {
            TeleportLog.shared.info(Self.subsystem, "leak guard released")
        }
    }

    private func armLease(seconds: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            TeleportLog.shared.warn(Self.subsystem, "leak guard lease expired without a renewal; releasing")
            self?.release()
        }
        lock.lock()
        leaseTimer?.cancel()
        leaseTimer = timer
        lock.unlock()
        timer.resume()
    }

    /// Returns the token `pfctl -E` prints, which `pfctl -X` needs to give the
    /// reference back.
    private func enablePacketFilter() throws -> String {
        let output = try run("/sbin/pfctl", ["-E"])
        // The token is on stderr, as `Token : 1234567890`.
        guard let line = output.split(separator: "\n").first(where: { $0.contains("Token") }),
              let token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
              !token.isEmpty,
              token.allSatisfy(\.isNumber) else {
            throw HelperError("Teleport could not enable the packet filter for its leak guard.")
        }
        return token
    }

    @discardableResult
    private func run(_ executablePath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperError("Teleport could not apply its leak-guard firewall rules.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func writeRootOwned(_ contents: String, to path: String) throws {
        var statInfo = stat()
        if lstat(path, &statInfo) == 0, (statInfo.st_mode & S_IFMT) == S_IFLNK {
            unlink(path)
        }
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        guard chown(path, 0, 0) == 0, chmod(path, 0o600) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    private func stageSummary(_ stage: LeakGuardRuleset.Stage) -> String {
        switch stage {
        case .standby: return "standby"
        case let .session(tunnelInterface): return "session over \(tunnelInterface)"
        }
    }
}
