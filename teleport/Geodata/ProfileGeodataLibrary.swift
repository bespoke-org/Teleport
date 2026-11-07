import Foundation

/// Availability belongs to a source, not to whichever dataset is currently
/// published for Xray. Profiles sharing a URL intentionally share its download.
final class ProfileGeodataLibrary {
    struct Key: Hashable {
        let kind: GeodataKind
        let source: URL
    }

    enum Status: Equatable {
        case bundled
        case missing
        case loading
        case ready(Date?)
        case failed(String)
    }

    private struct Job {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var jobs: [Key: Job] = [:]
    private var statuses: [Key: Status] = [:]
    private var cachedKeys: Set<Key> = []
    private let coordinator: GeodataUpdateCoordinator
    var didChange: (() -> Void)?
    var didCache: ((Key) -> Void)?

    init(coordinator: GeodataUpdateCoordinator) {
        self.coordinator = coordinator
    }

    func status(for kind: GeodataKind, sources: GeodataSources) -> Status {
        guard let value = sourceString(kind, sources: sources) else { return .bundled }
        guard let source = GeodataUpdateService.validatedSourceURL(value) else {
            return .failed(GeodataUpdateError.invalidURL.localizedDescription)
        }
        return statuses[Key(kind: kind, source: source)] ?? .missing
    }

    func isLoading(sources: GeodataSources) -> Bool {
        GeodataKind.allCases.contains { status(for: $0, sources: sources) == .loading }
    }

    func hasCachedPair(sources: GeodataSources) -> Bool {
        GeodataKind.allCases.allSatisfy { kind in
            guard let value = sourceString(kind, sources: sources) else { return true }
            guard let source = URL(string: value) else { return false }
            return cachedKeys.contains(Key(kind: kind, source: source))
        }
    }

    func preload(sources: GeodataSources, forceDownload: Bool = false) {
        for kind in GeodataKind.allCases {
            guard let value = sourceString(kind, sources: sources),
                  let source = GeodataUpdateService.validatedSourceURL(value) else { continue }
            let key = Key(kind: kind, source: source)
            guard jobs[key] == nil else { continue }
            if !forceDownload, cachedKeys.contains(key), case .ready = statuses[key] { continue }
            let token = UUID()
            statuses[key] = .loading
            let task = Task.detached { [weak self, coordinator] in
                do {
                    let date = try await coordinator.cacheUpdate(kind: kind, from: source, useCache: !forceDownload)
                    await MainRunLoopWork.run { [weak self] in
                        guard let self, self.jobs[key]?.token == token else { return }
                        self.jobs[key] = nil
                        self.statuses[key] = .ready(date)
                        self.cachedKeys.insert(key)
                        self.didCache?(key)
                        self.didChange?()
                    }
                } catch {
                    await MainRunLoopWork.run { [weak self] in
                        guard let self, self.jobs[key]?.token == token else { return }
                        self.jobs[key] = nil
                        self.statuses[key] = error is CancellationError ? .missing : .failed(error.localizedDescription)
                        self.didChange?()
                    }
                }
            }
            jobs[key] = Job(token: token, task: task)
        }
        didChange?()
    }

    func recordReady(kind: GeodataKind, source: URL, date: Date?, cached: Bool = true) {
        let key = Key(kind: kind, source: source)
        jobs.removeValue(forKey: key)?.task.cancel()
        statuses[key] = .ready(date)
        if cached { cachedKeys.insert(key) }
        didChange?()
    }

    func cancel(sources: GeodataSources) {
        for kind in GeodataKind.allCases {
            guard let value = sourceString(kind, sources: sources), let source = URL(string: value) else { continue }
            let key = Key(kind: kind, source: source)
            if let job = jobs.removeValue(forKey: key) {
                job.task.cancel()
                statuses[key] = .missing
            }
        }
        didChange?()
    }

    func cancelAll() {
        let cancelled = jobs
        jobs.removeAll()
        for (key, job) in cancelled {
            job.task.cancel()
            statuses[key] = .missing
        }
        didChange?()
    }

    private func sourceString(_ kind: GeodataKind, sources: GeodataSources) -> String? {
        kind == .geosite ? sources.geositeURLString : sources.geoipURLString
    }
}
