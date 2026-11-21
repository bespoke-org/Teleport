import Foundation
import XCTest

final class LeakGuardControllerTests: XCTestCase {
    private final class Commands {
        var calls: [[String]] = []
        var enabled = false
        var anchor = ""
        var rejectsToken = false
        var rejectsRelease = false
        var rootRules = "anchor \"com.apple/*\" all\n"
        func run(_ executable: String, _ args: [String]) throws -> String {
            calls.append(args)
            if rejectsRelease && args.suffix(2) == ["-F", "all"] { throw HelperError("injected failure") }
            if rejectsToken && args == ["-X", "123"] { throw HelperError("injected token failure") }
            if args == ["-s", "References"] { return rejectsToken ? "123" : "" }
            if args == ["-sr"] { return rootRules }
            if args == ["-E"] { enabled = true; return "Token : 123\n" }
            if args == ["-s", "info"] { return enabled ? "Status: Enabled for 0 days" : "Status: Disabled" }
            if args == ["-a", LeakGuardRuleset.anchorName, "-sr"] { return anchor }
            if args.contains("-f"), let path = args.last { anchor = try String(contentsOfFile: path, encoding: .utf8) }
            if args.suffix(2) == ["-F", "all"] { anchor = "" }
            return ""
        }
    }

    func testExpiryTightensAndRestartPreservesProtection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-guard-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        let guardController = LeakGuardController(helperStateDirectoryPath: directory.path, groupID: { 555 }, execute: commands.run)
        let policy = LeakGuardPolicy(endpoints: [.init(address: "203.0.113.7", transport: "tcp", ports: "443")], allowsDirect: true)
        try guardController.engage(stage: .session(tunnelInterface: "utun99"), protectedHosts: [], leaseSeconds: 180, policy: policy)
        XCTAssertTrue(guardController.isEngaged)
        try guardController.engage(stage: .session(tunnelInterface: "utun99"), protectedHosts: [], leaseSeconds: 180, policy: policy)
        XCTAssertEqual(commands.calls.filter { $0.contains("-f") }.count, 1, "healthy renewal must not reload the anchor")
        XCTAssertEqual(commands.calls.filter { $0 == ["-F", "states"] }.count, 1)
        guardController.expireLease()
        let rulesPath = directory.appendingPathComponent("leak-guard.pf")
        let standby = try String(contentsOf: rulesPath, encoding: .utf8)
        XCTAssertFalse(standby.contains("utun99"))
        XCTAssertFalse(standby.contains("203.0.113.7"))
        XCTAssertFalse(standby.contains("all group"))
        XCTAssertTrue(guardController.isEngaged)
        XCTAssertFalse(commands.calls.contains { $0.suffix(2) == ["-F", "all"] })
        let restarted = LeakGuardController(helperStateDirectoryPath: directory.path, groupID: { 555 }, execute: commands.run)
        try restarted.restoreGuard()
        XCTAssertTrue(restarted.isEngaged)
        commands.rejectsRelease = true
        XCTAssertThrowsError(try restarted.release())
        XCTAssertTrue(restarted.isEngaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rulesPath.path))
        commands.rejectsRelease = false
        commands.rejectsToken = true
        XCTAssertThrowsError(try restarted.release())
        XCTAssertFalse(FileManager.default.fileExists(atPath: rulesPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("leak-guard.token").path))
        let relaunched = LeakGuardController(helperStateDirectoryPath: directory.path, groupID: { 555 }, execute: commands.run)
        XCTAssertTrue(relaunched.protectionStatus.cleanupPending)
        XCTAssertFalse(relaunched.protectionStatus.held)
        let acquisitions = commands.calls.filter { $0 == ["-E"] }.count
        try restarted.engage(stage: .standby, protectedHosts: [], leaseSeconds: 180)
        XCTAssertEqual(commands.calls.filter { $0 == ["-E"] }.count, acquisitions)
        commands.rejectsToken = false
        try restarted.release()
        XCTAssertFalse(restarted.isEngaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rulesPath.path))
        try guardController.release() // cancels its test timer too
    }

    func testFailedExpiryRetriesWithoutAnotherHeartbeat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        let tightened = expectation(description: "Standby installed on retry")
        var loads = 0
        let controller = LeakGuardController(helperStateDirectoryPath: directory.path, groupID: { 555 }) { path, args in
            if args.contains("-f") {
                loads += 1
                if loads == 2 { throw HelperError("transient load failure") }
                if loads == 3 { tightened.fulfill() }
            }
            return try commands.run(path, args)
        }
        try controller.engage(stage: .session(tunnelInterface: "utun9"), protectedHosts: [], leaseSeconds: 180)
        controller.expireLease()
        wait(for: [tightened], timeout: 5)
        XCTAssertTrue(controller.isEngaged)
        XCTAssertFalse(commands.anchor.contains("utun9"))
        try controller.release()
    }

    func testRenewalRepairsChangedAnchorAndDisabledFilter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        let controller = LeakGuardController(helperStateDirectoryPath: directory.path, groupID: { 555 }, execute: commands.run)
        func renew() throws { try controller.engage(stage: .standby, protectedHosts: [], leaseSeconds: 180) }
        try renew()
        commands.anchor = "different rules"
        XCTAssertFalse(controller.isEngaged)
        try renew()
        XCTAssertTrue(controller.isEngaged)
        commands.enabled = false
        XCTAssertFalse(controller.isEngaged)
        try renew()
        XCTAssertTrue(controller.isEngaged)
        XCTAssertEqual(commands.calls.filter { $0 == ["-F", "states"] }.count, 3)
        try controller.release()
    }

    func testFailedStartupRestoreAllowsReleaseAndBlocksNewWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let commands = Commands()
        let controller = LeakGuardController(helperStateDirectoryPath: directory.path, groupID: { 555 }, execute: commands.run)
        try "saved policy".write(to: directory.appendingPathComponent("leak-guard.pf"), atomically: true, encoding: .utf8)
        commands.rootRules = "custom rules"
        XCTAssertThrowsError(try controller.restoreGuard())
        XCTAssertFalse(controller.isEngaged)
        XCTAssertThrowsError(try controller.requireProtectionIfPersisted())
        try controller.release()
        XCTAssertNoThrow(try controller.requireProtectionIfPersisted())
    }

    func testMissingRuntimeGroupFailsBeforeExecutingFirewallCommands() throws {
        let commands = Commands()
        let controller = LeakGuardController(helperStateDirectoryPath: "/unused", groupID: { throw HelperError("no group") }, execute: commands.run)
        XCTAssertThrowsError(try controller.engage(stage: .standby, protectedHosts: [], leaseSeconds: 180))
        XCTAssertTrue(commands.calls.isEmpty)
        XCTAssertFalse(controller.isEngaged)
    }

    func testUnreferencedOrOverridableAnchorIsRejected() throws {
        let commands = Commands()
        let controller = LeakGuardController(helperStateDirectoryPath: "/unused", groupID: { 555 }, execute: commands.run)
        for rules in ["", "pass out quick all\nanchor \"com.apple/*\" all\n", "anchor \"other/*\" all\n"] {
            commands.rootRules = rules
            commands.calls = []
            XCTAssertThrowsError(try controller.engage(stage: .standby, protectedHosts: [], leaseSeconds: 180))
            XCTAssertEqual(commands.calls, [["-sr"]], "unsupported root rules must fail before mutation")
        }
    }

    func testEndpointDNSRejectsUnexpectedAnswers() throws {
        let response = Data(#"{"Status":0,"Answer":[{"type":5,"data":"alias.example"},{"type":1,"data":"203.0.113.7"},{"type":1,"data":"hostname.example"},{"type":28,"data":"2001:db8::1"}]}"#.utf8)
        XCTAssertThrowsError(try EndpointResolver.resolveFamilies { _ in nil })
        XCTAssertEqual(try EndpointResolver.resolveFamilies { _ in Data(#"{"Status":3}"#.utf8) }.addresses, [])
        XCTAssertEqual(try EndpointResolver.resolveFamilies { $0 == "AAAA" ? response : nil }.addresses, ["2001:db8::1"])
        XCTAssertEqual(try EndpointResolver.parse(response, recordType: 1), ["203.0.113.7"])
        XCTAssertEqual(try EndpointResolver.parse(response, recordType: 28), ["2001:db8::1"])
        XCTAssertEqual(try EndpointResolver.parse(Data(#"{"Status":3}"#.utf8), recordType: 1), [])
    }
}
