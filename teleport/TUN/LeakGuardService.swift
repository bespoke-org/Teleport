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
/// matches the last stage set here, and the helper releases it if this loop stops.
actor LeakGuardService {
    /// Comfortably inside the helper's lease, so an ordinary hiccup — a busy
    /// machine, one dropped XPC call — never expires a guard that is still wanted.
    static let renewalInterval: TimeInterval = 45
    static let leaseSeconds: TimeInterval = 180

    private let client: PrivilegedHelperClient
    private let log: TeleportLog
    private var stage: LeakGuardRuleset.Stage?
    private var protectedHosts: [String] = []
    /// Servers opened for the duration of a health check. Held apart from
    /// `protectedHosts` so that re-arming a stage never inherits them and a probe
    /// that ends always takes its own path back down with it.
    private var probeExemptions = ProbeHostExemptions()
    private var isEnabled: Bool
    private var renewalTask: Task<Void, Never>?

    nonisolated static let subsystem = "leakguard"

    init(client: PrivilegedHelperClient = PrivilegedHelperClient(), isEnabled: Bool = true, log: TeleportLog = .shared) {
        self.client = client
        self.isEnabled = isEnabled
        self.log = log
    }

    /// Turning the guard off releases whatever is held now: a user who switches it
    /// off while a session runs is asking for the machine to stop being filtered,
    /// not for the change to take effect at some later reconnect.
    func setEnabled(_ isEnabled: Bool) async {
        guard self.isEnabled != isEnabled else { return }
        self.isEnabled = isEnabled
        if isEnabled {
            // The stage survived being turned off, so turning it back on protects
            // the session already running rather than only the next one.
            if stage != nil { try? await engage() }
        } else {
            await releaseHeldGuard()
        }
    }

    /// The tunnel that existed has just been torn down, or is about to be. The
    /// proxy servers stay allowed: a standby exists between two sessions to the
    /// same servers, and blocking them would leave nothing able to rebuild one.
    ///
    /// Failure is logged rather than thrown — this runs on teardown paths with no
    /// operation to fail, and the connect that follows fails closed on its own.
    func armStandby() async {
        stage = .standby
        guard isEnabled else { return }
        do {
            try await engage()
        } catch {
            log.error(Self.subsystem, "could not arm the leak guard: \(LogFormat.error(error))")
        }
    }

    /// A session is about to own `tunnelInterface`. Throws so the connect that asked
    /// for it fails: a guard that silently did not engage is worse than none, because
    /// the user believes the window is closed.
    func armForSession(tunnelInterface: String, protectedHosts: [String]) async throws {
        self.protectedHosts = protectedHosts
        stage = .session(tunnelInterface: tunnelInterface)
        guard isEnabled else { return }
        try await engage()
    }

    /// Whether the uplink is filtered right now, which is what makes a health probe
    /// need a path opened before it can ask anything.
    var isHoldingUplink: Bool {
        isEnabled && stage != nil
    }

    /// Opens the addresses of a server a health check is about to question, and
    /// closes them again when it is done.
    ///
    /// Failure is logged rather than thrown: a check is diagnostics, and must not
    /// fail the app over a path it could not open. A path that could not be closed
    /// is bounded by the helper's lease, which the renewal loop re-establishes from
    /// the set held here.
    func retainProbeHosts(_ addresses: [String]) async {
        guard probeExemptions.retain(addresses) else { return }
        await reengageForProbeHosts()
    }

    func releaseProbeHosts(_ addresses: [String]) async {
        guard probeExemptions.release(addresses) else { return }
        await reengageForProbeHosts()
    }

    private func reengageForProbeHosts() async {
        guard isEnabled, stage != nil else { return }
        do {
            try await engage()
        } catch {
            log.warn(Self.subsystem, "could not open a path for a health check: \(LogFormat.error(error))")
        }
    }

    /// The guard is no longer wanted at all: no stage is left to come back to.
    func disarm() async {
        guard stage != nil else { return }
        stage = nil
        await releaseHeldGuard()
    }

    private func releaseHeldGuard() async {
        renewalTask?.cancel()
        renewalTask = nil
        do {
            try await client.releaseLeakGuard()
        } catch {
            // The helper's lease releases it shortly anyway, which is the whole
            // reason the lease exists.
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
        try await client.engageLeakGuard(
            tunnelInterfaceName: tunnelInterfaceName,
            protectedHosts: protectedHosts + probeExemptions.addresses,
            leaseSeconds: Self.leaseSeconds
        )
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

    private func renew() async {
        guard isEnabled, stage != nil else { return }
        do {
            try await engage()
        } catch {
            log.warn(Self.subsystem, "could not renew the leak guard: \(LogFormat.error(error))")
        }
    }
}
