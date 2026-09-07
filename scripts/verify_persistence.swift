import Foundation
import Security

@main
struct VerifyPersistence {
    static func main() throws {
        try testKeychainReadStatusClassification()
        try testFreshStoreHasNoSnapshotAndNoLoadError()
        try testSaveAndLoadRoundTrip()
        try testLegacyStateFileMigratesToKeychain()
        try testLoadFailureRefusesToOverwriteExistingSnapshot()
        try testSessionConnectionsSurviveAndOldSnapshotsStaySingleConnection()
        print("verify_persistence: all checks passed")
    }

    /// Redirects the Application Support base directory to a throwaway location so
    /// ConfigurationStore's placeholder file is written to a temp path instead of the
    /// developer's real ~/Library/Application Support/teleport directory.
    private final class TempFileManager: FileManager {
        let root: URL
        init(root: URL) {
            self.root = root
            super.init()
        }

        override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            if directory == .applicationSupportDirectory {
                return [root]
            }
            return super.urls(for: directory, in: domainMask)
        }
    }

    // Classifying the raw SecItemCopyMatching outcome is the actual bug fix: previously
    // any non-success status (including access-denied style failures, not just "no
    // item") was treated identically to "nothing was ever saved", which let a later
    // save() silently overwrite real Keychain data with an empty snapshot. This checks
    // the mapping directly, without needing to force a real Keychain failure.
    private static func testKeychainReadStatusClassification() throws {
        let someData = Data([0x01, 0x02, 0x03])

        precondition(
            ConfigurationStore.classifyKeychainReadStatus(errSecSuccess, result: someData as CFTypeRef) == .found(someData),
            "expected errSecSuccess with data to classify as .found"
        )
        precondition(
            ConfigurationStore.classifyKeychainReadStatus(errSecItemNotFound, result: nil) == .notFound,
            "expected errSecItemNotFound to classify as .notFound"
        )
        precondition(
            ConfigurationStore.classifyKeychainReadStatus(errSecInteractionNotAllowed, result: nil) == .failed(errSecInteractionNotAllowed),
            "expected errSecInteractionNotAllowed to classify as .failed, not be conflated with .notFound"
        )
        precondition(
            ConfigurationStore.classifyKeychainReadStatus(errSecAuthFailed, result: nil) == .failed(errSecAuthFailed),
            "expected errSecAuthFailed to classify as .failed, not be conflated with .notFound"
        )
        precondition(
            ConfigurationStore.classifyKeychainReadStatus(errSecSuccess, result: nil) == .failed(errSecSuccess),
            "expected a success status with no data back to be treated as a failure rather than crash/round-trip empty data"
        )
    }

    private static func testFreshStoreHasNoSnapshotAndNoLoadError() throws {
        try withIsolatedStore(name: "fresh") { store in
            precondition(!store.hasSavedSnapshot, "expected a brand-new isolated Keychain item to report no saved snapshot")

            let snapshot = store.load()
            precondition(snapshot.savedConnections.isEmpty, "expected defaults for a never-saved store")
            precondition(store.lastLoadError == nil, "a missing item is not a load failure")
        }
    }

    private static func testSaveAndLoadRoundTrip() throws {
        try withIsolatedStore(name: "roundtrip") { store in
            let saved = AppSnapshot(
                savedConnections: [],
                subscriptionSources: [],
                selectedConnectionID: nil,
                proxyEndpoint: .default,
                showsLatencyInMenuBarPicker: false
            )
            try store.save(saved)

            precondition(store.hasSavedSnapshot, "expected hasSavedSnapshot to be true right after save()")
            let loaded = store.load()
            precondition(store.lastLoadError == nil, "a successful save/load round trip should not report a load error")
            precondition(loaded.showsLatencyInMenuBarPicker == false, "expected the round-tripped snapshot to match what was saved")
        }
    }

    /// Which connections a session carries is derived from the rules, so the only
    /// new persisted state is the connection a rule names.
    private static func testSessionConnectionsSurviveAndOldSnapshotsStaySingleConnection() throws {
        let connectionID = UUID()
        let rule = SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy, connectionID: connectionID)
        let roundTripped = try JSONDecoder().decode(
            SplitTunnelRule.self,
            from: try JSONEncoder().encode(rule)
        )
        precondition(roundTripped.connectionID == connectionID)

        // A rule written before rules could name a connection routes through the
        // selected one.
        let ruleData = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "value": "example.com",
            "kind": "domain",
            "action": "proxy",
            "isEnabled": true
        ])
        let legacyRule = try JSONDecoder().decode(SplitTunnelRule.self, from: ruleData)
        precondition(legacyRule.connectionID == nil, "expected a pre-upgrade rule to use the default connection")
    }

    private static func testLegacyStateFileMigratesToKeychain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-persistence-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = TempFileManager(root: root)
        let store = ConfigurationStore(
            fileManager: fileManager,
            keychainService: "dev.x.teleport.configuration.verify",
            keychainAccount: "verify-migration-\(UUID().uuidString)"
        )
        defer { store.deleteKeychainItemForTesting() }

        let legacySnapshot = AppSnapshot(
            savedConnections: [],
            subscriptionSources: [],
            selectedConnectionID: nil,
            proxyEndpoint: .default,
            showsLatencyInMenuBarPicker: false
        )
        let legacyFileURL = root
            .appendingPathComponent("teleport", isDirectory: true)
            .appendingPathComponent("state.json")
        try JSONEncoder().encode(legacySnapshot).write(to: legacyFileURL, options: .atomic)

        precondition(store.hasSavedSnapshot, "expected the legacy state file to count as a saved snapshot")
        let migrated = store.load()
        precondition(!migrated.showsLatencyInMenuBarPicker, "expected legacy settings to be returned during migration")
        precondition(store.hasSavedSnapshot, "expected the migrated Keychain snapshot to exist")
        precondition(!fileManager.fileExists(atPath: legacyFileURL.path), "expected plaintext state to be removed after migration")

        let loadedAgain = store.load()
        precondition(!loadedAgain.showsLatencyInMenuBarPicker, "expected the migrated Keychain snapshot to survive a second load")
    }

    // This is the regression the fix targets: once load() has flagged a Keychain read
    // failure, save() must refuse rather than silently persist an in-memory snapshot
    // that was only ever populated with defaults because the real data was unreadable.
    private static func testLoadFailureRefusesToOverwriteExistingSnapshot() throws {
        try withIsolatedStore(name: "refusal") { store in
            let saved = AppSnapshot(
                savedConnections: [],
                subscriptionSources: [],
                selectedConnectionID: nil,
                proxyEndpoint: .default,
                showsLatencyInMenuBarPicker: true
            )
            try store.save(saved)

            store.simulateLoadFailureForTesting(status: errSecInteractionNotAllowed)
            precondition(store.lastLoadError != nil, "expected the simulated load failure to be recorded")

            do {
                try store.save(AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default))
                fatalError("expected save() to throw after a load failure instead of overwriting the existing snapshot")
            } catch is ConfigurationStoreError {
                // expected
            }

            store.simulateLoadFailureForTesting(status: nil)
            let stillIntact = store.load()
            precondition(stillIntact.showsLatencyInMenuBarPicker == true, "expected the original snapshot to survive the refused save")
        }
    }

    private static func withIsolatedStore(name: String, _ body: (ConfigurationStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-persistence-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ConfigurationStore(
            fileManager: TempFileManager(root: root),
            keychainService: "dev.x.teleport.configuration.verify",
            keychainAccount: "verify-\(name)-\(UUID().uuidString)"
        )
        defer { store.deleteKeychainItemForTesting() }

        try body(store)
    }
}
