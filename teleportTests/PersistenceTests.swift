import Foundation
import XCTest
import Security

final class PersistenceTests: XCTestCase {
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
    private func retainedSnapshotCount(_ store: ConfigurationStore) -> Int {
        store.retainedSnapshotCopies().count
    }

    /// A snapshot that loads cleanly is copied aside, so no later write can be the
    /// only copy of it. Loading the same bytes again must not spend a generation,
    /// or five uneventful launches would push out every copy that differs.
    func testGoodSnapshotIsRetainedAndNotDuplicated() throws {
        try withIsolatedStore(name: "retain") { store, _ in
            try store.save(AppSnapshot(
                savedConnections: [],
                subscriptionSources: [],
                selectedConnectionID: nil,
                proxyEndpoint: .default,
                showsLatencyInMenuBarPicker: false
            ))

            _ = store.load()
            XCTAssert(retainedSnapshotCount(store) == 1, "expected a good load to retain a copy")

            _ = store.load()
            _ = store.load()
            XCTAssert(retainedSnapshotCount(store) == 1, "expected identical reloads to reuse one generation")
        }
    }

    /// The regression this whole guard exists for: an in-memory state that lost
    /// connections must not be able to replace the stored one without leaving the
    /// stored one behind. Deleting a connection is allowed — losing it is not.
    func testShrinkingSaveKeepsThePreviousSnapshot() throws {
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
            XCTAssert(retainedSnapshotCount(store) == 0, "expected no retained copy before the shrinking save")

            try store.save(AppSnapshot(
                savedConnections: [],
                subscriptionSources: [],
                selectedConnectionID: nil,
                proxyEndpoint: .default
            ))

            XCTAssert(
                retainedSnapshotCount(store) == 1,
                "expected a shrinking save to keep a copy of the snapshot it replaced"
            )

            let newest = store.retainedSnapshotCopies().last!
            let recovered = try JSONDecoder().decode(AppSnapshot.self, from: store.snapshotBackupData(name: newest)!)
            XCTAssert(recovered.savedConnections.count == 1, "expected the kept copy to still hold the connection")

            // Sealed, not plaintext: a copy of a snapshot is a copy of every password
            // in it, and the store went into the Keychain for that.
            for name in ["snapshot", newest] {
                let raw = try Data(contentsOf: store.sealedDirectoryURL.appendingPathComponent(name))
                XCTAssert(raw.range(of: Data("example.com".utf8)) == nil, "expected \(name) not to hold the link in plaintext")
            }
            XCTAssert(store.sealedDirectoryURL.path.hasPrefix(root.path), "expected the sealed files under the isolated root")
        }
    }

    /// Copies are the recovery path, so a save may add one but never change or
    /// remove one; only pruning to five generations removes the oldest.
    func testSavesNeverRewriteRetainedCopies() throws {
        try withIsolatedStore(name: "copies") { store, _ in
            var seen: [String: Data] = [:]
            func saveAndRecordCopies(_ count: Int) throws {
                try store.save(try makeSnapshot(connections: count))
                for name in store.retainedSnapshotCopies() {
                    let raw = try Data(contentsOf: store.sealedDirectoryURL.appendingPathComponent(name))
                    XCTAssert(seen[name] == nil || seen[name] == raw, "expected the copy \(name) to keep its bytes")
                    seen[name] = raw
                }
            }

            try saveAndRecordCopies(3)
            _ = store.load()
            // Growing saves keep nothing; each shrinking one keeps the snapshot it replaces.
            for count in [2, 1, 4, 3, 5, 2, 1, 0] {
                try saveAndRecordCopies(count)
            }

            let surviving = store.retainedSnapshotCopies()
            XCTAssert(surviving.count == 5, "expected pruning to leave five copies, found \(surviving.count)")
            XCTAssert(surviving == Array(seen.keys.sorted().suffix(5)), "expected only the oldest copies to be pruned")
            for name in surviving {
                XCTAssert(try Data(contentsOf: store.sealedDirectoryURL.appendingPathComponent(name)) == seen[name], "expected \(name) unchanged")
            }
        }
    }

    func testRetainedSnapshotsArePruned() throws {
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
            XCTAssert(count <= 5, "expected retained snapshots to be pruned, found \(count)")
        }
    }

    /// The incident this store's guard was written for: a stored item this build
    /// cannot decode. It must be surfaced as an error, saving must be refused so the
    /// first autosave cannot replace it, and the bytes must be kept where a later
    /// build or a person can get them back.
    func testUndecodableSnapshotIsKeptAndSavingIsRefused() throws {
        try withIsolatedStore(name: "undecodable") { store, _ in
            let unreadable = Data("{\"savedConnections\": \"written by a build with a different model\"}".utf8)
            try store.writeRawSnapshotDataForTesting(unreadable)

            let loaded = store.load()
            XCTAssert(loaded.savedConnections.isEmpty, "expected an undecodable snapshot to load as empty")
            XCTAssert(store.hasSavedSnapshot, "expected the undecodable item to still count as a saved snapshot")
            guard case let .snapshotCouldNotBeDecoded(backupName)? = store.lastLoadError as? ConfigurationStoreError else {
                XCTFail("expected lastLoadError to say the snapshot could not be decoded, got \(String(describing: store.lastLoadError))")
                return
            }
            XCTAssert(backupName != nil, "expected a copy of the unreadable bytes to be kept")
            XCTAssert(store.unreadableSnapshotCopies() == [backupName!], "expected exactly the kept copy to be listed")
            XCTAssert(store.snapshotBackupData(name: backupName!) == unreadable, "expected the kept copy to be byte-identical")

            do {
                try store.save(AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default))
                XCTFail("expected save() to refuse after an undecodable load")
            } catch is ConfigurationStoreError {
                // expected
            }

            // Refusing must mean the original bytes are still the live snapshot.
            XCTAssert(store.snapshotBackupData(name: "snapshot") == unreadable, "expected the live snapshot to be untouched")
        }
    }

    /// A sealed file that does not open with the key is as unreadable as one that
    /// does not decode: surfaced, saving refused, bytes left in place.
    func testTamperedSnapshotIsKeptAndSavingIsRefused() throws {
        try withIsolatedStore(name: "tampered") { store, _ in
            try store.save(try makeSnapshot(connections: 1))
            var sealed = try Data(contentsOf: store.currentSnapshotFileURL)
            sealed[sealed.count - 1] ^= 0xff
            try sealed.write(to: store.currentSnapshotFileURL)

            let loaded = store.load()
            XCTAssert(loaded.savedConnections.isEmpty, "expected a tampered snapshot to load as empty")
            XCTAssert(store.hasSavedSnapshot, "expected the tampered file to still count as a saved snapshot")
            guard case .snapshotCouldNotBeOpened? = store.lastLoadError as? ConfigurationStoreError else {
                XCTFail("expected lastLoadError to say the snapshot could not be opened, got \(String(describing: store.lastLoadError))")
                return
            }

            do {
                try store.save(try makeSnapshot(connections: 0))
                XCTFail("expected save() to refuse after a tampered load")
            } catch is ConfigurationStoreError {
                // expected
            }
            XCTAssert(try Data(contentsOf: store.currentSnapshotFileURL) == sealed, "expected the tampered bytes to be kept")
        }
    }

    /// Sealed files without their key are not "nothing saved": a fresh key would
    /// lock them for good, and a save would write over them.
    func testMissingKeyRefusesToSaveAndMakesNoNewKey() throws {
        try withIsolatedStore(name: "nokey") { store, _ in
            let account = store.sealedDirectoryURL.lastPathComponent
            try store.save(try makeSnapshot(connections: 1))
            let sealed = try Data(contentsOf: store.currentSnapshotFileURL)
            store.deleteEncryptionKeyForTesting()

            let loaded = store.load()
            XCTAssert(loaded.savedConnections.isEmpty, "expected a load without the key to come back empty")
            guard case .encryptionKeyMissing? = store.lastLoadError as? ConfigurationStoreError else {
                XCTFail("expected lastLoadError to say the key is missing, got \(String(describing: store.lastLoadError))")
                return
            }

            do {
                try store.save(try makeSnapshot(connections: 0))
                XCTFail("expected save() to refuse without the key")
            } catch is ConfigurationStoreError {
                // expected
            }
            XCTAssert(keychainAccounts().filter { $0.hasPrefix(account) }.isEmpty, "expected no replacement key to be made")
            XCTAssert(try Data(contentsOf: store.currentSnapshotFileURL) == sealed, "expected the sealed snapshot to be untouched")
        }
    }

    /// Earlier builds kept the snapshot and each copy as its own Keychain item.
    /// The first load moves every one of them, decodable or not, into a sealed
    /// file, and deletes the items so only the key is left under the service.
    func testKeychainItemsMigrateIntoSealedFiles() throws {
        try withIsolatedStore(name: "migrate") { store, _ in
            let account = store.sealedDirectoryURL.lastPathComponent
            let live = try JSONEncoder().encode(try makeSnapshot(connections: 2))
            let retained = try JSONEncoder().encode(try makeSnapshot(connections: 1))
            let unreadable = Data("{\"savedConnections\": \"written by a build with a different model\"}".utf8)
            try addKeychainItem(account: account, data: live)
            try addKeychainItem(account: "\(account).retained.2026-01-01T00-00-00-loaded", data: retained)
            try addKeychainItem(account: "\(account).unreadable.2026-01-02T00-00-00", data: unreadable)

            let loaded = store.load()
            XCTAssert(store.lastLoadError == nil, "expected the migration to load cleanly, got \(String(describing: store.lastLoadError))")
            XCTAssert(loaded.savedConnections.count == 2, "expected the live item to be the loaded snapshot")
            XCTAssert(store.snapshotBackupData(name: "snapshot") == live, "expected the live item's bytes to be sealed verbatim")
            // The migrated copy, plus the one this load retained of the live snapshot.
            XCTAssert(store.retainedSnapshotCopies().first == "retained.2026-01-01T00-00-00-loaded" && store.retainedSnapshotCopies().count == 2)
            XCTAssert(store.snapshotBackupData(name: "retained.2026-01-01T00-00-00-loaded") == retained)
            XCTAssert(store.unreadableSnapshotCopies() == ["unreadable.2026-01-02T00-00-00"])
            XCTAssert(store.snapshotBackupData(name: "unreadable.2026-01-02T00-00-00") == unreadable)
            XCTAssert(keychainAccounts().filter { $0.hasPrefix(account) } == ["\(account).key"], "expected only the key to remain in the keychain")

            let loadedAgain = store.load()
            XCTAssert(loadedAgain.savedConnections.count == 2 && store.lastLoadError == nil, "expected the sealed files to serve the next load")
        }
    }

    /// A live item that could not be sealed must stay where it is and keep saves
    /// refused; otherwise an autosave would write a snapshot and the next launch
    /// would delete the item as already moved.
    func testFailedMigrationKeepsTheItemAndRefusesToSave() throws {
        try withIsolatedStore(name: "migrate-fail") { store, _ in
            let account = store.sealedDirectoryURL.lastPathComponent
            try addKeychainItem(account: account, data: try JSONEncoder().encode(try makeSnapshot(connections: 2)))

            let directory = store.sealedDirectoryURL.path
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory) }

            _ = store.load()
            XCTAssert(store.lastLoadError != nil, "expected a failed move to be reported")
            XCTAssertThrowsError(
                try store.save(AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)),
                "expected save() to refuse after a failed move"
            )
            XCTAssert(keychainAccounts().contains(account), "expected the live item to stay in the keychain")
        }
    }

    /// After an update the old items cannot always be deleted, so they can still be
    /// there once the sealed snapshot exists. They must be left alone: reading them
    /// again would ask for the password after every update, and a copy pruning
    /// removed would come back.
    func testMigrationDoesNotRunAgainOnceSealed() throws {
        try withIsolatedStore(name: "migrate-once") { store, _ in
            try store.save(try makeSnapshot(connections: 1))
            let account = store.sealedDirectoryURL.lastPathComponent
            try addKeychainItem(account: account, data: try JSONEncoder().encode(try makeSnapshot(connections: 3)))
            try addKeychainItem(account: "\(account).retained.2026-01-01T00-00-00-loaded", data: Data("old".utf8))

            let loaded = store.load()
            XCTAssert(loaded.savedConnections.count == 1, "expected the sealed snapshot to win over a leftover item")
            XCTAssert(!store.retainedSnapshotCopies().contains("retained.2026-01-01T00-00-00-loaded"), "expected no copy moved from a leftover item")
            XCTAssert(keychainAccounts().contains(account), "expected the leftover item to be left alone")
        }
    }

    func testKeychainReadStatusClassification() throws {
        let someData = Data([0x01, 0x02, 0x03])

        XCTAssert(
            ConfigurationStore.classifyKeychainReadStatus(errSecSuccess, result: someData as CFTypeRef) == .found(someData),
            "expected errSecSuccess with data to classify as .found"
        )
        XCTAssert(
            ConfigurationStore.classifyKeychainReadStatus(errSecItemNotFound, result: nil) == .notFound,
            "expected errSecItemNotFound to classify as .notFound"
        )
        XCTAssert(
            ConfigurationStore.classifyKeychainReadStatus(errSecInteractionNotAllowed, result: nil) == .failed(errSecInteractionNotAllowed),
            "expected errSecInteractionNotAllowed to classify as .failed, not be conflated with .notFound"
        )
        XCTAssert(
            ConfigurationStore.classifyKeychainReadStatus(errSecAuthFailed, result: nil) == .failed(errSecAuthFailed),
            "expected errSecAuthFailed to classify as .failed, not be conflated with .notFound"
        )
        XCTAssert(
            ConfigurationStore.classifyKeychainReadStatus(errSecSuccess, result: nil) == .failed(errSecSuccess),
            "expected a success status with no data back to be treated as a failure rather than crash/round-trip empty data"
        )
    }

    func testFreshStoreHasNoSnapshotAndNoLoadError() throws {
        try withIsolatedStore(name: "fresh") { store, _ in
            XCTAssert(!store.hasSavedSnapshot, "expected a brand-new isolated Keychain item to report no saved snapshot")

            let snapshot = store.load()
            XCTAssert(snapshot.savedConnections.isEmpty, "expected defaults for a never-saved store")
            XCTAssert(store.lastLoadError == nil, "a missing item is not a load failure")
        }
    }

    func testSaveAndLoadRoundTrip() throws {
        try withIsolatedStore(name: "roundtrip") { store, _ in
            let saved = AppSnapshot(
                savedConnections: [],
                subscriptionSources: [],
                selectedConnectionID: nil,
                proxyEndpoint: .default,
                showsLatencyInMenuBarPicker: false
            )
            try store.save(saved)

            XCTAssert(store.hasSavedSnapshot, "expected hasSavedSnapshot to be true right after save()")
            let loaded = store.load()
            XCTAssert(store.lastLoadError == nil, "a successful save/load round trip should not report a load error")
            XCTAssert(loaded.showsLatencyInMenuBarPicker == false, "expected the round-tripped snapshot to match what was saved")
        }
    }

    func testHysteriaSaveAndLoad() throws {
        try withIsolatedStore(name: "hysteria") { store, _ in
            let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures/subscriptions/hysteria2.json")
            let configuration = try ConnectionLinkParser().parse(String(contentsOf: fixture, encoding: .utf8))
            let connection = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date(), customName: "My Hysteria server")
            try store.save(AppSnapshot(savedConnections: [connection], subscriptionSources: [], selectedConnectionID: connection.id, proxyEndpoint: .default))
            let loaded = store.load()
            XCTAssert(store.lastLoadError == nil && loaded.savedConnections == [connection])
            let reparsed = try ConnectionLinkParser().parse(loaded.savedConnections[0].configuration.rawLink)
            XCTAssert(reparsed == configuration, "Extended Hysteria settings must survive Keychain storage and startup reparsing")
        }
    }

    /// Which connections a session carries is derived from the rules, so the only
    /// new persisted state is the connection a rule names.
    func testSessionConnectionsSurviveAndOldSnapshotsStaySingleConnection() throws {
        let connectionID = UUID()
        let rule = SplitTunnelRule(value: "example.com", kind: .domain, action: .proxy, connectionID: connectionID)
        let roundTripped = try JSONDecoder().decode(
            SplitTunnelRule.self,
            from: try JSONEncoder().encode(rule)
        )
        XCTAssert(roundTripped.connectionID == connectionID)

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
        XCTAssert(legacyRule.connectionID == nil, "expected a pre-upgrade rule to use the default connection")
    }

    func testLegacyStateFileMigratesToSealedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-persistence-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileManager = TempFileManager(root: root)
        let store = ConfigurationStore(
            fileManager: fileManager,
            keychainService: Self.verifyService,
            keychainAccount: "verify-migration-\(UUID().uuidString)",
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
        )
        defer { store.deleteStoredDataForTesting() }

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
        XCTAssert(store.hasSavedSnapshot, "expected the legacy state file to count as a saved snapshot")
        XCTAssert(!migrated.showsLatencyInMenuBarPicker, "expected legacy settings to be returned during migration")
        XCTAssert(store.hasSavedSnapshot, "expected the migrated Keychain snapshot to exist")
        XCTAssert(!fileManager.fileExists(atPath: legacyFileURL.path), "expected plaintext state to be removed after migration")

        let loadedAgain = store.load()
        XCTAssert(!loadedAgain.showsLatencyInMenuBarPicker, "expected the migrated Keychain snapshot to survive a second load")
    }

    // This is the regression the fix targets: once load() has flagged a Keychain read
    // failure, save() must refuse rather than silently persist an in-memory snapshot
    // that was only ever populated with defaults because the real data was unreadable.
    func testLoadFailureRefusesToOverwriteExistingSnapshot() throws {
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
            XCTAssert(store.lastLoadError != nil, "expected the simulated load failure to be recorded")

            do {
                try store.save(AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default))
                XCTFail("expected save() to throw after a load failure instead of overwriting the existing snapshot")
            } catch is ConfigurationStoreError {
                // expected
            }

            store.simulateLoadFailureForTesting(status: nil)
            let stillIntact = store.load()
            XCTAssert(stillIntact.showsLatencyInMenuBarPicker == true, "expected the original snapshot to survive the refused save")
        }
    }

    private static let verifyService = "dev.x.teleport.configuration.verify"

    private func makeSnapshot(connections count: Int) throws -> AppSnapshot {
        let connections = try (0..<count).map { index in
            SavedConnection(
                id: UUID(),
                configuration: try ConnectionLinkParser().parse("trojan://secret@server\(index).example.com:443?security=tls&type=tcp#\(index)"),
                savedAt: Date()
            )
        }
        return AppSnapshot(savedConnections: connections, subscriptionSources: [], selectedConnectionID: connections.first?.id, proxyEndpoint: .default)
    }

    /// Stages an item the way the old layout wrote them, under the isolated service.
    private func addKeychainItem(account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.verifyService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ConfigurationStoreError.keychainWriteFailed(status) }
    }

    /// Every account under the isolated service, attributes only.
    private func keychainAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.verifyService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func withIsolatedStore(name: String, _ body: (ConfigurationStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("teleport-verify-persistence-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ConfigurationStore(
            fileManager: TempFileManager(root: root),
            keychainService: Self.verifyService,
            keychainAccount: "verify-\(name)-\(UUID().uuidString)",
            // Into the throwaway root, so a test run does not write test noise
            // into the log a real incident is read from.
            log: TeleportLog(directoryURL: root, fileName: "verify.log")
        )
        defer { store.deleteStoredDataForTesting() }

        try body(store, root)
    }
}
