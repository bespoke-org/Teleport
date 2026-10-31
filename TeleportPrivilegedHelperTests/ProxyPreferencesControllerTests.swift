import Foundation
import XCTest

final class ProxyPreferencesControllerTests: XCTestCase {
    private func fixture() -> ProxyInventory {
        ProxyInventory(locationID: "home", eligibleServiceIDs: ["wifi"], services: [
            "wifi": ProxyServiceConfiguration(id: "wifi", name: "Wi-Fi", values: [
                "HTTPEnable": .number(1), "HTTPProxy": .string("old.example"), "HTTPPort": .number(8080),
                "ProxyAutoConfigEnable": .number(1), "ProxyAutoConfigURLString": .string("https://pac.example"),
                "ExceptionsList": .strings(["*.corp"]), "UnknownKey": .string("preserve")])])
    }

    func testLockedWritePreservesUnrelatedFieldsAndVerifiesThroughStore() throws {
        let preferences = Preferences(fixture())
        let controller = ProxyPreferencesController(preferences: preferences)
        let snapshot = try controller.read()
        let request = ApplyProxyPreferencesRequest(transactionID: snapshot.transactionID, expected: preferences.inventory,
            mutations: [ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(0)])])
        preferences.onLock = { $0.services["wifi"]!.values["UnknownKey"] = .string("external") }
        XCTAssertTrue(try controller.apply(request).applied)
        XCTAssertEqual(preferences.inventory.services["wifi"]?.values["HTTPEnable"], .number(0))
        XCTAssertEqual(preferences.inventory.services["wifi"]?.values["UnknownKey"], .string("external"))
        XCTAssertEqual(preferences.applyCount, 1)
    }

    func testExternalEditBetweenReadAndLockRejectsWholeBatch() throws {
        let preferences = Preferences(fixture())
        let controller = ProxyPreferencesController(preferences: preferences)
        let snapshot = try controller.read()
        let request = ApplyProxyPreferencesRequest(transactionID: snapshot.transactionID, expected: preferences.inventory, mutations: [
            ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(0), "ProxyAutoConfigEnable": .number(0)])])
        preferences.onLock = { $0.services["wifi"]!.values["HTTPProxy"] = .string("external.example") }
        XCTAssertFalse(try controller.apply(request).applied)
        XCTAssertEqual(preferences.applyCount, 0)
        XCTAssertEqual(preferences.inventory.services["wifi"]?.values["ProxyAutoConfigEnable"], .number(1))
    }

    func testPACMetadataAndCredentialChangesRejectFlagOnlyWrites() throws {
        for credentials in [false, true] {
            let preferences = Preferences(fixture())
            let controller = ProxyPreferencesController(preferences: preferences)
            let snapshot = try controller.read()
            let key = credentials ? "HTTPEnable" : "ProxyAutoConfigEnable"
            let request = ApplyProxyPreferencesRequest(transactionID: snapshot.transactionID, expected: preferences.inventory,
                mutations: [ProxyMutation(serviceID: "wifi", values: [key: .number(0)])])
            preferences.onLock = {
                if credentials { $0.services["wifi"]!.credentialGroups.insert(.http) }
                else { $0.services["wifi"]!.values["ProxyAutoConfigURLString"] = .string("external PAC") }
            }
            XCTAssertFalse(try controller.apply(request).applied)
            XCTAssertEqual(preferences.applyCount, 0)
        }
    }

    func testNewServiceAndLocationRejectWrite() throws {
        for locationChange in [false, true] {
            let preferences = Preferences(fixture())
            let controller = ProxyPreferencesController(preferences: preferences)
            let snapshot = try controller.read()
            let request = ApplyProxyPreferencesRequest(transactionID: snapshot.transactionID, expected: preferences.inventory,
                mutations: [ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(0)])])
            preferences.onLock = { inventory in
                inventory = ProxyInventory(locationID: locationChange ? "work" : inventory.locationID,
                    eligibleServiceIDs: locationChange ? inventory.eligibleServiceIDs : ["wifi", "new"], services: inventory.services)
            }
            XCTAssertFalse(try controller.apply(request).applied)
            XCTAssertEqual(preferences.applyCount, 0)
        }
    }

    func testTUNBypassEditsDoNotVetoFlagUpdates() throws {
        let preferences = Preferences(fixture())
        let controller = ProxyPreferencesController(preferences: preferences)
        let snapshot = try controller.read()
        let request = ApplyProxyPreferencesRequest(transactionID: snapshot.transactionID, expected: preferences.inventory,
            mutations: [ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(0)])])
        preferences.onLock = { $0.services["wifi"]!.values["ExceptionsList"] = .strings(["new.corp"]) }
        XCTAssertTrue(try controller.apply(request).applied)
        XCTAssertEqual(preferences.inventory.services["wifi"]?.values["ExceptionsList"], .strings(["new.corp"]))
    }

    func testEmptyRecoveryStillAppliesCommittedPreferences() throws {
        let preferences = Preferences(fixture())
        let controller = ProxyPreferencesController(preferences: preferences)
        let snapshot = try controller.read()
        XCTAssertTrue(try controller.apply(
            ApplyProxyPreferencesRequest(transactionID: snapshot.transactionID, expected: preferences.inventory, mutations: [])).applied)
        XCTAssertEqual(preferences.applyCount, 1)
    }

    func testInvalidMutationsNeverAcquirePreferencesLock() throws {
        let preferences = Preferences(fixture())
        let controller = ProxyPreferencesController(preferences: preferences)
        let snapshot = try controller.read()
        let invalid = [
            [ProxyMutation(serviceID: "wifi", values: ["DNS": .string("bad")])],
            [ProxyMutation(serviceID: "wifi", values: ["HTTPPassword": .string("bad")])],
            [ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .string("bad")])],
            [ProxyMutation(serviceID: "missing", values: ["HTTPEnable": .number(0)])],
            [ProxyMutation(serviceID: "wifi"), ProxyMutation(serviceID: "wifi")],
            [ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(0)], removed: ["HTTPEnable"])]
        ]
        for mutations in invalid {
            XCTAssertThrowsError(try controller.apply(
                ApplyProxyPreferencesRequest(transactionID: snapshot.transactionID, expected: preferences.inventory, mutations: mutations)))
        }
        XCTAssertEqual(preferences.lockCount, 0)
    }

    func testRecoveryReadFencesDelayedWritesAndReplay() throws {
        let preferences = Preferences(fixture())
        let controller = ProxyPreferencesController(preferences: preferences)
        let first = try controller.read()
        let delayed = ApplyProxyPreferencesRequest(transactionID: first.transactionID, expected: first.inventory,
            mutations: [ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(0)])])
        let recovery = try controller.read()
        XCTAssertFalse(try controller.apply(delayed).applied)
        XCTAssertEqual(preferences.applyCount, 0)
        let current = ApplyProxyPreferencesRequest(transactionID: recovery.transactionID, expected: recovery.inventory,
            mutations: [ProxyMutation(serviceID: "wifi", values: ["HTTPEnable": .number(0)])])
        XCTAssertTrue(try controller.apply(current).applied)
        XCTAssertFalse(try controller.apply(current).applied)
        XCTAssertEqual(preferences.applyCount, 1)
    }

    private final class Preferences: ProxyPreferencesAccess {
        var inventory: ProxyInventory
        var onLock: ((inout ProxyInventory) -> Void)?
        var lockCount = 0
        var applyCount = 0
        init(_ inventory: ProxyInventory) { self.inventory = inventory }
        func read() throws -> ProxyInventory { inventory }
        func observe(_ changed: @escaping @Sendable () -> Void) -> (any ProxyPreferencesObserving)? { nil }
        func transaction(_ body: (ProxyInventory, ([ProxyMutation]) throws -> Void) throws -> Void) throws {
            lockCount += 1
            onLock?(&inventory)
            try body(inventory) { mutations in
                self.applyCount += 1
                for mutation in mutations {
                    for (key, value) in mutation.values { self.inventory.services[mutation.serviceID]?.values[key] = value }
                    for key in mutation.removed { self.inventory.services[mutation.serviceID]?.values.removeValue(forKey: key) }
                }
            }
        }
    }
}
