import Foundation

/// A provider-reported snapshot, refreshed with the subscription catalog.
nonisolated struct SubscriptionUsage: Codable, Equatable, Sendable {
    let uploadBytes: Int64?
    let downloadBytes: Int64?
    let totalBytes: Int64?

    var usedBytes: Int64? {
        guard let uploadBytes, let downloadBytes else { return nil }
        let (sum, overflow) = uploadBytes.addingReportingOverflow(downloadBytes)
        return overflow ? nil : sum
    }

    var fractionUsed: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }

    static func parse(_ header: String?) -> Self? {
        guard let header else { return nil }
        var values: [String: Int64] = [:]
        var seen: Set<String> = []
        for field in header.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["upload", "download", "total"].contains(key) else { continue }
            // Conflicting duplicate fields must not produce a misleading quota.
            guard seen.insert(key).inserted else { values.removeValue(forKey: key); continue }
            let raw = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int64(raw) else { continue }
            values[key] = value
        }
        let usage = Self(uploadBytes: values["upload"], downloadBytes: values["download"], totalBytes: values["total"])
        return usage.usedBytes != nil || usage.totalBytes != nil ? usage : nil
    }
}
