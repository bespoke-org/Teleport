import Foundation

nonisolated protocol GeodataUpdateServicing: Sendable {
    func cacheCurrentDownload(for kind: GeodataKind, source: URL?, updatedAt: Date?) throws
    func prepareUpdate(kind: GeodataKind, from source: URL, useCache: Bool) async throws -> GeodataUpdateService.PreparedUpdate
    func activate(_ update: GeodataUpdateService.PreparedUpdate, for kind: GeodataKind) throws
    func discard(_ update: GeodataUpdateService.PreparedUpdate)
    func hasCustomGeodata(for kind: GeodataKind) -> Bool
    func removeCustomGeodata(for kind: GeodataKind) throws
}

/// Owns each kind's current request and groups overlapping work into one batch.
/// Entry points run on the main actor, like the owning AppViewModel.
/// Replacing a request keeps its batch open; stale completions can only discard
/// staging files, never activate data, publish settings, or complete the batch.
final class GeodataUpdateCoordinator {
    struct Request: Sendable {
        let kind: GeodataKind
        let source: URL?
        let useCache: Bool
        var previousSource: URL?
        var previousUpdatedAt: Date?
    }

    struct Change {
        let source: URL?
        let updatedAt: Date?
        let changed: Bool
    }

    enum Outcome {
        case applied(Change)
        case failed(Error)
        case cancelled
    }

    struct Batch {
        let id = UUID()
        var outcomes: [GeodataKind: Outcome] = [:]
        var changedKinds: Set<GeodataKind> = []
    }

    private struct Job {
        let token: UUID
        let request: Request
        let task: Task<Void, Never>
    }

    private let service: any GeodataUpdateServicing
    private var jobs: [GeodataKind: Job] = [:]
    private var batch: Batch?

    var stateDidChange: (() -> Void)?
    var didFinish: ((GeodataKind, Outcome) -> Void)?
    var batchDidComplete: ((Batch) -> Void)?
    var updatingKinds: Set<GeodataKind> { Set(jobs.keys) }

    init(service: any GeodataUpdateServicing = GeodataUpdateService()) {
        self.service = service
    }

    func hasCustomGeodata(for kind: GeodataKind) -> Bool {
        service.hasCustomGeodata(for: kind)
    }

    @discardableResult
    func startBatch(_ requests: [Request]) -> UUID? {
        guard !requests.isEmpty else { return nil }
        if batch == nil { batch = Batch() }
        // Register every request before yielding, including bundled resets.
        for request in requests {
            jobs[request.kind]?.task.cancel()
            batch?.outcomes[request.kind] = nil
            let token = UUID()
            let task = Task { @MainActor [weak self, service] in
                do {
                    try await BlockingWork.run {
                        try service.cacheCurrentDownload(for: request.kind, source: request.previousSource,
                                                         updatedAt: request.previousUpdatedAt)
                    }
                    try Task.checkCancellation()
                    if let source = request.source {
                        let prepared = try await service.prepareUpdate(kind: request.kind, from: source,
                                                                       useCache: request.useCache)
                        defer { service.discard(prepared) }
                        guard let self, self.isCurrent(request.kind, token: token), !Task.isCancelled else { return }
                        // No suspension between ownership validation and publication.
                        try service.activate(prepared, for: request.kind)
                        self.finish(request.kind, token: token, outcome: .applied(Change(
                            source: source, updatedAt: prepared.updatedAt, changed: prepared.changed
                        )))
                    } else {
                        guard let self, self.isCurrent(request.kind, token: token), !Task.isCancelled else { return }
                        let changed = service.hasCustomGeodata(for: request.kind)
                        try service.removeCustomGeodata(for: request.kind)
                        self.finish(request.kind, token: token, outcome: .applied(Change(
                            source: nil, updatedAt: nil, changed: changed
                        )))
                    }
                } catch is CancellationError {
                    self?.finish(request.kind, token: token, outcome: .cancelled)
                } catch {
                    self?.finish(request.kind, token: token, outcome: .failed(error))
                }
            }
            jobs[request.kind] = Job(token: token, request: request, task: task)
        }
        stateDidChange?()
        return batch?.id
    }

    func cancel(kind: GeodataKind) {
        guard let job = jobs[kind] else { return }
        job.task.cancel()
        finish(kind, token: job.token, outcome: .cancelled)
    }

    func cancelAll() {
        // Cancel as one operation so the batch completes once, after all its jobs.
        let cancelled = jobs
        jobs.removeAll()
        for (kind, job) in cancelled {
            job.task.cancel()
            batch?.outcomes[kind] = .cancelled
            didFinish?(kind, .cancelled)
        }
        stateDidChange?()
        completeBatchIfReady()
    }

    private func isCurrent(_ kind: GeodataKind, token: UUID) -> Bool {
        jobs[kind]?.token == token
    }

    private func finish(_ kind: GeodataKind, token: UUID, outcome: Outcome) {
        guard isCurrent(kind, token: token) else { return }
        jobs[kind] = nil
        batch?.outcomes[kind] = outcome
        if case let .applied(change) = outcome, change.changed {
            batch?.changedKinds.insert(kind)
        }
        didFinish?(kind, outcome)
        stateDidChange?()
        completeBatchIfReady()
    }

    private func completeBatchIfReady() {
        guard jobs.isEmpty, let completed = batch else { return }
        batch = nil
        batchDidComplete?(completed)
    }
}
