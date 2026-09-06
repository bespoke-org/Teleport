import Foundation

/// Mode-specific side effects behind `ConnectionProvider`. Implementations own
/// processes, proxy settings and privileged IPC; ordering and state publication
/// belong to `BackendConnectionProvider`, so nothing here serializes itself.
nonisolated protocol ConnectionBackend: AnyObject, Sendable {
    func hasRestorableState() async -> Bool
    func hasActiveRuntimeSession() async -> Bool
    func restorePreviousState() async throws
    func start(_ request: ConnectionRequest) async throws
    func reconnect(_ request: ConnectionRequest) async throws
    func stop() async throws
}
