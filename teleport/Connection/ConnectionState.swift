import Foundation

/// User-facing lifecycle state shared by every connection implementation.
/// It deliberately excludes process IDs, interface names, routes, and helper state.
enum ConnectionState: Sendable, Equatable {
    case idle
    case preparing
    case awaitingUserApproval
    case connecting
    case connected(ConnectionSession)
    case disconnecting
    case failed(ConnectionFailure)
}

/// UI-level identity for one connected interval. Until the helper protocol gains
/// authoritative session IDs, this UUID exists only in the app provider layer.
struct ConnectionSession: Sendable, Equatable {
    let id: UUID
    let mode: ConnectionMode
    let connectedAt: Date
}

/// Stable, transport-independent diagnostics that can safely reach presentation code.
struct ConnectionFailure: Sendable, Equatable {
    let summary: String
    let details: String?

    init(summary: String, details: String?) {
        self.summary = summary
        self.details = details
    }

    init(error: Error) {
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
