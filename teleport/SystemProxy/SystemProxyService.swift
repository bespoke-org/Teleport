import Foundation

/// One coordinator owns preferences, recovery, and notifications for both modes.
/// Every operation is synchronous leaf work, called off the cooperative pool.
nonisolated final class SystemProxyService: @unchecked Sendable {
    static let shared = SystemProxyService()
    static let subsystem = "sysproxy"

    private let lock = NSRecursiveLock()
    private let preferences: any ProxyPreferencesAccess
    private let journalStore: any ProxyJournalStoring
    private let log: TeleportLog
    private var session: ProxySessionRecord?
    private var records: [ProxyServiceRecord] = []
    private var pendingFailure: ConnectionFailure?
    private var deferredRecoverySuppressed = false
    private var takeoverReserved = false
    private var observation: (any ProxyPreferencesObserving)?
    private var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(
        fileManager: FileManager = .default,
        log: TeleportLog = .shared,
        preferences: any ProxyPreferencesAccess = HelperProxyPreferences(),
        journalStore: (any ProxyJournalStoring)? = nil
    ) {
        self.preferences = preferences
        self.journalStore = journalStore ?? ProxyJournalStore(fileManager: fileManager)
        self.log = log
    }

    func hasSavedProxySnapshot() -> Bool { synchronized { journalStore.exists } }

    func reserveForStop() throws {
        try synchronized {
            try journalStore.acquire()
            takeoverReserved = true
        }
    }

    /// Acquire process ownership before a backend cleans up runtimes or starts
    /// requesting approval. A second app must not recover a live app's settings.
    func prepareForTakeover() throws {
        try synchronized {
            try journalStore.acquire()
            do { _ = try journalStore.load() } catch {
                if session == nil { journalStore.release() }
                throw error
            }
            takeoverReserved = true
        }
    }

    func enableProxy(endpoint: ProxyEndpoint) throws { try takeOver(mode: .systemProxy, endpoint: endpoint) }
    func suspendProxyForTUN() throws { try takeOver(mode: .tun, endpoint: .default) }
    func disableProxy() throws { try restoreSavedProxyState() }

    func rollbackIfActive() throws {
        try synchronized {
            if session != nil {
                try restoreSavedProxyState()
            } else {
                takeoverReserved = false
                journalStore.release()
            }
        }
    }

    private func takeOver(mode: ConnectionMode, endpoint: ProxyEndpoint) throws {
        try synchronized {
            try journalStore.acquire()
            deferredRecoverySuppressed = false
            var wroteIntent = false
            do {
                if let session {
                    if let failure = checkForConflict() { throw failure }
                    // A TUN rebuild keeps its original pre-session preferences.
                    if session.mode == .tun, mode == .tun { takeoverReserved = false; return }
                    try restoreLocked()
                }
                pendingFailure = nil
                if journalStore.exists { try restoreLocked() }
                var journal = try journalStore.load() ?? ProxyJournal()
                try preferences.transaction { inventory, apply in
                    guard !inventory.eligibleServiceIDs.isEmpty else { throw SystemProxyError.noServices }
                    guard !journal.services.contains(where: { inventory.eligibleServiceIDs.contains($0.serviceID) }) else {
                        throw SystemProxyError.unresolvedService
                    }
                    let newSession = ProxySessionRecord(id: UUID(), mode: mode, locationID: inventory.locationID, eligibleServiceIDs: inventory.eligibleServiceIDs)
                    var newRecords: [ProxyServiceRecord] = []
                    var mutations: [ProxyMutation] = []
                    let groups = ProxyGroup.allCases.filter { mode == .systemProxy || $0 != .bypass }
                    for id in inventory.eligibleServiceIDs.sorted() {
                        guard let service = inventory.services[id] else { throw SystemProxyError.preferencesUnavailable }
                        try service.rejectUnsafeAuthentication(mode: mode)
                        var mutation = ProxyMutation(serviceID: id)
                        let groupRecords = groups.map { group in
                            let original = group.values(in: service.values)
                            let applied = group.target(from: original, mode: mode, endpoint: endpoint)
                            for (key, value) in applied where original[key] != value { mutation.values[key] = value }
                            mutation.removed.formUnion(original.keys.filter { applied[$0] == nil })
                            return ProxyGroupRecord(
                                group: group, original: original, applied: applied,
                                hasCredentialMetadata: service.credentialGroups.contains(group))
                        }
                        newRecords.append(ProxyServiceRecord(sessionID: newSession.id, serviceID: id, serviceName: service.name, groups: groupRecords))
                        if !mutation.values.isEmpty || !mutation.removed.isEmpty { mutations.append(mutation) }
                    }
                    journal.session = newSession
                    journal.services += newRecords
                    // Intent is durable before the one atomic preferences commit.
                    // Recovery accepts either the original or intended group state.
                    try journalStore.save(journal)
                    wroteIntent = true
                    try apply(mutations)
                    session = newSession
                    takeoverReserved = false
                    records = newRecords
                    log.info(Self.subsystem, "took over proxy preferences for \(newRecords.count) services")
                }
                if let failure = checkForConflict() { throw failure }
            } catch {
                takeoverReserved = false
                let primary = error
                do {
                    if wroteIntent || session != nil { try restoreLocked() }
                } catch {
                    deferredRecoverySuppressed = true
                    journalStore.release()
                    throw failureWithCleanup(primary, cleanup: error)
                }
                journalStore.release()
                throw primary
            }
        }
    }

    func restoreSavedProxyState() throws {
        try synchronized {
            try journalStore.acquire()
            takeoverReserved = false
            defer { journalStore.release() }
            do {
                try restoreLocked()
                deferredRecoverySuppressed = false
            } catch {
                deferredRecoverySuppressed = true
                throw error
            }
        }
    }

    private func restoreLocked() throws {
        var conflict = pendingFailure
        let previousSession = session
        let previousRecords = records
        session = nil
        records = []
        guard var journal = try journalStore.load() else { return }
        // Missing services need no privileged write. Keep their records and avoid
        // asking for authorization on every path notification while they are gone.
        let readable = try preferences.read()
        if let previousSession {
            conflict = conflict ?? conflictIn(readable, session: previousSession, records: previousRecords)
            if conflict != nil {
                relinquishExternalGroups(in: &journal, observed: previousRecords, inventory: readable)
                try journalStore.save(journal)
            }
        }
        if !journal.services.contains(where: { readable.services[$0.serviceID] != nil }) {
            journal.session = nil
            try journalStore.save(journal.services.isEmpty ? nil : journal)
            if let conflict { throw conflict }
            return
        }
        do {
            try preferences.transaction { inventory, apply in
                if conflict == nil, let previousSession {
                    conflict = conflictIn(inventory, session: previousSession, records: previousRecords)
                }
                journal.session = nil
                var retained: [ProxyServiceRecord] = []
                var restoredIDs: Set<String> = []
                var mutations: [ProxyMutation] = []
                for var record in journal.services {
                    guard let service = inventory.services[record.serviceID] else {
                        retained.append(record)
                        continue
                    }
                    var mutation = ProxyMutation(serviceID: record.serviceID)
                    record.groups = record.groups.filter { group in
                        guard !group.relinquished else { return false }
                        let current = group.group.values(in: service.values)
                        // Password metadata introduced by another writer is also
                        // a conflict, even though we never serialize its value.
                        guard service.credentialGroups.contains(group.group) == group.hasCredentialMetadata,
                            current == group.original || current == group.applied
                        else {
                            log.warn(Self.subsystem, "preserving external \(group.group.rawValue) change on service \(record.serviceID)")
                            return false
                        }
                        if current == group.applied { mutation.restore(group) }
                        return true
                    }
                    if !record.groups.isEmpty {
                        // Keep already-original groups until apply succeeds: a
                        // previous restore may have committed but failed to apply.
                        retained.append(record)
                        restoredIDs.insert(record.serviceID)
                    }
                    if !mutation.values.isEmpty || !mutation.removed.isEmpty { mutations.append(mutation) }
                }
                journal.services = retained
                // Relinquished groups are removed durably before any other write.
                try journalStore.save(journal)
                if !restoredIDs.isEmpty { try apply(mutations) }
                journal.services.removeAll { restoredIDs.contains($0.serviceID) }
                try journalStore.save(journal.services.isEmpty ? nil : journal)
            }
        } catch {
            if let conflict { throw failureWithCleanup(conflict, cleanup: error) }
            throw error
        }
        if let conflict {
            pendingFailure = conflict
            throw conflict
        }
    }

    /// A declined authorization must not reopen on every path notification.
    func restoreDeferredProxyStateIfNeeded() throws {
        try synchronized {
            guard session == nil, !takeoverReserved, journalStore.exists, !deferredRecoverySuppressed else { return }
            try restoreSavedProxyState()
        }
    }

    /// A root session can survive an app crash. Adopt its durable expectations so
    /// the relaunched provider monitors settings without taking them over again.
    func resumeMonitoringIfNeeded() throws {
        try synchronized {
            guard session == nil else { return }
            try journalStore.acquire()
            do {
                guard let journal = try journalStore.load(), let savedSession = journal.session else {
                    throw SystemProxyError.unresolvedService
                }
                session = savedSession
                records = journal.services.filter { $0.sessionID == savedSession.id }
            } catch {
                journalStore.release()
                throw error
            }
        }
    }

    func checkForConflict() -> ConnectionFailure? {
        synchronized {
            if let pendingFailure { return pendingFailure }
            guard let session else { return nil }
            do {
                let inventory = try preferences.read()
                pendingFailure = conflictIn(inventory, session: session, records: records)
                if pendingFailure != nil, var journal = try journalStore.load() {
                    // Record observed ownership loss before a possible approval
                    // dialog. A later value equal to our old value is still external.
                    relinquishExternalGroups(in: &journal, observed: records, inventory: inventory)
                    records = journal.services.filter { $0.sessionID == session.id }
                    try journalStore.save(journal)
                }
            } catch {
                pendingFailure = ConnectionFailure(
                    summary: "Proxy settings could not be verified",
                    details: "Teleport stopped to avoid continuing with unknown proxy settings. \(error.localizedDescription)",
                    requiresExplicitReconnect: true
                )
            }
            return pendingFailure
        }
    }

    private func relinquishExternalGroups(in journal: inout ProxyJournal, observed: [ProxyServiceRecord], inventory: ProxyInventory) {
        for index in journal.services.indices {
            guard let baseline = observed.first(where: {
                $0.serviceID == journal.services[index].serviceID && $0.sessionID == journal.services[index].sessionID
            }) else { continue }
            let live = inventory.services[baseline.serviceID]
            for groupIndex in journal.services[index].groups.indices {
                let group = journal.services[index].groups[groupIndex]
                let alreadyRelinquished = baseline.groups.first { $0.group == group.group }?.relinquished == true
                let changed = live.map {
                    group.group.values(in: $0.values) != group.applied || $0.credentialGroups.contains(group.group) != group.hasCredentialMetadata
                } ?? false
                if alreadyRelinquished || changed { journal.services[index].groups[groupIndex].relinquished = true }
            }
        }
    }

    private func conflictIn(_ inventory: ProxyInventory, session: ProxySessionRecord, records: [ProxyServiceRecord]) -> ConnectionFailure? {
        if inventory.locationID != session.locationID || !inventory.eligibleServiceIDs.isSubset(of: session.eligibleServiceIDs) {
            return ConnectionFailure(
                summary: "Network proxy scope changed",
                details:
                    "A network location changed or a new network service became eligible. Its settings were left untouched. Reconnect to configure the current services.",
                requiresExplicitReconnect: true
            )
        }
        for record in records {
            guard let service = inventory.services[record.serviceID] else { continue }
            for group in record.groups {
                if group.group.values(in: service.values) != group.applied
                    || service.credentialGroups.contains(group.group) != group.hasCredentialMetadata
                {
                    return ConnectionFailure(
                        summary: "System proxy settings changed outside Teleport",
                        details:
                            "The \(group.group.label) settings for “\(service.name)” changed. Teleport stopped and preserved the external change. Reconnect when ready.",
                        requiresExplicitReconnect: true
                    )
                }
            }
        }
        return nil
    }

    func changes() -> AsyncStream<Void> {
        synchronized {
            let id = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.synchronized { self?.subscribers.removeValue(forKey: id) }
            }
            if observation == nil {
                observation = preferences.observe { [weak self] in
                    self?.synchronized {
                        guard let self else { return }
                        for subscriber in self.subscribers.values { subscriber.yield(()) }
                    }
                }
            }
            return stream
        }
    }

    private func failureWithCleanup(_ primary: Error, cleanup: Error) -> ConnectionFailure {
        let failure = ConnectionFailure(error: primary)
        if failure == ConnectionFailure(error: cleanup) { return failure }
        return ConnectionFailure(
            summary: failure.summary,
            details: [failure.details, "Proxy recovery is incomplete: \(cleanup.localizedDescription)"].compactMap { $0 }.joined(separator: "\n"),
            requiresExplicitReconnect: failure.requiresExplicitReconnect
        )
    }

    @discardableResult
    private func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
