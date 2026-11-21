import Foundation

/// Holds the privileged leak guard across the whole span in which a TUN session is
/// meant to be carrying traffic — including the parts where no session exists.
///
/// A routed session is torn down and rebuilt whenever the uplink changes, and it
/// is torn down and *not* rebuilt for as long as the uplink stays away. Both are
/// windows in which the machine routes directly, and applications use them: a
/// browser reissues its open requests the moment an address is published, and the
/// far side records the address it arrived from. The guard spans them because it
/// is armed before the session that follows and released only when the user says
/// so.
///
/// One owner of the stage and one renewal loop: the guard the helper holds always
/// matches the last stage set here. Missed heartbeats tighten it to standby.
actor LeakGuardService {
    /// Comfortably inside the helper's lease, so an ordinary hiccup — a busy
    /// machine, one dropped XPC call — never expires a guard that is still wanted.
    static let renewalInterval: TimeInterval = 45
    static let leaseSeconds: TimeInterval = 180

    private let client: PrivilegedHelperClient
    private let log: TeleportLog
    private var stage: LeakGuardRuleset.Stage?
    private var protectedHosts: [String] = []
    private var policy = LeakGuardPolicy()
    private var isEnabled: Bool
    private(set) var lastError: String?
    private var generation = UUID()
    private var cleanupPending = false
    private var releaseError: String?
    private var renewalTask: Task<Void, Never>?
    /// Last confirmed helper state, independent of the user's setting or wanted stage.
    struct Observation: Equatable, Sendable {
        var releasePending: Bool
        var held: Bool
        var error: String?
    }
    private var observation: Observation?
    private var holdingContinuations: [UUID: AsyncStream<Observation>.Continuation] = [:]

    nonisolated static let subsystem = "leakguard"

    init(client: PrivilegedHelperClient = PrivilegedHelperClient(), isEnabled: Bool = true, log: TeleportLog = .shared) {
        self.client = client
        self.isEnabled = isEnabled
        self.log = log
    }

    /// Loading a preference must never release protection left by a crashed app.
    func configure(isEnabled: Bool) { self.isEnabled = isEnabled }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        if !enabled { await disarm() }
    }

    /// Required before resolving endpoints or changing routes. Failure aborts start.
    func armBootstrap() async throws {
        generation = UUID()
        stage = .standby
        policy = .init()
        guard isEnabled else { return }
        try await engage()
    }

    func armStandby() async {
        do { try await armBootstrap() }
        catch is CancellationError { return }
        catch {
            lastError = error.localizedDescription
            log.error(Self.subsystem, "could not arm protection: \(LogFormat.error(error))")
        }
    }

    func resolveEndpoint(host: String, interface: String) async throws -> [String] {
        try await client.resolveEndpoint(host: host, interface: interface)
    }

    func refreshStatus() async {
        let expected = generation
        let previous = observation
        do {
            let status = try await client.status()
            guard expected == generation, observation == previous else { return }
            if let pending = status.cleanupPending {
                cleanupPending = pending || (releaseError != nil && status.isLeakGuardEngaged)
                if !cleanupPending { releaseError = nil }
            }
            updateHolding(status.isLeakGuardEngaged)
        } catch {
            guard expected == generation, observation == previous else { return }
            updateHolding(false, error: error.localizedDescription)
        }
    }

    /// A session is about to own `tunnelInterface`. Throws so the connect that asked
    /// for it fails: a guard that silently did not engage is worse than none, because
    /// the user believes the window is closed.
    func armForSession(tunnelInterface: String, protectedHosts: [String], policy: LeakGuardPolicy = .init()) async throws {
        generation = UUID()
        self.policy = policy
        self.protectedHosts = protectedHosts
        stage = .session(tunnelInterface: tunnelInterface)
        guard isEnabled else { return }
        try await engage()
    }

    var isHoldingUplink: Bool { cleanupPending || observation?.held == true || (isEnabled && stage != nil) }

    func holdingUpdates() -> AsyncStream<Observation> {
        AsyncStream { continuation in
            let id = UUID()
            holdingContinuations[id] = continuation
            if let observation { continuation.yield(observation) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeHoldingContinuation(id) }
            }
        }
    }

    private func removeHoldingContinuation(_ id: UUID) {
        holdingContinuations.removeValue(forKey: id)
    }

    private func updateHolding(_ held: Bool, error: String? = nil) {
        let next = Observation(releasePending: cleanupPending, held: held, error: releaseError ?? error)
        guard observation != next else { return }
        observation = next
        for continuation in holdingContinuations.values { continuation.yield(next) }
    }


    /// The guard is no longer wanted at all: no stage is left to come back to.
    func disarm() async {
        // A previous process may have left persistent protection behind.
        let protectionWasRequested = isHoldingUplink
        generation = UUID()
        stage = nil
        await releaseHeldGuard(protectionWasRequested: protectionWasRequested)
    }

    private func releaseHeldGuard(protectionWasRequested: Bool) async {
        renewalTask?.cancel()
        renewalTask = nil
        let expected = generation
        do {
            try await client.releaseLeakGuard()
            guard expected == generation else { return }
            releaseError = nil
            cleanupPending = false
            updateHolding(false)
            lastError = nil
        } catch {
            guard expected == generation else { return }
            lastError = error.localizedDescription
            if protectionWasRequested {
                releaseError = error.localizedDescription
                cleanupPending = true
                updateHolding(false, error: releaseError)
            }
            // Keep failure visible: persistent protection is never timed out open.
            log.warn(Self.subsystem, "could not release the leak guard: \(LogFormat.error(error))")
        }
    }

    private func engage() async throws {
        guard let stage else { return }
        let tunnelInterfaceName: String?
        switch stage {
        case .standby:
            tunnelInterfaceName = nil
        case let .session(tunnelInterface):
            tunnelInterfaceName = tunnelInterface
        }
        let expected = generation
        do {
            try await client.engageLeakGuard(
                tunnelInterfaceName: tunnelInterfaceName,
                protectedHosts: protectedHosts,
                leaseSeconds: Self.leaseSeconds, policy: policy
            )
        } catch {
            guard expected == generation else { throw CancellationError() }
            throw error
        }
        guard expected == generation else { throw CancellationError() }
        releaseError = nil
        cleanupPending = false
        updateHolding(true)
        lastError = nil
        startRenewing()
    }

    private func startRenewing() {
        guard renewalTask == nil else { return }
        renewalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.renewalInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.renew()
            }
        }
    }

    func renew() async {
        guard isEnabled, stage != nil else { return }
        let expected = generation
        do {
            try await engage()
        } catch {
            guard expected == generation, !Task.isCancelled, stage != nil else { return }
            lastError = error.localizedDescription
            updateHolding(false, error: error.localizedDescription)
            log.warn(Self.subsystem, "could not renew the leak guard: \(LogFormat.error(error))")
        }
    }
}
