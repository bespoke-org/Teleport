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
nonisolated struct ConnectionFailure: Sendable, Equatable {
    let summary: String
    let details: String?

    /// Keep the compact notice to the cause. Recovery steps remain available in
    /// the notice itself; copying the error still includes the complete message.
    var briefSummary: String {
        guard let boundary = summary.range(of: ". ") else { return summary }
        return String(summary[...boundary.lowerBound])
    }

    var recoveryInstructions: String? {
        guard let boundary = summary.range(of: ". ") else { return nil }
        let instructions = summary[boundary.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return instructions.isEmpty ? nil : instructions
    }

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
