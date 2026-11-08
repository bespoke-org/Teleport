import Darwin
import Foundation

/// Owns persistent protection. A missed heartbeat tightens the rules to standby;
/// only an authenticated explicit release removes them. Operations and expiry
/// share one lock, so an old timer cannot overwrite a newer session policy.
final class LeakGuardController: @unchecked Sendable {
    static let maximumLeaseSeconds: TimeInterval = 180
    private let lock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "dev.x.teleport.helper.leak-guard")
    private let helperStateDirectoryPath: String
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private var engaged = false
    private var lastRules: String?
    private let groupID: () throws -> UInt32
    private let execute: (String, [String]) throws -> String

    init(helperStateDirectoryPath: String,
         groupID: @escaping () throws -> UInt32 = {
             guard let group = getgrnam(PrivilegedHelperConstants.runtimeGroup),
                   group.pointee.gr_gid != 0, getegid() == group.pointee.gr_gid else {
                 throw HelperError("Teleport's isolated runtime group is unavailable. Reinstall the helper.")
             }
             return group.pointee.gr_gid
         },
         execute: @escaping (String, [String]) throws -> String = LeakGuardController.run) {
        self.helperStateDirectoryPath = helperStateDirectoryPath
        self.groupID = groupID
        self.execute = execute
    }

    var isEngaged: Bool { lock.lock(); defer { lock.unlock() }; return engaged }
    private var rulesPath: String { helperStateDirectoryPath + "/leak-guard.pf" }
    private var tokenPath: String { helperStateDirectoryPath + "/leak-guard.token" }

    func restoreGuard() throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: rulesPath) else { return }
        // Reacquire a reference even after a reboot. Release the previous token
        // only after the new reference exists, avoiding a filter-disabled gap.
        try apply(stage: .standby, policy: .init())
        TeleportLog.shared.warn("helper", "restored protection in standby; direct access remains blocked")
    }

    func engage(stage: LeakGuardRuleset.Stage, protectedHosts: [String], leaseSeconds: TimeInterval, policy: LeakGuardPolicy = .init()) throws {
        lock.lock(); defer { lock.unlock() }
        try apply(stage: stage, policy: policy)
        timer?.cancel()
        generation = UUID()
        let expectedGeneration = generation
        let next = DispatchSource.makeTimerSource(queue: queue)
        next.schedule(deadline: .now() + min(leaseSeconds, Self.maximumLeaseSeconds))
        next.setEventHandler { [weak self] in self?.expireLease(generation: expectedGeneration) }
        timer = next
        next.resume()
    }

    /// Internal for deterministic lifecycle tests; an expired lease never calls release.
    func expireLease(generation expected: UUID? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard engaged, expected == nil || expected == generation else { return }
        do {
            try apply(stage: .standby, policy: .init())
            TeleportLog.shared.warn("helper", "protection heartbeat expired; traffic remains blocked in standby")
        } catch {
            // Keep the existing filter if tightening failed. Never flush it.
            TeleportLog.shared.error("helper", "could not tighten protection after heartbeat expiry")
        }
    }

    private func apply(stage: LeakGuardRuleset.Stage, policy: LeakGuardPolicy) throws {
        let rules = LeakGuardRuleset.rules(stage: stage, policy: policy, runtimeGroupID: try groupID())
        guard !engaged || rules != lastRules else { return }
        if !engaged {
            let rootRules = try execute("/sbin/pfctl", ["-sr"])
            // Loading an unreferenced anchor succeeds but filters no packets.
            // Other root filter rules could override this nested anchor, so only
            // the stock macOS filter structure is supported.
            let filterLines = rootRules.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("scrub-anchor ")
                    && $0 != "No ALTQ support in kernel" && $0 != "ALTQ related functions disabled" }
            guard filterLines == ["anchor \"com.apple/*\" all"] else {
                throw HelperError("Protection requires the standard macOS packet-filter anchor. Custom PF rules are not supported.")
            }
        }
        try writeRootOwned(rules, to: rulesPath)
        if !engaged {
            let previousToken = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let output = try execute("/sbin/pfctl", ["-E"])
            guard let line = output.split(separator: "\n").first(where: { $0.contains("Token") }),
                  let token = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                  !token.isEmpty, token.allSatisfy(\.isNumber) else {
                throw HelperError("Teleport could not enable its packet filter.")
            }
            try writeRootOwned(token + "\n", to: tokenPath)
            if let previousToken, !previousToken.isEmpty, previousToken.allSatisfy(\.isNumber) {
                _ = try? execute("/sbin/pfctl", ["-X", previousToken])
            }
        }
        _ = try execute("/sbin/pfctl", ["-a", LeakGuardRuleset.anchorName, "-f", rulesPath])
        if !engaged {
            // PF checks existing states before filter rules. Enabling protection
            // must retire pre-existing direct connections, including IPv6/UDP.
            _ = try execute("/sbin/pfctl", ["-F", "states"])
        }
        engaged = true
        lastRules = rules
    }

    func release() throws {
        lock.lock(); defer { lock.unlock() }
        _ = try execute("/sbin/pfctl", ["-a", LeakGuardRuleset.anchorName, "-F", "all"])
        if let token = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty, token.allSatisfy(\.isNumber) {
            _ = try? execute("/sbin/pfctl", ["-X", token])
        }
        timer?.cancel(); timer = nil; generation = UUID()
        engaged = false; lastRules = nil
        unlink(tokenPath); unlink(rulesPath)
    }

    private func writeRootOwned(_ contents: String, to path: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        // The production directory is root-only. Tests use an isolated directory
        // owned by their current uid; never operate on the real helper paths.
        guard chmod(path, 0o600) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw HelperError("Teleport could not apply its protection rules.") }
        return String(decoding: data, as: UTF8.self)
    }
}
