import AppKit
import CFNetwork
import Combine
import Darwin
import Foundation
import Network
import Security
import SystemConfiguration

final class ConfigurationStore {
    private let fileManager: FileManager
    private let fileURL: URL
    private let directoryURL: URL
    private let keychainService: String
    private let keychainAccount: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private static let defaultKeychainService = "dev.x.teleport.configuration"
    private static let defaultKeychainAccount = "app-snapshot"
    private static let stateFilePlaceholder = "{\"storage\":\"keychain\",\"version\":2}\n"

    /// `keychainService`/`keychainAccount` are overridable so verification scripts can
    /// exercise this store against an isolated Keychain item instead of the real one
    /// used by the shipping app (which holds the user's actual saved connections).
    init(
        fileManager: FileManager = .default,
        keychainService: String = ConfigurationStore.defaultKeychainService,
        keychainAccount: String = ConfigurationStore.defaultKeychainAccount
    ) {
        self.fileManager = fileManager
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = baseURL.appendingPathComponent("teleport", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        fileURL = directoryURL.appendingPathComponent("state.json")
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
        keychainSnapshotData() != nil || fileManager.fileExists(atPath: fileURL.path)
    }

    func load() -> AppSnapshot {
        lastLoadError = nil

        switch keychainSnapshotResult() {
        case let .found(data):
            if let snapshot = decodeSnapshot(from: data) {
                return snapshot
            }
        case .notFound:
            break
        case let .failed(status):
            lastLoadError = ConfigurationStoreError.keychainReadFailed(status)
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
        }

        if let snapshot = decodeSnapshot(from: data) {
            try? save(snapshot)
            return snapshot
        }

        return AppSnapshot(savedConnections: [], subscriptionSources: [], selectedConnectionID: nil, proxyEndpoint: .default)
    }

    func save(_ snapshot: AppSnapshot) throws {
        if lastLoadError != nil {
            throw ConfigurationStoreError.refusedToOverwriteAfterLoadFailure
        }
        let data = try encoder.encode(snapshot)
        try saveKeychainSnapshotData(data)
        try writeStatePlaceholder()
    }

    private func decodeSnapshot(from data: Data) -> AppSnapshot? {
        if let snapshot = try? decoder.decode(AppSnapshot.self, from: data) {
            return snapshot
        }

        if let legacySnapshot = try? decoder.decode(LegacyAppSnapshot.self, from: data) {
            return legacySnapshot.asAppSnapshot
        }

        return nil
    }

    private func writeStatePlaceholder() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try Data(Self.stateFilePlaceholder.utf8).write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
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
    case refusedToOverwriteAfterLoadFailure

    var errorDescription: String? {
        switch self {
        case let .keychainWriteFailed(status):
            return "Failed to save Teleport configuration secrets to Keychain: OSStatus \(status)"
        case let .keychainReadFailed(status):
            return "Failed to read Teleport configuration secrets from Keychain (OSStatus \(status)). Your saved connections were not lost — unlock Keychain Access and restart Teleport."
        case .refusedToOverwriteAfterLoadFailure:
            return "Refusing to save: the previous Keychain read failed, so saving now could overwrite your existing settings."
        }
    }
}
