import Foundation
import XCTest

final class LeakGuardControllerTests: XCTestCase {
    private final class Commands {
        var calls: [[String]] = []
        var rejectsRelease = false
        var rootRules = "anchor \"com.apple/*\" all\n"
        func run(_ executable: String, _ args: [String]) throws -> String {
            calls.append(args)
            if rejectsRelease && args.suffix(2) == ["-F", "all"] { throw HelperError("injected failure") }
            if args == ["-sr"] { return rootRules }
            return args == ["-E"] ? "Token : 123\n" : ""
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
        let initialCount = commands.calls.count
        try guardController.engage(stage: .session(tunnelInterface: "utun99"), protectedHosts: [], leaseSeconds: 180, policy: policy)
        XCTAssertEqual(commands.calls.count, initialCount, "heartbeat must not flush connections")
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
        try restarted.release()
        XCTAssertFalse(restarted.isEngaged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rulesPath.path))
        try guardController.release() // cancels its test timer too
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
        XCTAssertEqual(try EndpointResolver.parse(response, recordType: 1), ["203.0.113.7"])
        XCTAssertEqual(try EndpointResolver.parse(response, recordType: 28), ["2001:db8::1"])
        XCTAssertEqual(try EndpointResolver.parse(Data(#"{"Status":3}"#.utf8), recordType: 1), [])
    }
}
