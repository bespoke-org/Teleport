import Foundation

nonisolated struct SubscriptionImportResult {
    let importedEntries: [ImportedSubscriptionEntry]
    let skippedReasons: [String: Int]

    var skippedCount: Int { skippedReasons.values.reduce(0, +) }

    var skipSummary: String {
        skippedReasons.sorted { $0.key < $1.key }.map { "\($0.value) × \($0.key)" }.joined(separator: "; ")
    }

    var statusMessage: String? {
        guard skippedCount > 0 else { return nil }
        return "Imported \(importedEntries.count), skipped \(skippedCount). \(skipSummary)"
    }
}

nonisolated struct ImportedSubscriptionEntry {
    let sourceEntryID: String
    let configuration: ConnectionConfiguration
}

struct SubscriptionReplacementResult {
    let savedConnections: [SavedConnection]
    let selectedConnectionID: UUID?
}

struct SubscriptionConnectionReconciler {
    func reconcile(
        existingConnections: [SavedConnection],
        sourceID: UUID,
        selectedConnectionID: UUID?,
        importedEntries: [ImportedSubscriptionEntry],
        fetchedAt: Date,
        autoSelectFirstImported: Bool
    ) -> SubscriptionReplacementResult {
        let previousSelectedConnection = existingConnections.first { $0.id == selectedConnectionID }
        let previousImportedEntries = existingConnections.filter { $0.source?.subscriptionSourceID == sourceID }

        // Older imports could persist duplicate entry IDs. Keep one complete
        // record so identity, name and health all come from the same copy.
        let existingByEntry = Dictionary(previousImportedEntries.compactMap { connection -> (String, SavedConnection)? in
            guard let source = connection.source else { return nil }
            return (source.subscriptionEntryID, connection)
        }, uniquingKeysWith: { first, next in
            next.id == selectedConnectionID ? next : first
        })

        let replacementConnections = importedEntries.map { entry in
            SavedConnection(
                id: existingByEntry[entry.sourceEntryID]?.id ?? UUID(),
                configuration: entry.configuration,
                savedAt: existingByEntry[entry.sourceEntryID]?.savedAt ?? fetchedAt,
                source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: entry.sourceEntryID),
                healthCheck: existingByEntry[entry.sourceEntryID]?.healthCheck,
                customName: existingByEntry[entry.sourceEntryID]?.customName
            )
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        var updatedConnections = existingConnections.filter { $0.source?.subscriptionSourceID != sourceID }
        updatedConnections.append(contentsOf: replacementConnections)

        let resolvedSelectedConnectionID: UUID?
        if let previousSelectedConnection,
           previousSelectedConnection.source?.subscriptionSourceID == sourceID {
            let previousEntryID = previousSelectedConnection.source?.subscriptionEntryID
            if let previousEntryID,
               let matched = replacementConnections.first(where: { $0.source?.subscriptionEntryID == previousEntryID }) {
                resolvedSelectedConnectionID = matched.id
            } else if let firstReplacement = replacementConnections.first {
                resolvedSelectedConnectionID = firstReplacement.id
            } else {
                resolvedSelectedConnectionID = updatedConnections.first?.id
            }
        } else if autoSelectFirstImported,
                  selectedConnectionID == nil,
                  let firstReplacement = replacementConnections.first {
            resolvedSelectedConnectionID = firstReplacement.id
        } else if let selectedConnectionID,
                  updatedConnections.contains(where: { $0.id == selectedConnectionID }) {
            resolvedSelectedConnectionID = selectedConnectionID
        } else {
            resolvedSelectedConnectionID = updatedConnections.first?.id
        }

        return SubscriptionReplacementResult(
            savedConnections: updatedConnections,
            selectedConnectionID: resolvedSelectedConnectionID
        )
    }
}

struct SubscriptionClient {
    func fetchCandidates(from url: URL) async throws -> [SubscriptionCandidate] {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SubscriptionError.networkFailure(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SubscriptionError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw SubscriptionError.networkFailure("Subscription request failed with status \(httpResponse.statusCode)")
        }

        guard !responseData.isEmpty else {
            throw SubscriptionError.emptyPayload
        }

        return try SubscriptionPayloadDecoder().decode(responseData)
    }
}
