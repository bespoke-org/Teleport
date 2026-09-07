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

    /// Forces `lastLoadError` without going through a real Keychain failure, since
    /// deterministically forcing SecItemCopyMatching to fail would require locking the
    /// system Keychain (risking flakiness and leftover state). Pass `nil` to clear it.
    /// The shipping app never calls this.
    func simulateLoadFailureForTesting(status: OSStatus?) {
        lastLoadError = status.map(ConfigurationStoreError.keychainReadFailed)
    }

    var hasSavedSnapshot: Bool {
        keychainSnapshotData() != nil || fileManager.fileExists(atPath: legacyFileURL.path)
    }

    func load() -> AppSnapshot {
        lastLoadError = nil

        switch keychainSnapshotResult() {
        case let .found(data):
            if let snapshot = decodeSnapshot(from: data) {
                log.info(Self.subsystem, "loaded snapshot: \(snapshot.savedConnections.count) connections, \(snapshot.subscriptionSources.count) subscriptions, mode \(snapshot.connectionMode)")
                return snapshot
            }

            // The item is there but this build cannot decode it, which one
            // incompatible model change between two builds is enough to cause.
            // Treated exactly like a read failure rather than as "no data":
            // without the save-guard the first autosave after launch (a health
            // probe, a subscription refresh) would encode the current empty state
            // over the only copy of the user's connections.
            let backupURL = backUpUndecodableSnapshot(data)
            lastLoadError = ConfigurationStoreError.snapshotCouldNotBeDecoded(backupURL: backupURL)
            log.error(Self.subsystem, "keychain snapshot could not be decoded (\(data.count) bytes); refusing to save, raw copy at \(backupURL?.path ?? "<backup failed>")")
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        case .notFound:
            log.info(Self.subsystem, "no keychain snapshot yet")
        case let .failed(status):
            lastLoadError = ConfigurationStoreError.keychainReadFailed(status)
            log.error(Self.subsystem, "keychain read failed with OSStatus \(status); refusing to save")
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        }

        if let data = try? Data(contentsOf: legacyFileURL) {
            if let snapshot = decodeSnapshot(from: data) {
                // Direct upgrades from v0.1.0 still have their only snapshot here.
                // Delete the plaintext copy only after the Keychain migration succeeds.
                if (try? save(snapshot)) != nil {
                    try? fileManager.removeItem(at: legacyFileURL)
                    log.info(Self.subsystem, "migrated legacy state.json into keychain")
                }
                return snapshot
            }

            let backupURL = backUpUndecodableSnapshot(data)
            lastLoadError = ConfigurationStoreError.snapshotCouldNotBeDecoded(backupURL: backupURL)
            log.error(Self.subsystem, "legacy state.json could not be decoded; refusing to save, raw copy at \(backupURL?.path ?? "<backup failed>")")
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        }

        return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
    }

    /// Keeps the bytes we could not decode, so a snapshot this build rejects is
    /// still recoverable by hand (or by a later build that understands it). Named
    /// with a timestamp because a user who relaunches a few times before noticing
    /// should not overwrite the first, most complete copy.
    private func backUpUndecodableSnapshot(_ data: Data) -> URL? {
        let directoryURL = legacyFileURL.deletingLastPathComponent()
            .appendingPathComponent("unreadable-snapshots", isDirectory: true)
        guard (try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)) != nil else { return nil }
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backupURL = directoryURL.appendingPathComponent("snapshot-\(stamp).json")

        guard (try? data.write(to: backupURL, options: [.atomic])) != nil else { return nil }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        return backupURL
    }

    func save(_ snapshot: AppSnapshot) throws {
        if let lastLoadError {
            log.warn(Self.subsystem, "refused to save \(snapshot.savedConnections.count) connections after a failed load: \(LogRedaction.error(lastLoadError))")
            throw ConfigurationStoreError.refusedToOverwriteAfterLoadFailure
        }
        let data = try encoder.encode(snapshot)
        do {
            try saveKeychainSnapshotData(data)
        } catch {
            log.error(Self.subsystem, "save failed: \(LogRedaction.error(error))")
            throw error
        }
        log.info(Self.subsystem, "saved snapshot: \(snapshot.savedConnections.count) connections, \(snapshot.subscriptionSources.count) subscriptions")
    }

    private func decodeSnapshot(from data: Data) -> AppSnapshot? {
        try? decoder.decode(AppSnapshot.self, from: data)
    }

    enum KeychainSnapshotResult: Equatable {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    private func keychainSnapshotData() -> Data? {
        if case let .found(data) = keychainSnapshotResult() {
            return data
        }
        return nil
    }

    private func keychainSnapshotResult() -> KeychainSnapshotResult {
        var query = keychainBaseQuery()
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

    private func saveKeychainSnapshotData(_ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(keychainBaseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw ConfigurationStoreError.keychainWriteFailed(updateStatus)
        }

        var addQuery = keychainBaseQuery()
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ConfigurationStoreError.keychainWriteFailed(addStatus)
        }
    }

    private func keychainBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    /// Deletes the Keychain item outright (bypassing the `lastLoadError` save-guard).
    /// Only meaningful for tests that need to reset an isolated item between runs;
    /// the shipping app never calls this.
    func deleteKeychainItemForTesting() {
        SecItemDelete(keychainBaseQuery() as CFDictionary)
    }
}

enum ConfigurationStoreError: LocalizedError {
    case keychainWriteFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case snapshotCouldNotBeDecoded(backupURL: URL?)
    case refusedToOverwriteAfterLoadFailure

    var errorDescription: String? {
        switch self {
        case let .keychainWriteFailed(status):
            return "Failed to save Teleport configuration secrets to Keychain: OSStatus \(status)"
        case let .keychainReadFailed(status):
            return "Failed to read Teleport configuration secrets from Keychain (OSStatus \(status)). Your saved connections were not lost — unlock Keychain Access and restart Teleport."
        case let .snapshotCouldNotBeDecoded(backupURL):
            let location = backupURL.map { " A copy of it was kept at \($0.path)." } ?? ""
            return "Teleport could not read its saved settings — they were written by a different version of the app. Nothing was deleted, and Teleport will not overwrite them.\(location)"
        case .refusedToOverwriteAfterLoadFailure:
            return "Refusing to save: the previous Keychain read failed, so saving now could overwrite your existing settings."
        }
    }
}
