import Foundation

final class ConnectionHealthProbeQueue: @unchecked Sendable {
    typealias ConnectionLookup = (UUID) -> SavedConnection?
    typealias StateDidChange = (_ refreshingIDs: Set<UUID>, _ queuedIDs: Set<UUID>) -> Void
    typealias ResultsDidFlush = (_ results: [UUID: ConnectionHealthProbeResult]) -> Void

    private let healthProbeService: ConnectionHealthProbeService
    private let concurrencyLimit: Int
    private let connectionLookup: ConnectionLookup
    private let stateDidChange: StateDidChange
    private let resultsDidFlush: ResultsDidFlush

    private var pendingIDs: [UUID] = []
    private var pendingIDSet: Set<UUID> = []
    private var refreshingIDs: Set<UUID> = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingResults: [UUID: ConnectionHealthProbeResult] = [:]
    private var applyResultsWorkItem: DispatchWorkItem?

    init(
        healthProbeService: ConnectionHealthProbeService,
        concurrencyLimit: Int,
        connectionLookup: @escaping ConnectionLookup,
        stateDidChange: @escaping StateDidChange,
        resultsDidFlush: @escaping ResultsDidFlush
    ) {
        self.healthProbeService = healthProbeService
        self.concurrencyLimit = concurrencyLimit
        self.connectionLookup = connectionLookup
        self.stateDidChange = stateDidChange
        self.resultsDidFlush = resultsDidFlush
    }

    func enqueue(ids: [UUID], force: Bool, priority: Bool) {
        guard !ids.isEmpty else { return }

        var prioritizedIDs: [UUID] = []

        for id in ids {
            guard let connection = connectionLookup(id) else { continue }
            guard force || Self.needsRefresh(for: connection) else { continue }
            guard activeTasks[id] == nil else { continue }
            guard !pendingIDSet.contains(id) else { continue }

            if priority {
                prioritizedIDs.append(id)
            } else {
                pendingIDs.append(id)
            }
            pendingIDSet.insert(id)
        }

        publishState()

        if priority, !prioritizedIDs.isEmpty {
            pendingIDs.insert(contentsOf: prioritizedIDs, at: 0)
        }

        drain()
    }

    func cancelAll() {
        pendingIDs = []
        pendingIDSet = []
        for task in activeTasks.values { task.cancel() }
        activeTasks = [:]
        refreshingIDs = []
        pendingResults = [:]
        applyResultsWorkItem?.cancel()
        applyResultsWorkItem = nil
        publishState()
    }

    func cancel(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        refreshingIDs.remove(id)
        pendingIDSet.remove(id)
        pendingIDs.removeAll { $0 == id }
        publishState()
    }

    func cancel(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            cancel(id: id)
        }
    }

    private func drain() {
        while activeTasks.count < concurrencyLimit, let nextID = pendingIDs.first {
            pendingIDs.removeFirst()
            pendingIDSet.remove(nextID)
            publishState()

            guard let connection = connectionLookup(nextID) else {
                continue
            }

            refreshingIDs.insert(nextID)
            publishState()

            let task = Task.detached(priority: .utility) { [healthProbeService, connection, nextID, queue = self] in
                let result = await healthProbeService.probe(connection)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    queue.receive(result, for: nextID)
                }
            }
            activeTasks[nextID] = task
        }
    }

    private func receive(_ result: ConnectionHealthProbeResult, for connectionID: UUID) {
        activeTasks[connectionID] = nil
        pendingResults[connectionID] = result
        scheduleResultFlush()
        drain()
    }

    private func scheduleResultFlush() {
        guard applyResultsWorkItem == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.flushResults()
            }
        }

        applyResultsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func flushResults() {
        applyResultsWorkItem = nil
        guard !pendingResults.isEmpty else { return }

        let results = pendingResults
        pendingResults = [:]

        for connectionID in results.keys {
            refreshingIDs.remove(connectionID)
        }
        publishState()

        resultsDidFlush(results)
    }

    private func publishState() {
        stateDidChange(refreshingIDs, pendingIDSet)
    }

    private static func needsRefresh(for connection: SavedConnection) -> Bool {
        guard let healthCheck = connection.healthCheck else {
            return true
        }

        switch healthCheck.state {
        case .unknown, .queued, .checking:
            return true
        case .reachable, .unreachable:
            return false
        }
    }
}
