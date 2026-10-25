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
    @Published private(set) var showsInDock: Bool
    @Published private(set) var connectsOnLaunch: Bool
    @Published private(set) var isLeakGuardEnabled: Bool
    @Published private(set) var splitTunnelProfiles: [SplitTunnelProfile]
    @Published private(set) var selectedSplitTunnelProfileID: UUID?
    @Published private(set) var isSplitTunnelEnabled: Bool
    @Published private(set) var geodataSettings: GeodataSourceSettings
    @Published private(set) var isSplitTunnelGeodataReady = false
    @Published private(set) var updatingGeodataKinds: Set<GeodataKind> = []
    @Published private(set) var startsAtLogin: Bool
    /// Whether the privileged helper's files are on disk; see
    /// `PrivilegedHelperUninstaller.isInstalled`. Read on demand, not watched.
    @Published private(set) var isHelperInstalled = false
    @Published private(set) var isUninstallingHelper = false
    /// The outcome of the last uninstall, shown under the button that started it.
    @Published private(set) var helperUninstallMessage: String?
    @Published private(set) var isOperationPending = false
    /// Kept until the connect call returns, even if its final state arrives first.
    @Published private var connectingSelection: (operationID: UUID, connectionID: UUID)?
    @Published private(set) var refreshingSubscriptionIDs: Set<UUID> = []
    @Published private(set) var refreshingHealthConnectionIDs: Set<UUID> = []
    @Published private(set) var queuedHealthConnectionIDs: Set<UUID> = []

    private let parser: ConnectionLinkParser
    private let store: ConfigurationStore
    private let bundledSeeder: BundledConfigurationSeeder
    /// Names of the subscription lists shipped with the app. Nothing imports them
    /// on its own; see `addBundledSubscriptions`.
    let bundledSubscriptionTitles: [String]
    private let connectionProviderFactory: ConnectionProviderFactory
    private var connectionProvider: any ConnectionProvider
    private let subscriptionClient: SubscriptionClient
    private let healthProbeService: ConnectionHealthProbeService
    private let splitTunnelGeodataMatcher = SplitTunnelGeodataMatcher()
    private let loginItemService = LoginItemService()
    private let helperUninstaller = PrivilegedHelperUninstaller()
    private let persistenceQueue = DispatchQueue(label: "dev.x.teleport.persistence", qos: .utility)
    private let log: TeleportLog
    /// Only used to finish a proxy restore an earlier run could not complete.
    /// Injected so a verification script never reaches the real system settings.
    private let systemProxyService: SystemProxyService
    private var networkPathObserver: NetworkPathObserver?
    private var systemWakeObserver: SystemWakeObserver?
    /// Held across teardowns and rebuilds, which is where the leak it guards
    /// against happens. Owned here rather than by a provider for that reason.
    private let leakGuard: LeakGuardService
    /// When the machine last went to sleep, so a session built after that instant
    /// is known to be newer than the sleep and needs no rebuild.
    private var lastSleepAt: Date?
    /// Set between `willSleep` and `didWake`. A dark wake — Wi-Fi coming back for a
    /// maintenance window — posts neither notification, so the machine can be awake
    /// enough to rebuild a session while this is still true.
    private var isAsleep = false
    /// When the running session was established, compared against `lastSleepAt`.
    /// Left `nil` for a session built while the machine was asleep: such a session
    /// has the rest of the sleep still ahead of it, so the wake has to rebuild it.
    private var sessionEstablishedAt: Date?
    /// The uplink the running session was built on, recorded when it connects.
    private var sessionUplink: SystemUplinkInventory.Uplink?
    /// Set when a session was torn down because the uplink vanished, so the next
    /// uplink to appear reconnects instead of leaving the user disconnected.
    private var awaitsUplinkToReconnect = false

    nonisolated static let subsystem = "app"
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
    private var deferredProxyRestoreTask: Task<Void, Never>?
    private var deferredProxyRestoreFailedAt: SuspendingClock.Instant?
    private var pendingOperationCount = 0
    /// Only the latest pick is retained while a connect is touching the machine.
    private var pendingConnectionSelectionID: UUID?
    private var connectionTask: (operationID: UUID, task: Task<Void, Never>)?
    private var hasObservedInitialConnectionState = false
    private var isLaunchConnectionPending = false
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
        let leakGuard = LeakGuardService()
        self.init(
            parser: ConnectionLinkParser(),
            store: ConfigurationStore(),
            connectionProviderFactory: ConnectionProviderFactory(leakGuard: leakGuard),
            leakGuard: leakGuard,
            subscriptionClient: SubscriptionClient(),
            // The same guard the session arms: a health check leaves through the
            // physical uplink, so while the guard filters that uplink the check has
            // to hold its own server open for the seconds it takes to ask.
            healthProbeService: ConnectionHealthProbeService(
                uplinkExemption: LeakGuardProbeExemption(leakGuard: leakGuard)
            )
        )
    }

    init(
        parser: ConnectionLinkParser,
        store: ConfigurationStore,
        connectionProviderFactory: ConnectionProviderFactory,
        leakGuard: LeakGuardService = LeakGuardService(),
        subscriptionClient: SubscriptionClient,
        healthProbeService: ConnectionHealthProbeService,
        systemProxyService: SystemProxyService = SystemProxyService(),
        log: TeleportLog = .shared
    ) {
        self.parser = parser
        self.store = store
        let bundledSeeder = BundledConfigurationSeeder(parser: parser)
        self.bundledSeeder = bundledSeeder
        self.bundledSubscriptionTitles = bundledSeeder.subscriptionTitles()
        self.connectionProviderFactory = connectionProviderFactory
        self.leakGuard = leakGuard
        self.subscriptionClient = subscriptionClient
        self.healthProbeService = healthProbeService
        self.systemProxyService = systemProxyService
        self.log = log

        log.info(
            AppViewModel.subsystem,
            "launched build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")), state dumps \(SystemStateDump.isEnabled ? "on" : "off")"
        )

        let snapshot = store.load()
        var loadErrorMessage: String?
        if let loadError = store.lastLoadError {
            // The saved data could not be read (e.g. the Keychain key was still locked
            // right after boot) rather than there being none. Surface it instead of
            // silently showing an empty state, since a save from here would go on to
            // overwrite the real snapshot.
            loadErrorMessage = loadError.localizedDescription
        }

        lastError = loadErrorMessage
        connectionMode = snapshot.connectionMode
        subscriptionConnectionSort = snapshot.subscriptionConnectionSort
        showsLatencyInMenuBarPicker = snapshot.showsLatencyInMenuBarPicker
        animatesMenuBarIcon = snapshot.animatesMenuBarIcon
        showsInDock = snapshot.showsInDock
        connectsOnLaunch = snapshot.connectsOnLaunch
        isLaunchConnectionPending = snapshot.connectsOnLaunch && loadErrorMessage == nil
        splitTunnelProfiles = snapshot.splitTunnelProfiles
        selectedSplitTunnelProfileID = snapshot.selectedSplitTunnelProfileID
        isSplitTunnelEnabled = snapshot.isSplitTunnelEnabled
        isLeakGuardEnabled = snapshot.isLeakGuardEnabled
        geodataSettings = snapshot.geodataSettings
        startsAtLogin = loginItemService.isEnabled
        connectionProvider = connectionProviderFactory.makeProvider(for: snapshot.connectionMode)
        proxyEndpoint = snapshot.proxyEndpoint
        subscriptionSources = snapshot.subscriptionSources

        savedConnections = snapshot.savedConnections.map { savedConnection in
            // Only the parsed configuration is refreshed here; everything else the
            // connection carries — its name above all — belongs to the stored
            // connection, not to the link it was parsed from.
            var connection = savedConnection
            if let reparsedConfiguration = try? parser.parse(savedConnection.configuration.rawLink) {
                connection.configuration = reparsedConfiguration
            }
            connection.healthCheck = savedConnection.healthCheck?.normalizedForPersistence
            return connection
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
        observeNetworkPath()
        observeSystemWake()
        syncLeakGuardSetting()
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
        guard !isTerminating, hasObservedInitialConnectionState else { return false }
        if isOperationPending {
            return connectingSelection != nil
        }
        return connectionPresentation.canChangeSelection
    }

    var hasActiveConnectionSession: Bool {
        isOperationPending || connectionPresentation.hasActiveConnectionSession
    }

    func isConnectionInUse(id: UUID) -> Bool {
        guard hasActiveConnectionSession else { return false }
        return selectedConnectionID == id
            || connectingSelection?.connectionID == id
            || routedConnections.contains { $0.id == id }
            || inFlightConnectionRequest?.request.additionalConnections.contains { $0.id == id } == true
    }

    private func isSubscriptionInUse(id: UUID) -> Bool {
        importedConnections(for: id).contains { isConnectionInUse(id: $0.id) }
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

    /// The connect is waiting on the administrator prompt for the helper install.
    var isInstallingHelper: Bool {
        connectionState == .awaitingUserApproval
    }

    var statusSummary: String {
        if isInstallingHelper {
            return "Installing Teleport's helper. Enter your administrator password in the dialog."
        }
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
                case .wireGuardHandshake:
                    return "Handshake \(latency) ms"
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
            // A probe that could not run says why; it must not read as a verdict
            // about the server.
            if let failureSummary = healthCheck.failureSummary, !failureSummary.isEmpty {
                return failureSummary
            }
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
                case .wireGuardHandshake:
                    return "Handshake \(latency) ms"
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
            // A probe that could not run says why; it must not read as a verdict
            // about the server.
            if let failureSummary = healthCheck.failureSummary, !failureSummary.isEmpty {
                return failureSummary
            }
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

    /// Adds the subscription lists from `bundled-connections.json`. They point at
    /// servers run by third parties the user has no relation to, so they are
    /// never imported on their own: the user adds them from Settings, next to
    /// the warning that says what that means.
    func addBundledSubscriptions() {
        let seeded = bundledSeeder.seed(makeSnapshot())
        let newSources = seeded.subscriptionSources.filter { subscriptionSourcesByID[$0.id] == nil }
        let newConnections = seeded.savedConnections.filter { savedConnectionsByID[$0.id] == nil }
        guard !newSources.isEmpty || !newConnections.isEmpty else { return }

        subscriptionSources.append(contentsOf: newSources)
        savedConnections.append(contentsOf: newConnections)
        rebuildSubscriptionSourceIndexes()
        rebuildSavedConnectionIndexes()
        normalizeSelection()
        setStoredError(nil)
        persistSettingError()
        for (index, source) in newSources.enumerated() {
            refreshSubscription(id: source.id, autoSelectFirstImported: index == 0 && savedConnections.isEmpty)
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

    /// Re-parses a hand-added connection in place, so a peer whose endpoint, DNS
    /// or MTU changed does not have to be deleted and re-added — the identity the
    /// rest of the app keys on (`id`, and with it the name and any split-tunnel
    /// rule pointing at it) survives the edit. Subscription-imported connections
    /// are excluded: the next refresh would overwrite the change.
    @discardableResult
    func updateConnection(id: UUID, from rawValue: String) -> Bool {
        guard let index = savedConnections.firstIndex(where: { $0.id == id }) else { return false }

        guard savedConnections[index].source == nil else {
            setStoredError("Imported connections are replaced on refresh, so they cannot be edited")
            return false
        }

        if isConnectionInUse(id: id) {
            setStoredError("Disconnect before editing this connection")
            return false
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setStoredError("Paste a connection URL or configuration first")
            return false
        }

        do {
            savedConnections[index].configuration = try parser.parse(trimmed)
            rebuildSavedConnectionIndexes()
            healthChecksByConnectionID.removeValue(forKey: id)
            setStoredError(nil)
            updateMenuBarAnimation()
            try persist()
            enqueueHealthProbes(for: [id], force: true, priority: true)
            return true
        } catch {
            setStoredError(error.localizedDescription)
            return false
        }
    }

    func removeConnection(id: UUID) {
        guard let index = savedConnections.firstIndex(where: { $0.id == id }) else { return }

        if isConnectionInUse(id: id) {
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

        if isSubscriptionInUse(id: id) {
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

        if let connectingSelection, isOperationPending {
            // A cancelled attempt cannot be uncancelled. Picking its target again
            // requests a fresh attempt if cancellation actually takes effect.
            let wasCancelled = connectionTask?.task.isCancelled == true
            pendingConnectionSelectionID = id == connectingSelection.connectionID && !wasCancelled ? nil : id
            if pendingConnectionSelectionID != nil {
                connectionTask?.task.cancel()
            }
        } else if shouldReconnect {
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

            if urlChanged, isSubscriptionInUse(id: id) {
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

        isLaunchConnectionPending = false
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

    func setConnectsOnLaunch(_ connectsOnLaunch: Bool) {
        guard connectsOnLaunch != self.connectsOnLaunch else { return }
        self.connectsOnLaunch = connectsOnLaunch
        if !connectsOnLaunch { isLaunchConnectionPending = false }
        schedulePersist()
    }

    func setShowsInDock(_ showsInDock: Bool) {
        guard showsInDock != self.showsInDock else { return }
        self.showsInDock = showsInDock
        schedulePersist()
    }

    func setLeakGuardEnabled(_ isEnabled: Bool) {
        guard isEnabled != isLeakGuardEnabled else { return }
        isLeakGuardEnabled = isEnabled
        schedulePersist()
        log.info(Self.subsystem, "leak guard turned \(isEnabled ? "on" : "off")")
        let leakGuard = leakGuard
        Task { await leakGuard.setEnabled(isEnabled) }
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
    /// toggles) into a single TUN reconnect once the user settles, instead of
    /// tearing the tunnel down and back up on every individual change.
    private func scheduleSplitTunnelLiveApply() {
        guard connectionMode == .tun, hasActiveConnectionSession else { return }
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
        guard !isTerminating, connectionMode == .tun, hasEstablishedConnection else { return }
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
        guard connectionMode == .tun, hasEstablishedConnection else { return }
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

    /// Deletes a downloaded custom override so TUN mode falls back to Teleport's
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
    /// TUN mode is already connected instead of waiting for the user to notice.
    private func applyGeodataLiveIfNeeded() {
        guard connectionMode == .tun, hasEstablishedConnection else { return }
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

    func refreshHelperInstallationStatus() {
        isHelperInstalled = PrivilegedHelperUninstaller.isInstalled()
    }

    /// Removes the privileged helper after an administrator prompt. A running
    /// session is torn down first and the leak guard released, while the helper is
    /// still there to do both; the uninstall then flushes the guard's anchor anyway
    /// in case the release did not reach it. Counted as a connection operation so
    /// nothing connects, and in TUN mode reinstalls, halfway through.
    func uninstallHelper() {
        refreshHelperInstallationStatus()
        guard isHelperInstalled else {
            helperUninstallMessage = "Teleport's helper is not installed; there is nothing to remove."
            return
        }
        guard !isUninstallingHelper, !isTerminating else { return }
        isUninstallingHelper = true
        helperUninstallMessage = nil
        awaitsUplinkToReconnect = false
        log.info(Self.subsystem, "helper uninstall requested: mode \(connectionMode), session \(hasActiveConnectionSession ? "active" : "none")")
        let provider = connectionProvider
        let leakGuard = leakGuard
        let uninstaller = helperUninstaller
        let operationID = UUID()
        beginConnectionOperation()
        Task { @MainActor [weak self] in
            // A teardown that fails is not a reason to keep the helper: the user
            // asked for it gone, and the lease and anchor flush cover what it left.
            try? await provider.disconnect()
            await leakGuard.disarm()
            do {
                try await uninstaller.uninstall()
                self?.helperUninstallMessage = "Teleport's helper was removed. TUN mode will ask to install it again on the next connect."
                self?.log.info(AppViewModel.subsystem, "helper uninstalled")
            } catch {
                self?.helperUninstallMessage = error.localizedDescription
                self?.log.warn(AppViewModel.subsystem, "helper uninstall failed: \(LogFormat.error(error))")
            }
            self?.refreshHelperInstallationStatus()
            self?.isUninstallingHelper = false
            self?.finishConnectionOperation(operationID)
        }
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
        isLaunchConnectionPending = false
        guard let selectedConfiguration else {
            setStoredError("Add and select a connection first")
            return
        }

        awaitsUplinkToReconnect = false
        log.info(Self.subsystem, "connect requested: mode \(connectionMode), server \(LogFormat.host(selectedConfiguration.host)):\(selectedConfiguration.port), split tunnel \(isSplitTunnelEnabled ? "on" : "off") with \(activeSplitTunnelRules.count) rules")
        SystemStateDump.capture("before connect", log: log)
        startConnection(using: selectedConfiguration)
    }

    /// A disconnect the user asked for. The guard comes off with it: someone who
    /// disconnects on purpose is asking to be back on the network, not filtered.
    func disconnect() {
        isLaunchConnectionPending = false
        releaseLeakGuard()
        tearDownSession()
    }

    /// The same teardown without touching the guard, for the paths that tear a
    /// session down in order to build another one. Releasing and re-arming around
    /// those would open the window the guard exists to close — and, since both are
    /// asynchronous, could land in either order.
    private func tearDownSession() {
        guard !isTerminating else { return }
        pendingConnectionSelectionID = nil
        connectingSelection = nil
        awaitsUplinkToReconnect = false
        let provider = connectionProvider
        let operationID = UUID()
        log.info(Self.subsystem, "disconnect requested: mode \(connectionMode)")
        SystemStateDump.capture("before disconnect", log: log)
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
            // Captured whether or not the disconnect reported success: routes and
            // proxy settings left behind by a failed teardown are exactly what this
            // dump exists to show.
            SystemStateDump.capture("after disconnect", log: self?.log ?? .shared)
            self?.finishConnectionOperation(operationID)
        }
    }

    /// How long a quit waits for the session's teardown. Long enough for a
    /// helper stop and a proxy restore that each time out once; short enough that
    /// a teardown stuck behind something is not a reason to force-quit the app.
    static let terminationTeardownLimit: Duration = .seconds(20)

    func handleAppTermination(
        teardownLimit: Duration = AppViewModel.terminationTeardownLimit,
        completion: @escaping () -> Void
    ) {
        isTerminating = true
        pendingConnectionSelectionID = nil
        connectingSelection = nil
        log.info(Self.subsystem, "terminating")
        let provider = connectionProvider
        let leakGuard = leakGuard
        networkPathObserver?.stop()
        systemWakeObserver?.stop()
        Task { @MainActor [weak self] in
            let tornDown = await Self.awaitTeardown({ try? await provider.disconnect() }, limit: teardownLimit)
            if tornDown {
                // After the teardown, not before: the guard covers the moment the
                // tunnel's routes come out from under the machine.
                await leakGuard.disarm()
            } else {
                // The guard stays with the helper, whose lease flushes it; the
                // proxy snapshot is restored on the next launch.
                self?.log.warn(Self.subsystem, "teardown did not finish within \(teardownLimit); quitting with the session's cleanup left to the helper's lease and the next launch")
            }
            self?.connectionStateTask?.cancel()
            // Anything still queued would otherwise be lost exactly when the log
            // matters most: a quit that follows something going wrong.
            self?.log.flush()
            completion()
        }
    }

    /// True once the teardown returns, false once the limit passes, whichever is
    /// first. Not a task group: that would wait for the stuck teardown as well,
    /// since cancelling it does not abort the operation queued behind it.
    private static func awaitTeardown(_ teardown: @escaping @Sendable () async -> Void, limit: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let outcome = TeardownOutcome(continuation)
            Task {
                await teardown()
                outcome.resolve(true)
            }
            Task {
                try? await Task.sleep(for: limit, clock: .suspending)
                outcome.resolve(false)
            }
        }
    }

    /// Every state change funnels through `applyConnectionState`, so logging here
    /// records transitions the app did not initiate too — a tunnel that dropped on
    /// its own is the case worth having in a file after the fact.
    private func logConnectionState(_ state: ConnectionState, isInitialState: Bool) {
        let prefix = isInitialState ? "initial connection state" : "connection state"
        switch state {
        case let .failed(failure):
            log.error(Self.subsystem, "\(prefix): failed — \(failure.summary)")
        case .connected:
            // Normally recorded when the session was requested, which is closer to
            // the moment the helper pinned its routes. Read here only for a session
            // this process did not start — one still up from a previous run.
            sessionUplink = sessionUplink ?? SystemUplinkInventory.current()
            awaitsUplinkToReconnect = false
            log.info(Self.subsystem, "\(prefix): connected (mode \(connectionMode)) over uplink \(sessionUplink?.summary ?? "<unknown>")")
            SystemStateDump.capture("after connect", log: log)
        case .awaitingUserApproval:
            log.info(Self.subsystem, "\(prefix): awaiting administrator approval for the helper install")
        default:
            log.info(Self.subsystem, "\(prefix): \(state)")
        }
    }

    /// A tunnel pins its proxy-server routes to the gateway that was current when
    /// it started, and installs both default halves through its TUN. Neither is
    /// revisited afterwards, so an uplink that changes underneath a running session
    /// leaves the machine routing into a tunnel whose own transport can no longer
    /// get out — reachable only by tearing the session down.
    private func observeNetworkPath() {
        let observer = NetworkPathObserver(
            onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reconnectAsSoonAsAnUplinkAppears()
                }
            },
            onSettledChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reconcileSessionWithUplink()
                }
            }
        )
        networkPathObserver = observer
        observer.start()
    }

    /// A routed session does not survive sleep in practice: after wake its Xray
    /// reaches the server but no tunneled stream receives a byte, and only a
    /// rebuild recovers it. The uplink is usually unchanged, so the path observer
    /// would keep it running; wake itself is the trigger. System Proxy mode is
    /// left alone, as nothing pins it to the machine's sleep state.
    private func observeSystemWake() {
        let observer = SystemWakeObserver(
            onSleep: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.lastSleepAt = Date()
                    self?.isAsleep = true
                }
            },
            onWake: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.isAsleep = false
                    self?.rebuildSessionAfterWake()
                }
            }
        )
        systemWakeObserver = observer
        observer.start()
    }

    private func rebuildSessionAfterWake() {
        guard !isTerminating, connectionMode == .tun, hasEstablishedConnection, !isOperationPending else { return }
        // A session built after the machine went to sleep did not live through the
        // sleep and does not need rebuilding. The path observer routinely gets
        // there first — a wake onto a different network is a path change, and its
        // notification arrives before this one — and rebuilding again would tear
        // down a working tunnel seconds old, for a second window of direct routing.
        if let lastSleepAt, let sessionEstablishedAt, sessionEstablishedAt > lastSleepAt {
            log.info(Self.subsystem, "machine woke from sleep; session is newer than the sleep, keeping it")
            return
        }
        log.warn(Self.subsystem, "machine woke from sleep; rebuilding the session over \(SystemUplinkInventory.current()?.summary ?? "<no uplink>")")
        sessionUplink = nil
        rebuildSessionForNewUplink()
    }

    /// The guard's own copy of the setting: it runs off the main actor and cannot
    /// read the published one.
    private func syncLeakGuardSetting() {
        let leakGuard = leakGuard
        let isEnabled = isLeakGuardEnabled
        Task { await leakGuard.setEnabled(isEnabled) }
    }

    private func armLeakGuardStandby() {
        guard isLeakGuardEnabled, connectionMode == .tun else { return }
        let leakGuard = leakGuard
        Task { await leakGuard.armStandby() }
    }

    private func releaseLeakGuard() {
        let leakGuard = leakGuard
        Task { await leakGuard.disarm() }
    }

    /// The uncoalesced half of the path observer, and the only thing it is used
    /// for: a session that is waiting to be rebuilt is rebuilt the moment there is
    /// an uplink to rebuild it on.
    ///
    /// Nothing is running, so there is no session for an intermediate path state to
    /// damage, and the quiet period would only extend the window in which the
    /// machine routes directly. A router address is still required: an interface
    /// that has come up without one cannot carry a tunnel yet, and the settled
    /// callback will come back to it.
    private func reconnectAsSoonAsAnUplinkAppears() {
        guard !isTerminating, awaitsUplinkToReconnect, !isOperationPending else { return }
        guard let currentUplink = SystemUplinkInventory.current(), currentUplink.routerAddress != nil else { return }
        awaitsUplinkToReconnect = false
        log.info(Self.subsystem, "uplink is back (\(currentUplink.summary)); reconnecting without waiting for the path to settle")
        reconnectToSelectedConnection(afterUplinkChange: true)
    }

    private func reconcileSessionWithUplink() {
        guard !isTerminating else { return }

        let currentUplink = SystemUplinkInventory.current()

        if awaitsUplinkToReconnect {
            guard currentUplink != nil else { return }
            awaitsUplinkToReconnect = false
            log.info(Self.subsystem, "uplink is back (\(currentUplink?.summary ?? "<unknown>")); reconnecting")
            reconnectToSelectedConnection(afterUplinkChange: true)
            return
        }

        guard hasEstablishedConnection || isOperationPending else {
            // Nothing is routing. If an earlier teardown could not put a service's
            // proxy settings back because that service was down, the path change
            // that just fired may be it coming back — the moment to finish the job,
            // rather than waiting for the next launch.
            restoreDeferredProxyStateIfNeeded()
            return
        }

        // System Proxy mode points applications at a local port, which no change of
        // uplink invalidates. Only a routed session pins itself to one.
        guard connectionMode == .tun, hasEstablishedConnection, !isOperationPending else { return }

        switch UplinkChangeDecision.decide(sessionUplink: sessionUplink, currentUplink: currentUplink) {
        case .keepRunning:
            return
        case .tearDownAndWaitForUplink:
            log.warn(Self.subsystem, "uplink \(sessionUplink?.summary ?? "<unknown>") is gone; tearing down the session, guard \(isLeakGuardEnabled ? "armed" : "off")")
            sessionUplink = nil
            // Armed before the teardown, and kept across it: this is the longest
            // window of the two — it lasts until an uplink comes back, which on a
            // commute is the commute.
            armLeakGuardStandby()
            tearDownSession()
            // After, not before: the teardown clears the flag so that a user who
            // disconnects on purpose is never reconnected behind their back.
            awaitsUplinkToReconnect = true
        case .reconnect:
            log.warn(Self.subsystem, "uplink changed from \(sessionUplink?.summary ?? "<unknown>") to \(currentUplink?.summary ?? "<unknown>"); rebuilding the session")
            sessionUplink = nil
            rebuildSessionForNewUplink()
        }
    }

    /// Disconnect and reconnect as one operation, so the tunnel's routes are removed
    /// before new ones are pinned to the new gateway. Reconnecting without waiting
    /// would install the second set on top of the first.
    private func rebuildSessionForNewUplink() {
        guard !isTerminating else { return }
        // Armed before the teardown so no packet leaves between the tunnel's routes
        // being removed and the next tunnel's being installed.
        armLeakGuardStandby()
        let provider = connectionProvider
        let operationID = UUID()
        beginConnectionOperation()
        Task { @MainActor [weak self] in
            try? await provider.disconnect()
            self?.finishConnectionOperation(operationID)
            guard let self, !self.isTerminating else { return }
            guard SystemUplinkInventory.current() != nil else {
                self.awaitsUplinkToReconnect = true
                return
            }
            self.reconnectToSelectedConnection(afterUplinkChange: true)
        }
    }

    /// A teardown that ran while an interface was down could not put that service's
    /// proxy settings back, and kept its entry instead of discarding it. Launching
    /// with no session running is the moment to finish that.
    /// One restore at a time, and after a failure none for a while. Path changes
    /// arrive in bursts, and each restore that times out takes 5 s per networksetup
    /// call; the log once held 60 such failures in 50 minutes, with two restores
    /// overlapping and each deleting a snapshot the other had already read.
    private static let deferredProxyRestoreRetryInterval: Duration = .seconds(30)

    private func restoreDeferredProxyStateIfNeeded() {
        guard deferredProxyRestoreTask == nil else { return }
        if let failedAt = deferredProxyRestoreFailedAt,
           SuspendingClock().now - failedAt < Self.deferredProxyRestoreRetryInterval {
            return
        }
        let service = systemProxyService
        let log = log
        deferredProxyRestoreTask = Task { @MainActor [weak self] in
            let failed = await Task.detached(priority: .utility) { () -> Bool in
                do {
                    try service.restoreDeferredProxyStateIfNeeded()
                    return false
                } catch {
                    log.error(AppViewModel.subsystem, "could not restore deferred proxy state: \(LogFormat.error(error))")
                    return true
                }
            }.value
            self?.deferredProxyRestoreFailedAt = failed ? SuspendingClock().now : nil
            self?.deferredProxyRestoreTask = nil
            self?.connectOnLaunchIfNeeded()
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
        if state != connectionState || isInitialState {
            logConnectionState(state, isInitialState: isInitialState)
        }
        if isInitialState, !state.isConnected {
            // Only with nothing routing: while a session from a previous run is
            // still up, the snapshot describes settings that are meant to stay
            // suspended until it stops.
            restoreDeferredProxyStateIfNeeded()
        }
        connectionState = state

        switch state {
        case let .failed(failure):
            lastError = failure.summary
            lastErrorDetails = failure.details
            inFlightConnectionRequest = nil
        case .connected:
            // A dark wake brings the uplink back for a maintenance window, and the
            // path observer rebuilds the session on it. That session is not newer
            // than the sleep — the sleep has not ended — so it is recorded as having
            // no establishment time at all, and the wake that follows rebuilds it.
            sessionEstablishedAt = isAsleep ? nil : Date()
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
            sessionEstablishedAt = nil
            inFlightConnectionRequest = nil
            appliedSplitTunnelRules = nil
            appliedSplitTunnelDefaultAction = nil
            pendingSplitTunnelLiveApply = false
        case .preparing, .awaitingUserApproval, .connecting, .disconnecting:
            break
        }
        updateMenuBarAnimation()
        connectOnLaunchIfNeeded()
    }

    private func connectOnLaunchIfNeeded() {
        guard isLaunchConnectionPending, hasObservedInitialConnectionState else { return }
        switch connectionState {
        case .preparing:
            return
        case .idle:
            // Finish restoring old proxy settings before starting a new session.
            guard deferredProxyRestoreTask == nil else { return }
            isLaunchConnectionPending = false
            guard deferredProxyRestoreFailedAt == nil, canConnect else { return }
            connect()
        case .connected, .failed, .awaitingUserApproval, .connecting, .disconnecting:
            // An existing session or a failed recovery consumes the launch attempt.
            isLaunchConnectionPending = false
        }
    }

    private var hasEstablishedConnection: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    private func reconnectToSelectedConnection(afterUplinkChange: Bool = false) {
        guard let selectedConfiguration else {
            setStoredError("Add and select a connection first")
            return
        }
        startConnection(using: selectedConfiguration, afterUplinkChange: afterUplinkChange)
    }

    /// An uplink can have a router address before its resolver answers, and a
    /// reconnect started on it then fails on the lookup of the proxy server. The
    /// path has usually stopped changing by that time, so no further notification
    /// would start another attempt, and the leak guard armed for the reconnect
    /// would keep the machine off the network until the user stepped in.
    private func retryReconnectAfterUplinkChange() {
        awaitsUplinkToReconnect = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            // A connect or disconnect the user asked for in the meantime cleared
            // the flag, and this does nothing.
            self?.reconnectAsSoonAsAnUplinkAppears()
        }
    }

    private func startConnection(using configuration: ConnectionConfiguration, afterUplinkChange: Bool = false) {
        guard !isTerminating else { return }

        // The helper pins routes to the gateway that is current when its script
        // runs, which is moments from now; the connected state can arrive seconds
        // later, by which time a roaming machine may already be on another one.
        sessionUplink = SystemUplinkInventory.current()
        let request = makeConnectionRequest(configuration: configuration)
        let provider = connectionProvider
        let operationID = UUID()
        connectingSelection = (operationID, request.defaultConnection.id)
        beginConnectionOperation()
        inFlightConnectionRequest = (operationID, request)
        setStoredError(nil)

        let task = Task { @MainActor [weak self] in
            do {
                try await provider.connect(request)
                // Past its commit point a backend may finish despite cancellation.
                // If that is the latest choice again, it needs no second connect.
                if self?.connectingSelection?.operationID == operationID,
                   self?.pendingConnectionSelectionID == request.defaultConnection.id {
                    self?.pendingConnectionSelectionID = nil
                }
                self?.finishConnectionOperation(operationID, discardPendingRequest: false)
                self?.applyDeferredSplitTunnelRulesLiveIfNeeded()
            } catch {
                // A connect cancelled by a disconnect or quit is what the user asked
                // for, not a failure to report.
                if !(error is CancellationError),
                   await provider.currentState().isTerminalFailure == false {
                    self?.applyConnectionError(error)
                }
                let hasPendingSelection = self?.pendingConnectionSelectionID != nil
                self?.finishConnectionOperation(operationID, discardPendingRequest: true)
                if afterUplinkChange && !hasPendingSelection {
                    switch error as? XrayTunConnectionError {
                    case .proxyAddressResolutionFailed, .proxyRouteUnavailable:
                        self?.retryReconnectAfterUplinkChange()
                    default:
                        break
                    }
                }
            }
        }
        connectionTask = (operationID, task)
    }

    private func beginConnectionOperation() {
        pendingOperationCount += 1
        isOperationPending = true
    }

    private func finishConnectionOperation(_ operationID: UUID, discardPendingRequest: Bool = false) {
        if connectionTask?.operationID == operationID {
            connectionTask = nil
        }
        if connectingSelection?.operationID == operationID {
            connectingSelection = nil
        }
        if discardPendingRequest, inFlightConnectionRequest?.operationID == operationID {
            inFlightConnectionRequest = nil
        }
        pendingOperationCount = max(0, pendingOperationCount - 1)
        isOperationPending = pendingOperationCount > 0
        guard !isOperationPending, !isTerminating, let pendingID = pendingConnectionSelectionID else { return }
        pendingConnectionSelectionID = nil
        guard pendingID == selectedConnectionID, savedConnectionsByID[pendingID] != nil else { return }
        reconnectToSelectedConnection()
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
            ),
            usesLeakGuard: isLeakGuardEnabled
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
        if isSubscriptionInUse(id: id) {
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

                let candidates = try await subscriptionClient.fetchCandidates(from: url)
                let importResult = try SubscriptionImportProcessor.importEntries(
                    candidates: candidates,
                    parser: parser,
                    sourceID: source.id,
                    filterDuplicateImports: source.filterDuplicateImports
                )

                self?.applyImportedEntries(
                    importResult.importedEntries,
                    skippedCount: importResult.skippedCount,
                    importStatus: importResult.statusMessage,
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
        importStatus: String?,
        to sourceID: UUID,
        fetchedAt: Date,
        autoSelectFirstImported: Bool
    ) {
        if isSubscriptionInUse(id: sourceID) {
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
            $0.lastError = importStatus
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

        let workItem = DispatchWorkItem { [store, weak self] in
            do {
                try store.save(snapshot)
            } catch {
                Task { @MainActor in
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
            showsInDock: showsInDock,
            connectsOnLaunch: connectsOnLaunch,
            splitTunnelProfiles: splitTunnelProfiles,
            selectedSplitTunnelProfileID: selectedSplitTunnelProfileID,
            isSplitTunnelEnabled: isSplitTunnelEnabled,
            isLeakGuardEnabled: isLeakGuardEnabled,
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

/// Resumes a continuation on the first of two outcomes and drops the second.
nonisolated private final class TeardownOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ tornDown: Bool) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: tornDown)
    }
}
