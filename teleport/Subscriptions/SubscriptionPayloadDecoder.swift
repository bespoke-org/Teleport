import Foundation

nonisolated enum SubscriptionCandidate {
    case link(String)
    case skipped(String)
}

/// Decodes the downloaded body without doing network I/O. Unsupported profiles
/// remain candidates so a mixed subscription can report why they were skipped.
nonisolated struct SubscriptionPayloadDecoder {
    func decode(_ data: Data) throws -> [SubscriptionCandidate] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SubscriptionError.unsupportedFormat
        }
        let trimmed = normalized(text)
        guard !trimmed.isEmpty else { throw SubscriptionError.emptyPayload }
        if let candidates = try decodeText(trimmed) { return candidates }

        let compact = trimmed.components(separatedBy: .whitespacesAndNewlines).joined()
        if let decoded = Data(base64Encoded: compact),
            let decodedText = String(data: decoded, encoding: .utf8),
            let candidates = try decodeText(normalized(decodedText))
        {
            return candidates
        }
        throw SubscriptionError.unsupportedFormat
    }

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
    }

    private func decodeText(_ text: String) throws -> [SubscriptionCandidate]? {
        if text.hasPrefix("{") || text.hasPrefix("[") {
            let json: Any
            do {
                json = try JSONSerialization.jsonObject(with: Data(text.utf8))
            } catch {
                throw SubscriptionError.invalidJSON
            }
            let profiles: [Any]
            if let array = json as? [Any] {
                profiles = array
            } else {
                profiles = [json]
            }
            guard !profiles.isEmpty else { throw SubscriptionError.emptyPayload }
            return profiles.map { profile in
                do {
                    return .link(try XraySubscriptionProfileParser().parse(profile))
                } catch let error as XraySubscriptionProfileError {
                    return .skipped(error.reason)
                } catch {
                    return .skipped("Invalid Xray profile")
                }
            }
        }

        let links = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil }
        guard !links.isEmpty else { return nil }
        return links.map { link in
            let scheme = link.components(separatedBy: "://")[0].lowercased()
            switch scheme {
            case "vless", "trojan": return .link(link)
            case "hysteria", "hysteria2", "hy2": return .skipped("Hysteria is not supported")
            case "ss": return .skipped("Shadowsocks is not supported")
            default: return .skipped("Unsupported subscription link protocol")
            }
        }
    }
}
