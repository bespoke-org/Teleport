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
    private var expiryRetryDelay: TimeInterval = 1
    private var generation = UUID()
    private var engaged = false
    private var lastRules: String?
    private var installedAnchor: String?
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

    var isEngaged: Bool {
        lock.lock(); defer { lock.unlock() }
        return engaged && (try? livePolicyMatches()) == true
    }

    /// Retry a failed startup restore before allowing network work. Status and
    /// explicit release remain available even when the saved policy cannot load.
    func requireProtectionIfPersisted() throws {
        lock.lock(); defer { lock.unlock() }
        if engaged {
            guard try livePolicyMatches() else { throw HelperError("Firewall protection could not be verified.") }
        } else {
            try restoreGuard()
        }
    }

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
        expiryRetryDelay = 1
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
            // Reschedule the same generation; replacement and release cancel this timer.
            timer?.schedule(deadline: .now() + expiryRetryDelay)
            expiryRetryDelay = min(30, expiryRetryDelay * 2)
            TeleportLog.shared.error("helper", "could not tighten protection after heartbeat expiry")
        }
    }

    private func apply(stage: LeakGuardRuleset.Stage, policy: LeakGuardPolicy) throws {
        let rules = LeakGuardRuleset.rules(stage: stage, policy: policy, runtimeGroupID: try groupID())
        try validateRootRules()
        let intact = try engaged && installedFilterMatches()
        guard !intact || rules != lastRules else { return }
        try writeRootOwned(rules, to: rulesPath)
        if !intact {
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
        if !intact {
            // PF checks existing states before filter rules. Enabling protection
            // must retire pre-existing direct connections, including IPv6/UDP.
            _ = try execute("/sbin/pfctl", ["-F", "states"])
        }
        let loaded = try anchorRules()
        guard !loaded.isEmpty, try filterEnabled() else {
            throw HelperError("Teleport could not confirm its packet filter.")
        }
        installedAnchor = loaded
        engaged = true
        lastRules = rules
    }

    private func validateRootRules() throws {
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

    private func filterEnabled() throws -> Bool {
        let info = try execute("/sbin/pfctl", ["-s", "info"])
        return info.split(separator: "\n").contains { $0.split(whereSeparator: \.isWhitespace).prefix(2) == ["Status:", "Enabled"] }
    }

    private func anchorRules() throws -> String {
        let output = try execute("/sbin/pfctl", ["-a", LeakGuardRuleset.anchorName, "-sr"])
        return output.split(separator: "\n").filter {
            !$0.hasPrefix("No ALTQ support") && !$0.hasPrefix("ALTQ related functions")
        }.joined(separator: "\n")
    }

    private func livePolicyMatches() throws -> Bool {
        try validateRootRules()
        return try installedFilterMatches()
    }

    private func installedFilterMatches() throws -> Bool {
        try filterEnabled() && anchorRules() == installedAnchor
    }

    func release() throws {
        lock.lock(); defer { lock.unlock() }
        _ = try execute("/sbin/pfctl", ["-a", LeakGuardRuleset.anchorName, "-F", "all"])
        timer?.cancel(); timer = nil; generation = UUID()
        engaged = false; lastRules = nil; installedAnchor = nil
        // Once the anchor is empty, a restart must not restore it. Retain any
        // outstanding PF reference in its own file until release succeeds.
        try removeIfPresent(rulesPath)
        let contents: String
        do { contents = try String(contentsOfFile: tokenPath, encoding: .utf8) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return }
        let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UInt64(token) != nil else { throw HelperError("Invalid saved PF reference.") }
        do { _ = try execute("/sbin/pfctl", ["-X", token]) }
        catch {
            let references = try execute("/sbin/pfctl", ["-s", "References"])
            if references.split(whereSeparator: \.isWhitespace).contains(Substring(token)) { throw error }
        }
        try removeIfPresent(tokenPath)
    }

    private func removeIfPresent(_ path: String) throws {
        if unlink(path) != 0 && errno != ENOENT { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
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
