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

    static let subsystem = "persistence"

    private static let defaultKeychainService = "dev.x.teleport.configuration"
    private static let defaultKeychainAccount = "app-snapshot"

    /// `keychainService`/`keychainAccount` are overridable so verification scripts can
    /// exercise this store against an isolated Keychain item instead of the real one
    /// used by the shipping app (which holds the user's actual saved connections).
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
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    /// Set by the most recent `load()` when the Keychain item exists but could not be
    /// read (e.g. access denied because the Keychain was still locked, or the app's
    /// code signature changed since the item was written). Distinguishing this from
    /// "no snapshot was ever saved" matters: if we silently treated it as empty, the
    /// next `save()` would overwrite the real data in Keychain with a blank snapshot,
    /// making the loss permanent. Callers should surface this to the user and avoid
    /// persisting until it is resolved (e.g. after unlocking Keychain and relaunching).
    private(set) var lastLoadError: Error?

    /// Whether the most recent `load()` actually found a stored item. Callers used to
    /// answer this with a second Keychain read, which could disagree with the one
    /// `load()` made — and a disagreement that says "nothing saved" makes the caller
    /// seed defaults and write them over the real snapshot. One read, one answer.
    private(set) var lastLoadFoundStoredSnapshot = false

    /// How much user data the snapshot currently believed to be in the Keychain
    /// holds, so `save()` can tell a save that drops some of it from one that does
    /// not. Nil until a load or save establishes it.
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
        importPlaintextBackupsIfPresent()

        switch keychainSnapshotResult() {
        case let .found(data):
            lastLoadFoundStoredSnapshot = true
            if let snapshot = decodeSnapshot(from: data) {
                persistedExtent = SnapshotExtent(snapshot)
                // Every launch that reads a good snapshot leaves a copy behind, so
                // no later write is ever the only copy of what was there.
                retainGoodSnapshot(data, reason: "loaded")
                log.info(Self.subsystem, "loaded snapshot: \(snapshot.savedConnections.count) connections, \(snapshot.subscriptionSources.count) subscriptions, mode \(snapshot.connectionMode)")
                return snapshot
            }

            // The item is there but this build cannot decode it, which one
            // incompatible model change between two builds is enough to cause.
            // Treated exactly like a read failure rather than as "no data":
            // without the save-guard the first autosave after launch (a health
            // probe, a subscription refresh) would encode the current empty state
            // over the only copy of the user's connections.
            let backupAccount = backUpUndecodableSnapshot(data)
            lastLoadError = ConfigurationStoreError.snapshotCouldNotBeDecoded(backupAccount: backupAccount)
            log.error(Self.subsystem, "keychain snapshot could not be decoded (\(data.count) bytes); refusing to save, raw copy kept as keychain item \(backupAccount ?? "<backup failed>")")
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        case .notFound:
            log.info(Self.subsystem, "no keychain snapshot yet")
        case let .failed(status):
            lastLoadError = ConfigurationStoreError.keychainReadFailed(status)
            log.error(Self.subsystem, "keychain read failed with OSStatus \(status); refusing to save")
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        }

        if let data = try? Data(contentsOf: legacyFileURL) {
            lastLoadFoundStoredSnapshot = true
            if let snapshot = decodeSnapshot(from: data) {
                persistedExtent = SnapshotExtent(snapshot)
                retainGoodSnapshot(data, reason: "legacy")
                // Direct upgrades from v0.1.0 still have their only snapshot here.
                // Delete the plaintext copy only after the Keychain migration succeeds.
                if (try? save(snapshot)) != nil {
                    try? fileManager.removeItem(at: legacyFileURL)
                    log.info(Self.subsystem, "migrated legacy state.json into keychain")
                }
                return snapshot
            }

            let backupAccount = backUpUndecodableSnapshot(data)
            lastLoadError = ConfigurationStoreError.snapshotCouldNotBeDecoded(backupAccount: backupAccount)
            log.error(Self.subsystem, "legacy state.json could not be decoded; refusing to save, raw copy kept as keychain item \(backupAccount ?? "<backup failed>")")
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
        // copy. Whatever is in the Keychain right now is written aside first, so an
        // in-memory state that lost data to a bug is recoverable rather than merely
        // logged.
        let extent = SnapshotExtent(snapshot)
        if let previous = persistedExtent, extent.shrinks(from: previous) {
            var kept = "<none>"
            if case let .found(currentData) = keychainSnapshotResult() {
                kept = retainGoodSnapshot(currentData, reason: "shrink") ?? "<backup failed>"
            }
            log.warn(Self.subsystem, "save drops connections \(previous.connections) -> \(extent.connections), subscriptions \(previous.subscriptions) -> \(extent.subscriptions); previous snapshot kept as keychain item \(kept)")
        }

        let data = try encoder.encode(snapshot)
        do {
            try writeKeychainItem(data, account: keychainAccount)
        } catch {
            log.error(Self.subsystem, "save failed: \(LogFormat.error(error))")
            throw error
        }
        persistedExtent = extent
        lastLoadFoundStoredSnapshot = true
        log.info(Self.subsystem, "saved snapshot: \(snapshot.savedConnections.count) connections, \(snapshot.subscriptionSources.count) subscriptions")
    }

    // MARK: - Backup copies

    /// Copies live in the Keychain beside the live item, under accounts derived
    /// from it, so they get the same protection the live snapshot was moved into
    /// the Keychain for: a snapshot holds every link, user id and password the user
    /// has. A file under Application Support would have undone that move.
    ///
    /// They are still recoverable by hand:
    ///
    ///     security find-generic-password -s dev.x.teleport.configuration \
    ///         -a 'app-snapshot.retained.<stamp>-loaded' -w
    private var retainedAccountPrefix: String { "\(keychainAccount).retained." }
    private var unreadableAccountPrefix: String { "\(keychainAccount).unreadable." }

    /// Rolling copies of snapshots that decoded cleanly. Kept separately from the
    /// unreadable ones because these are the ones worth restoring from directly:
    /// they are known-good, and the newest predates whatever went wrong.
    /// Returns the account the copy lives under.
    @discardableResult
    private func retainGoodSnapshot(_ data: Data, reason: String) -> String? {
        let existing = retainedSnapshotAccounts()

        // An unchanged snapshot re-read on every launch would otherwise push the
        // generations that differ from it out of the window within five launches.
        if let newest = existing.last, readKeychainItem(account: newest) == data {
            return newest
        }

        let account = "\(retainedAccountPrefix)\(Self.fileStamp())-\(reason)"
        guard (try? writeKeychainItem(data, account: account)) != nil else { return nil }

        for stale in (existing + [account]).dropLast(Self.retainedSnapshotGenerations) {
            deleteKeychainItem(account: stale)
        }
        return account
    }

    /// Keeps the bytes we could not decode, so a snapshot this build rejects is
    /// still recoverable by hand (or by a later build that understands it). Stamped
    /// because a user who relaunches a few times before noticing should not
    /// overwrite the first, most complete copy. Returns the account it lives under.
    private func backUpUndecodableSnapshot(_ data: Data) -> String? {
        let account = "\(unreadableAccountPrefix)\(Self.fileStamp())"
        guard (try? writeKeychainItem(data, account: account)) != nil else { return nil }
        return account
    }

    /// Accounts of the retained good copies, oldest first. Names begin with a
    /// sortable timestamp, so lexicographic order is chronological order.
    func retainedSnapshotAccounts() -> [String] {
        keychainAccounts().filter { $0.hasPrefix(retainedAccountPrefix) }.sorted()
    }

    /// Accounts of the copies this build could not decode, oldest first.
    func unreadableSnapshotAccounts() -> [String] {
        keychainAccounts().filter { $0.hasPrefix(unreadableAccountPrefix) }.sorted()
    }

    /// The raw bytes of one backup copy, for a recovery tool or a test.
    func snapshotBackupData(account: String) -> Data? {
        readKeychainItem(account: account)
    }

    /// Five launches back is far enough to cover "I only noticed a few restarts
    /// later", which is how the loss this guards against was actually discovered.
    private static let retainedSnapshotGenerations = 5

    private static func fileStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    /// One earlier build of this branch kept its copies as plaintext files under
    /// Application Support. Any still there are moved into the Keychain and the
    /// files removed, so no plaintext copy of a link outlives this build's first
    /// launch. Temporary: safe to delete once no machine has run that build.
    private func importPlaintextBackupsIfPresent() {
        let baseURL = legacyFileURL.deletingLastPathComponent()
        let directories = [
            (baseURL.appendingPathComponent("snapshots", isDirectory: true), retainedAccountPrefix),
            (baseURL.appendingPathComponent("unreadable-snapshots", isDirectory: true), unreadableAccountPrefix)
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
                if (try? writeKeychainItem(data, account: prefix + stem)) != nil {
                    imported += 1
                }
            }
            try? fileManager.removeItem(at: directoryURL)
            log.info(Self.subsystem, "moved \(imported) of \(files.count) plaintext backup copies from \(directoryURL.lastPathComponent)/ into the keychain and removed the directory")
        }
    }

    private func decodeSnapshot(from data: Data) -> AppSnapshot? {
        try? decoder.decode(AppSnapshot.self, from: data)
    }

    // MARK: - Keychain

    enum KeychainSnapshotResult: Equatable {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    private func keychainSnapshotResult() -> KeychainSnapshotResult {
        var query = keychainQuery(account: keychainAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return Self.classifyKeychainReadStatus(status, result: result)
    }

    /// Pure mapping from a raw `SecItemCopyMatching` outcome to a `KeychainSnapshotResult`,
    /// pulled out of `keychainSnapshotResult()` so it can be exercised deterministically by
    /// verification scripts without needing to force real Keychain failures (which would
    /// require locking the system Keychain and risking flakiness/leftover state).
    static func classifyKeychainReadStatus(_ status: OSStatus, result: CFTypeRef?) -> KeychainSnapshotResult {
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

    private func readKeychainItem(account: String) -> Data? {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
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

    private func writeKeychainItem(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(keychainQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw ConfigurationStoreError.keychainWriteFailed(updateStatus)
        }

        var addQuery = keychainQuery(account: account)
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ConfigurationStoreError.keychainWriteFailed(addStatus)
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

    /// Writes bytes into the live item without encoding them, so a verification
    /// script can stage a snapshot this build cannot decode. The shipping app never
    /// calls this.
    func writeRawSnapshotDataForTesting(_ data: Data) throws {
        try writeKeychainItem(data, account: keychainAccount)
    }

    /// Deletes the live item and every backup copy derived from it (bypassing the
    /// `lastLoadError` save-guard). Only meaningful for tests that need to reset an
    /// isolated item between runs; the shipping app never calls this.
    func deleteKeychainItemForTesting() {
        deleteKeychainItem(account: keychainAccount)
        for account in keychainAccounts() where account.hasPrefix("\(keychainAccount).") {
            deleteKeychainItem(account: account)
        }
    }
}

enum ConfigurationStoreError: LocalizedError {
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case snapshotCouldNotBeDecoded(backupAccount: String?)
    case refusedToOverwriteAfterLoadFailure

    var errorDescription: String? {
        switch self {
        case let .keychainWriteFailed(status):
            return "Failed to save Teleport configuration secrets to Keychain: OSStatus \(status)"
        case let .keychainReadFailed(status):
            return "Failed to read Teleport configuration secrets from Keychain (OSStatus \(status)). Your saved connections were not lost — unlock Keychain Access and restart Teleport."
        case let .snapshotCouldNotBeDecoded(backupAccount):
            let location = backupAccount.map { " A copy was kept in your Keychain as item “\($0)”." } ?? ""
            return "Teleport could not read its saved settings — they were written by a different version of the app. Nothing was deleted, and Teleport will not overwrite them.\(location)"
        case .refusedToOverwriteAfterLoadFailure:
            return "Refusing to save: the previous Keychain read failed, so saving now could overwrite your existing settings."
        }
    }
}
