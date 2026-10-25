import CryptoKit
import Foundation
import Security

final class ConfigurationStore {
    private let fileManager: FileManager
    private let legacyFileURL: URL
    private let keychainService: String
    private let keychainAccount: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let log: TeleportLog

    /// The sealed snapshot and its copies, one directory per account so an
    /// isolated test store never touches the files of the shipping app.
    let sealedDirectoryURL: URL

    static let subsystem = "persistence"

    private static let defaultKeychainService = "dev.x.teleport.configuration"
    private static let defaultKeychainAccount = "app-snapshot"

    /// `keychainService`/`keychainAccount` are overridable so verification scripts can
    /// exercise this store against an isolated key and directory instead of the real
    /// ones used by the shipping app (which hold the user's actual saved connections).
    init(
        fileManager: FileManager = .default,
        keychainService: String = ConfigurationStore.defaultKeychainService,
        keychainAccount: String = ConfigurationStore.defaultKeychainAccount,
        log: TeleportLog = .shared
    ) {
        self.fileManager = fileManager
        self.log = log
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = baseURL.appendingPathComponent("teleport", isDirectory: true)
        legacyFileURL = directoryURL.appendingPathComponent("state.json")
        sealedDirectoryURL = directoryURL
            .appendingPathComponent("sealed", isDirectory: true)
            .appendingPathComponent(keychainAccount, isDirectory: true)
        try? fileManager.createDirectory(at: sealedDirectoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sealedDirectoryURL.path)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    /// Set by the most recent `load()` when a snapshot exists but could not be read
    /// (e.g. the key could not be read because the Keychain was still locked, or the
    /// app's code signature changed since the key was written). Distinguishing this
    /// from "no snapshot was ever saved" matters: if we silently treated it as empty,
    /// the next `save()` would overwrite the real data with a blank snapshot, making
    /// the loss permanent. Callers should surface this to the user and avoid
    /// persisting until it is resolved (e.g. after unlocking Keychain and relaunching).
    private(set) var lastLoadError: Error?

    /// Whether the most recent `load()` actually found a stored snapshot. Callers used
    /// to answer this with a second read, which could disagree with the one `load()`
    /// made — and a disagreement that says "nothing saved" makes the caller seed
    /// defaults and write them over the real snapshot. One read, one answer.
    private(set) var lastLoadFoundStoredSnapshot = false

    /// How much user data the snapshot currently believed to be on disk holds, so
    /// `save()` can tell a save that drops some of it from one that does not. Nil
    /// until a load or save establishes it.
    private var persistedExtent: SnapshotExtent?

    /// The two collections a user builds up by hand and would notice missing.
    /// Everything else in a snapshot is a setting that can be re-chosen.
    private struct SnapshotExtent: Equatable {
        let connections: Int
        let subscriptions: Int

        init(_ snapshot: AppSnapshot) {
            connections = snapshot.savedConnections.count
            subscriptions = snapshot.subscriptionSources.count
        }

        func shrinks(from previous: SnapshotExtent) -> Bool {
            connections < previous.connections || subscriptions < previous.subscriptions
        }
    }

    /// Forces `lastLoadError` without going through a real Keychain failure, since
    /// deterministically forcing SecItemCopyMatching to fail would require locking the
    /// system Keychain (risking flakiness and leftover state). Pass `nil` to clear it.
    /// The shipping app never calls this.
    func simulateLoadFailureForTesting(status: OSStatus?) {
        lastLoadError = status.map(ConfigurationStoreError.keychainReadFailed)
    }

    /// Answered from the last `load()` rather than from a fresh read, so a caller
    /// deciding whether to seed defaults cannot be told "nothing is saved" about a
    /// snapshot that `load()` just read successfully.
    var hasSavedSnapshot: Bool {
        lastLoadFoundStoredSnapshot
    }

    func load() -> AppSnapshot {
        lastLoadError = nil
        lastLoadFoundStoredSnapshot = false
        persistedExtent = nil

        // Everything below reads or writes sealed files, so the key comes first;
        // without it nothing is touched.
        do {
            _ = try obtainKey()
        } catch {
            lastLoadError = error
            log.error(Self.subsystem, "encryption key unavailable: \(LogFormat.error(error)); refusing to save")
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        }
        migrateKeychainItemsIfPresent()
        if lastLoadError != nil {
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        }
        importPlaintextBackupsIfPresent()

        if fileManager.fileExists(atPath: currentSnapshotFileURL.path) {
            lastLoadFoundStoredSnapshot = true
            guard let data = readSealedFile(name: Self.currentSnapshotName) else {
                // The file is there but does not open with the key, so it is
                // either damaged or sealed under another key (another machine's,
                // or one this Keychain no longer has). Treated like a read failure.
                lastLoadError = ConfigurationStoreError.snapshotCouldNotBeOpened
                log.error(Self.subsystem, "sealed snapshot could not be opened; refusing to save")
                return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
            }
            if let snapshot = decodeSnapshot(from: data) {
                persistedExtent = SnapshotExtent(snapshot)
                // Every launch that reads a good snapshot leaves a copy behind, so
                // no later write is ever the only copy of what was there.
                retainGoodSnapshot(data, reason: "loaded")
                log.info(Self.subsystem, "loaded snapshot: \(snapshot.savedConnections.count) connections, \(snapshot.subscriptionSources.count) subscriptions, mode \(snapshot.connectionMode)")
                return snapshot
            }

            // The snapshot is there but this build cannot decode it, which one
            // incompatible model change between two builds is enough to cause.
            // Treated exactly like a read failure rather than as "no data":
            // without the save-guard the first autosave after launch (a health
            // probe, a subscription refresh) would encode the current empty state
            // over the only copy of the user's connections.
            let backupName = backUpUndecodableSnapshot(data)
            lastLoadError = ConfigurationStoreError.snapshotCouldNotBeDecoded(backupName: backupName)
            log.error(Self.subsystem, "snapshot could not be decoded (\(data.count) bytes); refusing to save, raw copy kept as sealed file \(backupName ?? "<backup failed>")")
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        }
        log.info(Self.subsystem, "no sealed snapshot yet")

        if let data = try? Data(contentsOf: legacyFileURL) {
            lastLoadFoundStoredSnapshot = true
            if let snapshot = decodeSnapshot(from: data) {
                persistedExtent = SnapshotExtent(snapshot)
                retainGoodSnapshot(data, reason: "legacy")
                // Direct upgrades from v0.1.0 still have their only snapshot here.
                // Delete the plaintext copy only after the sealed one is written.
                if (try? save(snapshot)) != nil {
                    try? fileManager.removeItem(at: legacyFileURL)
                    log.info(Self.subsystem, "migrated legacy state.json into a sealed file")
                }
                return snapshot
            }

            let backupName = backUpUndecodableSnapshot(data)
            lastLoadError = ConfigurationStoreError.snapshotCouldNotBeDecoded(backupName: backupName)
            log.error(Self.subsystem, "legacy state.json could not be decoded; refusing to save, raw copy kept as sealed file \(backupName ?? "<backup failed>")")
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        }

        return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
    }

    func save(_ snapshot: AppSnapshot) throws {
        if let lastLoadError {
            log.warn(Self.subsystem, "refused to save \(snapshot.savedConnections.count) connections after a failed load: \(LogFormat.error(lastLoadError))")
            throw ConfigurationStoreError.refusedToOverwriteAfterLoadFailure
        }

        // A save that drops connections or subscriptions is not refused — deleting
        // one is an ordinary thing to do — but it is never allowed to be the only
        // copy. Whatever is on disk right now is written aside first, so an
        // in-memory state that lost data to a bug is recoverable rather than merely
        // logged.
        let extent = SnapshotExtent(snapshot)
        if let previous = persistedExtent, extent.shrinks(from: previous) {
            var kept = "<none>"
            if let currentData = readSealedFile(name: Self.currentSnapshotName) {
                kept = retainGoodSnapshot(currentData, reason: "shrink") ?? "<backup failed>"
            }
            log.warn(Self.subsystem, "save drops connections \(previous.connections) -> \(extent.connections), subscriptions \(previous.subscriptions) -> \(extent.subscriptions); previous snapshot kept as sealed file \(kept)")
        }

        let data = try encoder.encode(snapshot)
        do {
            try writeSealedFile(data, name: Self.currentSnapshotName)
        } catch {
            log.error(Self.subsystem, "save failed: \(LogFormat.error(error))")
            throw error
        }
        persistedExtent = extent
        lastLoadFoundStoredSnapshot = true
        log.info(Self.subsystem, "saved snapshot: \(snapshot.savedConnections.count) connections, \(snapshot.subscriptionSources.count) subscriptions")
    }

    // MARK: - Backup copies

    /// Copies live beside the live snapshot as files sealed under the same key, so
    /// they get the protection the snapshot was moved into the Keychain for: a
    /// snapshot holds every link, user id and password the user has. Each copy is
    /// its own file that no save ever rewrites; only pruning removes one.
    ///
    /// They are still recoverable by hand:
    ///
    ///     just decrypt-snapshot retained.<stamp>-loaded
    private static let retainedFilePrefix = "retained."
    private static let unreadableFilePrefix = "unreadable."

    /// Rolling copies of snapshots that decoded cleanly. Kept separately from the
    /// unreadable ones because these are the ones worth restoring from directly:
    /// they are known-good, and the newest predates whatever went wrong.
    /// Returns the file name the copy lives under.
    @discardableResult
    private func retainGoodSnapshot(_ data: Data, reason: String) -> String? {
        let existing = retainedSnapshotCopies()

        // An unchanged snapshot re-read on every launch would otherwise push the
        // generations that differ from it out of the window within five launches.
        if let newest = existing.last, readSealedFile(name: newest) == data {
            return newest
        }

        guard let name = writeNewSealedFile(data, base: "\(Self.retainedFilePrefix)\(Self.fileStamp())-\(reason)") else { return nil }

        for stale in (existing + [name]).dropLast(Self.retainedSnapshotGenerations) {
            try? fileManager.removeItem(at: sealedFileURL(stale))
        }
        return name
    }

    /// Keeps the bytes we could not decode, so a snapshot this build rejects is
    /// still recoverable by hand (or by a later build that understands it). Stamped
    /// because a user who relaunches a few times before noticing should not
    /// overwrite the first, most complete copy. Returns the file name it lives under.
    private func backUpUndecodableSnapshot(_ data: Data) -> String? {
        writeNewSealedFile(data, base: "\(Self.unreadableFilePrefix)\(Self.fileStamp())")
    }

    /// File names of the retained good copies, oldest first. Names begin with a
    /// sortable timestamp, so lexicographic order is chronological order.
    func retainedSnapshotCopies() -> [String] {
        sealedFileNames().filter { $0.hasPrefix(Self.retainedFilePrefix) }
    }

    /// File names of the copies this build could not decode, oldest first.
    func unreadableSnapshotCopies() -> [String] {
        sealedFileNames().filter { $0.hasPrefix(Self.unreadableFilePrefix) }
    }

    /// The decrypted bytes of one backup copy, for a recovery tool or a test.
    func snapshotBackupData(name: String) -> Data? {
        readSealedFile(name: name)
    }

    /// Five launches back is far enough to cover "I only noticed a few restarts
    /// later", which is how the loss this guards against was actually discovered.
    private static let retainedSnapshotGenerations = 5

    private static func fileStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    /// Earlier builds kept the snapshot and every copy as its own Keychain item.
    /// Each item has its own access list, so an ad hoc signed update asked for the
    /// Keychain password once per item it touched. The first load of this build
    /// moves them into sealed files, deleting each item only once its bytes are on
    /// disk. Temporary: safe to delete once no machine has run those builds.
    ///
    /// Runs only while there is no sealed snapshot yet. An item that outlives the
    /// move (its delete failed) must not be read again: after the next update that
    /// read asks for the password again, and a copy pruning removed would come back.
    private func migrateKeychainItemsIfPresent() {
        let accounts = keychainAccounts()
        guard accounts.contains(keychainAccount),
              !fileManager.fileExists(atPath: currentSnapshotFileURL.path) else { return }

        // "app-snapshot.retained.<stamp>-loaded" → "retained.<stamp>-loaded".
        // Deliberately not every account under the prefix: the key lives there too.
        for account in accounts where account.hasPrefix("\(keychainAccount).") {
            let name = String(account.dropFirst(keychainAccount.count + 1))
            guard name.hasPrefix(Self.retainedFilePrefix) || name.hasPrefix(Self.unreadableFilePrefix) else { continue }
            try? moveKeychainItem(account: account, toSealedFile: name)
        }

        // The live item last, since its sealed file is what ends the migration.
        // One that did not move must stop the load: with no sealed snapshot and no
        // error, the first autosave would write one over the user's connections.
        do {
            try moveKeychainItem(account: keychainAccount, toSealedFile: Self.currentSnapshotName)
        } catch {
            lastLoadError = error
            log.error(Self.subsystem, "could not move the keychain snapshot into a sealed file: \(LogFormat.error(error)); refusing to save")
            return
        }
        log.info(Self.subsystem, "moved keychain snapshot items into sealed files")
    }

    /// Reads the item only when its file is missing, so a rerun after a failed
    /// live move costs no prompt for the copies already moved.
    private func moveKeychainItem(account: String, toSealedFile name: String) throws {
        if !fileManager.fileExists(atPath: sealedFileURL(name).path) {
            switch readKeychainItemResult(account: account) {
            case let .found(data):
                try writeSealedFile(data, name: name)
            case let .failed(status):
                throw ConfigurationStoreError.keychainReadFailed(status)
            case .notFound:
                return
            }
        }
        deleteMovedKeychainItem(account: account)
    }

    /// Only the build that created an item may delete it (errSecInvalidOwnerEdit
    /// otherwise), and after an update every item was created by another build.
    /// /usr/bin/security deletes it without a prompt.
    private func deleteMovedKeychainItem(account: String) {
        guard SecItemDelete(keychainQuery(account: account) as CFDictionary) == errSecInvalidOwnerEdit else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", keychainService, "-a", account]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.warn(Self.subsystem, "could not delete keychain item \(account): \(LogFormat.error(error))")
        }
    }

    /// One earlier build of this branch kept its copies as plaintext files under
    /// Application Support. Any still there are sealed and the files removed, so
    /// no plaintext copy of a link outlives this build's first launch. Temporary:
    /// safe to delete once no machine has run that build.
    private func importPlaintextBackupsIfPresent() {
        let baseURL = legacyFileURL.deletingLastPathComponent()
        let directories = [
            (baseURL.appendingPathComponent("snapshots", isDirectory: true), Self.retainedFilePrefix),
            (baseURL.appendingPathComponent("unreadable-snapshots", isDirectory: true), Self.unreadableFilePrefix)
        ]
        for (directoryURL, prefix) in directories {
            guard fileManager.fileExists(atPath: directoryURL.path) else { continue }
            let files = ((try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var imported = 0
            for fileURL in files {
                guard let data = try? Data(contentsOf: fileURL) else { continue }
                // "snapshot-<stamp>-<reason>.json" → "<stamp>-<reason>", keeping the order.
                let stem = fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "snapshot-", with: "")
                if writeNewSealedFile(data, base: prefix + stem) != nil {
                    imported += 1
                }
            }
            try? fileManager.removeItem(at: directoryURL)
            log.info(Self.subsystem, "moved \(imported) of \(files.count) plaintext backup copies from \(directoryURL.lastPathComponent)/ into sealed files and removed the directory")
        }
    }

    private func decodeSnapshot(from data: Data) -> AppSnapshot? {
        try? decoder.decode(AppSnapshot.self, from: data)
    }

    // MARK: - Sealed files

    private static let currentSnapshotName = "snapshot"

    var currentSnapshotFileURL: URL { sealedFileURL(Self.currentSnapshotName) }

    private func sealedFileURL(_ name: String) -> URL {
        sealedDirectoryURL.appendingPathComponent(name)
    }

    /// Every file in the sealed directory, sorted.
    private func sealedFileNames() -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: sealedDirectoryURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// AES-GCM, nonce and tag in the file with the ciphertext; a changed byte makes
    /// the file fail to open rather than decode to something else.
    private func writeSealedFile(_ data: Data, name: String) throws {
        let sealed = try AES.GCM.seal(data, using: obtainKey()).combined!
        let fileURL = sealedFileURL(name)
        try sealed.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Writes a copy under a name no existing copy has, so two copies made within
    /// the same second both survive. Returns the name used.
    private func writeNewSealedFile(_ data: Data, base: String) -> String? {
        var name = base
        var attempt = 2
        while fileManager.fileExists(atPath: sealedFileURL(name).path) {
            name = "\(base).\(attempt)"
            attempt += 1
        }
        guard (try? writeSealedFile(data, name: name)) != nil else { return nil }
        return name
    }

    /// Nil when the file is missing, unreadable, or does not open with the key.
    private func readSealedFile(name: String) -> Data? {
        guard let key = try? obtainKey(), let sealed = try? Data(contentsOf: sealedFileURL(name)) else { return nil }
        return try? AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }

    // MARK: - Keychain

    private var keyAccount: String { "\(keychainAccount).key" }
    private var cachedKey: SymmetricKey?

    /// The key is the only thing kept in the Keychain, so a build whose signature
    /// changed asks for the Keychain password once, here, instead of once per item
    /// it touches. Read once and kept for the life of the store.
    private func obtainKey() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let key: SymmetricKey
        switch readKeychainItemResult(account: keyAccount) {
        case let .found(data):
            key = SymmetricKey(data: data)
        case let .failed(status):
            throw ConfigurationStoreError.keychainReadFailed(status)
        case .notFound:
            // Only a store with nothing sealed yet may start a key: a new key next
            // to existing files would lock them for good.
            guard sealedFileNames().isEmpty else { throw ConfigurationStoreError.encryptionKeyMissing }
            key = SymmetricKey(size: .bits256)
            try addKeychainItem(key.withUnsafeBytes { Data($0) }, account: keyAccount)
        }
        cachedKey = key
        return key
    }

    enum KeychainReadResult: Equatable {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    private func readKeychainItemResult(account: String) -> KeychainReadResult {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return Self.classifyKeychainReadStatus(status, result: result)
    }

    /// Pure mapping from a raw `SecItemCopyMatching` outcome to a `KeychainReadResult`,
    /// pulled out of `readKeychainItemResult()` so it can be exercised deterministically by
    /// verification scripts without needing to force real Keychain failures (which would
    /// require locking the system Keychain and risking flakiness/leftover state).
    static func classifyKeychainReadStatus(_ status: OSStatus, result: CFTypeRef?) -> KeychainReadResult {
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(status) }
            return .found(data)
        case errSecItemNotFound:
            return .notFound
        default:
            return .failed(status)
        }
    }

    /// Every account under this store's service. Attributes are not protected
    /// data, so listing them prompts for nothing.
    private func keychainAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Add only, never update: the key is written once and the item is never
    /// touched again, so no later build has a reason to ask for it twice.
    private func addKeychainItem(_ data: Data, account: String) throws {
        var query = keychainQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ConfigurationStoreError.keychainWriteFailed(status)
        }
    }

    private func deleteKeychainItem(account: String) {
        SecItemDelete(keychainQuery(account: account) as CFDictionary)
    }

    private func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }

    // MARK: - Test hooks

    /// Seals bytes into the live snapshot file without encoding them, so a
    /// verification script can stage a snapshot this build cannot decode. The
    /// shipping app never calls this.
    func writeRawSnapshotDataForTesting(_ data: Data) throws {
        try writeSealedFile(data, name: Self.currentSnapshotName)
    }

    /// Forgets the key and deletes its Keychain item, leaving the sealed files
    /// behind, so a test can stage a launch whose key is gone. The shipping app
    /// never calls this.
    func deleteEncryptionKeyForTesting() {
        deleteKeychainItem(account: keyAccount)
        cachedKey = nil
    }

    /// Deletes the key, every sealed file and any old-layout Keychain items
    /// (bypassing the `lastLoadError` save-guard). Only meaningful for tests that
    /// need to reset an isolated store between runs; the shipping app never calls this.
    func deleteStoredDataForTesting() {
        try? fileManager.removeItem(at: sealedDirectoryURL)
        deleteKeychainItem(account: keychainAccount)
        for account in keychainAccounts() where account.hasPrefix("\(keychainAccount).") {
            deleteKeychainItem(account: account)
        }
        cachedKey = nil
    }
}

enum ConfigurationStoreError: LocalizedError {
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case encryptionKeyMissing
    case snapshotCouldNotBeOpened
    case snapshotCouldNotBeDecoded(backupName: String?)
    case refusedToOverwriteAfterLoadFailure

    var errorDescription: String? {
        switch self {
        case let .keychainWriteFailed(status):
            return "Failed to save Teleport's encryption key to Keychain: OSStatus \(status)"
        case let .keychainReadFailed(status):
            return "Failed to read Teleport's encryption key from Keychain (OSStatus \(status)). Your saved connections were not lost — unlock Keychain Access and restart Teleport."
        case .encryptionKeyMissing:
            return "Teleport's saved settings are encrypted, but the key is missing from your Keychain. Nothing was deleted, and Teleport will not overwrite them."
        case .snapshotCouldNotBeOpened:
            return "Teleport could not decrypt its saved settings — the file does not match the key in your Keychain. Nothing was deleted, and Teleport will not overwrite them."
        case let .snapshotCouldNotBeDecoded(backupName):
            let location = backupName.map { " A copy was kept as the encrypted file “\($0)” in Teleport's Application Support folder." } ?? ""
            return "Teleport could not read its saved settings — they were written by a different version of the app. Nothing was deleted, and Teleport will not overwrite them.\(location)"
        case .refusedToOverwriteAfterLoadFailure:
            return "Refusing to save: the previous load failed, so saving now could overwrite your existing settings."
        }
    }
}
