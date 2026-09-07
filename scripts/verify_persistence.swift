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
        try testGoodSnapshotIsRetainedAndNotDuplicated()
        try testShrinkingSaveKeepsThePreviousSnapshot()
        try testRetainedSnapshotsArePruned()
        try testUndecodableSnapshotIsKeptAndSavingIsRefused()
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
    private static func retainedSnapshotCount(_ store: ConfigurationStore) -> Int {
        store.retainedSnapshotAccounts().count
    }

    /// A snapshot that loads cleanly is copied aside, so no later write can be the
    /// only copy of it. Loading the same bytes again must not spend a generation,
    /// or five uneventful launches would push out every copy that differs.
    private static func testGoodSnapshotIsRetainedAndNotDuplicated() throws {
        try withIsolatedStore(name: "retain") { store, _ in
            try store.save(AppSnapshot(
                savedConnections: [],
                subscriptionSources: [],
                selectedConnectionID: nil,
                proxyEndpoint: .default,
                showsLatencyInMenuBarPicker: false
            ))

            _ = store.load()
            precondition(retainedSnapshotCount(store) == 1, "expected a good load to retain a copy")

            _ = store.load()
            _ = store.load()
            precondition(retainedSnapshotCount(store) == 1, "expected identical reloads to reuse one generation")
        }
    }

    /// The regression this whole guard exists for: an in-memory state that lost
    /// connections must not be able to replace the stored one without leaving the
    /// stored one behind. Deleting a connection is allowed — losing it is not.
    private static func testShrinkingSaveKeepsThePreviousSnapshot() throws {
        try withIsolatedStore(name: "shrink") { store, root in
            let connection = SavedConnection(
                id: UUID(),
                configuration: try ConnectionLinkParser().parse("trojan://secret@example.com:443?security=tls&type=tcp#kept"),
                savedAt: Date()
            )
            try store.save(AppSnapshot(
                savedConnections: [connection],
                subscriptionSources: [],
                selectedConnectionID: connection.id,
                proxyEndpoint: .default
            ))

            // No reload in between, which is the shape of the failure this guards
            // against: an in-memory state that lost connections to a bug, persisted
            // by an autosave without anyone having read the stored one again.
            precondition(retainedSnapshotCount(store) == 0, "expected no retained copy before the shrinking save")

            try store.save(AppSnapshot(
                savedConnections: [],
                subscriptionSources: [],
                selectedConnectionID: nil,
                proxyEndpoint: .default
            ))

            precondition(
                retainedSnapshotCount(store) == 1,
                "expected a shrinking save to keep a copy of the snapshot it replaced"
            )

            let newest = store.retainedSnapshotAccounts().last!
            let recovered = try JSONDecoder().decode(AppSnapshot.self, from: store.snapshotBackupData(account: newest)!)
            precondition(recovered.savedConnections.count == 1, "expected the kept copy to still hold the connection")

            // Kept in the Keychain, not on disk: a copy of a snapshot is a copy of
            // every password in it, and the store went into the Keychain for that.
            let plaintextDirectory = root
                .appendingPathComponent("teleport", isDirectory: true)
                .appendingPathComponent("snapshots", isDirectory: true)
            precondition(!FileManager.default.fileExists(atPath: plaintextDirectory.path), "expected no plaintext copy on disk")
        }
    }

    private static func testRetainedSnapshotsArePruned() throws {
        try withIsolatedStore(name: "prune") { store, _ in
            for index in 0..<12 {
                try store.save(AppSnapshot(
                    savedConnections: [],
                    subscriptionSources: [],
                    selectedConnectionID: nil,
                    proxyEndpoint: ProxyEndpoint(host: "127.0.0.1", httpPort: 8080 + index, socksPort: 1080)
                ))
                _ = store.load()
            }
            let count = retainedSnapshotCount(store)
            precondition(count <= 5, "expected retained snapshots to be pruned, found \(count)")
        }
    }

    /// The incident this store's guard was written for: a stored item this build
    /// cannot decode. It must be surfaced as an error, saving must be refused so the
    /// first autosave cannot replace it, and the bytes must be kept where a later
    /// build or a person can get them back.
    private static func testUndecodableSnapshotIsKeptAndSavingIsRefused() throws {
        try withIsolatedStore(name: "undecodable") { store, _ in
            let unreadable = Data("{\"savedConnections\": \"written by a build with a different model\"}".utf8)
            try store.writeRawSnapshotDataForTesting(unreadable)

            let loaded = store.load()
            precondition(loaded.savedConnections.isEmpty, "expected an undecodable snapshot to load as empty")
            precondition(store.hasSavedSnapshot, "expected the undecodable item to still count as a saved snapshot")
            guard case let .snapshotCouldNotBeDecoded(backupAccount)? = store.lastLoadError as? ConfigurationStoreError else {
                fatalError("expected lastLoadError to say the snapshot could not be decoded, got \(String(describing: store.lastLoadError))")
            }
            precondition(backupAccount != nil, "expected a copy of the unreadable bytes to be kept")
            precondition(store.unreadableSnapshotAccounts() == [backupAccount!], "expected exactly the kept copy to be listed")
            precondition(store.snapshotBackupData(account: backupAccount!) == unreadable, "expected the kept copy to be byte-identical")

            do {
                try store.save(AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default))
                fatalError("expected save() to refuse after an undecodable load")
            } catch is ConfigurationStoreError {
                // expected
            }

            // Refusing must mean the original bytes are still the live item.
            precondition(store.snapshotBackupData(account: backupAccount!) == unreadable, "expected the live item to be untouched")
        }
    }

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
        try withIsolatedStore(name: "fresh") { store, _ in
            precondition(!store.hasSavedSnapshot, "expected a brand-new isolated Keychain item to report no saved snapshot")

            let snapshot = store.load()
            precondition(snapshot.savedConnections.isEmpty, "expected defaults for a never-saved store")
            precondition(store.lastLoadError == nil, "a missing item is not a load failure")
        }
    }

    private static func testSaveAndLoadRoundTrip() throws {
        try withIsolatedStore(name: "roundtrip") { store, _ in
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
            keychainAccount: "verify-migration-\(UUID().uuidString)",
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
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

        let migrated = store.load()
        precondition(store.hasSavedSnapshot, "expected the legacy state file to count as a saved snapshot")
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
        try withIsolatedStore(name: "refusal") { store, _ in
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

    private static func withIsolatedStore(name: String, _ body: (ConfigurationStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-persistence-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ConfigurationStore(
            fileManager: TempFileManager(root: root),
            keychainService: "dev.x.teleport.configuration.verify",
            keychainAccount: "verify-\(name)-\(UUID().uuidString)",
            // Into the throwaway root, so a verify run does not write test noise
            // into the log a real incident is read from.
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
        )
        defer { store.deleteKeychainItemForTesting() }

        try body(store, root)
    }
}
