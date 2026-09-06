import Foundation

nonisolated struct SubscriptionImportProcessor {
    static func importEntries(
        links: [String],
        parser: ConnectionLinkParser,
        sourceID: UUID,
        filterDuplicateImports: Bool
    ) throws -> SubscriptionImportResult {
        var importedEntries: [ImportedSubscriptionEntry] = []
        var skippedCount = 0
        var seenDuplicateKeys: Set<String> = []

        for rawLink in links {
            do {
                let configuration = try parser.parse(rawLink)
                let sourceEntryID = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)

                if filterDuplicateImports {
                    let duplicateKey = configuration.duplicateFilterIdentity
                    guard seenDuplicateKeys.insert(duplicateKey).inserted else {
                        continue
                    }
                }

                importedEntries.append(
                    ImportedSubscriptionEntry(
                        sourceEntryID: sourceEntryID,
                        configuration: configuration
                    )
                )
            } catch {
                skippedCount += 1
            }
        }

        _ = sourceID

        guard !importedEntries.isEmpty else {
            throw SubscriptionError.noSupportedEntries
        }

        return SubscriptionImportResult(
            importedEntries: disambiguateDuplicateDisplayNames(in: importedEntries),
            skippedCount: skippedCount
        )
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
