import CFNetwork
import Foundation
import XCTest

final class SystemProxyServiceTests: XCTestCase {
    private let original: ProxyValues = [
        "HTTPEnable": .number(1), "HTTPProxy": .string("old.example"), "HTTPPort": .number(3128),
        "HTTPSEnable": .number(0), "HTTPSProxy": .string("secure.example"), "HTTPSPort": .number(8443),
        "SOCKSEnable": .number(1), "SOCKSProxy": .string("socks.example"), "SOCKSPort": .number(1088),
        "ProxyAutoConfigEnable": .number(1), "ProxyAutoConfigURLString": .string("https://pac.example/config"),
        "ProxyAutoDiscoveryEnable": .number(1), "ExceptionsList": .strings(["*.corp", "10.0.0.0/8"]),
        "ExcludeSimpleHostnames": .number(1), "UnrelatedSetting": .string("keep"),
    ]

    func testSystemProxyTakeoverAndExactRestore() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        let active = fixture.preferences.values
        XCTAssertEqual(active["HTTPEnable"], .number(1))
        XCTAssertEqual(active["HTTPProxy"], .string(ProxyEndpoint.default.host))
        XCTAssertEqual(active["HTTPSPort"], .number(ProxyEndpoint.default.httpPort))
        XCTAssertEqual(active["SOCKSPort"], .number(ProxyEndpoint.default.socksPort))
        XCTAssertEqual(active["ProxyAutoConfigEnable"], .number(0))
        XCTAssertEqual(active["ProxyAutoConfigURLString"], original["ProxyAutoConfigURLString"])
        XCTAssertEqual(active["ProxyAutoDiscoveryEnable"], .number(0))
        XCTAssertEqual(active["ExceptionsList"], .strings(["localhost", "127.0.0.0/8", "::1"]))
        XCTAssertNil(active["ExcludeSimpleHostnames"])
        XCTAssertEqual(active["UnrelatedSetting"], .string("keep"))
        XCTAssertNil(fixture.service.checkForConflict())
        try fixture.service.disableProxy()
        XCTAssertEqual(fixture.preferences.values, original)
        XCTAssertNil(fixture.journal.journal)
    }

    func testTUNSuspendsAllFlagsAndPreservesBypassChanges() throws {
        let fixture = fixture()
        try fixture.service.suspendProxyForTUN()
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            XCTAssertEqual(fixture.preferences.values[key], .number(0))
        }
        XCTAssertEqual(fixture.preferences.values["HTTPProxy"], original["HTTPProxy"])
        XCTAssertEqual(fixture.preferences.values["ExceptionsList"], original["ExceptionsList"])
        fixture.preferences.values["ExceptionsList"] = .strings(["new.corp"])
        fixture.preferences.values["ExcludeSimpleHostnames"] = .number(0)
        XCTAssertNil(fixture.service.checkForConflict())
        try fixture.service.restoreSavedProxyState()
        var expected = original
        expected["ExceptionsList"] = .strings(["new.corp"])
        expected["ExcludeSimpleHostnames"] = .number(0)
        XCTAssertEqual(fixture.preferences.values, expected)
    }

    func testAbsentKeysAreRemovedOnRecovery() throws {
        let fixture = fixture(values: [:])
        try fixture.service.enableProxy(endpoint: .default)
        XCTAssertFalse(fixture.preferences.values.isEmpty)
        try fixture.service.disableProxy()
        XCTAssertEqual(fixture.preferences.values, [:])
    }

    func testConflictingManualGroupIsPreservedAndNeverReplayed() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        fixture.preferences.values["HTTPProxy"] = .string("external.example")
        let externalHTTP = ProxyGroup.http.values(in: fixture.preferences.values)
        let failure = try XCTUnwrap(fixture.service.checkForConflict())
        XCTAssertTrue(failure.requiresExplicitReconnect)
        XCTAssertThrowsError(try fixture.service.disableProxy())
        XCTAssertEqual(ProxyGroup.http.values(in: fixture.preferences.values), externalHTTP)
        XCTAssertEqual(ProxyGroup.pac.values(in: fixture.preferences.values), ProxyGroup.pac.values(in: original))
        XCTAssertEqual(ProxyGroup.socks.values(in: fixture.preferences.values), ProxyGroup.socks.values(in: original))
        XCTAssertNil(fixture.journal.journal)
        try fixture.service.restoreSavedProxyState()
        XCTAssertEqual(ProxyGroup.http.values(in: fixture.preferences.values), externalHTTP)
    }

    func testPACURLEditDoesNotReenableSuspendedPACOnNewURL() throws {
        let fixture = fixture()
        try fixture.service.suspendProxyForTUN()
        fixture.preferences.values["ProxyAutoConfigURLString"] = .string("https://new.example/private-token")
        let failure = try XCTUnwrap(fixture.service.checkForConflict())
        XCTAssertFalse((failure.details ?? "").contains("private-token"))
        XCTAssertThrowsError(try fixture.service.restoreSavedProxyState())
        XCTAssertEqual(fixture.preferences.values["ProxyAutoConfigEnable"], .number(0))
        XCTAssertEqual(fixture.preferences.values["ProxyAutoConfigURLString"], .string("https://new.example/private-token"))
    }

    func testObservedOwnershipLossSurvivesRelaunchEvenIfValuesReturn() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        let applied = ProxyGroup.http.values(in: fixture.preferences.values)
        fixture.preferences.values["HTTPProxy"] = .string("external.example")
        XCTAssertNotNil(fixture.service.checkForConflict())
        for (key, value) in applied { fixture.preferences.values[key] = value }
        // An external writer returned to the local endpoint after we observed its
        // earlier edit. A relaunched app must not reclaim that group.
        try fixture.newService().restoreSavedProxyState()
        XCTAssertEqual(ProxyGroup.http.values(in: fixture.preferences.values), applied)
        XCTAssertEqual(ProxyGroup.socks.values(in: fixture.preferences.values), ProxyGroup.socks.values(in: original))
    }

    func testExternalBypassGroupIsPreservedInSystemProxyMode() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        fixture.preferences.values["ExceptionsList"] = .strings(["external.example"])
        XCTAssertNotNil(fixture.service.checkForConflict())
        XCTAssertThrowsError(try fixture.service.disableProxy())
        XCTAssertEqual(fixture.preferences.values["ExceptionsList"], .strings(["external.example"]))
        XCTAssertNil(fixture.preferences.values["ExcludeSimpleHostnames"])
    }

    func testUnrelatedEditsAndRenameDoNotConflict() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        fixture.preferences.values["UnrelatedSetting"] = .string("changed")
        let service = fixture.preferences.inventory.services["wifi"]!
        fixture.preferences.inventory.services["wifi"] = ProxyServiceConfiguration(id: "wifi", name: "Renamed", values: service.values)
        XCTAssertNil(fixture.service.checkForConflict())
        try fixture.service.disableProxy()
        var expected = original
        expected["UnrelatedSetting"] = .string("changed")
        XCTAssertEqual(fixture.preferences.values, expected)
    }

    func testNewEligibleServiceStopsWithoutTouchingItsSettings() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        fixture.preferences.inventory.services["ethernet"] = ProxyServiceConfiguration(id: "ethernet", name: "Ethernet", values: original)
        fixture.preferences.inventory = ProxyInventory(
            locationID: "home", eligibleServiceIDs: ["wifi", "ethernet"], services: fixture.preferences.inventory.services)
        XCTAssertTrue(try XCTUnwrap(fixture.service.checkForConflict()).requiresExplicitReconnect)
        XCTAssertThrowsError(try fixture.service.disableProxy())
        XCTAssertEqual(fixture.preferences.inventory.services["ethernet"]?.values, original)
        try fixture.service.enableProxy(endpoint: .default)
        XCTAssertEqual(fixture.journal.journal?.session?.eligibleServiceIDs, ["wifi", "ethernet"])
        try fixture.service.disableProxy()
    }

    func testLocationChangeConflictsEvenWithSameServices() throws {
        let fixture = fixture()
        try fixture.service.suspendProxyForTUN()
        fixture.preferences.inventory = ProxyInventory(locationID: "office", eligibleServiceIDs: ["wifi"], services: fixture.preferences.inventory.services)
        XCTAssertNotNil(fixture.service.checkForConflict())
        XCTAssertThrowsError(try fixture.service.restoreSavedProxyState())
        XCTAssertEqual(fixture.preferences.values, original)
    }

    func testMissingServiceRetainedAndNameReuseDoesNotRestoreOntoNewID() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        let old = fixture.preferences.inventory.services.removeValue(forKey: "wifi")!
        fixture.preferences.inventory = ProxyInventory(locationID: "home", eligibleServiceIDs: [], services: [:])
        XCTAssertNil(fixture.service.checkForConflict())
        try fixture.service.disableProxy()
        XCTAssertEqual(fixture.journal.journal?.services.map(\.serviceID), ["wifi"])
        let replacement = ProxyServiceConfiguration(id: "replacement", name: "Wi-Fi", values: [:])
        fixture.preferences.inventory = ProxyInventory(locationID: "home", eligibleServiceIDs: ["replacement"], services: ["replacement": replacement])
        try fixture.service.enableProxy(endpoint: .default)
        XCTAssertEqual(Set(fixture.journal.journal!.services.map(\.serviceID)), ["wifi", "replacement"])
        try fixture.service.disableProxy()
        XCTAssertEqual(fixture.preferences.inventory.services["replacement"]?.values, [:])
        fixture.preferences.inventory.services["wifi"] = old
        try fixture.service.restoreDeferredProxyStateIfNeeded()
        XCTAssertEqual(fixture.preferences.values, original)
        XCTAssertNil(fixture.journal.journal)
    }

    func testAuthenticatedProxiesRejectedBeforeAnyWrite() throws {
        for mode in [ConnectionMode.systemProxy, .tun] {
            let fixture = fixture()
            fixture.preferences.values["HTTPUser"] = .string("alice")
            let before = fixture.preferences.values
            XCTAssertThrowsError(try mode == .tun ? fixture.service.suspendProxyForTUN() : fixture.service.enableProxy(endpoint: .default))
            XCTAssertEqual(fixture.preferences.values, before)
            XCTAssertEqual(fixture.preferences.applyCount, 0)
            XCTAssertNil(fixture.journal.journal)
        }
    }

    func testDisabledAuthenticatedProxyIsOnlyAllowedForTUN() throws {
        let fixture = fixture()
        fixture.preferences.values["HTTPEnable"] = .number(0)
        fixture.preferences.values["HTTPUser"] = .string("alice")
        fixture.preferences.inventory.services["wifi"]?.credentialGroups = [.http]
        let before = fixture.preferences.values
        XCTAssertThrowsError(try fixture.service.enableProxy(endpoint: .default))
        try fixture.service.suspendProxyForTUN()
        XCTAssertNil(fixture.service.checkForConflict())
        try fixture.service.restoreSavedProxyState()
        XCTAssertEqual(fixture.preferences.values, before)
    }

    func testCrashAfterCommitBeforeApplyRecoversOriginalState() throws {
        let fixture = fixture()
        fixture.preferences.failApply = true
        XCTAssertThrowsError(try fixture.service.enableProxy(endpoint: .default))
        XCTAssertNotNil(fixture.journal.journal)
        fixture.preferences.failApply = false
        let relaunched = fixture.newService()
        try relaunched.restoreSavedProxyState()
        XCTAssertEqual(fixture.preferences.values, original)
        XCTAssertNil(fixture.journal.journal)
    }

    func testCrashAfterIntentBeforeCommitRecognizesOriginalState() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        // Equivalent to the process dying after its intent was written, before
        // its atomic SCPreferences commit changed the system.
        fixture.preferences.values = original
        let relaunched = fixture.newService()
        try relaunched.restoreSavedProxyState()
        XCTAssertEqual(fixture.preferences.values, original)
        XCTAssertNil(fixture.journal.journal)
    }

    func testFailedIntentSaveDoesNotChangePreferences() throws {
        let fixture = fixture()
        fixture.journal.failSave = true
        XCTAssertThrowsError(try fixture.service.enableProxy(endpoint: .default))
        XCTAssertEqual(fixture.preferences.values, original)
        XCTAssertEqual(fixture.preferences.applyCount, 0)
    }

    func testFailedRecoveryApplyKeepsRecordUntilApplySucceeds() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        fixture.preferences.failApply = true
        XCTAssertThrowsError(try fixture.service.disableProxy())
        XCTAssertEqual(fixture.preferences.values, original, "commit succeeded even though apply failed")
        XCTAssertNotNil(fixture.journal.journal)
        fixture.preferences.failApply = false
        let count = fixture.preferences.applyCount
        try fixture.newService().restoreSavedProxyState()
        XCTAssertGreaterThan(fixture.preferences.applyCount, count, "an empty recovery diff must still finish the failed apply")
        XCTAssertNil(fixture.journal.journal)
    }

    func testCrashRecoveryPreservesExternalChanges() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        fixture.preferences.values["SOCKSProxy"] = .string("other.example")
        try fixture.newService().restoreSavedProxyState()
        XCTAssertEqual(fixture.preferences.values["SOCKSProxy"], .string("other.example"))
        XCTAssertEqual(ProxyGroup.http.values(in: fixture.preferences.values), ProxyGroup.http.values(in: original))
    }

    func testLiveSessionCanBeAdoptedAfterRelaunch() throws {
        let fixture = fixture()
        try fixture.service.suspendProxyForTUN()
        let relaunched = fixture.newService()
        try relaunched.resumeMonitoringIfNeeded()
        XCTAssertNil(relaunched.checkForConflict())
        fixture.preferences.values["ProxyAutoDiscoveryEnable"] = .number(1)
        XCTAssertNotNil(relaunched.checkForConflict())
    }

    func testTUNRebuildKeepsOriginalSnapshot() throws {
        let fixture = fixture()
        try fixture.service.suspendProxyForTUN()
        let originalID = fixture.journal.journal?.session?.id
        try fixture.service.suspendProxyForTUN()
        XCTAssertEqual(fixture.journal.journal?.session?.id, originalID)
        try fixture.service.restoreSavedProxyState()
        XCTAssertEqual(fixture.preferences.values, original)
    }

    func testDeclinedRecoveryIsNotPromptedAgainByPathNotifications() throws {
        let fixture = fixture()
        try fixture.service.enableProxy(endpoint: .default)
        fixture.preferences.authorizationDenied = true
        XCTAssertThrowsError(try fixture.service.disableProxy())
        let count = fixture.preferences.transactionCount
        try fixture.service.restoreDeferredProxyStateIfNeeded()
        XCTAssertEqual(fixture.preferences.transactionCount, count)
        XCTAssertNotNil(fixture.journal.journal)
        fixture.preferences.authorizationDenied = false
        try fixture.service.restoreSavedProxyState()
        XCTAssertNil(fixture.journal.journal)
    }

    func testRealJournalLockAndLegacyPreservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = TestFileManager(root: root)
        let first = ProxyJournalStore(fileManager: manager)
        let second = ProxyJournalStore(fileManager: manager)
        try first.acquire()
        XCTAssertThrowsError(try second.acquire())
        let journal = ProxyJournal(session: nil)
        try first.save(journal)
        let url = root.appendingPathComponent("teleport/system-proxy-snapshot.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try first.load()?.version, ProxyJournal.currentVersion)
        first.release()
        try second.acquire()
        let legacy = Data("{\"createdAt\":0,\"services\":[]}".utf8)
        try legacy.write(to: url)
        XCTAssertThrowsError(try second.load()) { error in
            guard case SystemProxyError.legacyJournal = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), legacy)
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(try second.load())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json")
        second.release()
    }

    func testMacOSLoopbackBypassMatching() throws {
        let values = ProxyGroup.bypass.target(from: [:], mode: .systemProxy, endpoint: .default)
        var dictionary = values.mapValues(\.foundationValue)
        dictionary["HTTPEnable"] = 1
        dictionary["HTTPProxy"] = "127.0.0.1"
        dictionary["HTTPPort"] = 8080
        for host in ["localhost", "127.0.0.1", "127.17.2.3", "[::1]"] {
            let url = try XCTUnwrap(URL(string: "http://\(host)/"))
            let proxies = CFNetworkCopyProxiesForURL(url as CFURL, dictionary as CFDictionary).takeRetainedValue() as NSArray
            let first = try XCTUnwrap(proxies.firstObject as? [String: Any])
            XCTAssertEqual(first[kCFProxyTypeKey as String] as? String, kCFProxyTypeNone as String, host)
        }
        for host in ["intranet", "printer.local", "10.0.0.2", "example.com"] {
            let url = try XCTUnwrap(URL(string: "http://\(host)/"))
            let proxies = CFNetworkCopyProxiesForURL(url as CFURL, dictionary as CFDictionary).takeRetainedValue() as NSArray
            let first = try XCTUnwrap(proxies.firstObject as? [String: Any])
            XCTAssertEqual(first[kCFProxyTypeKey as String] as? String, kCFProxyTypeHTTP as String, host)
        }
    }

    private func fixture(values: ProxyValues? = nil) -> Fixture {
        Fixture(values: values ?? original)
    }

    private final class Fixture {
        let preferences: FakePreferences
        let journal = MemoryJournal()
        let log: TeleportLog
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("teleport-proxy-test-\(UUID().uuidString)")
        lazy var service = newService()

        init(values: ProxyValues) {
            preferences = FakePreferences(values: values)
            log = TeleportLog(directoryURL: root, fileName: "proxy.log")
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func newService() -> SystemProxyService { SystemProxyService(log: log, preferences: preferences, journalStore: journal) }
    }

    private final class FakePreferences: ProxyPreferencesAccess {
        var inventory: ProxyInventory
        var failApply = false
        var authorizationDenied = false
        var transactionCount = 0
        var applyCount = 0
        var values: ProxyValues {
            get { inventory.services["wifi"]!.values }
            set { inventory.services["wifi"]!.values = newValue }
        }

        init(values: ProxyValues) {
            inventory = ProxyInventory(
                locationID: "home", eligibleServiceIDs: ["wifi"],
                services: [
                    "wifi": ProxyServiceConfiguration(id: "wifi", name: "Wi-Fi", values: values)
                ])
        }
        func read() throws -> ProxyInventory { inventory }
        func transaction(_ body: (ProxyInventory, ([ProxyMutation]) throws -> Void) throws -> Void) throws {
            transactionCount += 1
            if authorizationDenied { throw PrivilegedShellError.commandFailed("User canceled helper installation") }
            try body(inventory) { mutations in
                self.applyCount += 1
                for mutation in mutations {
                    for key in mutation.removed { self.inventory.services[mutation.serviceID]?.values.removeValue(forKey: key) }
                    for (key, value) in mutation.values { self.inventory.services[mutation.serviceID]?.values[key] = value }
                }
                if self.failApply { throw SystemProxyError.preferencesFailed("apply", 1003) }
            }
        }
        func observe(_ changed: @escaping @Sendable () -> Void) -> (any ProxyPreferencesObserving)? { nil }
    }

    private final class MemoryJournal: ProxyJournalStoring {
        var journal: ProxyJournal?
        var failSave = false
        var exists: Bool { journal != nil }
        func acquire() throws {}
        func release() {}
        func load() throws -> ProxyJournal? { journal }
        func save(_ journal: ProxyJournal?) throws {
            if failSave { throw CocoaError(.fileWriteOutOfSpace) }
            self.journal = journal
        }
    }

    private final class TestFileManager: FileManager {
        let root: URL
        init(root: URL) {
            self.root = root
            super.init()
        }
        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
    }
}
