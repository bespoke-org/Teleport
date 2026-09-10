import Foundation

/// The pf ruleset that keeps traffic off the physical uplink between sessions.
/// Exercising it for real means taking a machine off the network, so the ruleset
/// is a pure function and this covers it directly — then hands the result to
/// `pfctl -n`, which is the only authority on whether pf would accept it.
@main
struct VerifyLeakGuard {
    static func main() throws {
        try testStandbyHasNoTunnelOrRootException()
        try testSessionPassesItsOwnTunnel()
        try testProtectedHostsKeepTheirFamily()
        try testBothFamiliesAreBlockedLast()
        try testTheMachineCanStillConfigureItself()
        try testEmptyProtectedHostIsDropped()
        try testPacketFilterAcceptsBothStages()
        print("verify_leak_guard: all checks passed")
    }

    private static let standby = LeakGuardRuleset.rules(
        stage: .standby,
        protectedHosts: ["203.0.113.7"]
    )

    private static let session = LeakGuardRuleset.rules(
        stage: .session(tunnelInterface: "utun10"),
        protectedHosts: ["203.0.113.7", "2001:db8::1"]
    )

    /// Nothing is running that could own traffic on the uplink, so nothing is
    /// entitled to any: the root exception exists only to keep a live Xray's direct
    /// outbound working, and a tunnel pass would name an interface that is gone.
    private static func testStandbyHasNoTunnelOrRootException() throws {
        precondition(!standby.contains("user root"), "a standby guard must not pass root traffic")
        precondition(!standby.contains(" on utun"), "a standby guard must not name a tunnel interface")
        precondition(standby.contains("pass quick on lo0 all"), "loopback is never filtered")
        precondition(
            standby.contains("pass out quick inet to 203.0.113.7"),
            "the proxy server stays reachable, or nothing could rebuild the session"
        )
    }

    private static func testSessionPassesItsOwnTunnel() throws {
        precondition(session.contains("pass out quick on utun10 all"), "the session's tunnel carries traffic")
        precondition(!session.contains("utun11"), "only the session's own tunnel is passed")
        precondition(
            session.contains("pass out quick all user root"),
            "Xray's direct outbound leaves the uplink as root and is indistinguishable from a leak by address alone"
        )
    }

    private static func testProtectedHostsKeepTheirFamily() throws {
        precondition(session.contains("pass out quick inet to 203.0.113.7"), "an IPv4 server is passed as inet")
        precondition(session.contains("pass out quick inet6 to 2001:db8::1"), "an IPv6 server is passed as inet6")
    }

    /// pf takes the first `quick` match, so a block above a pass would swallow it.
    /// IPv6 is blocked as deliberately as IPv4: an uplink that gains IPv6 after a
    /// session was built is exactly the case a routing-only guard misses.
    private static func testBothFamiliesAreBlockedLast() throws {
        for rules in [standby, session] {
            let lines = rules.split(separator: "\n").map(String.init)
            guard let firstBlock = lines.firstIndex(where: { $0.hasPrefix("block") }),
                  let lastPass = lines.lastIndex(where: { $0.hasPrefix("pass") }) else {
                preconditionFailure("a ruleset must contain both pass and block rules")
            }
            precondition(lastPass < firstBlock, "every pass rule precedes the first block rule")
            precondition(rules.contains("block drop out quick inet all"), "IPv4 is blocked by default")
            precondition(rules.contains("block drop out quick inet6 all"), "IPv6 is blocked by default")
        }
    }

    /// A guard that blocked these would leave a machine unable to get an address or
    /// resolve the server it is meant to reconnect to — permanently stuck rather
    /// than briefly filtered.
    private static func testTheMachineCanStillConfigureItself() throws {
        precondition(standby.contains("port { 67, 68 }"), "DHCP survives the guard")
        precondition(standby.contains("192.168.0.0/16"), "local networks survive the guard")
        precondition(standby.contains("port { 53, 853 }"), "name resolution survives the guard")
        precondition(standby.contains("fe80::/10"), "IPv6 neighbour discovery survives the guard")
    }

    /// An empty entry would emit `pass out quick inet to ` — a rule pf rejects,
    /// taking the whole guard down with it.
    private static func testEmptyProtectedHostIsDropped() throws {
        let rules = LeakGuardRuleset.rules(stage: .standby, protectedHosts: ["", "203.0.113.7"])
        precondition(!rules.contains("to \n"), "an empty protected host is dropped rather than emitted")
    }

    private static func testPacketFilterAcceptsBothStages() throws {
        for (name, rules) in [("standby", standby), ("session", session)] {
            let result = parse(rules)
            precondition(result.accepted, "pfctl rejects the \(name) ruleset:\n\(result.output)")
        }
    }

    /// Parse-only: nothing on the machine running this is changed.
    private static func parse(_ rules: String) -> (accepted: Bool, output: String) {
        let path = NSTemporaryDirectory() + "teleport-verify-leak-guard.pf"
        try? rules.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        process.arguments = ["-a", LeakGuardRuleset.anchorName, "-n", "-f", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return (false, "pfctl could not be run") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
    }
}
