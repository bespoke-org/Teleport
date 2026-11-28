import Foundation

/// One executor owns provider operations. UI and system observers only replace
/// inputs; presentation is a read-only stream and never drives execution.
actor ConnectionIntentRuntime {
    nonisolated enum Desired: Sendable, Equatable {
        case preserve, disconnected, connected(ConnectionRequest)
    }

    nonisolated enum Activity: Sendable, Equatable {
        case idle, restoringProxy, disconnecting, waitingForNetwork
        case connecting(ConnectionRequest)
    }

    nonisolated struct Presentation: Sendable, Equatable {
        var providerID: UUID
        var intentRevision: UInt64 = 0
        var state: ConnectionState = .preparing
        var activity: Activity = .idle
        var appliedRequest: ConnectionRequest?
        var failure: ConnectionFailure?
        var isSettled = false
        var allowsLaunchConnection = false
    }

    nonisolated private struct Provider: Sendable {
        let id = UUID()
        let value: any ConnectionProvider
        let mode: ConnectionMode
        var adoptionRequest: ConnectionRequest?
    }

    nonisolated private struct Network: Sendable, Equatable {
        let uplink: SystemUplinkInventory.Uplink?
        var isReady: Bool { uplink?.routerAddress != nil }
    }

    nonisolated private struct Input: Sendable {
        var provider: Provider
        var desired: Desired = .preserve
        var intentRevision: UInt64 = 0
        // Changes of target, including an intermediate disconnect, end recovery.
        // Equal connect clicks still advance intentRevision to request a retry.
        var desireGeneration: UInt64 = 0
        var network: Network?
        var settledNetwork: Network?
        var networkRevision: UInt64 = 0
        var settledNetworkRevision: UInt64 = 0
        var sleepGeneration: UInt64 = 0
        var wakeGeneration: UInt64 = 0
        var isAsleep = false
        var retryRevision: UInt64 = 0
        var isClosing = false
    }

    nonisolated private struct Progress: Sendable {
        var settledIntent: UInt64 = 0
        var disconnected = false
        var failure: ConnectionFailure?
    }

    private struct Applied {
        let request: ConnectionRequest
        let uplink: SystemUplinkInventory.Uplink?
        let networkRevision: UInt64
        let sleepGeneration: UInt64
        let startedAsleep: Bool
        var wakeGeneration: UInt64
        var acceptedIntent: UInt64
    }

    private enum Protection { case released, standby }
    private enum Session {
        case undiscovered
        case inactive(Protection)
        case active(Applied)
        case cleanupRequired
    }

    private struct FailureContext {
        enum Retry { case user, network(observed: UInt64, timer: UInt64) }
        let intent: UInt64
        let error: ConnectionFailure?
        let retry: Retry

        func blocks(_ input: Input) -> Bool {
            guard intent == input.intentRevision else { return false }
            switch retry {
            case .user: return true
            case let .network(observed, timer):
                return observed == input.networkRevision && timer == input.retryRevision
            }
        }
    }

    private nonisolated let inputs: Watch<Input>
    private nonisolated let output: Watch<Presentation>
    private nonisolated let progress = Watch(Progress())
    private let guardService: (any ConnectionGuarding)?
    private let proxyRestorer: DeferredProxyRestorer?
    private let clock: any LifecycleClock
    private let log: TeleportLog
    private var provider: Provider
    private var presentation: Presentation
    private var session: Session = .undiscovered
    private var recoveryGeneration: UInt64?
    private var failure: FailureContext?
    private var restoredNetworkRevision: UInt64?
    private var proxyRestoreSucceeded = true
    private var prepare: @Sendable (ConnectionRequest) async throws -> Void = { _ in }
    private var runner: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    init(provider: any ConnectionProvider, mode: ConnectionMode,
         guardService: (any ConnectionGuarding)? = nil, proxyRestorer: DeferredProxyRestorer? = nil,
         clock: any LifecycleClock = SuspendingLifecycleClock(), log: TeleportLog = .shared) {
        let binding = Provider(value: provider, mode: mode)
        self.provider = binding
        inputs = Watch(Input(provider: binding))
        let presentation = Presentation(providerID: binding.id)
        self.presentation = presentation
        output = Watch(presentation)
        self.guardService = guardService
        self.proxyRestorer = proxyRestorer
        self.clock = clock
        self.log = log
    }

    deinit { runner?.cancel(); observation?.cancel(); retry?.cancel() }

    func start(adopting request: ConnectionRequest? = nil,
               prepare: @escaping @Sendable (ConnectionRequest) async throws -> Void = { _ in }) {
        guard runner == nil else { return }
        self.prepare = prepare
        inputs.update { $0.provider.adoptionRequest = request }
        observeProvider()
        let inputs = self.inputs
        let progress = self.progress
        runner = Task { [weak self] in
            while !Task.isCancelled {
                let observed: UInt64
                if let self { observed = await self.reconcile() } else { return }
                let latest = inputs.snapshot().value
                if latest.isClosing, progress.snapshot().value.settledIntent >= latest.intentRevision {
                    await self?.stopObserving()
                    return
                }
                guard await inputs.nextChange(after: observed) != nil else { return }
            }
        }
    }

    nonisolated var intentRevision: UInt64 { inputs.snapshot().value.intentRevision }
    nonisolated var providerID: UUID { inputs.snapshot().value.provider.id }
    nonisolated var currentUplink: SystemUplinkInventory.Uplink? { inputs.snapshot().value.network?.uplink }
    nonisolated var snapshot: Presentation { output.snapshot().value }

    nonisolated func updates() -> AsyncStream<Presentation> {
        let output = self.output
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                var observed = output.snapshot()
                continuation.yield(observed.value)
                while let next = await output.nextChange(after: observed.revision) {
                    observed = next
                    continuation.yield(next.value)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    nonisolated func request(_ desired: Desired) -> UInt64 {
        inputs.update {
            guard !$0.isClosing else { return }
            if $0.desired != desired { $0.desireGeneration += 1 }
            $0.desired = desired
            $0.intentRevision += 1
        }.value.intentRevision
    }

    /// Replacing a mode also replaces its intent. The executor finishes cleanup
    /// against the old provider before it observes or calls the replacement.
    nonisolated func replaceProvider(_ provider: any ConnectionProvider, mode: ConnectionMode,
                                     adopting request: ConnectionRequest?) {
        inputs.update {
            guard !$0.isClosing else { return }
            $0.provider = Provider(value: provider, mode: mode, adoptionRequest: request)
            $0.desired = .preserve
            $0.intentRevision += 1
            $0.desireGeneration += 1
        }
    }

    nonisolated func networkChanged(_ uplink: SystemUplinkInventory.Uplink?, settled: Bool) {
        inputs.update {
            let network = Network(uplink: uplink)
            if $0.network != network { $0.networkRevision += 1 }
            $0.network = network
            if settled {
                $0.settledNetwork = network
                $0.settledNetworkRevision = $0.networkRevision
            }
        }
    }

    nonisolated func slept() {
        inputs.update { $0.sleepGeneration += 1; $0.isAsleep = true }
    }

    nonisolated func woke() {
        inputs.update { $0.isAsleep = false; $0.wakeGeneration += 1 }
    }

    nonisolated func waitForDisconnect(revision: UInt64) async throws {
        var result = progress.snapshot()
        while result.value.settledIntent < revision {
            result = try await progress.changed(after: result.revision)
        }
        guard result.value.disconnected else { throw CancellationError() }
        if let failure = result.value.failure { throw RuntimeFailure(failure: failure) }
    }

    nonisolated func close() async throws {
        let revision = inputs.update {
            guard !$0.isClosing else { return }
            $0.desired = .disconnected
            $0.desireGeneration += 1
            $0.intentRevision += 1
            $0.isClosing = true
        }.value.intentRevision
        try await waitForDisconnect(revision: revision)
    }

    private func observeProvider() {
        observation?.cancel()
        let binding = provider
        let stream = binding.value.stateUpdates()
        let inputs = self.inputs
        observation = Task { [weak self] in
            for await update in stream {
                guard !Task.isCancelled else { return }
                // Execution observes the provider directly, independently of UI.
                await self?.observe(update, from: binding)
                inputs.update { _ in }
            }
        }
    }

    private func stopObserving() { observation?.cancel(); observation = nil }

    private func observe(_ state: ConnectionState, from binding: Provider) {
        guard binding.id == provider.id else { return }
        let input = inputs.snapshot().value
        if case let .failed(error) = state, input.desired == .preserve, input.provider.id == binding.id {
            failure = FailureContext(intent: input.intentRevision, error: error, retry: .user)
        } else if case let .failed(error) = state, case let .active(applied) = session, presentation.activity == .idle {
            failure = FailureContext(intent: applied.acceptedIntent, error: error, retry: .user)
            session = .cleanupRequired
        }
        presentation.state = state
        publish()
    }

    private func reconcile() async -> UInt64 {
        while !Task.isCancelled {
            let snapshot = inputs.snapshot()
            let input = snapshot.value
            let state = await provider.value.currentState()
            guard inputs.snapshot().revision == snapshot.revision else { continue }
            // Cleanup still calls the old provider, but its outcome belongs to
            // the requested mode change and must remain visible/retryable there.
            presentation.providerID = input.provider.id
            presentation.intentRevision = input.intentRevision
            presentation.state = state
            if recoveryGeneration != input.desireGeneration { recoveryGeneration = nil }
            if let failure, failure.blocks(input) {
                settle(input)
                return snapshot.revision
            }
            clearFailure()

            if input.provider.id != provider.id {
                if state != .idle || requiresCleanup {
                    if await disconnect(input, keepingGuard: false) { continue }
                    settle(input)
                    return snapshot.revision
                }
                await guardService?.disarm()
                provider = input.provider
                session = .undiscovered
                restoredNetworkRevision = nil
                proxyRestoreSucceeded = true
                presentation = Presentation(providerID: provider.id)
                observeProvider()
                continue
            }
            // A preparing provider may discover a live session. No proxy restore
            // is safe until startup has positively resolved to idle.
            if state == .preparing || state == .connecting || state == .awaitingUserApproval || state == .disconnecting {
                presentation.isSettled = false
                publish()
                return snapshot.revision
            }
            if state == .idle, restoredNetworkRevision != input.networkRevision {
                restoredNetworkRevision = input.networkRevision
                begin(.restoringProxy)
                proxyRestoreSucceeded = await proxyRestorer?.restore() ?? true
                continue
            }
            presentation.allowsLaunchConnection = proxyRestoreSucceeded

            switch input.desired {
            case .preserve:
                if state.isConnected, let request = input.provider.adoptionRequest {
                    session = .active(applied(request, input: input, networkRevision: 0))
                    inputs.update {
                        if $0.intentRevision == input.intentRevision, $0.desired == .preserve {
                            $0.desired = .connected(request)
                        }
                    }
                    continue
                }
                if case let .failed(error) = state {
                    failure = FailureContext(intent: input.intentRevision, error: error, retry: .user)
                }
                settle(input)
                return snapshot.revision
            case .disconnected:
                recoveryGeneration = nil
                if state != .idle || requiresCleanup {
                    if await disconnect(input, keepingGuard: false) { continue }
                } else if progress.snapshot().value.settledIntent != input.intentRevision {
                    await guardService?.disarm()
                    session = .inactive(.released)
                }
                settle(input)
                return snapshot.revision
            case let .connected(request):
                if state.isConnected {
                    if case var .active(current) = session {
                        let routeChanged = provider.mode == .tun
                            && input.settledNetworkRevision > current.networkRevision
                            && input.settledNetwork.map {
                                !$0.isReady || UplinkChangeDecision.decide(
                                    sessionUplink: current.uplink, currentUplink: $0.uplink
                                ) != .keepRunning
                            } == true
                        let woke = provider.mode == .tun && current.wakeGeneration != input.wakeGeneration
                            && (current.startedAsleep || current.sleepGeneration < input.sleepGeneration
                                || input.sleepGeneration == 0)
                        if current.request == request, !routeChanged, !woke {
                            current.acceptedIntent = input.intentRevision
                            current.wakeGeneration = input.wakeGeneration
                            session = .active(current)
                            settle(input)
                            return snapshot.revision
                        }
                        if routeChanged || woke { recoveryGeneration = input.desireGeneration }
                    }
                    if await disconnect(input, keepingGuard: provider.mode == .tun && request.usesLeakGuard) { continue }
                    settle(input)
                    return snapshot.revision
                }
                if case let .failed(error) = state, case let .active(previous) = session {
                    session = .cleanupRequired
                    // Attribute the failure to the session that died, never to
                    // a newer request that arrived before its notification.
                    if input.intentRevision <= previous.acceptedIntent {
                        failure = FailureContext(intent: previous.acceptedIntent, error: error, retry: .user)
                        settle(input)
                        return snapshot.revision
                    }
                }
                // An established session that stopped outside our teardown is
                // terminal for its original intent. Leave the guard in place
                // until the user chooses to retry or allow direct traffic.
                if state == .idle, case let .active(previous) = session,
                   input.intentRevision <= previous.acceptedIntent {
                    failure = FailureContext(intent: previous.acceptedIntent, error: failure?.error, retry: .user)
                    settle(input)
                    return snapshot.revision
                }
                if requiresCleanup {
                    if await disconnect(input, keepingGuard: provider.mode == .tun && request.usesLeakGuard) { continue }
                    settle(input)
                    return snapshot.revision
                }
                if provider.mode == .tun, let network = input.network, !network.isReady {
                    recoveryGeneration = input.desireGeneration
                    if request.usesLeakGuard {
                        if case .inactive(.standby) = session {} else {
                            await guardService?.armStandby()
                            session = .inactive(.standby)
                            continue
                        }
                    }
                    settle(input, waiting: true)
                    return snapshot.revision
                }
                begin(.connecting(request))
                let started = applied(request, input: input)
                SystemStateDump.capture("before connect", log: log)
                do {
                    let provider = provider.value
                    let prepare = self.prepare
                    let operation = Task {
                        try Task.checkCancellation()
                        try await prepare(request)
                        try Task.checkCancellation()
                        try await provider.connect(request)
                    }
                    // Stop superseded preflight work promptly. A provider past its
                    // commit point can finish, then the executor reconciles again.
                    let inputs = self.inputs
                    let cancellation = Task {
                        var observed = inputs.snapshot()
                        while observed.value.desireGeneration == input.desireGeneration {
                            guard let next = await inputs.nextChange(after: observed.revision) else { return }
                            observed = next
                        }
                        operation.cancel()
                    }
                    defer { cancellation.cancel() }
                    try await operation.value
                    session = .active(started)
                    recoveryGeneration = nil
                } catch {
                    recordFailure(error, input: input,
                                  networkRetry: recoveryGeneration == input.desireGeneration && Self.isNetworkFailure(error))
                }
                // Reread all inputs after every operation, including a failed one.
            }
        }
        return inputs.snapshot().revision
    }

    private var requiresCleanup: Bool {
        if case .cleanupRequired = session { return true }
        return false
    }

    private func applied(_ request: ConnectionRequest, input: Input, networkRevision: UInt64? = nil) -> Applied {
        Applied(request: request, uplink: input.network?.uplink,
                networkRevision: networkRevision ?? input.networkRevision,
                sleepGeneration: input.sleepGeneration, startedAsleep: input.isAsleep,
                wakeGeneration: input.wakeGeneration, acceptedIntent: input.intentRevision)
    }

    private func disconnect(_ input: Input, keepingGuard: Bool) async -> Bool {
        begin(.disconnecting)
        if keepingGuard { await guardService?.armStandby() }
        do {
            log.info("app", "disconnecting session: mode \(provider.mode)")
            SystemStateDump.capture("before disconnect", log: log)
            try await provider.value.disconnect()
            SystemStateDump.capture("after disconnect", log: log)
            if !keepingGuard { await guardService?.disarm() }
            session = .inactive(keepingGuard ? .standby : .released)
            return true
        } catch {
            session = .cleanupRequired
            recordFailure(error, input: input, networkRetry: false)
            presentation.state = await provider.value.currentState()
            return false
        }
    }

    private func recordFailure(_ error: Error, input: Input, networkRetry: Bool) {
        let latest = inputs.snapshot().value
        let intent = latest.desired == input.desired && latest.desireGeneration == input.desireGeneration
            ? latest.intentRevision : input.intentRevision
        failure = FailureContext(intent: intent, error: error is CancellationError ? nil : ConnectionFailure(error: error),
                                 retry: networkRetry ? .network(observed: input.networkRevision, timer: input.retryRevision) : .user)
        retry?.cancel()
        if networkRetry {
            let inputs = self.inputs
            let clock = self.clock
            retry = Task {
                do { try await clock.sleep(for: .seconds(5)) } catch { return }
                inputs.update { if $0.intentRevision == intent { $0.retryRevision += 1 } }
            }
        }
    }

    private func clearFailure() {
        failure = nil
        retry?.cancel()
        retry = nil
    }

    private func begin(_ activity: Activity) {
        presentation.activity = activity
        presentation.isSettled = false
        presentation.failure = nil
        publish()
    }

    private func settle(_ input: Input, waiting: Bool = false) {
        presentation.activity = waiting ? .waitingForNetwork : .idle
        presentation.isSettled = true
        presentation.failure = failure?.error
        publish()
        progress.update {
            $0 = Progress(settledIntent: input.intentRevision,
                          disconnected: input.desired == .disconnected, failure: failure?.error)
        }
    }

    private func publish() {
        if case let .active(applied) = session, presentation.state.isConnected { presentation.appliedRequest = applied.request }
        else { presentation.appliedRequest = nil }
        if output.snapshot().value != presentation { output.update { $0 = presentation } }
    }

    private static func isNetworkFailure(_ error: Error) -> Bool {
        switch error as? XrayTunConnectionError {
        case .proxyAddressResolutionFailed, .proxyRouteUnavailable, .proxyIPv6RouteUnavailable, .noReachableGroupMembers: true
        default: false
        }
    }

    private struct RuntimeFailure: LocalizedError {
        let failure: ConnectionFailure
        var errorDescription: String? { failure.summary }
    }
}
