import Foundation

/// Mode-specific side effects behind `ConnectionProvider`. Implementations own
/// processes, proxy settings and privileged IPC; ordering and state publication
/// belong to `BackendConnectionProvider`, so nothing here serializes itself.
nonisolated protocol ConnectionBackend: AnyObject, Sendable {
    func hasRestorableState() async -> Bool
    func hasActiveRuntimeSession() async -> Bool
    func adoptRuntimeSession() async throws
    func sessionFailure() async -> ConnectionFailure?
    func sessionChanges() -> AsyncStream<Void>
    func restorePreviousState() async throws
    /// `reportPhase` lets a start say what it is waiting on. The provider decides
    /// which states it accepts from a backend; today `.awaitingUserApproval` and
    /// `.connecting` to return from it.
    func start(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws
    func reconnect(_ request: ConnectionRequest, reportPhase: @escaping @Sendable (ConnectionState) -> Void) async throws
    func stop() async throws
}

extension ConnectionBackend {
    func adoptRuntimeSession() async throws {}
    func sessionFailure() async -> ConnectionFailure? { nil }
    func sessionChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}
