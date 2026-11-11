import Foundation

/// Whether a subscription refresh was asked for by the user or by the schedule.
nonisolated enum SubscriptionRefreshOrigin {
    case userInitiated
    case background
}

/// A finished subscription download, parsed and ready to be applied to the
/// published state.
nonisolated struct SubscriptionRefreshOutcome {
    let sourceID: UUID
    let fetchedAt: Date
    let importedEntries: [ImportedSubscriptionEntry]
    let skippedCount: Int
    let importStatus: String?
    let routing: SubscriptionRoutingImport?
    let autoSelectFirstImported: Bool
    let origin: SubscriptionRefreshOrigin
}

/// What the subscription refresh coordinator needs from the model that runs it:
/// the sources and busy flags its decisions read, and the publishing of each
/// stage's outcome. AppViewModel is the only conformer; the protocol is the seam
/// that keeps this type fetching and parsing while the model applies results to
/// published state.
protocol SubscriptionRefreshHost: AnyObject {
    var subscriptionSources: [SubscriptionSource] { get }
    var refreshingSubscriptionIDs: Set<UUID> { get }
    func isSubscriptionInUse(id: UUID) -> Bool

    /// Publishes the start of a refresh: the busy flag, the cleared source
    /// error, and for a user-initiated refresh the cleared stored error.
    func beginSubscriptionRefresh(id: UUID, userInitiated: Bool)
    /// Publishes the end of a refresh: the busy flag off.
    func endSubscriptionRefresh(id: UUID)
    func applySubscriptionRefresh(_ outcome: SubscriptionRefreshOutcome) async
    /// Records the failure on the source and, for a user-initiated refresh, in
    /// the stored error.
    func subscriptionRefreshDidFail(id: UUID, error: Error, userInitiated: Bool)
    /// A refresh was refused because one of its connections is in the running
    /// session; only a user-initiated attempt reports it.
    func subscriptionRefreshWasBlocked(id: UUID, userInitiated: Bool)
}

/// Fetches subscriptions, parses them into imported entries, and decides when a
/// scheduled refresh is due. Tokens invalidate a result whose source was
/// deleted or refreshed again while its download was in flight; applying what a
/// result carries stays with the model.
final class SubscriptionRefreshCoordinator {
    /// The model whose subscriptions this refreshes, attached once both are built.
    weak var host: (any SubscriptionRefreshHost)?

    private let parser: ConnectionLinkParser
    private let client: SubscriptionClient

    private var tokens: [UUID: UUID] = [:]

    init(parser: ConnectionLinkParser, client: SubscriptionClient) {
        self.parser = parser
        self.client = client
    }

    nonisolated static func importSubscriptionEntries(
        links: [String],
        parser: ConnectionLinkParser,
        sourceID: UUID,
        filterDuplicateImports: Bool
    ) throws -> SubscriptionImportResult {
        try SubscriptionImportProcessor.importEntries(
            links: links,
            parser: parser,
            sourceID: sourceID,
            filterDuplicateImports: filterDuplicateImports
        )
    }

    func refresh(id: UUID, autoSelectFirstImported: Bool, origin: SubscriptionRefreshOrigin) {
        guard let host else { return }
        guard let source = host.subscriptionSources.first(where: { $0.id == id }) else { return }
        if host.isSubscriptionInUse(id: id) {
            host.subscriptionRefreshWasBlocked(id: id, userInitiated: origin == .userInitiated)
            return
        }
        startRefresh(for: source, autoSelectFirstImported: autoSelectFirstImported, origin: origin)
    }

    /// Sources that were saved but never fetched, such as ones restored from a
    /// snapshot written before their first refresh finished.
    func refreshUnfetched(autoSelectFirstImported: Bool) {
        guard let host else { return }
        for source in host.subscriptionSources
        where source.lastRefreshedAt == nil && !host.refreshingSubscriptionIDs.contains(source.id) {
            refresh(id: source.id, autoSelectFirstImported: autoSelectFirstImported, origin: .background)
        }
    }

    /// Refreshes every source whose auto-update interval has elapsed since its
    /// last refresh (or since it was saved, if it has never refreshed).
    func scheduleRefreshes(now: Date = Date()) {
        guard let host else { return }
        for source in host.subscriptionSources {
            guard let intervalMinutes = source.autoUpdateIntervalMinutes,
                  intervalMinutes > 0,
                  !host.refreshingSubscriptionIDs.contains(source.id) else {
                continue
            }

            let referenceDate = source.lastRefreshedAt ?? source.savedAt
            guard now.timeIntervalSince(referenceDate) >= TimeInterval(intervalMinutes * 60) else {
                continue
            }

            refresh(id: source.id, autoSelectFirstImported: false, origin: .background)
        }
    }

    /// A source being deleted invalidates its in-flight refresh: the result
    /// would apply to a source that no longer exists.
    func cancelRefresh(for id: UUID) {
        tokens.removeValue(forKey: id)
    }

    private func startRefresh(
        for source: SubscriptionSource,
        autoSelectFirstImported: Bool,
        origin: SubscriptionRefreshOrigin
    ) {
        let refreshToken = UUID()
        tokens[source.id] = refreshToken
        host?.beginSubscriptionRefresh(id: source.id, userInitiated: origin == .userInitiated)

        let parser = parser
        let client = client

        Task { @MainActor [weak self] in
            defer {
                self?.finishToken(source.id, refreshToken)
            }
            do {
                guard let url = URL(string: source.urlString) else {
                    throw SubscriptionError.invalidURL
                }

                let fetched = try await client.fetch(from: url)
                // A newer refresh (or source deletion) invalidates this request.
                // Cosmetic URL edits do not invalidate a pending import.
                guard self?.tokens[source.id] == refreshToken else { return }
                let importResult = try await Task.detached(priority: .userInitiated) {
                    try SubscriptionImportProcessor.importEntries(
                        candidates: fetched.candidates,
                        parser: parser,
                        sourceID: source.id,
                        filterDuplicateImports: source.filterDuplicateImports
                    )
                }.value
                let importStatus = [importResult.statusMessage, fetched.routingWarning]
                    .compactMap { $0 }.joined(separator: " ")

                await self?.host?.applySubscriptionRefresh(SubscriptionRefreshOutcome(
                    sourceID: source.id,
                    fetchedAt: Date(),
                    importedEntries: importResult.importedEntries,
                    skippedCount: importResult.skippedCount,
                    importStatus: importStatus.isEmpty ? nil : importStatus,
                    routing: fetched.routing,
                    autoSelectFirstImported: autoSelectFirstImported,
                    origin: origin
                ))
            } catch {
                guard self?.tokens[source.id] == refreshToken else { return }
                self?.host?.subscriptionRefreshDidFail(
                    id: source.id, error: error, userInitiated: origin == .userInitiated
                )
            }
        }
    }

    private func finishToken(_ sourceID: UUID, _ token: UUID) {
        guard tokens[sourceID] == token else { return }
        tokens.removeValue(forKey: sourceID)
        host?.endSubscriptionRefresh(id: sourceID)
    }
}
