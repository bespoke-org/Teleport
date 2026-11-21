import AppKit
import Combine
import CoreFoundation
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
    /// A new provider reports preparing while checking for an existing session.
    /// Keep that lookup distinct from starting a connection in the settings UI.
    @Published private(set) var isResolvingConnectionProvider = true
    @Published private(set) var lastError: String?
    @Published private(set) var lastErrorDetails: String?
    /// Connection diagnostics survive unrelated import, edit, and persistence actions.
    @Published private(set) var connectionError: ConnectionFailure?
    @Published private(set) var isLeakGuardHoldingUplink = false
    @Published private(set) var proxyEndpoint: ProxyEndpoint
    @Published private(set) var connectionMode: ConnectionMode
    @Published private(set) var subscriptionConnectionSort: SubscriptionConnectionSort
    @Published private(set) var showsLatencyInMenuBarPicker: Bool
    @Published private(set) var animatesMenuBarIcon: Bool
    @Published private(set) var showsInDock: Bool
    @Published private(set) var connectsOnLaunch: Bool
    @Published private(set) var isLeakGuardEnabled: Bool
    @Published private(set) var splitTunnelProfiles: [SplitTunnelProfile]
    /// The document open in Routing; target assignments resolve independently.
    @Published private(set) var selectedSplitTunnelProfileID: UUID?
    @Published private(set) var isSplitTunnelEnabled: Bool
    @Published private(set) var tunnelAssignments: [TunnelProfileAssignment]
    @Published private(set) var geodataSettings: GeodataSourceSettings
    @Published private(set) var geodataLastAttemptSources: GeodataSources?
    @Published private(set) var isSplitTunnelGeodataReady = false
    var updatingGeodataKinds: Set<GeodataKind> { geodataUpdateCoordinator.updatingKinds }
    @Published private(set) var startsAtLogin: Bool
    /// Whether the privileged helper's files are on disk; see
    /// `PrivilegedHelperUninstaller.isInstalled`. Read on demand, not watched.
    @Published private(set) var isHelperInstalled = false
    @Published private(set) var isUninstallingHelper = false
    /// The outcome of the last uninstall, shown under the button that started it.
    @Published private(set) var helperUninstallMessage: String?
    @Published private(set) var helperUninstallFailure: ConnectionFailure?
    @Published private(set) var isOperationPending = false
    /// Kept until the connect call returns, even if its final state arrives first.
    @Published private var connectingSelection: UUID?
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
    private let subscriptionClient: SubscriptionClient
    private let healthProbeService: ConnectionHealthProbeService
    private var splitTunnelGeodataMatcher: SplitTunnelGeodataMatcher
    private var matcherSources: GeodataSources?
    private let loginItemService = LoginItemService()
    private let helperUninstaller = PrivilegedHelperUninstaller()
    private let persistenceQueue = DispatchQueue(label: "dev.x.teleport.persistence", qos: .utility)
    private let log: TeleportLog
    /// System observations feed the intent runtime; only that runtime executes
    /// lifecycle transitions independently of presentation.
    private let sessionLifecycle: SessionLifecycleCoordinator
    private let connectionIntent: ConnectionIntentRuntime
    @Published private(set) var isWaitingForNetwork = false
    /// Held across teardowns and rebuilds, which is where the leak it guards
    /// against happens. Owned here rather than by a provider for that reason.
    private let leakGuard: LeakGuardService

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
    private var leakGuardStateTask: Task<Void, Never>?
    @Published private(set) var isDisconnecting = false
    private var hasObservedInitialConnectionState = false
    private var allowsLaunchConnection = false
    private var lastPresentedFailure: (revision: UInt64, error: ConnectionFailure)?
    private var geodataRevision: UInt64 = 0
    private var isLaunchConnectionPending = false
    private var isTerminating = false
    private var persistWorkItem: DispatchWorkItem?
    private var splitTunnelApplyWorkItem: DispatchWorkItem?
    private var pendingSplitTunnelLiveApply = false
    /// Subscription imports persist immediately but leave the current session
    /// alone, including callbacks from a connect or edit already in progress.
    private var hasDeferredSubscriptionRoutingChanges = false
    /// The request whose `connect` is still running, kept so the applied split-tunnel
    /// policy can be recorded once the provider reports `.connected`. Not a queue.
    private var inFlightConnectionRequest: ConnectionRequest?
    private var appliedSplitTunnelRules: [SplitTunnelRule]?
    private var appliedConnectionIDs: Set<UUID> = []
    private var appliedSplitTunnelDefaultAction: SplitTunnelRuleAction?
    private var appliedGeodataSources: GeodataSources?
    private let geodataUpdateCoordinator: GeodataUpdateCoordinator
    // Removed subscription entries remain available only to the running session's
    // selection. They are never written back into the refreshed subscription.
    private var removedSessionConnections: [UUID: SavedConnection] = [:]
    private let profileGeodataLibrary: ProfileGeodataLibrary
    private var savedConnectionsByID: [UUID: SavedConnection] = [:]
    private var importedConnectionsBySourceID: [UUID: [SavedConnection]] = [:]
    private var importedConnectionCountsBySourceID: [UUID: Int] = [:]
    private var subscriptionSourcesByID: [UUID: SubscriptionSource] = [:]
    private var subscriptionRefreshTokens: [UUID: UUID] = [:]

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
        geodataUpdateCoordinator: GeodataUpdateCoordinator? = nil,
        systemObserverFactory: any SystemObserverFactoring = SystemObserverFactory(),
        currentUplink: @escaping @Sendable () -> SystemUplinkInventory.Uplink? = { SystemUplinkInventory.current() },
        log: TeleportLog = .shared
    ) {
        let geodataService = GeodataUpdateService(fileManager: store.fileManager)
        let geodataUpdateCoordinator = geodataUpdateCoordinator ?? GeodataUpdateCoordinator(service: geodataService)
        splitTunnelGeodataMatcher = SplitTunnelGeodataMatcher(service: geodataService)
        self.parser = parser
        self.store = store
        let bundledSeeder = BundledConfigurationSeeder(parser: parser)
        self.bundledSeeder = bundledSeeder
        self.bundledSubscriptionTitles = bundledSeeder.subscriptionTitles()
        self.connectionProviderFactory = connectionProviderFactory
        self.leakGuard = leakGuard
        self.subscriptionClient = subscriptionClient
        self.healthProbeService = healthProbeService
        self.geodataUpdateCoordinator = geodataUpdateCoordinator
        profileGeodataLibrary = ProfileGeodataLibrary(coordinator: geodataUpdateCoordinator)
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
        tunnelAssignments = snapshot.tunnelAssignments
        startsAtLogin = loginItemService.isEnabled
        let provider = connectionProviderFactory.makeProvider(for: snapshot.connectionMode)
        let connectionIntent = ConnectionIntentRuntime(
            provider: provider, mode: snapshot.connectionMode, guardService: leakGuard,
            proxyRestorer: DeferredProxyRestorer(service: systemProxyService, log: log), log: log
        )
        self.connectionIntent = connectionIntent
        self.sessionLifecycle = SessionLifecycleCoordinator(
            systemObserverFactory: systemObserverFactory,
            uplinkProvider: currentUplink,
            runtime: connectionIntent
        )
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
        normalizeTunnelProfileSelection()
        geodataUpdateCoordinator.stateDidChange = { [weak self] in self?.objectWillChange.send() }
        geodataUpdateCoordinator.didFinish = { [weak self] kind, outcome in
            self?.applyGeodataUpdateResult(kind: kind, outcome: outcome)
        }
        geodataUpdateCoordinator.batchDidComplete = { [weak self] batch in
            if !batch.changedKinds.isEmpty { self?.applyGeodataLiveIfNeeded() }
            if self?.pendingSplitTunnelLiveApply == true { self?.applyDeferredSplitTunnelRulesLiveIfNeeded() }
        }
        profileGeodataLibrary.didChange = { [weak self] in self?.objectWillChange.send() }
        profileGeodataLibrary.didCache = { [weak self] key in
            guard let self else { return }
            let selected = self.selectedProfileGeodataSources
            let value = key.kind == .geosite ? selected.geositeURLString : selected.geoipURLString
            if value == key.source.absoluteString {
                if self.geodataLastAttemptSources == selected { self.setGeodataError(kind: key.kind, error: nil) }
                self.prepareSplitTunnelGeodataMatcher(reload: true)
            }
        }
        for kind in GeodataKind.allCases {
            if let value = geodataURLString(for: kind), let source = validatedGeodataURL(value), hasCustomGeodata(kind: kind) {
                profileGeodataLibrary.recordReady(kind: kind, source: source, date: geodataLastUpdatedAt(for: kind), cached: false)
            }
        }
        for profile in splitTunnelProfiles where profile.subscriptionSourceID != nil || profile.id != connectionTunnelProfile?.id {
            profileGeodataLibrary.preload(sources: profile.geodataSources ?? GeodataSources())
        }
        prepareSplitTunnelGeodataMatcher()
        observeConnectionState()
        observeLeakGuardState()
        let adoptionRequest = selectedConfiguration.map { makeConnectionRequest(configuration: $0) }
        let sessionLifecycle = self.sessionLifecycle
        Task { [weak self] in
            await sessionLifecycle.start()
            await connectionIntent.start(adopting: adoptionRequest) { [weak self] request in
                guard let profileName = request.geodataProfileName else { return }
                try await self?.prepareConnectionGeodata(request.geodataSources, profileName: profileName)
            }
        }
        syncLeakGuardSetting()
        startAutoRefreshTimer()
        updateMenuBarAnimation()
        scheduleInitialHealthRefresh()
        refreshUnfetchedSubscriptionsIfNeeded()
    }

    deinit {
        connectionStateTask?.cancel()
        leakGuardStateTask?.cancel()
    }

    var selectedConnection: SavedConnection? {
        guard let selectedConnectionID else { return savedConnections.first }
        return savedConnectionsByID[selectedConnectionID] ?? removedSessionConnections[selectedConnectionID] ?? savedConnections.first
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
                  let connection = savedConnectionsByID[connectionID] ?? removedSessionConnections[connectionID] else { continue }
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
            && !isWaitingForNetwork
            && !isDisconnecting
            && hasObservedInitialConnectionState
            && selectedConfiguration != nil
            && !isOperationPending
            && connectionPresentation.canConnect
    }

    var canDisconnect: Bool {
        !isTerminating
            && !isUninstallingHelper
            && !isDisconnecting
            && connectionPhase != .stopping
            && hasObservedInitialConnectionState
            && (isOperationPending || isWaitingForNetwork || connectionPresentation.canDisconnect)
    }

    var canAllowDirectTraffic: Bool {
        !isTerminating && !isOperationPending && connectionState == .idle && isLeakGuardHoldingUplink
    }

    var canChangeSelection: Bool {
        guard !isTerminating, hasObservedInitialConnectionState else { return false }
        if isOperationPending {
            return connectingSelection != nil
        }
        return connectionPresentation.canChangeSelection
    }

    var isConnecting: Bool { isOperationPending && connectingSelection != nil }

    var hasActiveConnectionSession: Bool {
        isOperationPending || isWaitingForNetwork || connectionPresentation.hasActiveConnectionSession
    }

    func isConnectionInUse(id: UUID) -> Bool {
        guard hasActiveConnectionSession else { return false }
        return selectedConnectionID == id
            || appliedConnectionIDs.contains(id)
            || removedSessionConnections[id] != nil
            || connectingSelection == id
            || routedConnections.contains { $0.id == id }
            || inFlightConnectionRequest?.connections.contains { $0.id == id } == true
    }

    private func isSubscriptionInUse(id: UUID) -> Bool {
        importedConnections(for: id).contains { isConnectionInUse(id: $0.id) }
            || (hasActiveConnectionSession && removedSessionConnections.values.contains { $0.source?.subscriptionSourceID == id })
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
        guard let profile = connectionTunnelProfile, routingIsEnabled(for: profile) else { return [] }
        return profile.rules.filter { $0.isEnabled }
    }

    /// Default action of the selected profile, exposed for the settings picker.
    var splitTunnelDefaultAction: SplitTunnelRuleAction {
        selectedSplitTunnelProfile?.defaultAction ?? .proxy
    }

    /// The catch-all outbound that actually reaches Xray. When split tunneling is
    /// off we keep the classic full-tunnel behavior (everything proxied) so the
    /// profile's default only takes effect while the feature is enabled.
    private var activeSplitTunnelDefaultAction: SplitTunnelRuleAction {
        guard let profile = connectionTunnelProfile, routingIsEnabled(for: profile) else { return .proxy }
        return profile.defaultAction
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
            return savedConnections.isEmpty ? "Add a portal or subscription in Settings to get started" : "Select a portal to get started"
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
        healthSummary(for: healthCheck(for: connection))
    }

    func healthSnapshotForPicker() -> [UUID: ConnectionHealthCheck] {
        Dictionary(uniqueKeysWithValues: connectionPickerItems.map { ($0.id, healthCheck(for: $0.id)) })
    }

    func healthSummary(for healthCheck: ConnectionHealthCheck) -> String {
        ConnectionHealthFormatter.label(for: healthCheck)
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
            setStoredError("Paste a link or configuration, or choose a file first.")
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
            setStoredError("Imported portals are replaced on refresh, so they cannot be edited")
            return false
        }

        if isConnectionInUse(id: id) {
            setStoredError("Disconnect before editing this portal")
            return false
        }

        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setStoredError("Paste a portal URL or configuration first")
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
            setStoredError("Disconnect before removing the active portal")
            return
        }

        let removedConnection = savedConnections.remove(at: index)
        tunnelAssignments.removeAll { $0.target == .connection(id) }
        normalizeTunnelProfileSelection()
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
        subscriptionRefreshTokens.removeValue(forKey: id)
        splitTunnelProfiles.removeAll { $0.subscriptionSourceID == id }
        tunnelAssignments.removeAll { $0.target == .subscription(id) }
        normalizeTunnelProfileSelection()
        let removedIDs = Set(affectedConnections.map(\.id))
        cancelHealthProbes(ids: removedIDs)
        normalizeSelection()
        setStoredError(nil)
        persistSettingError()
    }

    func selectConnection(id: UUID) {
        guard savedConnectionsByID[id] != nil else { return }

        let previousSelectionID = selectedConnectionID

        if !canChangeSelection, previousSelectionID != id {
            setStoredError("Please wait for the current connection action to finish")
            return
        }

        selectedConnectionID = id
        setStoredError(nil)
        persistSettingError()
        enqueueHealthProbes(for: [id], force: false, priority: true)

        if previousSelectionID != id && (hasEstablishedConnection || connectingSelection != nil || isWaitingForNetwork) {
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
                    source.usage = nil
                    source.announcement = nil
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

    func dismissConnectionError() {
        if let error = connectionError,
           lastError == error.summary, lastErrorDetails == error.details {
            setStoredError(nil)
        }
        connectionError = nil
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
        connectionStateTask?.cancel()
        connectionMode = mode
        isResolvingConnectionProvider = true
        appliedGeodataSources = nil
        appliedConnectionIDs = []
        connectionIntent.replaceProvider(connectionProviderFactory.makeProvider(for: mode), mode: mode,
                                         adopting: selectedConfiguration.map { makeConnectionRequest(configuration: $0) })
        connectionState = .idle
        hasObservedInitialConnectionState = false
        inFlightConnectionRequest = nil
        appliedSplitTunnelRules = nil
        appliedSplitTunnelDefaultAction = nil
        observeConnectionState()
        setStoredError(nil)
        updateMenuBarAnimation()
        schedulePersist()
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
        scheduleActiveSplitTunnelLiveApply()
    }

    @discardableResult
    func addSplitTunnelRule(value: String, action: SplitTunnelRuleAction, connectionID: UUID? = nil) -> Result<SplitTunnelRule, SplitTunnelRuleValidationError> {
        guard canEditTunnelProfile else { return .failure(.readOnlyProfile) }
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
        guard canEditTunnelProfile else { return }
        guard let index = selectedSplitTunnelProfileIndex,
              splitTunnelProfiles[index].rules.contains(where: { $0.id == id }) else { return }
        splitTunnelProfiles[index].rules.removeAll { $0.id == id }
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func setSplitTunnelRuleEnabled(id: UUID, isEnabled: Bool) {
        guard canEditTunnelProfile else { return }
        guard let profileIndex = selectedSplitTunnelProfileIndex,
              let ruleIndex = splitTunnelProfiles[profileIndex].rules.firstIndex(where: { $0.id == id }),
              splitTunnelProfiles[profileIndex].rules[ruleIndex].isEnabled != isEnabled else { return }
        splitTunnelProfiles[profileIndex].rules[ruleIndex].isEnabled = isEnabled
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func setSplitTunnelRuleAction(id: UUID, action: SplitTunnelRuleAction) {
        guard canEditTunnelProfile else { return }
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
        guard canEditTunnelProfile else { return }
        guard let profileIndex = selectedSplitTunnelProfileIndex,
              let ruleIndex = splitTunnelProfiles[profileIndex].rules.firstIndex(where: { $0.id == id }),
              splitTunnelProfiles[profileIndex].rules[ruleIndex].action == .proxy,
              splitTunnelProfiles[profileIndex].rules[ruleIndex].connectionID != connectionID else { return }
        splitTunnelProfiles[profileIndex].rules[ruleIndex].connectionID = connectionID
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func setSplitTunnelDefaultAction(_ action: SplitTunnelRuleAction) {
        guard canEditTunnelProfile else { return }
        guard let profileIndex = selectedSplitTunnelProfileIndex,
              splitTunnelProfiles[profileIndex].defaultAction != action else { return }
        splitTunnelProfiles[profileIndex].defaultAction = action
        schedulePersist()
        scheduleSplitTunnelLiveApply()
    }

    func moveSplitTunnelRules(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard canEditTunnelProfile else { return }
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

    /// Atomic profile edit shared with automation. An inactive profile can be
    /// edited without selecting it or changing the live session's geodata.
    func replaceSplitTunnelProfile(_ profile: SplitTunnelProfile) {
        guard let index = splitTunnelProfiles.firstIndex(where: { $0.id == profile.id && $0.subscriptionSourceID == nil }),
              splitTunnelProfiles[index] != profile else { return }
        let previous = splitTunnelProfiles[index]
        splitTunnelProfiles[index] = profile
        schedulePersist()
        if profile.id == connectionTunnelProfile?.id,
           previous.rules != profile.rules || previous.defaultAction != profile.defaultAction {
            scheduleActiveSplitTunnelLiveApply()
        }
    }

    var mcpConnectionProfileID: UUID? { connectionTunnelProfile?.id }

    func mcpLoadRoutingAudit(profile: SplitTunnelProfile) async throws -> RoutingAudit {
        let service = GeodataUpdateService(fileManager: store.fileManager)
        let selected = profile.geodataSources ?? GeodataSources()
        let active = GeodataSources(geositeURLString: geodataSettings.geositeURLString, geoipURLString: geodataSettings.geoipURLString)
        let sources: GeodataSources? = selected == active && !profileGeodataLibrary.hasCachedPair(sources: selected) ? nil : selected
        return try await Task.detached(priority: .utility) {
            try RoutingAudit(service: service, sources: sources)
        }.value
    }

    var mcpGeodataRevision: [String] {
        splitTunnelProfiles.flatMap { profile in
            GeodataKind.allCases.map { kind in
                switch mcpGeodataStatus(kind: kind, profile: profile) {
                case .bundled: return "bundled"
                case .missing: return "missing"
                case .loading: return "loading"
                case let .failed(message): return "failed:" + message
                case let .ready(date): return "ready:" + (date.map { String($0.timeIntervalSince1970) } ?? "unknown")
                }
            }
        }
    }

    func mcpGeodataStatus(kind: GeodataKind, profile: SplitTunnelProfile) -> ProfileGeodataLibrary.Status {
        profileGeodataStatus(kind: kind, sources: profile.geodataSources ?? GeodataSources())
    }

    func mcpApplyPendingRouting(dryRun: Bool = false) throws {
        guard hasDeferredSubscriptionRoutingChanges else { throw MCPFailure("No deferred subscription routing to apply") }
        guard connectionMode == .tun, hasEstablishedConnection, !isOperationPending,
              inFlightConnectionRequest == nil else { throw MCPFailure("Wait for an established, idle TUN session before applying deferred routing") }
        // A subscription can refresh cached geodata without changing source URLs
        // or rules. Rebuild the connection request even in that case.
        if !dryRun { reconnectToSelectedConnection() }
    }

    /// The app's last acknowledged policy, not a read of the live Xray config.
    /// An adopted session may have been created by a previous app run.
    var mcpRoutingApplicationState: [String: Any] {
        ["hasActiveSession": hasActiveConnectionSession,
         "operationPending": isOperationPending,
         "liveApplyPending": pendingSplitTunnelLiveApply || splitTunnelApplyWorkItem != nil,
         "hasError": lastError != nil,
         "deferredSubscriptionChanges": hasDeferredSubscriptionRoutingChanges,
         "savedRulesMatchAcknowledgedPolicy": appliedSplitTunnelRules.map { $0 == activeSplitTunnelRules && appliedSplitTunnelDefaultAction == activeSplitTunnelDefaultAction } as Any? ?? NSNull(),
         "savedGeodataSourcesMatchAcknowledgedPolicy": appliedGeodataSources.map { $0 == connectionGeodataSources } as Any? ?? NSNull(),
         "basis": "app_acknowledged_policy_not_live_config"]
    }

    // MARK: - Split-tunnel profiles

    @discardableResult
    func addSplitTunnelProfile(name: String) -> UUID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SplitTunnelProfile(name: trimmedName.isEmpty ? "New profile" : trimmedName,
                                        geodataSources: GeodataSources())
        splitTunnelProfiles.append(profile)
        openSplitTunnelProfile(id: profile.id)
        return profile.id
    }

    func renameSplitTunnelProfile(id: UUID, name: String) {
        guard let index = splitTunnelProfiles.firstIndex(where: { $0.id == id && $0.subscriptionSourceID == nil }) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, splitTunnelProfiles[index].name != trimmedName else { return }
        splitTunnelProfiles[index].name = trimmedName
        schedulePersist()
    }

    /// Removes a profile. At least one profile must always exist, so the last
    /// remaining profile cannot be deleted (mirrors "can't disable the only mode").
    func removeSplitTunnelProfile(id: UUID) {
        guard personalTunnelProfiles.count > 1,
              let index = splitTunnelProfiles.firstIndex(where: { $0.id == id && $0.subscriptionSourceID == nil }) else { return }
        let wasActive = connectionTunnelProfile?.id == id
        splitTunnelProfiles.remove(at: index)
        let fallbackID = personalTunnelProfiles.first?.id
        for index in tunnelAssignments.indices where tunnelAssignments[index].personalProfileID == id {
            tunnelAssignments[index].personalProfileID = fallbackID
        }
        normalizeTunnelProfileSelection()
        schedulePersist()
        if wasActive { scheduleActiveSplitTunnelLiveApply() }
    }

    /// Open a profile in Routing. Browsing the library never assigns it to a
    /// portal or changes the policy of the active connection.
    @discardableResult
    func openSplitTunnelProfile(id: UUID) -> Bool {
        guard splitTunnelProfiles.contains(where: { $0.id == id }) else { return false }
        selectedSplitTunnelProfileID = id
        normalizeTunnelProfileSelection()
        profileGeodataLibrary.preload(sources: selectedProfileGeodataSources)
        schedulePersist()
        return true
    }

    /// Coalesces rapid rule edits (typing, dragging to reorder, flipping several
    /// toggles) into a single TUN reconnect once the user settles, instead of
    /// tearing the tunnel down and back up on every individual change.
    private func scheduleSplitTunnelLiveApply() {
        // Editing an unrelated library profile must not release deferred
        // subscription changes or reconnect the active session.
        guard selectedSplitTunnelProfileID == connectionTunnelProfile?.id else { return }
        scheduleActiveSplitTunnelLiveApply()
    }

    private func scheduleActiveSplitTunnelLiveApply() {
        // An explicit edit resumes live application, including any imported
        // changes the user has since reviewed in the editor.
        hasDeferredSubscriptionRoutingChanges = false
        guard connectionMode == .tun, hasActiveConnectionSession else { return }
        guard hasEstablishedConnection else {
            pendingSplitTunnelLiveApply = true
            return
        }

        splitTunnelApplyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.splitTunnelApplyWorkItem = nil
            self?.applySplitTunnelRulesLiveIfNeeded()
        }
        splitTunnelApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: workItem)
    }

    private func applySplitTunnelRulesLiveIfNeeded() {
        guard !isTerminating, !hasDeferredSubscriptionRoutingChanges,
              connectionMode == .tun, hasEstablishedConnection else { return }
        // connect() may return before its .connected update reaches this model.
        // Wait until that update records the request's applied policy as well.
        guard !isOperationPending, inFlightConnectionRequest == nil else {
            pendingSplitTunnelLiveApply = true
            return
        }
        pendingSplitTunnelLiveApply = false
        // Only reconnect when what Xray would actually see has changed. Editing a
        // disabled rule, or a no-op toggle, must not drop the tunnel; but a change
        // to the default (catch-all) action must, since it rewrites the config.
        guard activeSplitTunnelRules != appliedSplitTunnelRules
            || activeSplitTunnelDefaultAction != appliedSplitTunnelDefaultAction
            || connectionGeodataSources != appliedGeodataSources else { return }
        reconnectToSelectedConnection()
    }

    private func applyDeferredSplitTunnelRulesLiveIfNeeded() {
        guard connectionMode == .tun, hasEstablishedConnection else { return }
        guard pendingSplitTunnelLiveApply
            || activeSplitTunnelRules != appliedSplitTunnelRules
            || activeSplitTunnelDefaultAction != appliedSplitTunnelDefaultAction
            || connectionGeodataSources != appliedGeodataSources else { return }
        applySplitTunnelRulesLiveIfNeeded()
    }

    // MARK: - Geodata (geosite/geoip)

    private var connectionGeodataSources: GeodataSources {
        guard connectionMode == .tun, routingIsEnabled(for: connectionTunnelProfile) else { return GeodataSources() }
        return connectionTunnelProfile?.geodataSources ?? GeodataSources()
    }

    var selectedProfileGeodataSources: GeodataSources {
        selectedSplitTunnelProfile?.geodataSources ?? GeodataSources()
    }

    var geodataProfileError: String? {
        for kind in GeodataKind.allCases {
            switch profileGeodataStatus(kind: kind) {
            case let .failed(message): return "\(kind.displayName): \(message)"
            case .missing: return "\(kind.displayName) download is incomplete. Retry the download."
            case .loading, .bundled, .ready: continue
            }
        }
        return nil
    }

    func profileGeodataStatus(kind: GeodataKind) -> ProfileGeodataLibrary.Status {
        profileGeodataStatus(kind: kind, sources: selectedProfileGeodataSources)
    }

    private func profileGeodataStatus(kind: GeodataKind, sources: GeodataSources) -> ProfileGeodataLibrary.Status {
        let status = profileGeodataLibrary.status(for: kind, sources: sources)
        if status == .loading { return status }
        if geodataLastAttemptSources == sources {
            if updatingGeodataKinds.contains(kind) { return .loading }
            if let error = kind == .geosite ? geodataSettings.geositeLastError : geodataSettings.geoipLastError {
                return .failed(error)
            }
        }
        return status
    }

    var updatingSelectedProfileGeodataKinds: Set<GeodataKind> {
        var kinds = Set(GeodataKind.allCases.filter { profileGeodataStatus(kind: $0) == .loading })
        if geodataLastAttemptSources == selectedProfileGeodataSources { kinds.formUnion(updatingGeodataKinds) }
        return kinds
    }

    func isDownloadingSubscriptionGeodata(_ id: UUID) -> Bool {
        guard let sources = splitTunnelProfiles.first(where: { $0.subscriptionSourceID == id })?.geodataSources else { return false }
        return profileGeodataLibrary.isLoading(sources: sources)
    }

    func subscriptionGeodataError(_ id: UUID) -> String? {
        guard let sources = splitTunnelProfiles.first(where: { $0.subscriptionSourceID == id })?.geodataSources else { return nil }
        for kind in GeodataKind.allCases {
            if case let .failed(message) = profileGeodataLibrary.status(for: kind, sources: sources) {
                return "\(kind.displayName) download failed: \(message) Update this subscription to retry."
            }
        }
        return nil
    }

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
        guard canEditTunnelProfile, let index = selectedSplitTunnelProfileIndex,
              minutes != splitTunnelProfiles[index].geodataUpdateIntervalMinutes else { return }
        splitTunnelProfiles[index].geodataUpdateIntervalMinutes = minutes
        schedulePersist()
    }

    func cancelGeodataUpdate(kind: GeodataKind) {
        geodataUpdateCoordinator.cancel(kind: kind)
    }

    func cancelGeodataUpdates() {
        profileGeodataLibrary.cancel(sources: selectedProfileGeodataSources)
        if geodataLastAttemptSources == selectedProfileGeodataSources { geodataUpdateCoordinator.cancelAll() }
    }

    func applyGeodataSources(geositeURLString: String?, geoipURLString: String?, forceDownload: Bool = false) {
        guard canEditTunnelProfile, !isOperationPending, updatingGeodataKinds.isEmpty else { return }
        let sources = GeodataSources(geositeURLString: normalizedURLString(geositeURLString),
                                    geoipURLString: normalizedURLString(geoipURLString))
        guard [sources.geositeURLString, sources.geoipURLString].compactMap({ $0 })
            .allSatisfy({ validatedGeodataURL($0) != nil }) else {
            for kind in GeodataKind.allCases {
                let value = kind == .geosite ? sources.geositeURLString : sources.geoipURLString
                if let value, validatedGeodataURL(value) == nil { setGeodataError(kind: kind, error: GeodataUpdateError.invalidURL) }
            }
            schedulePersist()
            return
        }
        if let index = selectedSplitTunnelProfileIndex { splitTunnelProfiles[index].geodataSources = sources }
        schedulePersist()
        updateProfileGeodata(sources: sources, forceDownload: forceDownload)
    }

    func downloadSelectedProfileGeodata(forceDownload: Bool = false) {
        guard !isOperationPending, updatingGeodataKinds.isEmpty else { return }
        if canEditTunnelProfile {
            updateProfileGeodata(sources: selectedProfileGeodataSources, forceDownload: forceDownload)
        } else {
            profileGeodataLibrary.preload(sources: selectedProfileGeodataSources, forceDownload: forceDownload)
        }
    }

    private func updateProfileGeodata(sources: GeodataSources, forceDownload: Bool) {
        if selectedSplitTunnelProfileID == connectionTunnelProfile?.id, routingIsEnabled(for: connectionTunnelProfile) {
            startGeodataUpdates(sources: sources, forceDownload: forceDownload)
        } else {
            profileGeodataLibrary.preload(sources: sources, forceDownload: forceDownload)
        }
    }

    private func startGeodataUpdates(sources: GeodataSources, forceDownload: Bool = false) {
        geodataLastAttemptSources = sources
        var requests: [GeodataUpdateCoordinator.Request] = []
        for kind in GeodataKind.allCases {
            let value = normalizedURLString(kind == .geosite ? sources.geositeURLString : sources.geoipURLString)
            if let value {
                guard let url = validatedGeodataURL(value) else {
                    applyGeodataUpdateResult(kind: kind, outcome: .failed(GeodataUpdateError.invalidURL))
                    continue
                }
                requests.append(geodataRequest(kind: kind, source: url, useCache: !forceDownload))
            } else if geodataURLString(for: kind) != nil || hasCustomGeodata(kind: kind) {
                requests.append(geodataRequest(kind: kind, source: nil, useCache: true))
            }
        }
        geodataUpdateCoordinator.startBatch(requests)
    }

    func updateGeodataNow(kind: GeodataKind) {
        guard let value = geodataURLString(for: kind), let url = validatedGeodataURL(value) else {
            applyGeodataUpdateResult(kind: kind, outcome: .failed(GeodataUpdateError.invalidURL))
            return
        }
        if canEditTunnelProfile, let index = selectedSplitTunnelProfileIndex {
            var sources = selectedProfileGeodataSources
            if kind == .geosite { sources.geositeURLString = value }
            else { sources.geoipURLString = value }
            splitTunnelProfiles[index].geodataSources = sources
            geodataLastAttemptSources = sources
        }
        geodataUpdateCoordinator.startBatch([geodataRequest(kind: kind, source: url, useCache: false)])
    }

    private func geodataRequest(kind: GeodataKind, source: URL?, useCache: Bool) -> GeodataUpdateCoordinator.Request {
        let oldError = kind == .geosite ? geodataSettings.geositeLastError : geodataSettings.geoipLastError
        let oldSource = oldError == nil ? geodataURLString(for: kind).flatMap(validatedGeodataURL) : nil
        return .init(kind: kind, source: source, useCache: useCache,
                     previousSource: oldSource, previousUpdatedAt: geodataLastUpdatedAt(for: kind))
    }

    func hasCustomGeodata(kind: GeodataKind) -> Bool {
        geodataUpdateCoordinator.hasCustomGeodata(for: kind)
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

    private func applyGeodataUpdateResult(kind: GeodataKind, outcome: GeodataUpdateCoordinator.Outcome) {
        switch outcome {
        case let .applied(change):
            if let source = change.source {
                if kind == .geosite { geodataSettings.geositeURLString = source.absoluteString }
                else { geodataSettings.geoipURLString = source.absoluteString }
                profileGeodataLibrary.recordReady(kind: kind, source: source, date: change.updatedAt)
            } else {
                clearGeodataURL(kind: kind)
            }
            setGeodataError(kind: kind, error: nil)
            setGeodataLastUpdatedAt(kind: kind, date: change.updatedAt)
            if change.changed {
                prepareSplitTunnelGeodataMatcher(reload: true)
            }
        case let .failed(error):
            setGeodataError(kind: kind, error: error)
        case .cancelled:
            return
        }
        schedulePersist()
    }

    /// Geodata is read by Xray at process startup, so an update only takes
    /// effect after a restart; reuse the normal reconnect path immediately if
    /// TUN mode is already connected instead of waiting for the user to notice.
    private func applyGeodataLiveIfNeeded() {
        guard !isTerminating, !isOperationPending, !hasDeferredSubscriptionRoutingChanges,
              connectionMode == .tun, routingIsEnabled(for: connectionTunnelProfile), hasEstablishedConnection,
              geodataIsReady(for: connectionGeodataSources) else { return }
        geodataRevision += 1
        reconnectToSelectedConnection()
    }

    private func prepareSplitTunnelGeodataMatcher(reload: Bool = false) {
        let selected = selectedProfileGeodataSources
        let active = GeodataSources(geositeURLString: geodataSettings.geositeURLString, geoipURLString: geodataSettings.geoipURLString)
        let sources: GeodataSources? = selected == active && !profileGeodataLibrary.hasCachedPair(sources: selected) ? nil : selected
        if reload || matcherSources != sources {
            matcherSources = sources
            splitTunnelGeodataMatcher = SplitTunnelGeodataMatcher(
                service: GeodataUpdateService(fileManager: store.fileManager), sources: sources
            )
            isSplitTunnelGeodataReady = false
        }
        guard !splitTunnelGeodataMatcher.isReady else {
            isSplitTunnelGeodataReady = true
            return
        }
        let matcher = splitTunnelGeodataMatcher
        matcher.prepare { [weak self, weak matcher] in
            guard let self, let matcher, self.splitTunnelGeodataMatcher === matcher else { return }
            self.isSplitTunnelGeodataReady = matcher.isReady
        }
    }

    func performScheduledGeodataUpdateIfNeeded() {
        guard !isOperationPending else { return }
        for profile in splitTunnelProfiles where profile.id != connectionTunnelProfile?.id {
            guard let minutes = profile.geodataUpdateIntervalMinutes, minutes > 0 else { continue }
            let sources = profile.geodataSources ?? GeodataSources()
            let due = GeodataKind.allCases.contains { kind in
                switch profileGeodataLibrary.status(for: kind, sources: sources) {
                case let .ready(date): return Date().timeIntervalSince(date ?? .distantPast) >= TimeInterval(minutes * 60)
                case .missing, .failed: return true
                case .loading, .bundled: return false
                }
            }
            if due { profileGeodataLibrary.preload(sources: sources, forceDownload: true) }
        }
        let activeSources = connectionTunnelProfile?.geodataSources ?? GeodataSources()
        guard !profileGeodataLibrary.isLoading(sources: activeSources), geodataIsReady(for: activeSources, requireLatestCache: false) else { return }
        guard let intervalMinutes = connectionTunnelProfile?.geodataUpdateIntervalMinutes, intervalMinutes > 0 else { return }
        let requests = GeodataKind.allCases.compactMap { kind -> GeodataUpdateCoordinator.Request? in
            guard !updatingGeodataKinds.contains(kind), let value = geodataURLString(for: kind),
                  let url = validatedGeodataURL(value) else { return nil }
            let referenceDate = geodataLastUpdatedAt(for: kind) ?? .distantPast
            guard Date().timeIntervalSince(referenceDate) >= TimeInterval(intervalMinutes * 60) else { return nil }
            return geodataRequest(kind: kind, source: url, useCache: false)
        }
        geodataUpdateCoordinator.startBatch(requests)
    }

    func refreshStartsAtLoginStatus() {
        let enabled = loginItemService.isEnabled
        if startsAtLogin != enabled { startsAtLogin = enabled }
    }

    func refreshHelperInstallationStatus() {
        let installed = PrivilegedHelperUninstaller.isInstalled()
        if isHelperInstalled != installed { isHelperInstalled = installed }
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
        helperUninstallFailure = nil
        let revision = connectionIntent.request(.disconnected)
        let runtime = connectionIntent
        let uninstaller = helperUninstaller
        let leakGuard = leakGuard
        log.info(Self.subsystem, "helper uninstall requested: mode \(connectionMode)")
        isOperationPending = true
        Task { @MainActor [weak self] in
            try? await runtime.waitForDisconnect(revision: revision)
            // Explicit removal also stops guard renewal if cleanup failed.
            await leakGuard.disarm()
            do {
                try await uninstaller.uninstall()
                self?.helperUninstallMessage = "Teleport's helper was removed. TUN mode will ask to install it again on the next connect."
                self?.log.info(AppViewModel.subsystem, "helper uninstalled")
            } catch {
                self?.helperUninstallFailure = ConnectionFailure(error: error)
                self?.helperUninstallMessage = error.localizedDescription
                self?.log.warn(AppViewModel.subsystem, "helper uninstall failed: \(LogFormat.error(error))")
            }
            self?.refreshHelperInstallationStatus()
            self?.isUninstallingHelper = false
            self?.isOperationPending = false
        }
    }

    func dismissHelperUninstallFailure() {
        helperUninstallFailure = nil
        helperUninstallMessage = nil
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

    func toggleConnection() {
        if canConnect { connect() }
        else if canDisconnect { disconnect() }
    }

    func connect() {
        guard !isTerminating, !isDisconnecting, !isUninstallingHelper else { return }
        isLaunchConnectionPending = false
        discardRemovedSessionConnections()
        guard let selectedConfiguration else {
            setStoredError("Add and select a portal first")
            return
        }
        log.info(Self.subsystem, "connect requested: mode \(connectionMode), server \(LogFormat.host(selectedConfiguration.host)):\(selectedConfiguration.port)")
        requestConnection(using: selectedConfiguration)
    }

    /// A user command replaces the desired state. The runtime finishes its
    /// current operation, then observes this value before choosing another one.
    func disconnect() {
        guard !isTerminating, !isUninstallingHelper else { return }
        isLaunchConnectionPending = false
        guard !isDisconnecting else { return }
        isDisconnecting = true
        isWaitingForNetwork = false
        connectingSelection = nil
        isOperationPending = true
        dismissConnectionError()
        connectionIntent.request(.disconnected)
    }

    func allowDirectTraffic() {
        guard canAllowDirectTraffic else { return }
        disconnect()
    }

    /// How long a quit waits for the session's teardown. Long enough for a
    /// helper stop and a proxy restore that each time out once; short enough that
    /// a teardown stuck behind something is not a reason to force-quit the app.
    nonisolated static let terminationTeardownLimit: Duration = .seconds(20)

    func handleAppTermination(
        teardownLimit: Duration = AppViewModel.terminationTeardownLimit,
        completion: @escaping () -> Void
    ) {
        isTerminating = true
        geodataUpdateCoordinator.cancelAll()
        profileGeodataLibrary.cancelAll()
        connectingSelection = nil
        log.info(Self.subsystem, "terminating")
        let runtime = connectionIntent
        runtime.request(.disconnected)
        sessionLifecycle.stop()
        Task { @MainActor [weak self] in
            let tornDown = await Self.awaitTeardown({ try? await runtime.close() }, limit: teardownLimit)
            if !tornDown {
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

    /// Every state change funnels through `applyConnectionSnapshot`, so logging here
    /// records transitions the app did not initiate too — a tunnel that dropped on
    /// its own is the case worth having in a file after the fact.
    private func logConnectionState(_ state: ConnectionState, isInitialState: Bool) {
        let prefix = isInitialState ? "initial connection state" : "connection state"
        switch state {
        case let .failed(failure):
            log.error(Self.subsystem, "\(prefix): failed — \(failure.summary)")
        case .connected:
            // The lifecycle fills in the uplink for a session this process did not
            // start, one still up from a previous run, and hands it back for this
            // line.
            let uplink = connectionIntent.currentUplink
            log.info(Self.subsystem, "\(prefix): connected (mode \(connectionMode)) over uplink \(uplink?.summary ?? "<unknown>")")
            SystemStateDump.capture("after connect", log: log)
        case .awaitingUserApproval:
            log.info(Self.subsystem, "\(prefix): awaiting administrator approval for the helper install")
        default:
            log.info(Self.subsystem, "\(prefix): \(state)")
        }
    }

    /// The guard's own copy of the setting: it runs off the main actor and cannot
    /// read the published one.
    private func syncLeakGuardSetting() {
        let leakGuard = leakGuard
        let isEnabled = isLeakGuardEnabled
        Task { await leakGuard.setEnabled(isEnabled) }
    }

    private func observeLeakGuardState() {
        let leakGuard = leakGuard
        leakGuardStateTask = Task.detached { [weak self] in
            for await held in await leakGuard.holdingUpdates() {
                guard !Task.isCancelled else { break }
                await Self.onConnectionRunLoop { [weak self] in
                    self?.isLeakGuardHoldingUplink = held
                }
            }
        }
    }

    /// AppKit's menu tracking loop does not drain the dispatch-main actor queue.
    /// Deliver updates in common and explicit tracking modes so an open menu
    /// keeps showing progress, errors, and completion without needing to close it.
    nonisolated private static func onConnectionRunLoop(_ update: @escaping @MainActor @Sendable () -> Void) async {
        await MainRunLoopWork.run(update)
    }

    private func observeConnectionState() {
        connectionStateTask?.cancel()
        let updates = connectionIntent.updates()
        connectionStateTask = Task.detached { [weak self] in
            for await snapshot in updates {
                guard !Task.isCancelled else { break }
                await Self.onConnectionRunLoop { [weak self] in self?.applyConnectionSnapshot(snapshot) }
            }
        }
    }

    private func applyConnectionSnapshot(_ snapshot: ConnectionIntentRuntime.Presentation) {
        guard snapshot.providerID == connectionIntent.providerID else { return }
        let isInitialState = !hasObservedInitialConnectionState
        hasObservedInitialConnectionState = true
        if snapshot.state != connectionState || isInitialState {
            logConnectionState(snapshot.state, isInitialState: isInitialState)
        }
        if snapshot.state != .preparing { isResolvingConnectionProvider = false }
        connectionState = snapshot.state
        allowsLaunchConnection = snapshot.isSettled && snapshot.allowsLaunchConnection
        if case let .connecting(request) = snapshot.activity {
            inFlightConnectionRequest = request
        } else {
            inFlightConnectionRequest = nil
        }
        if let applied = snapshot.appliedRequest {
            appliedConnectionIDs = Set(applied.connections.map(\.id))
            appliedGeodataSources = applied.geodataSources
            appliedSplitTunnelRules = applied.splitTunnelPolicy.rules
            appliedSplitTunnelDefaultAction = applied.splitTunnelPolicy.defaultAction
        } else if snapshot.state == .idle {
            appliedConnectionIDs = []
            appliedGeodataSources = nil
            appliedSplitTunnelRules = nil
            appliedSplitTunnelDefaultAction = nil
            pendingSplitTunnelLiveApply = false
        }
        // A snapshot for an older intent may update actual state, but cannot
        // finish or clear the pending UI for the user's newer command.
        if snapshot.intentRevision == connectionIntent.intentRevision {
            isOperationPending = !snapshot.isSettled || isUninstallingHelper
            isWaitingForNetwork = snapshot.activity == .waitingForNetwork
            if case let .connecting(request) = snapshot.activity {
                connectingSelection = request.defaultConnection.id
            } else if snapshot.isSettled {
                connectingSelection = nil
            }
            if let failure = snapshot.failure, lastPresentedFailure?.revision != snapshot.intentRevision || lastPresentedFailure?.error != failure {
                lastPresentedFailure = (snapshot.intentRevision, failure)
                connectionError = failure
                lastError = failure.summary
                lastErrorDetails = failure.details
            } else if snapshot.failure == nil && snapshot.state.isConnected {
                dismissConnectionError()
            }
            if snapshot.isSettled { isDisconnecting = false }
            if snapshot.isSettled, !isOperationPending, snapshot.state == .idle { discardRemovedSessionConnections() }
            if snapshot.isSettled { applyDeferredSplitTunnelRulesLiveIfNeeded() }
        }
        updateMenuBarAnimation()
        connectOnLaunchIfNeeded()
    }

    private func discardRemovedSessionConnections() {
        guard !removedSessionConnections.isEmpty else { return }
        let nextSelectionID = selectionForNextConnectionID
        removedSessionConnections.removeAll()
        selectedConnectionID = nextSelectionID
        normalizeTunnelProfileSelection()
        schedulePersist()
    }

    /// If the current portal disappeared, prefer its refreshed subscription over
    /// an unrelated manual portal when saving or starting the next connection.
    private var selectionForNextConnectionID: UUID? {
        if let selectedConnectionID, savedConnectionsByID[selectedConnectionID] != nil { return selectedConnectionID }
        if let selectedConnectionID,
           let sourceID = removedSessionConnections[selectedConnectionID]?.source?.subscriptionSourceID,
           let replacement = savedConnections.first(where: { $0.source?.subscriptionSourceID == sourceID }) {
            return replacement.id
        }
        return savedConnections.first?.id
    }

    private func connectOnLaunchIfNeeded() {
        guard isLaunchConnectionPending, hasObservedInitialConnectionState else { return }
        switch connectionState {
        case .preparing:
            return
        case .idle:
            guard !isOperationPending else { return }
            isLaunchConnectionPending = false
            guard allowsLaunchConnection, canConnect else { return }
            connect()
        case .connected, .failed, .awaitingUserApproval, .connecting, .disconnecting:
            isLaunchConnectionPending = false
        }
    }

    private var hasEstablishedConnection: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    private func reconnectToSelectedConnection() {
        discardRemovedSessionConnections()
        guard !isTerminating, !isUninstallingHelper, let selectedConfiguration else { return }
        requestConnection(using: selectedConfiguration)
    }

    private func requestConnection(using configuration: ConnectionConfiguration) {
        hasDeferredSubscriptionRoutingChanges = false
        if hasEstablishedConnection, connectionMode == .tun, routingIsEnabled(for: connectionTunnelProfile),
           !geodataIsReady(for: connectionGeodataSources) {
            // The URLs can stay the same while a subscription refresh caches new files.
            geodataRevision += 1
        }
        let request = makeConnectionRequest(configuration: configuration)
        connectingSelection = request.defaultConnection.id
        isOperationPending = true
        isWaitingForNetwork = false
        dismissConnectionError()
        setStoredError(nil)
        connectionIntent.request(.connected(request))
    }

    private func makeConnectionRequest(configuration: ConnectionConfiguration) -> ConnectionRequest {
        // The caller may connect to a configuration that is not the current
        // selection (a menu-bar pick, for example), so the default connection is
        // taken from the argument and the extras are matched against it.
        let defaultConnectionID = savedConnections.first { $0.configuration == configuration }?.id
            ?? selectedConnectionID
            ?? UUID()
        let connection = savedConnectionsByID[defaultConnectionID]
        let profile = tunnelProfile(for: connection)
        let rules = routingIsEnabled(for: profile) ? (profile?.rules.filter { $0.isEnabled } ?? []) : []
        var seen: Set<UUID> = [defaultConnectionID]
        let additionalConnections = rules.compactMap { rule -> RoutedConnection? in
            guard rule.action == .proxy, let id = rule.connectionID, seen.insert(id).inserted,
                  let connection = savedConnectionsByID[id] else { return nil }
            return RoutedConnection(id: id, configuration: connection.configuration)
        }
        return ConnectionRequest(
            defaultConnection: RoutedConnection(id: defaultConnectionID, configuration: configuration),
            additionalConnections: additionalConnections,
            localProxy: proxyEndpoint,
            splitTunnelPolicy: SplitTunnelPolicy(
                rules: rules,
                defaultAction: routingIsEnabled(for: profile) ? (profile?.defaultAction ?? .proxy) : .proxy
            ),
            geodataSources: connectionMode == .tun && routingIsEnabled(for: profile) ? (profile?.geodataSources ?? GeodataSources()) : GeodataSources(),
            geodataProfileName: connectionMode == .tun && routingIsEnabled(for: profile) ? (profile?.name ?? "Default") : nil,
            geodataRevision: geodataRevision,
            usesLeakGuard: isLeakGuardEnabled
        )
    }

    private func setStoredError(_ message: String?) {
        lastError = message
        lastErrorDetails = nil
    }

    private func applyConnectionError(_ error: Error) {
        connectionError = ConnectionFailure(error: error)
        applyStoredError(error)
    }

    private func applyStoredError(_ error: Error) {
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
            normalizeTunnelProfileSelection()
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
            normalizeTunnelProfileSelection()
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

    private enum SubscriptionRefreshOrigin {
        case userInitiated
        case background
    }

    private func refreshSubscription(
        id: UUID,
        autoSelectFirstImported: Bool,
        origin: SubscriptionRefreshOrigin = .userInitiated
    ) {
        guard let source = subscriptionSources.first(where: { $0.id == id }) else { return }

        startSubscriptionRefresh(for: source, autoSelectFirstImported: autoSelectFirstImported, origin: origin)
    }

    private func startSubscriptionRefresh(
        for source: SubscriptionSource,
        autoSelectFirstImported: Bool,
        origin: SubscriptionRefreshOrigin
    ) {
        let refreshToken = UUID()
        subscriptionRefreshTokens[source.id] = refreshToken
        refreshingSubscriptionIDs.insert(source.id)
        updateSubscriptionSource(source.id) {
            $0.lastError = nil
        }
        if origin == .userInitiated { setStoredError(nil) }
        schedulePersist()

        let parser = parser
        let subscriptionClient = subscriptionClient

        Task { @MainActor [weak self] in
            defer {
                if self?.subscriptionRefreshTokens[source.id] == refreshToken {
                    self?.subscriptionRefreshTokens.removeValue(forKey: source.id)
                    self?.refreshingSubscriptionIDs.remove(source.id)
                }
            }
            do {
                guard let url = URL(string: source.urlString) else {
                    throw SubscriptionError.invalidURL
                }

                // Download decoding, JSON/link parsing and deduplication can be
                // expensive. An ordinary Task here inherits the main actor.
                let (fetched, importResult) = try await Task.detached(priority: .utility) {
                    let fetched = try await subscriptionClient.fetch(from: url)
                    let result = try SubscriptionImportProcessor.importEntries(
                        candidates: fetched.candidates,
                        parser: parser,
                        sourceID: source.id,
                        filterDuplicateImports: source.filterDuplicateImports
                    )
                    return (fetched, result)
                }.value
                // A newer refresh (or source deletion) invalidates this request.
                // Cosmetic URL edits do not invalidate a pending import.
                guard self?.subscriptionRefreshTokens[source.id] == refreshToken else { return }
                let importStatus = [importResult.statusMessage, fetched.routingWarning]
                    .compactMap { $0 }.joined(separator: " ")

                self?.applyImportedEntries(
                    importResult.importedEntries,
                    skippedCount: importResult.skippedCount,
                    importStatus: importStatus.isEmpty ? nil : importStatus,
                    routing: fetched.routing,
                    usage: fetched.usage,
                    announcement: fetched.announcement,
                    to: source.id,
                    fetchedAt: Date(),
                    autoSelectFirstImported: autoSelectFirstImported,
                    origin: origin
                )
            } catch {
                guard self?.subscriptionRefreshTokens[source.id] == refreshToken else { return }
                self?.updateSubscriptionSource(source.id) {
                    $0.lastError = error.localizedDescription
                }
                if origin == .userInitiated { self?.applyStoredError(error) }
                self?.schedulePersist()
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
        routing: SubscriptionRoutingImport?,
        usage: SubscriptionUsage?,
        announcement: String?,
        to sourceID: UUID,
        fetchedAt: Date,
        autoSelectFirstImported: Bool,
        origin: SubscriptionRefreshOrigin
    ) {
        // The provider already owns an immutable connection request. Catalog
        // updates can be saved immediately without rebuilding that session.
        if isSubscriptionInUse(id: sourceID) {
            hasDeferredSubscriptionRoutingChanges = true
            splitTunnelApplyWorkItem?.cancel()
            splitTunnelApplyWorkItem = nil
            pendingSplitTunnelLiveApply = false
        }
        let previousSelectionID = selectedConnectionID
        let inUseConnections = savedConnections.filter { isConnectionInUse(id: $0.id) }

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

        let replacementIDs = Set(replacementResult.savedConnections.map(\.id))
        for connection in inUseConnections where !replacementIDs.contains(connection.id) {
            removedSessionConnections[connection.id] = connection
        }
        let removedIDs = Set(savedConnections.map(\.id)).subtracting(replacementIDs)
        cancelHealthProbes(ids: removedIDs)
        savedConnections = replacementResult.savedConnections
        syncHealthChecksFromSavedConnections()
        invalidateHealthChecksForImportedConnections(from: sourceID)
        rebuildSavedConnectionIndexes()
        if let previousSelectionID, removedSessionConnections[previousSelectionID] != nil {
            selectedConnectionID = previousSelectionID
        } else {
            selectedConnectionID = replacementResult.selectedConnectionID
        }

        if let routing { importTunnelProfile(routing, sourceID: sourceID) }
        normalizeTunnelProfileSelection()

        updateSubscriptionSource(sourceID) {
            $0.usage = usage
            $0.announcement = announcement
            $0.lastRefreshedAt = fetchedAt
            $0.lastSkippedCount = skippedCount
            $0.lastError = importStatus
        }

        refreshingSubscriptionIDs.remove(sourceID)
        if origin == .userInitiated { setStoredError(nil) }
        updateMenuBarAnimation()
        schedulePersist()
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
            refreshSubscription(id: source.id, autoSelectFirstImported: shouldAutoSelectFirstImported, origin: .background)
        }
    }

    func performScheduledSubscriptionRefreshes() {
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

            refreshSubscription(id: source.id, autoSelectFirstImported: false, origin: .background)
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
        switch subscriptionConnectionSort {
        case .original:
            return connections
        case .name:
            return connections.sorted(by: compareByName)
        case .latency:
            return connections.sorted { lhs, rhs in
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
           (savedConnections.contains(where: { $0.id == selectedConnectionID }) || removedSessionConnections[selectedConnectionID] != nil) {
            return
        }

        selectedConnectionID = savedConnections.first?.id
    }

    private func updateMenuBarAnimation() {
        // Animation timing is owned by MenuBarIconAnimator. Keeping this hook avoids
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
                    self?.applyStoredError(error)
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
            selectedConnectionID: selectionForNextConnectionID,
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
            geodataSettings: geodataSettings,
            tunnelAssignments: tunnelAssignments
        )
    }

    private func persist() throws {
        // A synchronous edit must supersede a queued refresh snapshot. Serialize
        // it after any save already running so older state cannot win on disk.
        persistWorkItem?.cancel()
        persistWorkItem = nil
        let snapshot = makeSnapshot()
        try persistenceQueue.sync { try store.save(snapshot) }
    }
}

extension AppViewModel {
    var tunnelTargets: [TunnelTarget] {
        subscriptionSources.map { .subscription($0.id) } + manualConnections.map { .connection($0.id) }
    }

    func tunnelTargetName(_ target: TunnelTarget) -> String {
        switch target {
        case let .subscription(id): return subscriptionSources.first { $0.id == id }?.displayName ?? "Subscription"
        case let .connection(id): return savedConnectionsByID[id]?.displayName ?? "Portal"
        }
    }

    var personalTunnelProfiles: [SplitTunnelProfile] {
        splitTunnelProfiles.filter { $0.subscriptionSourceID == nil }
    }

    func providerTunnelProfile(for sourceID: UUID) -> SplitTunnelProfile? {
        splitTunnelProfiles.first { $0.subscriptionSourceID == sourceID }
    }

    func inheritsSubscriptionTunnel(for target: TunnelTarget) -> Bool {
        guard case let .subscription(id) = target, providerTunnelProfile(for: id) != nil else { return false }
        return tunnelAssignments.first { $0.target == target }?.personalProfileID == nil
    }

    var canEditTunnelProfile: Bool { selectedSplitTunnelProfile?.subscriptionSourceID == nil }

    private var connectionTunnelProfile: SplitTunnelProfile? { tunnelProfile(for: selectedConnection) }

    /// Personal profiles contain rules, not activation state. A provider can
    /// explicitly publish routing/off; the global switch never overrides that.
    private func routingIsEnabled(for profile: SplitTunnelProfile?) -> Bool {
        guard isSplitTunnelEnabled, let profile else { return false }
        return profile.subscriptionSourceID == nil || profile.isRoutingEnabled
    }

    private func tunnelProfile(for connection: SavedConnection?) -> SplitTunnelProfile? {
        tunnelProfile(for: connection.map(TunnelTarget.init(connection:)))
    }

    func tunnelProfile(for target: TunnelTarget?) -> SplitTunnelProfile? {
        TunnelProfileResolver.profile(for: target, profiles: splitTunnelProfiles, assignments: tunnelAssignments)
    }

    /// The selection shown in Portals. A nil value means the subscription's
    /// updating provider profile, while personal profiles have a stable id.
    func personalTunnelProfileID(for target: TunnelTarget) -> UUID? {
        inheritsSubscriptionTunnel(for: target) ? nil : tunnelProfile(for: target)?.id
    }

    func tunnelProfileUsers(id: UUID) -> [String] {
        tunnelProfileTargets(id: id).map(tunnelTargetName)
    }

    func tunnelProfileTargets(id: UUID) -> [TunnelTarget] {
        tunnelTargets.filter {
            TunnelProfileResolver.profile(for: $0, profiles: splitTunnelProfiles, assignments: tunnelAssignments)?.id == id
        }
    }

    func tunnelProfileUsageDescription(id: UUID) -> String {
        let targets = tunnelProfileTargets(id: id)
        let subscriptions = targets.filter { if case .subscription = $0 { true } else { false } }.count
        let portals = targets.count - subscriptions
        var parts: [String] = []
        if subscriptions > 0 { parts.append("\(subscriptions) \(subscriptions == 1 ? "subscription" : "subscriptions")") }
        if portals > 0 { parts.append("\(portals) standalone \(portals == 1 ? "portal" : "portals")") }
        return parts.isEmpty ? "Not assigned" : "Used by " + parts.joined(separator: " and ")
    }

    private func normalizeTunnelProfileSelection() {
        if !splitTunnelProfiles.contains(where: { $0.id == selectedSplitTunnelProfileID }) {
            selectedSplitTunnelProfileID = personalTunnelProfiles.first?.id ?? splitTunnelProfiles.first?.id
        }
        prepareSplitTunnelGeodataMatcher()
    }

    /// Explicit assignment from Portals. It is independent of the profile open
    /// in Routing, including when the target is the active connection.
    @discardableResult
    func assignTunnelProfile(_ id: UUID?, to target: TunnelTarget) -> Bool {
        guard tunnelTargets.contains(target) else { return false }
        if let id {
            guard personalTunnelProfiles.contains(where: { $0.id == id }) else { return false }
        } else {
            guard case let .subscription(sourceID) = target, providerTunnelProfile(for: sourceID) != nil else { return false }
        }
        if let existing = tunnelAssignments.first(where: { $0.target == target }), existing.personalProfileID == id {
            return true
        }
        let previousConnectionProfile = connectionTunnelProfile
        storeTunnelProfileAssignment(id, to: target)
        schedulePersist()
        if connectionTunnelProfile != previousConnectionProfile {
            scheduleActiveSplitTunnelLiveApply()
        }
        return true
    }

    private func storeTunnelProfileAssignment(_ id: UUID?, to target: TunnelTarget) {
        if let index = tunnelAssignments.firstIndex(where: { $0.target == target }) {
            tunnelAssignments[index].personalProfileID = id
        } else {
            tunnelAssignments.append(TunnelProfileAssignment(target: target, personalProfileID: id))
        }
    }

    @discardableResult
    func copySplitTunnelProfile(id: UUID) -> UUID? {
        guard let original = splitTunnelProfiles.first(where: { $0.id == id }) else { return nil }
        let copy = SplitTunnelProfile(name: "\(original.name) — Custom", rules: original.rules,
                                      defaultAction: original.defaultAction, geodataSources: original.geodataSources,
                                      geodataUpdateIntervalMinutes: original.geodataUpdateIntervalMinutes)
        splitTunnelProfiles.append(copy)
        openSplitTunnelProfile(id: copy.id)
        return copy.id
    }

    private func importTunnelProfile(_ routing: SubscriptionRoutingImport, sourceID: UUID) {
        let target = TunnelTarget.subscription(sourceID)
        let previous = TunnelProfileResolver.profile(for: target, profiles: splitTunnelProfiles, assignments: tunnelAssignments)
        if case .profile(_, activate: false) = routing,
           !tunnelAssignments.contains(where: { $0.target == target }),
           previous?.subscriptionSourceID == nil, let id = previous?.id {
            // `add` stores a provider profile without changing this target's choice.
            storeTunnelProfileAssignment(id, to: target)
        }
        var ignoredSelection: UUID?
        var ignoredEnabled = false
        switch routing {
        case .profile:
            routing.apply(to: &splitTunnelProfiles, sourceID: sourceID,
                          selectedProfileID: &ignoredSelection, isEnabled: &ignoredEnabled)
        case .off:
            if let index = splitTunnelProfiles.firstIndex(where: { $0.subscriptionSourceID == sourceID }) {
                splitTunnelProfiles[index].isRoutingEnabled = false
            } else {
                splitTunnelProfiles.append(SplitTunnelProfile(
                    name: subscriptionSources.first { $0.id == sourceID }?.title ?? "Subscription",
                    subscriptionSourceID: sourceID, geodataSources: GeodataSources(), isRoutingEnabled: false))
            }
        }
        if selectedConnection.map(TunnelTarget.init(connection:)) == target, hasActiveConnectionSession {
            hasDeferredSubscriptionRoutingChanges = true
            splitTunnelApplyWorkItem?.cancel()
            splitTunnelApplyWorkItem = nil
            pendingSplitTunnelLiveApply = false
        }
        normalizeTunnelProfileSelection()
        // Every imported profile owns a cached pair, regardless of selection.
        // Cache preparation never activates files or changes the live session.
        if let profile = splitTunnelProfiles.first(where: { $0.subscriptionSourceID == sourceID }) {
            profileGeodataLibrary.preload(sources: profile.geodataSources ?? GeodataSources(), forceDownload: true)
        }
    }

    private func geodataIsReady(for sources: GeodataSources, requireLatestCache: Bool = true) -> Bool {
        GeodataKind.allCases.allSatisfy { kind in
            let expected = kind == .geosite ? sources.geositeURLString : sources.geoipURLString
            switch profileGeodataLibrary.status(for: kind, sources: sources) {
            case .loading: return false
            case let .ready(date):
                if requireLatestCache, let date, date != geodataLastUpdatedAt(for: kind) { return false }
            default: break
            }
            return expected == geodataURLString(for: kind)
                && (expected == nil ? !hasCustomGeodata(kind: kind) : hasCustomGeodata(kind: kind))
        }
    }

    nonisolated private func prepareConnectionGeodata(_ sources: GeodataSources, profileName: String) async throws {
        while await MainRunLoopWork.run({ [weak self] in
            guard let self else { return false }
            return self.profileGeodataLibrary.isLoading(sources: sources) || !self.updatingGeodataKinds.isEmpty
        }) { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        let started = await MainRunLoopWork.run { [weak self] in
            guard let self, !self.geodataIsReady(for: sources) else { return false }
            self.startGeodataUpdates(sources: sources)
            return true
        }
        guard started else { return }
        do {
            while await MainRunLoopWork.run({ [weak self] in self?.updatingGeodataKinds.isEmpty == false }) {
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
        } catch {
            await MainRunLoopWork.run { [weak self] in self?.geodataUpdateCoordinator.cancelAll() }
            throw error
        }
        let failure: String? = await MainRunLoopWork.run { [weak self] in
            guard let self, !self.geodataIsReady(for: sources) else { return nil }
            let errors = [(GeodataKind.geosite, self.geodataSettings.geositeLastError), (.geoip, self.geodataSettings.geoipLastError)]
                .compactMap { kind, error in error.map { "\(kind.displayName): \($0)" } }.joined(separator: "\n")
            return "Geodata for profile ‘\(profileName)’ could not be loaded. Check that profile's source URLs in Settings → Routing, then download its data again.\(errors.isEmpty ? "" : "\n" + errors)"
        }
        if let failure { throw GeodataUpdateError.networkFailure(failure) }
    }

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
