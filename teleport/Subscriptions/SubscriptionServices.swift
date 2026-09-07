import Foundation

struct SubscriptionImportResult {
    let importedEntries: [ImportedSubscriptionEntry]
    let skippedCount: Int
}

struct ImportedSubscriptionEntry {
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

        let existingIDsByEntry: [String: UUID] = Dictionary(uniqueKeysWithValues: previousImportedEntries.compactMap { connection in
            guard let source = connection.source else { return nil }
            return (source.subscriptionEntryID, connection.id)
        })
        let existingSavedAtByEntry: [String: Date] = Dictionary(uniqueKeysWithValues: previousImportedEntries.compactMap { connection in
            guard let source = connection.source else { return nil }
            return (source.subscriptionEntryID, connection.savedAt)
        })
        let existingHealthByEntry: [String: ConnectionHealthCheck] = Dictionary(uniqueKeysWithValues: previousImportedEntries.compactMap { connection in
            guard let source = connection.source,
                  let healthCheck = connection.healthCheck else {
                return nil
            }
            return (source.subscriptionEntryID, healthCheck)
        })
        // A name the user gave an imported connection survives the refresh, like
        // its identity and health do.
        let existingNamesByEntry: [String: String] = Dictionary(uniqueKeysWithValues: previousImportedEntries.compactMap { connection in
            guard let source = connection.source,
                  let customName = connection.customName else {
                return nil
            }
            return (source.subscriptionEntryID, customName)
        })

        let replacementConnections = importedEntries.map { entry in
            SavedConnection(
                id: existingIDsByEntry[entry.sourceEntryID] ?? UUID(),
                configuration: entry.configuration,
                savedAt: existingSavedAtByEntry[entry.sourceEntryID] ?? fetchedAt,
                source: ConnectionSourceMetadata(subscriptionSourceID: sourceID, subscriptionEntryID: entry.sourceEntryID),
                healthCheck: existingHealthByEntry[entry.sourceEntryID],
                customName: existingNamesByEntry[entry.sourceEntryID]
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
    func fetchCandidateLinks(from url: URL) async throws -> [String] {
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

        let rawText = String(decoding: responseData, as: UTF8.self)
        let directLinks = extractCandidateLinks(from: rawText)
        if !directLinks.isEmpty {
            return directLinks
        }

        let compactBase64 = rawText
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        if let decodedData = Data(base64Encoded: compactBase64, options: [.ignoreUnknownCharacters]) {
            let decodedText = String(decoding: decodedData, as: UTF8.self)
            let decodedLinks = extractCandidateLinks(from: decodedText)
            if !decodedLinks.isEmpty {
                return decodedLinks
            }
        }

        throw SubscriptionError.noSupportedEntries
    }

    private func extractCandidateLinks(from text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { value in
                let lowercased = value.lowercased()
                return lowercased.hasPrefix("vless://") || lowercased.hasPrefix("trojan://")
            }
    }
}
