import Foundation

nonisolated enum SubscriptionAnnouncement {
    /// Happ's `announce` metadata may be an HTTP header or a comment in a
    /// plain/base64 subscription body. An explicit header takes precedence.
    static func parse(header: String?, body: Data) -> String? {
        if let header { return decode(header) }
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        if let value = comment(in: text) { return decode(value) }
        let compact = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let data = Data(base64Encoded: compact),
              let decoded = String(data: data, encoding: .utf8),
              let value = comment(in: decoded) else { return nil }
        return decode(value)
    }

    private static func comment(in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("#announce:") else { continue }
            return String(line.dropFirst("#announce:".count))
        }
        return nil
    }

    private static func decode(_ value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("base64:") {
            let encoded = text.dropFirst("base64:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: encoded),
                  let decoded = String(data: data, encoding: .utf8) else { return nil }
            text = decoded
        }
        // Keep the message compact, including providers sending embedded newlines.
        text = text.components(separatedBy: .whitespacesAndNewlines.union(.controlCharacters))
            .filter { !$0.isEmpty }.joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(200))
    }
}
