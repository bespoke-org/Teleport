import Combine
import Foundation

nonisolated struct ConnectionPickerItem: Identifiable, Equatable {
    let id: UUID
    let sourceID: UUID?
    let displayName: String

    init(connection: SavedConnection) {
        id = connection.id
        sourceID = connection.source?.subscriptionSourceID
        displayName = connection.displayName
    }
}

nonisolated struct SubscriptionPickerItem: Identifiable, Equatable {
    let id: UUID
    let displayName: String

    init(source: SubscriptionSource) {
        id = source.id
        displayName = source.displayName
    }
}

private struct LatencySortKey: Comparable, Equatable {
    let group: Int
    let latency: Int

    static func < (lhs: LatencySortKey, rhs: LatencySortKey) -> Bool {
        if lhs.group != rhs.group {
            return lhs.group < rhs.group
        }
        return lhs.latency < rhs.latency
    }
}

final class AppViewModel: ObservableObject {
    @Published private(set) var savedConnections: [SavedConnection]
    @Published private(set) var connectionPickerItems: [ConnectionPickerItem] = []
    @Published private(set) var subscriptionPickerItems: [SubscriptionPickerItem] = []
    @Published private(set) var healthChecksByConnectionID: [UUID: ConnectionHealthCheck] = [:]
    @Published private(set) var subscriptionSources: [SubscriptionSource]
    @Published private(set) var selectedConnectionID: UUID?
    @Published private(set) var connectionState: ConnectionState = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorDetails: String?
    @Published private(set) var proxyEndpoint: ProxyEndpoint
    @Published private(set) var connectionMode: ConnectionMode
    @Published private(set) var subscriptionConnectionSort: SubscriptionConnectionSort
    @Published private(set) var showsLatencyInMenuBarPicker: Bool
    @Published private(set) var animatesMenuBarIcon: Bool
    @Published private(set) var splitTunnelProfiles: [SplitTunnelProfile]
    @Published private(set) var selectedSplitTunnelProfileID: UUID?
    @Published private(set) var isSplitTunnelEnabled: Bool
    @Published private(set) var geodataSettings: GeodataSourceSettings
    @Published private(set) var isSplitTunnelGeodataReady = false
    @Published private(set) var updatingGeodataKinds: Set<GeodataKind> = []
    @Published private(set) var startsAtLogin: Bool
    @Published private(set) var isOperationPending = false
    @Published private(set) var refreshingSubscriptionIDs: Set<UUID> = []
    @Published private(set) var refreshingHealthConnectionIDs: Set<UUID> = []
    @Published private(set) var queuedHealthConnectionIDs: Set<UUID> = []

    private let parser: ConnectionLinkParser
    private let store: ConfigurationStore
    private let connectionProviderFactory: ConnectionProviderFactory
    private var connectionProvider: any ConnectionProvider
    private let subscriptionClient: SubscriptionClient
    private let healthProbeService: ConnectionHealthProbeService
    private let splitTunnelGeodataMatcher = SplitTunnelGeodataMatcher()
    private let loginItemService = LoginItemService()
    private let persistenceQueue = DispatchQueue(label: "dev.x.teleport.persistence", qos: .utility)
    private lazy var healthProbeQueue = ConnectionHealthProbeQueue(
        healthProbeService: healthProbeService,
        // Full tunnel probes spin up temporary Xray instances; allow a wider fan-out for bulk checks.
        concurrencyLimit: 10,
        connectionLookup: { [weak self] id in
            self?.savedConnectionsByID[id]
        },
        stateDidChange: { [weak self] refreshingIDs, queuedIDs in
            self?.refreshingHealthConnectionIDs = refreshingIDs
            self?.queuedHealthConnectionIDs = queuedIDs
        },
        resultsDidFlush: { [weak self] results in
            self?.applyHealthProbeResults(results)
        }
    )
    private var autoRefreshTimerCancellable: AnyCancellable?
    private var connectionStateTask: Task<Void, Never>?
    private var pendingOperationCount = 0
    private var hasObservedInitialConnectionState = false
    private var isTerminating = false
    private var persistWorkItem: DispatchWorkItem?
    private var splitTunnelApplyWorkItem: DispatchWorkItem?
    private var pendingSplitTunnelLiveApply = false
    /// The request whose `connect` is still running, kept so the applied split-tunnel
    /// policy can be recorded once the provider reports `.connected`. Not a queue.
    private var inFlightConnectionRequest: (operationID: UUID, request: ConnectionRequest)?
    private var appliedSplitTunnelRules: [SplitTunnelRule]?
    private var appliedSplitTunnelDefaultAction: SplitTunnelRuleAction?
    private var geodataUpdateTokens: [GeodataKind: UUID] = [:]
    private var geodataUpdateTasks: [GeodataKind: Task<Void, Never>] = [:]
    private var savedConnectionsByID: [UUID: SavedConnection] = [:]
    private var importedConnectionsBySourceID: [UUID: [SavedConnection]] = [:]
    private var importedConnectionCountsBySourceID: [UUID: Int] = [:]
    private var subscriptionSourcesByID: [UUID: SubscriptionSource] = [:]

    convenience init() {
        self.init(
            parser: ConnectionLinkParser(),
            store: ConfigurationStore(),
            connectionProviderFactory: ConnectionProviderFactory(),
            subscriptionClient: SubscriptionClient(),
            healthProbeService: ConnectionHealthProbeService()
        )
    }

    init(
        parser: ConnectionLinkParser,
        store: ConfigurationStore,
        connectionProviderFactory: ConnectionProviderFactory,
        subscriptionClient: SubscriptionClient,
        healthProbeService: ConnectionHealthProbeService
    ) {
        self.parser = parser
        self.store = store
        self.connectionProviderFactory = connectionProviderFactory
        self.subscriptionClient = subscriptionClient
        self.healthProbeService = healthProbeService

        var snapshot = store.load()
        var loadErrorMessage: String?
        if let loadError = store.lastLoadError {
            // Keychain read failed (e.g. still locked right after boot, or the app's
            // signature changed since the item was written) rather than there being no
            // saved data. Surface it instead of silently seeding/showing an empty state,
            // since seeding here would go on to overwrite the real Keychain item.
            loadErrorMessage = loadError.localizedDescription
        } else if !store.hasSavedSnapshot {
            snapshot = BundledConfigurationSeeder(parser: parser).seed(snapshot)
            try? store.save(snapshot)
        }

        lastError = loadErrorMessage
        connectionMode = snapshot.connectionMode
        subscriptionConnectionSort = snapshot.subscriptionConnectionSort
        showsLatencyInMenuBarPicker = snapshot.showsLatencyInMenuBarPicker
        animatesMenuBarIcon = snapshot.animatesMenuBarIcon
        splitTunnelProfiles = snapshot.splitTunnelProfiles
        selectedSplitTunnelProfileID = snapshot.selectedSplitTunnelProfileID
        isSplitTunnelEnabled = snapshot.isSplitTunnelEnabled
        geodataSettings = snapshot.geodataSettings
        startsAtLogin = loginItemService.isEnabled
        connectionProvider = connectionProviderFactory.makeProvider(for: snapshot.connectionMode)
        proxyEndpoint = snapshot.proxyEndpoint
        subscriptionSources = snapshot.subscriptionSources

        savedConnections = snapshot.savedConnections.map { savedConnection in
            if let reparsedConfiguration = try? parser.parse(savedConnection.configuration.rawLink) {
                return SavedConnection(
                    id: savedConnection.id,
                    configuration: reparsedConfiguration,
                    savedAt: savedConnection.savedAt,
                    source: savedConnection.source,
                    healthCheck: savedConnection.healthCheck?.normalizedForPersistence
                )
            }
            return savedConnection
        }

        selectedConnectionID = snapshot.selectedConnectionID
        healthChecksByConnectionID = Dictionary(uniqueKeysWithValues: savedConnections.compactMap { connection in
            connection.healthCheck.map { (connection.id, $0) }
        })
        rebuildSavedConnectionIndexes()
        rebuildSubscriptionSourceIndexes()
        normalizeSelection()
        prepareSplitTunnelGeodataMatcher()
        observeConnectionState()
        startAutoRefreshTimer()
        updateMenuBarAnimation()
        scheduleInitialHealthRefresh()
        refreshUnfetchedSubscriptionsIfNeeded()
    }

    var selectedConnection: SavedConnection? {
        guard let selectedConnectionID else { return savedConnections.first }
        return savedConnectionsByID[selectedConnectionID] ?? savedConnections.first
    }

    var selectedConfiguration: ConnectionConfiguration? {
        selectedConnection?.configuration
    }

    /// Every connection this session dials, the default one first. A connection
    /// joins simply by being named in an active rule: the config carries the
    /// outbounds the rules actually use, with no separate opt-in to keep in sync.
    var routedConnections: [SavedConnection] {
        guard let selectedConnection else { return [] }
        var connections = [selectedConnection]
        var seen: Set<UUID> = [selectedConnection.id]
        for rule in activeSplitTunnelRules where rule.action == .proxy {
            guard let connectionID = rule.connectionID,
                  seen.insert(connectionID).inserted,
                  let connection = savedConnectionsByID[connectionID] else { continue }
            connections.append(connection)
        }
        return connections
    }

    /// How many active rules send traffic through this connection, so the
    /// connections list can show what a connection is used for.
    func activeRuleCount(routingThrough id: UUID) -> Int {
        activeSplitTunnelRules.filter { $0.action == .proxy && $0.connectionID == id }.count
    }

    var manualConnections: [SavedConnection] {
        savedConnections.filter { $0.source == nil }
    }

    var manualConnectionPickerItems: [ConnectionPickerItem] {
        connectionPickerItems.filter { $0.sourceID == nil }
    }

    private var connectionPresentation: ConnectionPresentation {
        ConnectionPresentation(state: connectionState, hasConfiguration: selectedConfiguration != nil)
    }

    var connectionPhase: ConnectionPhase {
        connectionPresentation.connectionPhase
    }

    var proxyPhase: ProxyPhase {
        connectionPresentation.proxyPhase
    }

    var canConnect: Bool {
        !isTerminating
            && hasObservedInitialConnectionState
            && selectedConfiguration != nil
            && !isOperationPending
            && connectionPresentation.canConnect
    }

    var canDisconnect: Bool {
        !isTerminating
            && hasObservedInitialConnectionState
            && (isOperationPending || connectionPresentation.canDisconnect)
    }

    var canChangeSelection: Bool {
        !isTerminating
            && hasObservedInitialConnectionState
            && !isOperationPending
            && connectionPresentation.canChangeSelection
    }

    var hasActiveConnectionSession: Bool {
        isOperationPending || connectionPresentation.hasActiveConnectionSession
    }

    var isConnected: Bool {
        connectionPresentation.isConnected
    }

    var selectedSplitTunnelProfile: SplitTunnelProfile? {
        guard let selectedSplitTunnelProfileID else { return splitTunnelProfiles.first }
        return splitTunnelProfiles.first { $0.id == selectedSplitTunnelProfileID } ?? splitTunnelProfiles.first
    }

    /// Rules belonging to the currently selected split-tunnel profile.
    var splitTunnelRules: [SplitTunnelRule] {
        selectedSplitTunnelProfile?.rules ?? []
    }

    private var selectedSplitTunnelProfileIndex: Int? {
        guard let selectedSplitTunnelProfileID else { return splitTunnelProfiles.indices.first }
        return splitTunnelProfiles.firstIndex { $0.id == selectedSplitTunnelProfileID } ?? splitTunnelProfiles.indices.first
    }

    /// The rules that actually reach Xray: only when the master toggle is on, and
    /// only enabled rules from the selected profile, in list order. Used both to
    /// build the tunnel config and to decide whether a live edit changed anything
    /// worth reconnecting for.
    private var activeSplitTunnelRules: [SplitTunnelRule] {
        isSplitTunnelEnabled ? splitTunnelRules.filter { $0.isEnabled } : []
    }

    /// Default action of the selected profile, exposed for the settings picker.
    var splitTunnelDefaultAction: SplitTunnelRuleAction {
        selectedSplitTunnelProfile?.defaultAction ?? .proxy
    }

    /// The catch-all outbound that actually reaches Xray. When split tunneling is
    /// off we keep the classic full-tunnel behavior (everything proxied) so the
    /// profile's default only takes effect while the feature is enabled.
    private var activeSplitTunnelDefaultAction: SplitTunnelRuleAction {
        isSplitTunnelEnabled ? splitTunnelDefaultAction : .proxy
    }

    var statusSummary: String {
        switch connectionPhase {
        case .unconfigured:
            return savedConnections.isEmpty ? "Add a connection or subscription in Settings to get started" : "Select a connection to get started"
        case .ready, .stopped:
            return proxyPhase == .enabled ? "Connected" : "Disconnected"
        case .starting:
            return proxyPhase == .enabling ? "Connecting…" : "Starting connection…"
        case .running:
            return proxyPhase == .enabled ? "Connected" : "Xray is ready"
        case .stopping:
            return "Disconnecting…"
        case .failed:
            return lastError ?? "Connection failed"
        }
    }

    func importedConnections(for sourceID: UUID) -> [SavedConnection] {
        sortedImportedConnections(importedConnectionsBySourceID[sourceID] ?? [])
    }

    func importedConnectionPickerItems(for sourceID: UUID) -> [ConnectionPickerItem] {
        importedConnections(for: sourceID).map(ConnectionPickerItem.init)
    }

    var importedConnectionPickerItemsBySourceID: [UUID: [ConnectionPickerItem]] {
        importedConnectionsBySourceID.reduce(into: [:]) { partialResult, item in
            partialResult[item.key] = sortedImportedConnections(item.value).map(ConnectionPickerItem.init)
        }
    }

    func importedConnectionCount(for sourceID: UUID) -> Int {
        importedConnectionCountsBySourceID[sourceID] ?? 0
    }

    func subscriptionSource(for connection: SavedConnection) -> SubscriptionSource? {
        guard let sourceID = connection.source?.subscriptionSourceID else { return nil }
        return subscriptionSourcesByID[sourceID]
    }

    func isRefreshingSubscription(_ sourceID: UUID) -> Bool {
        refreshingSubscriptionIDs.contains(sourceID)
    }

    func isRefreshingHealth(for connectionID: UUID) -> Bool {
        refreshingHealthConnectionIDs.contains(connectionID)
    }

    func isRefreshingSubscriptionHealth(_ sourceID: UUID) -> Bool {
        let ids = Set((importedConnectionsBySourceID[sourceID] ?? []).map(\.id))
        return !refreshingHealthConnectionIDs.isDisjoint(with: ids)
    }

    func isQueuedHealth(for connectionID: UUID) -> Bool {
        queuedHealthConnectionIDs.contains(connectionID)
    }

    func isQueuedSubscriptionHealth(_ sourceID: UUID) -> Bool {
        let ids = Set((importedConnectionsBySourceID[sourceID] ?? []).map(\.id))
        return !queuedHealthConnectionIDs.isDisjoint(with: ids)
    }

    func healthCheck(for connection: SavedConnection) -> ConnectionHealthCheck {
        healthCheck(for: connection.id)
    }

    func healthCheck(for connectionID: UUID) -> ConnectionHealthCheck {
        let stored = healthChecksByConnectionID[connectionID]
            ?? savedConnectionsByID[connectionID]?.healthCheck
            ?? .unknown

        if refreshingHealthConnectionIDs.contains(connectionID) {
            var checking = stored
            checking.state = .checking
            return checking
        }

        if queuedHealthConnectionIDs.contains(connectionID) {
            var queued = stored
            queued.state = .queued
            return queued
        }

        return stored
    }

    func healthSummary(for connection: SavedConnection) -> String {
        let healthCheck = healthCheck(for: connection)
        switch healthCheck.state {
        case .reachable:
            if let latency = healthCheck.latencyMilliseconds {
                switch healthCheck.latencyKind {
                case .proxyRequest:
                    return "Ping \(latency) ms"
                case .tcpConnect, nil:
                    return "TCP \(latency) ms"
                }
            }
            return "Available"
        case .unreachable:
            return healthCheck.failureSummary ?? "Unavailable"
        case .queued:
            return "Queued…"
        case .checking:
            return "Checking…"
        case .unknown:
            if let checkedAt = healthCheck.checkedAt {
                return "Unknown • checked \(Self.relativeFormatter.localizedString(for: checkedAt, relativeTo: Date()))"
            }
            return "Not checked"
        }
    }

    func healthSnapshotForPicker() -> [UUID: ConnectionHealthCheck] {
        Dictionary(uniqueKeysWithValues: connectionPickerItems.map { ($0.id, healthCheck(for: $0.id)) })
    }

    func healthSummary(for healthCheck: ConnectionHealthCheck) -> String {
        switch healthCheck.state {
        case .reachable:
            if let latency = healthCheck.latencyMilliseconds {
                switch healthCheck.latencyKind {
                case .proxyRequest:
                    return "Ping \(latency) ms"
                case .tcpConnect, nil:
                    return "TCP \(latency) ms"
                }
            }
            return "Available"
        case .unreachable:
            return healthCheck.failureSummary ?? "Unavailable"
        case .queued:
            return "Queued…"
        case .checking:
            return "Checking…"
        case .unknown:
            if let checkedAt = healthCheck.checkedAt {
                return "Unknown • checked \(Self.relativeFormatter.localizedString(for: checkedAt, relativeTo: Date()))"
            }
            return "Not checked"
        }
    }

    func refreshConnectionHealth(id: UUID, force: Bool = true) {
        enqueueHealthProbes(for: [id], force: force, priority: true)
    }

    func refreshSubscriptionHealth(id: UUID, force: Bool = true) {
        let ids = importedConnections(for: id).map(\.id)
        enqueueHealthProbes(for: ids, force: force, priority: true)
    }

    func refreshVisibleConnectionHealth(force: Bool = true) {
        enqueueHealthProbes(for: savedConnections.map(\.id), force: force, priority: true)
    }

    @discardableResult
    func addConnection(from rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setStoredError("Paste a connection or subscription URL first")
            return false
        }

        if looksLikeSubscriptionURL(trimmed) {
            return addSubscription(from: trimmed)
        } else {
            return addManualConnection(from: trimmed)
        }
    }

    /// Names an imported connection as readily as a manual one: the name is kept
    /// next to the connection, so a subscription refresh carries it forward
    /// instead of overwriting it. An empty name restores the original.
    func renameConnection(id: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = savedConnections.firstIndex(where: { $0.id == id }) else { return }
        let newName = trimmedName.isEmpty ? nil : trimmedName
        guard newName != savedConnections[index].customName else { return }

        savedConnections[index].customName = newName
        rebuildSavedConnectionIndexes()
        setStoredError(nil)
        persistSettingError()
    }

    func removeConnection(id: UUID) {
        guard let index = savedConnections.firstIndex(where: { $0.id == id }) else { return }

        if (selectedConnectionID == id || routedConnections.contains { $0.id == id }) && hasActiveConnectionSession {
            setStoredError("Disconnect before removing the active connection")
            return
        }

        let removedConnection = savedConnections.remove(at: index)
        healthChecksByConnectionID.removeValue(forKey: id)
        rebuildSavedConnectionIndexes()
        cancelHealthProbe(id: id)
        if selectedConnectionID == removedConnection.id {
            recoverSelection(afterRemovingConnectionAt: index)
        } else {
            normalizeSelection()
        }

        setStoredError(nil)
        persistSettingError()
    }

    func removeSubscription(id: UUID) {
        let affectedConnections = importedConnections(for: id)

        if hasActiveConnectionSession,
           affectedConnections.contains(where: { $0.id == selectedConnectionID }) {
            setStoredError("Disconnect before removing the active subscription")
            return
        }

        savedConnections.removeAll { $0.source?.subscriptionSourceID == id }
        subscriptionSources.removeAll { $0.id == id }
        for connection in affectedConnections {
            healthChecksByConnectionID.removeValue(forKey: connection.id)
        }
        rebuildSavedConnectionIndexes()
        rebuildSubscriptionSourceIndexes()
        refreshingSubscriptionIDs.remove(id)
        let removedIDs = Set(affectedConnections.map(\.id))
        cancelHealthProbes(ids: removedIDs)
        normalizeSelection()
        setStoredError(nil)
        persistSettingError()
    }

    func selectConnection(id: UUID) {
        guard savedConnectionsByID[id] != nil else { return }

        let previousSelectionID = selectedConnectionID
        let shouldReconnect = previousSelectionID != id && hasEstablishedConnection

        if !canChangeSelection, previousSelectionID != id {
            setStoredError("Please wait for the current connection action to finish")
            return
        }

        selectedConnectionID = id
        setStoredError(nil)
        persistSettingError()
        enqueueHealthProbes(for: [id], force: false, priority: true)

        if shouldReconnect {
            reconnectToSelectedConnection()
        }
    }

    func refreshSubscription(id: UUID) {
        refreshSubscription(id: id, autoSelectFirstImported: false)
    }

    func updateSubscriptionSettings(id: UUID, customName: String, urlString: String, autoUpdateIntervalMinutes: Int?, filterDuplicateImports: Bool) {
        guard let existingSource = subscriptionSources.first(where: { $0.id == id }) else { return }

        do {
            let validatedURL = try validateSubscriptionURL(urlString)
            let normalizedURL = validatedURL.absoluteString

            if subscriptionSources.contains(where: { $0.id != id && $0.urlString.caseInsensitiveCompare(normalizedURL) == .orderedSame }) {
                throw SubscriptionError.duplicateSource
            }

            let trimmedName = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlChanged = existingSource.urlString.caseInsensitiveCompare(normalizedURL) != .orderedSame
            let selectedConnectionSourceID = selectedConnectionID.flatMap { savedConnectionsByID[$0] }?.source?.subscriptionSourceID
            let selectionBelongsToUpdatedSource = selectedConnectionSourceID == id

            if urlChanged,
               hasActiveConnectionSession,
               selectionBelongsToUpdatedSource {
                setStoredError("Disconnect before changing the active subscription URL")
                return
            }

            updateSubscriptionSource(id) { source in
                source.title = trimmedName
                source.urlString = normalizedURL
                source.autoUpdateIntervalMinutes = autoUpdateIntervalMinutes
                source.filterDuplicateImports = filterDuplicateImports
                if urlChanged {
                    source.lastError = nil
                    source.lastRefreshedAt = nil
                    source.lastSkippedCount = 0
                }
            }

            if urlChanged {
                let removedConnections = savedConnections.filter { $0.source?.subscriptionSourceID == id }
                savedConnections.removeAll { $0.source?.subscriptionSourceID == id }
                for connection in removedConnections {
                    healthChecksByConnectionID.removeValue(forKey: connection.id)
                }
                rebuildSavedConnectionIndexes()
                if selectionBelongsToUpdatedSource {
                    normalizeSelection()
                }
            }

            setStoredError(nil)
            persistSettingError()

            if urlChanged {
                refreshSubscription(id: id, autoSelectFirstImported: false)
            }
        } catch {
            setStoredError(error.localizedDescription)
        }
    }

    func clearError() {
        setStoredError(nil)
    }

    /// Surfaces a failure raised by the add-connection UI itself, such as an
    /// unreadable imported file, next to the parse failures shown in that sheet.
    func reportImportFailure(_ message: String) {
        setStoredError(message)
    }

    func selectConnectionMode(_ mode: ConnectionMode) {
        guard mode != connectionMode else { return }
        guard canChangeSelection && !hasActiveConnectionSession else {
            setStoredError("Disconnect before changing connection mode")
            return
        }

        let previousProvider = connectionProvider
        connectionStateTask?.cancel()
        connectionMode = mode
        connectionProvider = connectionProviderFactory.makeProvider(for: mode)
        connectionState = .idle
        hasObservedInitialConnectionState = false
        inFlightConnectionRequest = nil
        appliedSplitTunnelRules = nil
        appliedSplitTunnelDefaultAction = nil
        observeConnectionState()
        setStoredError(nil)
        updateMenuBarAnimation()
        schedulePersist()

        Task {
            try? await previousProvider.disconnect()
        }
    }

    func selectSubscriptionConnectionSort(_ sort: SubscriptionConnectionSort) {
        guard sort != subscriptionConnectionSort else { return }
        subscriptionConnectionSort = sort
        schedulePersist()
    }

    func setShowsLatencyInMenuBarPicker(_ showsLatency: Bool) {
        guard showsLatency != showsLatencyInMenuBarPicker else { return }
        showsLatencyInMenuBarPicker = showsLatency
        schedulePersist()
    }

    func setAnimatesMenuBarIcon(_ animates: Bool) {
        guard animates != animatesMenuBarIcon else { return }
        animatesMenuBarIcon = animates
        schedulePersist()
    }

    func setProxyEndpoint(httpPort: Int? = nil, socksPort: Int? = nil) {
        let nextHTTPPort = httpPort ?? proxyEndpoint.httpPort
        let nextSOCKSPort = socksPort ?? proxyEndpoint.socksPort
        guard nextHTTPPort != proxyEndpoint.httpPort || nextSOCKSPort != proxyEndpoint.socksPort else { return }

        guard !hasActiveConnectionSession else {
            setStoredError("Disconnect before changing local proxy ports")
            return
        }
        guard Self.isValidProxyPort(nextHTTPPort), Self.isValidProxyPort(nextSOCKSPort), nextHTTPPort != nextSOCKSPort else {
            setStoredError("Proxy ports must be different values between 1 and 65535")
            return
        }

        proxyEndpoint = ProxyEndpoint(host: proxyEndpoint.host, httpPort: nextHTTPPort, socksPort: nextSOCKSPort)
        setStoredError(nil)
        schedulePersist()
    }

    func setSplitTunnelEnabled(_ enabled: Bool) {
        guard enabled != isSplitTunnelEnabled else { return }
        isSplitTunnelEnabled = enabled
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    @discardableResult
    func addSplitTunnelRule(value: String, action: SplitTunnelRuleAction, connectionID: UUID? = nil) -> Result<SplitTunnelRule, SplitTunnelRuleValidationError> {
        switch SplitTunnelRuleClassifier.classify(value) {
        case let .success(classified):
            let rule = SplitTunnelRule(
                value: classified.value,
                kind: classified.kind,
                action: action,
                connectionID: action == .proxy ? connectionID : nil
            )
            // splitTunnelProfiles always has at least one profile (enforced by
            // removeSplitTunnelProfile and the AppSnapshot default), so this index
            // is always valid in practice.
            if let index = selectedSplitTunnelProfileIndex {
                splitTunnelProfiles[index].rules.append(rule)
                schedulePersist()
                scheduleSplitTunnelLiveApply()
            }
            return .success(rule)
        case let .failure(error):
            return .failure(error)
        }
    }

    func removeSplitTunnelRule(id: UUID) {
        guard let index = selectedSplitTunnelProfileIndex,
              splitTunnelProfiles[index].rules.contains(where: { $0.id == id }) else { return }
        splitTunnelProfiles[index].rules.removeAll { $0.id == id }
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func setSplitTunnelRuleEnabled(id: UUID, isEnabled: Bool) {
        guard let profileIndex = selectedSplitTunnelProfileIndex,
              let ruleIndex = splitTunnelProfiles[profileIndex].rules.firstIndex(where: { $0.id == id }),
              splitTunnelProfiles[profileIndex].rules[ruleIndex].isEnabled != isEnabled else { return }
        splitTunnelProfiles[profileIndex].rules[ruleIndex].isEnabled = isEnabled
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func setSplitTunnelRuleAction(id: UUID, action: SplitTunnelRuleAction) {
        guard let profileIndex = selectedSplitTunnelProfileIndex,
              let ruleIndex = splitTunnelProfiles[profileIndex].rules.firstIndex(where: { $0.id == id }),
              splitTunnelProfiles[profileIndex].rules[ruleIndex].action != action else { return }
        splitTunnelProfiles[profileIndex].rules[ruleIndex].action = action
        // Only a proxy rule can name a connection; leaving a stale id behind would
        // silently reappear if the rule were switched back to Proxy later.
        if action != .proxy {
            splitTunnelProfiles[profileIndex].rules[ruleIndex].connectionID = nil
        }
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    /// `nil` routes the rule through the session's default connection.
    func setSplitTunnelRuleConnection(id: UUID, connectionID: UUID?) {
        guard let profileIndex = selectedSplitTunnelProfileIndex,
              let ruleIndex = splitTunnelProfiles[profileIndex].rules.firstIndex(where: { $0.id == id }),
              splitTunnelProfiles[profileIndex].rules[ruleIndex].action == .proxy,
              splitTunnelProfiles[profileIndex].rules[ruleIndex].connectionID != connectionID else { return }
        splitTunnelProfiles[profileIndex].rules[ruleIndex].connectionID = connectionID
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func setSplitTunnelDefaultAction(_ action: SplitTunnelRuleAction) {
        guard let profileIndex = selectedSplitTunnelProfileIndex,
              splitTunnelProfiles[profileIndex].defaultAction != action else { return }
        splitTunnelProfiles[profileIndex].defaultAction = action
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func moveSplitTunnelRules(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard let index = selectedSplitTunnelProfileIndex else { return }
        let rules = splitTunnelProfiles[index].rules
        let movedRules = offsets.map { rules[$0] }
        var remainingRules = rules
        for offset in offsets.sorted(by: >) {
            remainingRules.remove(at: offset)
        }
        let adjustedDestination = destination - offsets.filter { $0 < destination }.count
        remainingRules.insert(contentsOf: movedRules, at: max(0, min(adjustedDestination, remainingRules.count)))
        splitTunnelProfiles[index].rules = remainingRules
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func matchingSplitTunnelRule(for candidate: String) -> SplitTunnelRule? {
        if !splitTunnelGeodataMatcher.isReady {
            prepareSplitTunnelGeodataMatcher()
        }
        return SplitTunnelRuleMatcher.firstMatch(for: candidate, in: splitTunnelRules, geodataMatcher: splitTunnelGeodataMatcher)
    }

    var hasEnabledSplitTunnelGeodataRules: Bool {
        splitTunnelRules.contains { $0.isEnabled && ($0.kind == .geosite || $0.kind == .geoip) }
    }

    // MARK: - Split-tunnel profiles

    @discardableResult
    func addSplitTunnelProfile(name: String) -> UUID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SplitTunnelProfile(name: trimmedName.isEmpty ? "New Profile" : trimmedName)
        splitTunnelProfiles.append(profile)
        selectedSplitTunnelProfileID = profile.id
        schedulePersist()
        scheduleSplitTunnelLiveApply()
        return profile.id
    }

    func renameSplitTunnelProfile(id: UUID, name: String) {
        guard let index = splitTunnelProfiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, splitTunnelProfiles[index].name != trimmedName else { return }
        splitTunnelProfiles[index].name = trimmedName
        schedulePersist()
    }

    /// Removes a profile. At least one profile must always exist, so the last
    /// remaining profile cannot be deleted (mirrors "can't disable the only mode").
    func removeSplitTunnelProfile(id: UUID) {
        guard splitTunnelProfiles.count > 1, let index = splitTunnelProfiles.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedSplitTunnelProfileID == id
        splitTunnelProfiles.remove(at: index)
        if wasSelected {
            selectedSplitTunnelProfileID = splitTunnelProfiles.first?.id
        }
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func selectSplitTunnelProfile(id: UUID) {
        guard id != selectedSplitTunnelProfileID, splitTunnelProfiles.contains(where: { $0.id == id }) else { return }
        selectedSplitTunnelProfileID = id
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    /// Coalesces rapid rule edits (typing, dragging to reorder, flipping several
    /// toggles) into a single VPN reconnect once the user settles, instead of
    /// tearing the tunnel down and back up on every individual change.
    private func scheduleSplitTunnelLiveApply() {
        guard connectionMode == .vpn, hasActiveConnectionSession else { return }
        guard hasEstablishedConnection else {
            pendingSplitTunnelLiveApply = true
            return
        }

        splitTunnelApplyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applySplitTunnelRulesLiveIfNeeded()
        }
        splitTunnelApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    private func applySplitTunnelRulesLiveIfNeeded() {
        guard !isTerminating, connectionMode == .vpn, hasEstablishedConnection else { return }
        guard !isOperationPending else {
            pendingSplitTunnelLiveApply = true
            return
        }
        pendingSplitTunnelLiveApply = false
        // Only reconnect when what Xray would actually see has changed. Editing a
        // disabled rule, or a no-op toggle, must not drop the tunnel; but a change
        // to the default (catch-all) action must, since it rewrites the config.
        guard activeSplitTunnelRules != appliedSplitTunnelRules
            || activeSplitTunnelDefaultAction != appliedSplitTunnelDefaultAction else { return }
        reconnectToSelectedConnection()
    }

    private func applyDeferredSplitTunnelRulesLiveIfNeeded() {
        guard connectionMode == .vpn, hasEstablishedConnection else { return }
        guard pendingSplitTunnelLiveApply
            || activeSplitTunnelRules != appliedSplitTunnelRules
            || activeSplitTunnelDefaultAction != appliedSplitTunnelDefaultAction else { return }
        applySplitTunnelRulesLiveIfNeeded()
    }

    // MARK: - Geodata (geosite/geoip)

    func setGeositeURL(_ urlString: String?) {
        let normalized = normalizedURLString(urlString)
        guard normalized != geodataSettings.geositeURLString else { return }
        geodataSettings.geositeURLString = normalized
        schedulePersist()
    }

    func setGeoipURL(_ urlString: String?) {
        let normalized = normalizedURLString(urlString)
        guard normalized != geodataSettings.geoipURLString else { return }
        geodataSettings.geoipURLString = normalized
        schedulePersist()
    }

    func setGeodataAutoUpdateIntervalMinutes(_ minutes: Int?) {
        guard minutes != geodataSettings.autoUpdateIntervalMinutes else { return }
        geodataSettings.autoUpdateIntervalMinutes = minutes
        schedulePersist()
    }

    func cancelGeodataUpdate(kind: GeodataKind) {
        guard updatingGeodataKinds.contains(kind) else { return }
        // Cancelling the task now aborts the transfer itself, not just its result.
        geodataUpdateTasks.removeValue(forKey: kind)?.cancel()
        geodataUpdateTokens[kind] = UUID()
        updatingGeodataKinds.remove(kind)
    }

    func cancelGeodataUpdates() {
        for kind in updatingGeodataKinds {
            geodataUpdateTasks.removeValue(forKey: kind)?.cancel()
            geodataUpdateTokens[kind] = UUID()
        }
        updatingGeodataKinds.removeAll()
    }

    func updateGeodataNow(kind: GeodataKind) {
        cancelGeodataUpdate(kind: kind)

        guard let urlString = geodataURLString(for: kind), let url = validatedGeodataURL(urlString) else {
            applyGeodataUpdateResult(kind: kind, error: GeodataUpdateError.invalidURL)
            return
        }

        let token = UUID()
        geodataUpdateTokens[kind] = token
        updatingGeodataKinds.insert(kind)

        geodataUpdateTasks[kind] = Task { @MainActor [weak self] in
            let service = GeodataUpdateService()
            do {
                let data = try await service.download(kind: kind, from: url)
                // The .dat files are tens of MB, so the atomic disk write belongs
                // neither on the main actor nor on a cooperative thread.
                let changed = try await BlockingWork.run { try service.store(data, for: kind) }
                guard self?.geodataUpdateTokens[kind] == token else { return }
                self?.applyGeodataUpdateResult(kind: kind, token: token, error: nil, changed: changed)
            } catch is CancellationError {
                return
            } catch {
                guard self?.geodataUpdateTokens[kind] == token else { return }
                self?.applyGeodataUpdateResult(kind: kind, token: token, error: error)
            }
        }
    }

    /// Deletes a downloaded custom override so VPN mode falls back to Teleport's
    /// bundled default for that kind on the next connect.
    func resetGeodataToBundled(kind: GeodataKind) {
        guard !updatingGeodataKinds.contains(kind) else { return }
        try? GeodataUpdateService().removeCustomGeodata(for: kind)
        splitTunnelGeodataMatcher.resetCache()
        isSplitTunnelGeodataReady = false
        prepareSplitTunnelGeodataMatcher()
        clearGeodataURL(kind: kind)
        setGeodataError(kind: kind, error: nil)
        setGeodataLastUpdatedAt(kind: kind, date: nil)
        schedulePersist()
        applyGeodataLiveIfNeeded()
    }

    func hasCustomGeodata(kind: GeodataKind) -> Bool {
        GeodataUpdateService().hasCustomGeodata(for: kind)
    }

    private func geodataURLString(for kind: GeodataKind) -> String? {
        switch kind {
        case .geosite: return geodataSettings.geositeURLString
        case .geoip: return geodataSettings.geoipURLString
        }
    }

    private func geodataLastUpdatedAt(for kind: GeodataKind) -> Date? {
        switch kind {
        case .geosite: return geodataSettings.geositeLastUpdatedAt
        case .geoip: return geodataSettings.geoipLastUpdatedAt
        }
    }

    private func setGeodataError(kind: GeodataKind, error: Error?) {
        let message = (error as? LocalizedError)?.errorDescription ?? error?.localizedDescription
        switch kind {
        case .geosite: geodataSettings.geositeLastError = message
        case .geoip: geodataSettings.geoipLastError = message
        }
    }

    private func setGeodataLastUpdatedAt(kind: GeodataKind, date: Date?) {
        switch kind {
        case .geosite: geodataSettings.geositeLastUpdatedAt = date
        case .geoip: geodataSettings.geoipLastUpdatedAt = date
        }
    }

    private func clearGeodataURL(kind: GeodataKind) {
        switch kind {
        case .geosite: geodataSettings.geositeURLString = nil
        case .geoip: geodataSettings.geoipURLString = nil
        }
    }

    private func normalizedURLString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    private static func isValidProxyPort(_ port: Int) -> Bool {
        (1 ... 65_535).contains(port)
    }

    private func validatedGeodataURL(_ value: String) -> URL? {
        GeodataUpdateService.validatedSourceURL(value)
    }

    private func applyGeodataUpdateResult(kind: GeodataKind, token: UUID? = nil, error: Error?, changed: Bool = true) {
        if let token, geodataUpdateTokens[kind] != token { return }
        geodataUpdateTokens[kind] = nil
        updatingGeodataKinds.remove(kind)
        setGeodataError(kind: kind, error: error)
        if error == nil {
            splitTunnelGeodataMatcher.resetCache()
            isSplitTunnelGeodataReady = false
            prepareSplitTunnelGeodataMatcher()
            setGeodataLastUpdatedAt(kind: kind, date: Date())
        }
        schedulePersist()
        // Geodata only takes effect at Xray startup, so only bounce a live tunnel
        // when the stored bytes actually changed — an identical scheduled
        // re-download must not drop a connected user's session.
        if error == nil, changed {
            applyGeodataLiveIfNeeded()
        }
    }

    /// Geodata is read by Xray at process startup, so an update only takes
    /// effect after a restart; reuse the normal reconnect path immediately if
    /// VPN mode is already connected instead of waiting for the user to notice.
    private func applyGeodataLiveIfNeeded() {
        guard connectionMode == .vpn, hasEstablishedConnection else { return }
        reconnectToSelectedConnection()
    }

    private func prepareSplitTunnelGeodataMatcher() {
        guard !splitTunnelGeodataMatcher.isReady else {
            isSplitTunnelGeodataReady = true
            return
        }
        splitTunnelGeodataMatcher.prepare { [weak self] in
            self?.isSplitTunnelGeodataReady = self?.splitTunnelGeodataMatcher.isReady == true
        }
    }

    private func performScheduledGeodataUpdateIfNeeded() {
        guard let intervalMinutes = geodataSettings.autoUpdateIntervalMinutes, intervalMinutes > 0 else { return }

        for kind in GeodataKind.allCases {
            guard !updatingGeodataKinds.contains(kind), geodataURLString(for: kind) != nil else { continue }
            let referenceDate = geodataLastUpdatedAt(for: kind) ?? .distantPast
            guard Date().timeIntervalSince(referenceDate) >= TimeInterval(intervalMinutes * 60) else { continue }
            updateGeodataNow(kind: kind)
        }
    }

    func refreshStartsAtLoginStatus() {
        startsAtLogin = loginItemService.isEnabled
    }

    func setStartsAtLogin(_ startsAtLogin: Bool) {
        do {
            try loginItemService.setEnabled(startsAtLogin)
            self.startsAtLogin = loginItemService.isEnabled
            setStoredError(nil)
        } catch {
            self.startsAtLogin = loginItemService.isEnabled
            setStoredError(error.localizedDescription)
        }
    }

    func connect() {
        guard let selectedConfiguration else {
            setStoredError("Add and select a connection first")
            return
        }

        startConnection(using: selectedConfiguration)
    }

    func disconnect() {
        guard !isTerminating else { return }
        let provider = connectionProvider
        let operationID = UUID()
        beginConnectionOperation()
        Task { @MainActor [weak self] in
            do {
                try await provider.disconnect()
                self?.setStoredError(nil)
            } catch {
                if await provider.currentState().isTerminalFailure == false {
                    self?.applyConnectionError(error)
                }
            }
            self?.finishConnectionOperation(operationID)
        }
    }

    func handleAppTermination(completion: @escaping () -> Void) {
        isTerminating = true
        let provider = connectionProvider
        Task { @MainActor [weak self] in
            try? await provider.disconnect()
            self?.connectionStateTask?.cancel()
            completion()
        }
    }

    private func observeConnectionState() {
        connectionStateTask?.cancel()
        let stateUpdates = connectionProvider.stateUpdates()
        connectionStateTask = Task { @MainActor [weak self] in
            for await state in stateUpdates {
                guard !Task.isCancelled else { break }
                self?.applyConnectionState(state)
            }
        }
    }

    private func applyConnectionState(_ state: ConnectionState) {
        let isInitialState = !hasObservedInitialConnectionState
        hasObservedInitialConnectionState = true
        connectionState = state

        switch state {
        case let .failed(failure):
            lastError = failure.summary
            lastErrorDetails = failure.details
            inFlightConnectionRequest = nil
        case .connected:
            if let inFlightConnectionRequest {
                appliedSplitTunnelRules = inFlightConnectionRequest.request.splitTunnelPolicy.rules
                appliedSplitTunnelDefaultAction = inFlightConnectionRequest.request.splitTunnelPolicy.defaultAction
                self.inFlightConnectionRequest = nil
                setStoredError(nil)
            } else if appliedSplitTunnelRules == nil {
                appliedSplitTunnelRules = activeSplitTunnelRules
                appliedSplitTunnelDefaultAction = activeSplitTunnelDefaultAction
                if !isInitialState {
                    setStoredError(nil)
                }
            }
            applyDeferredSplitTunnelRulesLiveIfNeeded()
        case .idle:
            inFlightConnectionRequest = nil
            appliedSplitTunnelRules = nil
            appliedSplitTunnelDefaultAction = nil
            pendingSplitTunnelLiveApply = false
        case .preparing, .awaitingUserApproval, .connecting, .disconnecting:
            break
        }
        updateMenuBarAnimation()
    }

    private var hasEstablishedConnection: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    private func reconnectToSelectedConnection() {
        guard let selectedConfiguration else {
            setStoredError("Add and select a connection first")
            return
        }
        startConnection(using: selectedConfiguration)
    }

    private func startConnection(using configuration: ConnectionConfiguration) {
        guard !isTerminating else { return }

        let request = makeConnectionRequest(configuration: configuration)
        let provider = connectionProvider
        let operationID = UUID()
        beginConnectionOperation()
        inFlightConnectionRequest = (operationID, request)
        setStoredError(nil)

        Task { @MainActor [weak self] in
            do {
                try await provider.connect(request)
                self?.finishConnectionOperation(operationID, discardPendingRequest: false)
                self?.applyDeferredSplitTunnelRulesLiveIfNeeded()
            } catch {
                if await provider.currentState().isTerminalFailure == false {
                    self?.applyConnectionError(error)
                }
                self?.finishConnectionOperation(operationID, discardPendingRequest: true)
            }
        }
    }

    private func beginConnectionOperation() {
        pendingOperationCount += 1
        isOperationPending = true
    }

    private func finishConnectionOperation(_ operationID: UUID, discardPendingRequest: Bool = false) {
        if discardPendingRequest, inFlightConnectionRequest?.operationID == operationID {
            inFlightConnectionRequest = nil
        }
        pendingOperationCount = max(0, pendingOperationCount - 1)
        isOperationPending = pendingOperationCount > 0
    }

    private func makeConnectionRequest(configuration: ConnectionConfiguration) -> ConnectionRequest {
        // The caller may connect to a configuration that is not the current
        // selection (a menu-bar pick, for example), so the default connection is
        // taken from the argument and the extras are matched against it.
        let defaultConnectionID = savedConnections.first { $0.configuration == configuration }?.id
            ?? selectedConnectionID
            ?? UUID()
        let additionalConnections = routedConnections.compactMap { connection -> RoutedConnection? in
            guard connection.id != defaultConnectionID else { return nil }
            return RoutedConnection(id: connection.id, configuration: connection.configuration)
        }
        return ConnectionRequest(
            defaultConnection: RoutedConnection(id: defaultConnectionID, configuration: configuration),
            additionalConnections: additionalConnections,
            localProxy: proxyEndpoint,
            splitTunnelPolicy: SplitTunnelPolicy(
                rules: activeSplitTunnelRules,
                defaultAction: activeSplitTunnelDefaultAction
            )
        )
    }

    private func setStoredError(_ message: String?) {
        lastError = message
        lastErrorDetails = nil
    }

    private func applyConnectionError(_ error: Error) {
        setStoredError(error.localizedDescription)
        if let localizedError = error as? LocalizedError,
           let details = localizedError.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
           !details.isEmpty,
           details != lastError {
            lastErrorDetails = details
        } else {
            lastErrorDetails = nil
        }
    }

    private func addManualConnection(from rawLink: String) -> Bool {
        do {
            let configuration = try parser.parse(rawLink)
            let savedConnection = SavedConnection(id: UUID(), configuration: configuration, savedAt: Date(), source: nil)
            let shouldSelectNewConnection = !hasActiveConnectionSession || selectedConnectionID == nil
            savedConnections.append(savedConnection)
            rebuildSavedConnectionIndexes()
            if shouldSelectNewConnection {
                selectedConnectionID = savedConnection.id
            }
            setStoredError(nil)
            updateMenuBarAnimation()
            try persist()
            enqueueHealthProbes(for: [savedConnection.id], force: true, priority: true)
            return true
        } catch {
            setStoredError(error.localizedDescription)
            return false
        }
    }

    private func addSubscription(from rawURL: String) -> Bool {
        do {
            let url = try validateSubscriptionURL(rawURL)
            let normalizedURL = url.absoluteString

            if subscriptionSources.contains(where: { $0.urlString.caseInsensitiveCompare(normalizedURL) == .orderedSame }) {
                throw SubscriptionError.duplicateSource
            }

            let source = SubscriptionSource(
                id: UUID(),
                urlString: normalizedURL,
                title: subscriptionTitle(for: url),
                savedAt: Date(),
                autoUpdateIntervalMinutes: nil,
                filterDuplicateImports: true
            )

            subscriptionSources.append(source)
            rebuildSubscriptionSourceIndexes()
            setStoredError(nil)
            persistSettingError()
            refreshSubscription(id: source.id, autoSelectFirstImported: savedConnections.isEmpty)
            return true
        } catch {
            setStoredError(error.localizedDescription)
            return false
        }
    }

    private func refreshSubscription(id: UUID, autoSelectFirstImported: Bool) {
        guard let source = subscriptionSources.first(where: { $0.id == id }) else { return }
        guard let selectedConnection else {
            startSubscriptionRefresh(for: source, autoSelectFirstImported: autoSelectFirstImported)
            return
        }

        if hasActiveConnectionSession,
           selectedConnection.source?.subscriptionSourceID == id {
            setStoredError("Disconnect before refreshing the active subscription")
            return
        }

        startSubscriptionRefresh(for: source, autoSelectFirstImported: autoSelectFirstImported)
    }

    private func startSubscriptionRefresh(for source: SubscriptionSource, autoSelectFirstImported: Bool) {
        refreshingSubscriptionIDs.insert(source.id)
        updateSubscriptionSource(source.id) {
            $0.lastError = nil
        }
        setStoredError(nil)
        persistSettingError()

        let parser = parser
        let subscriptionClient = subscriptionClient

        Task { @MainActor [weak self] in
            do {
                guard let url = URL(string: source.urlString) else {
                    throw SubscriptionError.invalidURL
                }

                let links = try await subscriptionClient.fetchCandidateLinks(from: url)
                let importResult = try Self.importSubscriptionEntries(
                    links: links,
                    parser: parser,
                    sourceID: source.id,
                    filterDuplicateImports: source.filterDuplicateImports
                )

                self?.applyImportedEntries(
                    importResult.importedEntries,
                    skippedCount: importResult.skippedCount,
                    to: source.id,
                    fetchedAt: Date(),
                    autoSelectFirstImported: autoSelectFirstImported
                )
            } catch {
                self?.refreshingSubscriptionIDs.remove(source.id)
                self?.updateSubscriptionSource(source.id) {
                    $0.lastError = error.localizedDescription
                }
                self?.applyConnectionError(error)
                self?.persistSettingError()
            }
        }
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

    private func applyImportedEntries(
        _ importedEntries: [ImportedSubscriptionEntry],
        skippedCount: Int,
        to sourceID: UUID,
        fetchedAt: Date,
        autoSelectFirstImported: Bool
    ) {
        let selectedConnectionSourceID = selectedConnectionID.flatMap { savedConnectionsByID[$0] }?.source?.subscriptionSourceID
        if hasActiveConnectionSession,
           selectedConnectionSourceID == sourceID {
            refreshingSubscriptionIDs.remove(sourceID)
            updateSubscriptionSource(sourceID) {
                $0.lastError = "Disconnect before refreshing the active subscription"
            }
            setStoredError("Disconnect before refreshing the active subscription")
            persistSettingError()
            return
        }

        let existingConnectionsForReconcile = savedConnections.map { connection in
            var connection = connection
            connection.healthCheck = healthChecksByConnectionID[connection.id] ?? connection.healthCheck
            return connection
        }
        let replacementResult = SubscriptionConnectionReconciler().reconcile(
            existingConnections: existingConnectionsForReconcile,
            sourceID: sourceID,
            selectedConnectionID: selectedConnectionID,
            importedEntries: importedEntries,
            fetchedAt: fetchedAt,
            autoSelectFirstImported: autoSelectFirstImported
        )

        savedConnections = replacementResult.savedConnections
        syncHealthChecksFromSavedConnections()
        invalidateHealthChecksForImportedConnections(from: sourceID)
        rebuildSavedConnectionIndexes()
        selectedConnectionID = replacementResult.selectedConnectionID

        updateSubscriptionSource(sourceID) {
            $0.lastRefreshedAt = fetchedAt
            $0.lastSkippedCount = skippedCount
            $0.lastError = skippedCount > 0 ? "Skipped \(skippedCount) unsupported entries during last refresh" : nil
        }

        refreshingSubscriptionIDs.remove(sourceID)
        setStoredError(nil)
        updateMenuBarAnimation()
        persistSettingError()
        refreshSubscriptionHealth(id: sourceID, force: true)
    }

    private func validateSubscriptionURL(_ rawURL: String) throws -> URL {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            throw SubscriptionError.invalidURL
        }
        return url
    }

    private func subscriptionTitle(for url: URL) -> String {
        if let host = url.host, !host.isEmpty {
            return host
        }
        return url.absoluteString
    }

    private func looksLikeSubscriptionURL(_ value: String) -> Bool {
        guard let scheme = URLComponents(string: value)?.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private func startAutoRefreshTimer() {
        autoRefreshTimerCancellable = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.performScheduledSubscriptionRefreshes()
                self?.performScheduledGeodataUpdateIfNeeded()
            }
    }

    private func refreshUnfetchedSubscriptionsIfNeeded() {
        let shouldAutoSelectFirstImported = savedConnections.isEmpty
        for source in subscriptionSources where source.lastRefreshedAt == nil && !refreshingSubscriptionIDs.contains(source.id) {
            refreshSubscription(id: source.id, autoSelectFirstImported: shouldAutoSelectFirstImported)
        }
    }

    private func performScheduledSubscriptionRefreshes() {
        let now = Date()

        for source in subscriptionSources {
            guard let intervalMinutes = source.autoUpdateIntervalMinutes,
                  intervalMinutes > 0,
                  !refreshingSubscriptionIDs.contains(source.id) else {
                continue
            }

            let referenceDate = source.lastRefreshedAt ?? source.savedAt
            guard now.timeIntervalSince(referenceDate) >= TimeInterval(intervalMinutes * 60) else {
                continue
            }

            refreshSubscription(id: source.id, autoSelectFirstImported: false)
        }
    }

    private func scheduleInitialHealthRefresh() {
        guard let selectedConnectionID else { return }
        enqueueHealthProbes(for: [selectedConnectionID], force: false, priority: true)
    }

    private func enqueueHealthProbes(for ids: [UUID], force: Bool, priority: Bool) {
        healthProbeQueue.enqueue(ids: ids, force: force, priority: priority)
    }

    private func applyHealthProbeResults(_ pendingResults: [UUID: ConnectionHealthProbeResult]) {
        guard !pendingResults.isEmpty else { return }

        for (connectionID, result) in pendingResults where savedConnectionsByID[connectionID] != nil {
            healthChecksByConnectionID[connectionID] = ConnectionHealthCheck(
                state: result.state,
                checkedAt: result.checkedAt,
                latencyMilliseconds: result.latencyMilliseconds,
                latencyKind: result.latencyKind,
                failureSummary: result.failureSummary
            )
        }

        schedulePersist()
    }

    private func cancelHealthProbe(id: UUID) {
        healthProbeQueue.cancel(id: id)
    }

    private func cancelHealthProbes(ids: Set<UUID>) {
        healthProbeQueue.cancel(ids: ids)
    }

    private func invalidateHealthChecksForImportedConnections(from sourceID: UUID) {
        for connection in savedConnections where connection.source?.subscriptionSourceID == sourceID {
            healthChecksByConnectionID.removeValue(forKey: connection.id)
        }
    }

    private func syncHealthChecksFromSavedConnections() {
        let validIDs = Set(savedConnections.map(\.id))
        healthChecksByConnectionID = healthChecksByConnectionID.filter { validIDs.contains($0.key) }
        for connection in savedConnections {
            if let healthCheck = connection.healthCheck {
                healthChecksByConnectionID[connection.id] = healthCheck
            }
        }
    }

    private func updateSubscriptionSource(_ id: UUID, mutate: (inout SubscriptionSource) -> Void) {
        guard let index = subscriptionSources.firstIndex(where: { $0.id == id }) else { return }
        mutate(&subscriptionSources[index])
        subscriptionSourcesByID[id] = subscriptionSources[index]
        let pickerItem = SubscriptionPickerItem(source: subscriptionSources[index])
        if let pickerIndex = subscriptionPickerItems.firstIndex(where: { $0.id == id }) {
            if subscriptionPickerItems[pickerIndex] != pickerItem {
                subscriptionPickerItems[pickerIndex] = pickerItem
            }
        } else {
            subscriptionPickerItems = subscriptionSources.map(SubscriptionPickerItem.init)
        }
    }

    private func rebuildSavedConnectionIndexes() {
        savedConnectionsByID = Dictionary(uniqueKeysWithValues: savedConnections.map { ($0.id, $0) })
        connectionPickerItems = savedConnections.map(ConnectionPickerItem.init)

        let groupedImportedConnections = Dictionary(grouping: savedConnections) { connection in
            connection.source?.subscriptionSourceID
        }

        importedConnectionsBySourceID = groupedImportedConnections.reduce(into: [:]) { partialResult, item in
            guard let sourceID = item.key else { return }
            partialResult[sourceID] = item.value
        }

        importedConnectionCountsBySourceID = importedConnectionsBySourceID.reduce(into: [:]) { partialResult, item in
            partialResult[item.key] = item.value.count
        }
    }

    private func sortedImportedConnections(_ connections: [SavedConnection]) -> [SavedConnection] {
        connections.sorted { lhs, rhs in
            switch subscriptionConnectionSort {
            case .name:
                return compareByName(lhs, rhs)
            case .latency:
                let lhsKey = latencySortKey(for: lhs)
                let rhsKey = latencySortKey(for: rhs)
                if lhsKey != rhsKey {
                    return lhsKey < rhsKey
                }
                return compareByName(lhs, rhs)
            }
        }
    }

    private func compareByName(_ lhs: SavedConnection, _ rhs: SavedConnection) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private func latencySortKey(for connection: SavedConnection) -> LatencySortKey {
        let healthCheck = healthChecksByConnectionID[connection.id] ?? connection.healthCheck ?? .unknown
        switch healthCheck.state {
        case .reachable:
            return LatencySortKey(group: healthCheck.latencyMilliseconds == nil ? 1 : 0, latency: healthCheck.latencyMilliseconds ?? Int.max)
        case .checking, .queued:
            return LatencySortKey(group: 2, latency: Int.max)
        case .unknown:
            return LatencySortKey(group: 3, latency: Int.max)
        case .unreachable:
            return LatencySortKey(group: 4, latency: Int.max)
        }
    }

    private func rebuildSubscriptionSourceIndexes() {
        subscriptionSourcesByID = Dictionary(uniqueKeysWithValues: subscriptionSources.map { ($0.id, $0) })
        subscriptionPickerItems = subscriptionSources.map(SubscriptionPickerItem.init)
    }

    private func recoverSelection(afterRemovingConnectionAt index: Int) {
        if savedConnections.indices.contains(index) {
            selectedConnectionID = savedConnections[index].id
        } else {
            selectedConnectionID = savedConnections.last?.id
        }
        normalizeSelection()
    }

    private func normalizeSelection() {
        if let selectedConnectionID,
           savedConnections.contains(where: { $0.id == selectedConnectionID }) {
            return
        }

        selectedConnectionID = savedConnections.first?.id
    }

    private func updateMenuBarAnimation() {
        // Animation timing is owned by MenuBarIconView. Keeping this hook avoids
        // broad call-site churn while preventing high-frequency AppViewModel
        // publications that re-render the entire menu/settings UI while connected.
    }

    private func persistSettingError() {
        do {
            try persist()
        } catch {
            setStoredError(error.localizedDescription)
        }
    }

    private func schedulePersist() {
        let snapshot = makeSnapshot()
        persistWorkItem?.cancel()

        let workItem = DispatchWorkItem { [store] in
            do {
                try store.save(snapshot)
            } catch {
                Task { @MainActor [weak self] in
                    self?.applyConnectionError(error)
                }
            }
        }

        persistWorkItem = workItem
        persistenceQueue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func makeSnapshot() -> AppSnapshot {
        let persistedConnections = savedConnections.map { connection in
            var normalizedConnection = connection
            normalizedConnection.healthCheck = healthChecksByConnectionID[connection.id]?.normalizedForPersistence
                ?? connection.healthCheck?.normalizedForPersistence
            return normalizedConnection
        }

        return AppSnapshot(
            savedConnections: persistedConnections,
            subscriptionSources: subscriptionSources,
            selectedConnectionID: selectedConnectionID ?? savedConnections.first?.id,
            proxyEndpoint: proxyEndpoint,
            connectionMode: connectionMode,
            subscriptionConnectionSort: subscriptionConnectionSort,
            showsLatencyInMenuBarPicker: showsLatencyInMenuBarPicker,
            animatesMenuBarIcon: animatesMenuBarIcon,
            splitTunnelProfiles: splitTunnelProfiles,
            selectedSplitTunnelProfileID: selectedSplitTunnelProfileID,
            isSplitTunnelEnabled: isSplitTunnelEnabled,
            geodataSettings: geodataSettings
        )
    }

    private func persist() throws {
        try store.save(makeSnapshot())
    }
}

extension AppViewModel {
    fileprivate static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
