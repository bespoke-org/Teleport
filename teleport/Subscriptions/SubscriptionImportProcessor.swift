import Foundation

nonisolated struct SubscriptionImportProcessor {
    static func importEntries(
        links: [String],
        parser: ConnectionLinkParser,
        sourceID: UUID,
        filterDuplicateImports: Bool
    ) throws -> SubscriptionImportResult {
        try importEntries(
            candidates: links.map(SubscriptionCandidate.link), parser: parser,
            sourceID: sourceID, filterDuplicateImports: filterDuplicateImports
        )
    }

    static func importEntries(
        candidates: [SubscriptionCandidate],
        parser: ConnectionLinkParser,
        sourceID: UUID,
        filterDuplicateImports: Bool
    ) throws -> SubscriptionImportResult {
        var importedEntries: [ImportedSubscriptionEntry] = []
        var skippedReasons: [String: Int] = [:]
        var seenDuplicateKeys: Set<String> = []
        var seenEntryIDs: Set<String> = []

        for candidate in candidates {
            guard case let .link(rawLink) = candidate else {
                if case let .skipped(reason) = candidate { skippedReasons[reason, default: 0] += 1 }
                continue
            }
            do {
                let configuration = try parser.parse(rawLink)
                let sourceEntryID = configuration.protocolType == .hysteria
                    ? configuration.duplicateFilterIdentity
                    : rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
                // Exact repetitions share a refresh identity even when optional
                // endpoint deduplication is off. Keeping both breaks reconciliation.
                guard seenEntryIDs.insert(sourceEntryID).inserted else { continue }
                if filterDuplicateImports {
                    guard seenDuplicateKeys.insert(configuration.duplicateFilterIdentity).inserted else { continue }
                }
                importedEntries.append(ImportedSubscriptionEntry(sourceEntryID: sourceEntryID, configuration: configuration))
            } catch {
                skippedReasons[skipReason(for: error), default: 0] += 1
            }
        }
        _ = sourceID
        let result = SubscriptionImportResult(
            importedEntries: disambiguateDuplicateDisplayNames(in: importedEntries),
            skippedReasons: skippedReasons
        )
        guard !importedEntries.isEmpty else {
            throw SubscriptionError.noImportableEntries(result.statusMessage ?? "No supported entries were found")
        }
        return result
    }

    static func skipReason(for error: Error) -> String {
        // Parser errors may contain provider-supplied values. Summarize their
        // category instead of persisting credentials or arbitrary text in status.
        guard let error = error as? ConfigurationError else { return "Invalid connection settings" }
        switch error {
        case .unsupportedTransport: return "Unsupported transport"
        case .unsupportedSecurity: return "Unsupported security"
        case .unsupportedFlow: return "Unsupported VLESS flow"
        case .missingParameter: return "Missing required connection parameters"
        case .invalidUUID: return "Invalid VLESS user ID"
        case .missingPassword: return "Missing Trojan password"
        case .invalidXrayJSON: return "Invalid Xray JSON configuration"
        case .invalidHysteria(let reason): return reason
        default: return "Invalid connection settings"
        }
    }

    private static func disambiguateDuplicateDisplayNames(in entries: [ImportedSubscriptionEntry]) -> [ImportedSubscriptionEntry] {
        let countsByName = entries.reduce(into: [String: Int]()) { counts, entry in
            counts[displayNameKey(for: entry.configuration), default: 0] += 1
        }
        var indexesByName: [String: Int] = [:]

        return entries.map { entry in
            let key = displayNameKey(for: entry.configuration)
            guard countsByName[key, default: 0] > 1 else { return entry }

            indexesByName[key, default: 0] += 1
            let disambiguatedName = "\(entry.configuration.displayName) (\(indexesByName[key, default: 1]))"
            return ImportedSubscriptionEntry(
                sourceEntryID: entry.sourceEntryID,
                configuration: entry.configuration.withDisplayName(disambiguatedName)
            )
        }
    }

    private static func displayNameKey(for configuration: ConnectionConfiguration) -> String {
        configuration.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
