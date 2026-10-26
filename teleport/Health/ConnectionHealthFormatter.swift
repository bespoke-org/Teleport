import Foundation

nonisolated enum ConnectionHealthFormatter {
    static func label(for check: ConnectionHealthCheck, locale: Locale = .current) -> String {
        switch check.state {
        case .reachable:
            return check.latencyMilliseconds.map {
                ConnectionLatencyFormatter.string(milliseconds: $0, locale: locale)
            } ?? "Available"
        case .unreachable:
            return failureLabel(check.failureSummary)
        case .queued:
            return "Queued…"
        case .checking:
            return "Checking…"
        case .unknown:
            // A failed local check says nothing about the server's availability.
            if let reason = check.failureSummary, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Check failed"
            }
            return check.checkedAt == nil ? "Not checked" : "Unknown"
        }
    }

    private static func failureLabel(_ summary: String?) -> String {
        // Health results are persisted. Normalize earlier wording here as well as
        // new results, and never put arbitrary runtime diagnostics in a menu label.
        switch summary?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "the peer did not answer the wireguard handshake", "tls handshake failed", "handshake failed":
            return "Handshake failed"
        case "timed out":
            return "Timed out"
        case "dns resolution failed":
            return "DNS resolution failed"
        case "connection refused":
            return "Connection refused"
        case "network error":
            return "Network error"
        case "probe blocked":
            return "Check blocked"
        case "invalid probe response", "bad server response", "invalid response":
            return "Invalid response"
        case "server error":
            return "Server error"
        case "invalid port":
            return "Invalid port"
        case "tcp probe failed", "probe request failed", "probe failed":
            return "Check failed"
        default:
            return "Unavailable"
        }
    }
}
