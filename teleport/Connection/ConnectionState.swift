import Foundation

/// User-facing lifecycle state shared by every connection implementation.
/// It deliberately excludes process IDs, interface names, routes, and helper state.
nonisolated enum ConnectionState: Sendable, Equatable {
    case idle
    case preparing
    case awaitingUserApproval
    case connecting
    case connected(ConnectionSession)
    case disconnecting
    case failed(ConnectionFailure)

    var isTerminalFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// UI-level identity for one connected interval. Until the helper protocol gains
/// authoritative session IDs, this UUID exists only in the app provider layer.
nonisolated struct ConnectionSession: Sendable, Equatable {
    let id: UUID
    let mode: ConnectionMode
    let connectedAt: Date
}

/// Stable, transport-independent diagnostics that can safely reach presentation code.
nonisolated struct ConnectionFailure: LocalizedError, Sendable, Equatable {
    let summary: String
    let details: String?
    let requiresExplicitReconnect: Bool

    var errorDescription: String? { summary }
    var failureReason: String? { details }

    init(summary: String, details: String?, requiresExplicitReconnect: Bool = false) {
        self.summary = summary
        self.details = details
        self.requiresExplicitReconnect = requiresExplicitReconnect
    }

    init(error: Error) {
        if let failure = error as? ConnectionFailure {
            self = failure
            return
        }
        requiresExplicitReconnect = false
        summary = error.localizedDescription
        if let localizedError = error as? LocalizedError,
           let reason = localizedError.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !reason.isEmpty,
           reason != summary {
            details = reason
        } else {
            details = nil
        }
    }
}
