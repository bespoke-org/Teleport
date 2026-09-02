# Connection Provider API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `AppViewModel` depend only on an asynchronous `ConnectionProvider` and one domain `ConnectionState`, while preserving the current System Proxy and root-Xray VPN behavior behind internal adapters.

**Architecture:** Add provider-domain values and a serial provider coordinator around the existing synchronous `ConnectionBackend` implementations. Mode-specific providers forward to the coordinator, own state publication, and hide PID, route, helper, Xray, and proxy-setting details from `AppViewModel`. Keep the lower-level backend protocol as a transitional internal implementation detail during Phase 2; XPC and authoritative helper sessions remain Phase 3/4 work.

**Tech Stack:** Swift 5, Foundation concurrency (`async`/`await`, `AsyncStream`), SwiftUI/Combine, Xcode filesystem-synchronized groups, standalone Swift verification scripts, Just.

**Spec:** `docs/superpowers/specs/2026-09-02-xray-macos-architecture-design.md`

## Global Constraints

- Preserve System Proxy and current root-Xray VPN executable ordering and rollback behavior.
- Do not introduce XPC, `SMAppService`, Network Extension, IPv6, startup optimization, or auto-connect in this phase.
- `AppViewModel` must not directly reference `ConnectionBackend`, PID values, helper revisions, `utun` names, route details, Xray paths, or Xray JSON.
- `ConnectionSession` contains user-facing identity only; generated UUIDs are not yet authoritative helper session IDs.
- Existing synchronous backends remain internal transitional adapters and must not leak through the provider API.
- Provider operations are serialized; a second connect/disconnect request while an operation is active fails deterministically.
- All comments and `TODO(gpt-5.6-sol)` annotations added by this plan are English-only.
- Do not change helper IPC, root state, shell route text, geodata behavior, release signing, or persistence formats.
- Every task uses red-green verification and ends with a commit whose subject begins with `🤖`.

---

## Source map

```text
teleport/Connection/
├── ConnectionProvider.swift             # Public async lifecycle contract
├── ConnectionRequest.swift              # Provider input and split-tunnel policy
├── ConnectionState.swift                # One lifecycle state and UI-safe session/failure
├── ConnectionStateStore.swift           # Locked current value + AsyncStream fan-out
├── BackendConnectionProvider.swift      # Serial adapter over transitional backends
├── ConnectionPresentation.swift         # Pure legacy UI projection
├── ConnectionBackend.swift              # Transitional synchronous lower-level contract
└── ConnectionProviderFactory.swift      # Builds mode-specific provider wrappers

teleport/SystemProxy/
└── SystemProxyConnectionProvider.swift  # System Proxy provider facade

teleport/VPN/
└── RootXrayConnectionProvider.swift      # Root-Xray VPN provider facade

scripts/
└── verify_connection_provider.swift     # Provider state/order/presentation tests
```

---

### Task 1: Add provider domain values and presentation mapping

**Files:**
- Create: `teleport/Connection/ConnectionState.swift`
- Create: `teleport/Connection/ConnectionRequest.swift`
- Create: `teleport/Connection/ConnectionProvider.swift`
- Create: `teleport/Connection/ConnectionPresentation.swift`
- Create: `scripts/verify_connection_provider.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `ConnectionMode`, `ConnectionConfiguration`, `ProxyEndpoint`, `SplitTunnelRule`, `SplitTunnelRuleAction`, `ConnectionPhase`, and `ProxyPhase`.
- Produces:

```swift
protocol ConnectionProvider: Sendable {
    func currentState() async -> ConnectionState
    func stateUpdates() -> AsyncStream<ConnectionState>
    func connect(_ request: ConnectionRequest) async throws
    func disconnect() async throws
}

struct ConnectionRequest: Sendable, Equatable {
    let configuration: ConnectionConfiguration
    let localProxy: ProxyEndpoint
    let splitTunnelPolicy: SplitTunnelPolicy
}

struct SplitTunnelPolicy: Sendable, Equatable {
    let rules: [SplitTunnelRule]
    let defaultAction: SplitTunnelRuleAction
}

enum ConnectionState: Sendable, Equatable {
    case idle
    case preparing
    case awaitingUserApproval
    case connecting
    case connected(ConnectionSession)
    case disconnecting
    case failed(ConnectionFailure)
}

struct ConnectionSession: Sendable, Equatable {
    let id: UUID
    let mode: ConnectionMode
    let connectedAt: Date
}

struct ConnectionFailure: Sendable, Equatable {
    let summary: String
    let details: String?
}

struct ConnectionPresentation: Equatable {
    let connectionPhase: ConnectionPhase
    let proxyPhase: ProxyPhase
}
```

- [ ] **Step 1: Add failing domain/presentation tests**

Create `scripts/verify_connection_provider.swift` with an async `@main` that calls `testConnectionPresentationMapping()`. Assert these mappings:

```swift
precondition(ConnectionPresentation(state: .idle, hasConfiguration: false) == .init(connectionPhase: .unconfigured, proxyPhase: .disabled))
precondition(ConnectionPresentation(state: .idle, hasConfiguration: true) == .init(connectionPhase: .stopped, proxyPhase: .disabled))
precondition(ConnectionPresentation(state: .preparing, hasConfiguration: true) == .init(connectionPhase: .starting, proxyPhase: .enabling))
precondition(ConnectionPresentation(state: .awaitingUserApproval, hasConfiguration: true) == .init(connectionPhase: .starting, proxyPhase: .enabling))
precondition(ConnectionPresentation(state: .connecting, hasConfiguration: true) == .init(connectionPhase: .starting, proxyPhase: .enabling))
precondition(ConnectionPresentation(state: .connected(.init(id: UUID(), mode: .vpn, connectedAt: Date())), hasConfiguration: true) == .init(connectionPhase: .running, proxyPhase: .enabled))
precondition(ConnectionPresentation(state: .disconnecting, hasConfiguration: true) == .init(connectionPhase: .stopping, proxyPhase: .disabling))
precondition(ConnectionPresentation(state: .failed(.init(summary: "failed", details: nil)), hasConfiguration: true) == .init(connectionPhase: .failed, proxyPhase: .failed))
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
swiftc teleport/TeleportModels.swift teleport/Connection/ConnectionState.swift teleport/Connection/ConnectionRequest.swift teleport/Connection/ConnectionPresentation.swift scripts/verify_connection_provider.swift -o /tmp/teleport-verify-connection-provider
```

Expected: compilation fails because the new domain files/types do not exist.

- [ ] **Step 3: Implement domain values**

Create the three domain files using the exact declarations in the Interfaces block. Give `ConnectionFailure` this conversion initializer so providers preserve current diagnostics without exposing concrete errors:

```swift
init(error: Error) {
    summary = error.localizedDescription
    if let localizedError = error as? LocalizedError,
       let reason = localizedError.failureReason?.trimmingCharacters(in: .whitespacesAndNewlines),
       !reason.isEmpty,
       reason != summary {
        details = reason
    } else {
        details = nil
    }
}
```

- [ ] **Step 4: Implement pure UI projection**

In `ConnectionPresentation.swift`, map states exactly as asserted in Step 1. Add computed flags:

```swift
var canConnect: Bool
var canDisconnect: Bool
var canChangeSelection: Bool
var hasActiveConnectionSession: Bool
var isConnected: Bool
```

Contract:

- idle: connect allowed only with configuration; selection allowed; no active session.
- preparing/awaitingUserApproval/connecting: disconnect allowed; selection forbidden; active session true.
- connected: disconnect allowed; selection forbidden; connected true.
- disconnecting: selection forbidden; active session true.
- failed: connect and disconnect allowed when configured; selection allowed only after disconnect; active session true.

- [ ] **Step 5: Run the focused test and verify GREEN**

Compile with `teleport/TeleportModels.swift`, the four new Connection files, and the test. Expected: `verify_connection_provider: all checks passed`.

- [ ] **Step 6: Add the Just recipe**

Add `verify-connection-provider` using `{{verify_sources}}`, and add it to the aggregate `verify` dependencies.

- [ ] **Step 7: Commit domain API**

```bash
git add teleport/Connection scripts/verify_connection_provider.swift justfile
git commit -m "🤖 feat: add connection provider domain API"
```

---

### Task 2: Add state streaming and serial backend coordination

**Files:**
- Create: `teleport/Connection/ConnectionStateStore.swift`
- Create: `teleport/Connection/BackendConnectionProvider.swift`
- Modify: `teleport/Connection/ConnectionBackend.swift`
- Modify: `scripts/verify_connection_provider.swift`

**Interfaces:**
- Consumes: Task 1 domain values and existing synchronous `ConnectionBackend` methods.
- Produces:

```swift
final class ConnectionStateStore: @unchecked Sendable {
    init(initialState: ConnectionState)
    func current() -> ConnectionState
    func update(_ state: ConnectionState)
    func stream() -> AsyncStream<ConnectionState>
}

final class BackendConnectionProvider: ConnectionProvider, @unchecked Sendable {
    init(mode: ConnectionMode, backend: ConnectionBackend)
    func currentState() async -> ConnectionState
    func stateUpdates() -> AsyncStream<ConnectionState>
    func connect(_ request: ConnectionRequest) async throws
    func disconnect() async throws
}

enum ConnectionProviderError: LocalizedError, Equatable {
    case operationInProgress
}
```

- [ ] **Step 1: Add failing state-store tests**

Extend the verification script to subscribe to a store initialized with `.idle`, call `update(.preparing)` and `update(.connecting)`, and assert the stream receives exactly `.idle`, `.preparing`, `.connecting`. Cancel the reader after three values.

- [ ] **Step 2: Run and verify RED**

Run `just verify-connection-provider`. Expected: compile failure for missing `ConnectionStateStore`.

- [ ] **Step 3: Implement ConnectionStateStore**

Use `NSLock`, a current value, and `[UUID: AsyncStream<ConnectionState>.Continuation]`. `stream()` must yield the current state before registering subsequent updates. Its `onTermination` removes the matching continuation under the lock. Copy the continuation array before yielding updates so no caller runs while the lock is held.

- [ ] **Step 4: Verify state-store GREEN**

Run `just verify-connection-provider`. Expected: all checks pass.

- [ ] **Step 5: Add a recording fake backend and failing lifecycle tests**

The fake records method calls under `NSLock`, supports injected start/stop errors, and implements every existing backend method. Add async tests that assert:

```text
connect state sequence: idle, preparing, connecting, connected
first connect backend call: start
connect while connected backend call: reconnect
successful disconnect sequence: connected, disconnecting, idle
start failure terminal state: failed with the thrown summary
stop failure terminal state: failed with the thrown summary
```

Also block fake `start` with semaphores and assert a concurrent second connect throws `ConnectionProviderError.operationInProgress` instead of entering the backend.

- [ ] **Step 6: Run and verify RED**

Run `just verify-connection-provider`. Expected: missing `BackendConnectionProvider` and `ConnectionProviderError` failures.

- [ ] **Step 7: Make backends safely storable by the provider**

Change the transitional protocol to:

```swift
protocol ConnectionBackend: AnyObject, Sendable
```

Mark `SystemProxyConnectionBackend` and `XrayTunConnectionBackend` as `@unchecked Sendable`; their use is serialized by `BackendConnectionProvider`.

- [ ] **Step 8: Implement BackendConnectionProvider**

Use one private serial `DispatchQueue`, `ConnectionStateStore`, and a lock-protected `operationInProgress` flag. Bridge queue work with `withCheckedThrowingContinuation`.

Connect ordering:

```text
reserve operation
publish preparing
publish connecting
if previous state was connected: backend.reconnect(..., shouldDisableExistingProxy: true, ...)
otherwise: backend.start(...)
publish connected(ConnectionSession(id: UUID(), mode: mode, connectedAt: Date()))
release operation
```

On error, publish `.failed(ConnectionFailure(error: error))`, release the operation, and resume by throwing the original error.

Disconnect ordering:

```text
reserve operation
publish disconnecting
backend.stop(shouldDisableProxy: true)
publish idle
release operation
```

If already idle, return without backend work. If reservation fails, throw `operationInProgress` without changing state.

Initialize the store as connected when `backend.hasActiveRuntimeSession()` is true. If `backend.hasRestorableState()` is true and no runtime is active, publish `.preparing`, restore on the serial queue, then publish `.idle` or `.failed`.

- [ ] **Step 9: Run provider and complete verification**

Run:

```bash
just verify-connection-provider
just verify-core
just verify-split-tunneling
```

Expected: all pass.

- [ ] **Step 10: Commit provider coordinator**

```bash
git add teleport/Connection teleport/SystemProxy/SystemProxyConnectionBackend.swift teleport/VPN/XrayTunConnectionBackend.swift scripts/verify_connection_provider.swift
git commit -m "🤖 feat: serialize connection provider lifecycle"
```

---

### Task 3: Add mode-specific providers and provider factory

**Files:**
- Create: `teleport/SystemProxy/SystemProxyConnectionProvider.swift`
- Create: `teleport/VPN/RootXrayConnectionProvider.swift`
- Create: `teleport/Connection/ConnectionProviderFactory.swift`
- Modify: `scripts/verify_connection_provider.swift`
- Modify: `scripts/verify_architecture_layout.swift`

**Interfaces:**
- Consumes: `BackendConnectionProvider` and concrete backends.
- Produces:

```swift
struct SystemProxyConnectionProvider: ConnectionProvider, Sendable
struct RootXrayConnectionProvider: ConnectionProvider, Sendable
struct ConnectionProviderFactory {
    func makeProvider(for mode: ConnectionMode) -> any ConnectionProvider
}
```

- [ ] **Step 1: Add failing factory tests**

Assert that `.systemProxy` produces `SystemProxyConnectionProvider` and `.vpn` produces `RootXrayConnectionProvider`. Add initializer injection to the factory so tests can pass prepared providers without constructing bundle/root dependencies.

- [ ] **Step 2: Run and verify RED**

Run `just verify-connection-provider`. Expected: missing provider/factory types.

- [ ] **Step 3: Implement provider facades**

Each facade owns a `BackendConnectionProvider` and forwards all four `ConnectionProvider` requirements. Production initializers build exactly the same concrete backend dependencies as the old factory.

- [ ] **Step 4: Implement ConnectionProviderFactory**

Production behavior:

```swift
switch mode {
case .systemProxy: return SystemProxyConnectionProvider()
case .vpn: return RootXrayConnectionProvider()
}
```

The injected initializer stores two `@Sendable () -> any ConnectionProvider` closures.

- [ ] **Step 5: Strengthen layout guards**

Require `ConnectionProviderFactory.swift` and both mode-specific provider files. Keep `ConnectionBackendFactory.swift` until Task 4 replaces its final `AppViewModel` consumer, and keep `ConnectionBackend.swift` as an explicitly documented transitional lower-level adapter.

- [ ] **Step 6: Run tests and builds**

Run:

```bash
just verify-connection-provider
just verify-architecture-layout
just build-debug
```

Expected: all pass.

- [ ] **Step 7: Commit provider selection**

```bash
git add teleport/Connection teleport/SystemProxy teleport/VPN scripts
git commit -m "🤖 refactor: select connection providers by mode"
```

---

### Task 4: Convert AppViewModel to one provider state stream

**Files:**
- Modify: `teleport/ViewModels/AppViewModel.swift`
- Delete: `teleport/Connection/ConnectionBackendFactory.swift`
- Modify: `scripts/verify_connection_provider.swift`

**Interfaces:**
- Consumes: `ConnectionProviderFactory`, `ConnectionProvider`, `ConnectionRequest`, `ConnectionState`, and `ConnectionPresentation`.
- Produces: `AppViewModel` with one stored provider state and no direct backend dependency.

- [ ] **Step 1: Add structural assertions that initially fail**

In `verify_connection_provider.swift`, recursively load `teleport/ViewModels/AppViewModel.swift` and assert:

```swift
precondition(!source.contains("ConnectionBackend"))
precondition(!source.contains("connectionBackend"))
precondition(source.contains("ConnectionProviderFactory"))
precondition(source.contains("connectionProvider.stateUpdates()"))
precondition(source.contains("@Published private(set) var connectionState"))
```

- [ ] **Step 2: Run and verify RED**

Run `just verify-connection-provider`. Expected: the source assertions fail against the current view model.

- [ ] **Step 3: Replace backend storage**

Replace backend factory/backend fields with:

```swift
private let connectionProviderFactory: ConnectionProviderFactory
private var connectionProvider: any ConnectionProvider
private var connectionStateTask: Task<Void, Never>?
private var connectionOperationTask: Task<Void, Never>?
@Published private(set) var connectionState: ConnectionState = .idle
```

Update initializers to accept `ConnectionProviderFactory`, construct the selected provider, and start exactly one state observer after all stored properties are initialized.

- [ ] **Step 4: Derive legacy UI phases from one state**

Change `connectionPhase` and `proxyPhase` from stored `@Published` values to computed properties backed by:

```swift
ConnectionPresentation(state: connectionState, hasConfiguration: selectedConfiguration != nil)
```

Derive `canConnect`, `canDisconnect`, `canChangeSelection`, `hasActiveConnectionSession`, and `isConnected` from the same presentation. Remove every assignment to `connectionPhase` and `proxyPhase`.

- [ ] **Step 5: Consume provider state updates**

Implement `observeConnectionState()` so it cancels the previous observer, captures the current provider, consumes its `AsyncStream`, and applies each value on `MainActor`. Applying `.failed` copies `ConnectionFailure.summary/details` into `lastError/lastErrorDetails`; applying `.connected` clears errors and performs deferred split-tunnel application.

- [ ] **Step 6: Replace connect and reconnect execution**

Build one request helper:

```swift
private func makeConnectionRequest(configuration: ConnectionConfiguration) -> ConnectionRequest {
    ConnectionRequest(
        configuration: configuration,
        localProxy: proxyEndpoint,
        splitTunnelPolicy: SplitTunnelPolicy(
            rules: activeSplitTunnelRules,
            defaultAction: activeSplitTunnelDefaultAction
        )
    )
}
```

Both initial connect and live reconnect call `connectionProvider.connect(request)` in `connectionOperationTask`. The provider chooses backend `start` versus `reconnect` from its current state. Update applied split-tunnel caches only after the async call succeeds.

- [ ] **Step 7: Replace disconnect execution**

`disconnect()` cancels no accepted provider work; it creates a task that awaits `connectionProvider.disconnect()`. State and errors come only from the provider stream. Remove `shouldManageSystemProxy`, `detectActiveRuntimeSessionFromPreviousRunIfNeeded`, and `restoreProxyStateFromPreviousSessionIfNeeded` from `AppViewModel` because the provider owns those details.

- [ ] **Step 8: Replace mode switching**

On mode change, capture the previous provider, cancel its observer, assign `connectionProviderFactory.makeProvider(for:)`, set local `connectionState = .idle`, start the new observer, and asynchronously disconnect the previous provider. Preserve the existing guard requiring no active session before mode changes.

- [ ] **Step 9: Remove the obsolete backend factory**

Delete `teleport/Connection/ConnectionBackendFactory.swift` after `AppViewModel` has no remaining references to it. Add `requireMissing("teleport/Connection/ConnectionBackendFactory.swift")` to `verify_architecture_layout.swift`.

- [ ] **Step 10: Run focused and UI-facing verification**

Run:

```bash
just verify-connection-provider
just verify-core
just verify-split-tunneling
just build-debug
```

Expected: all pass and source assertions confirm `AppViewModel` has no backend references.

- [ ] **Step 11: Commit AppViewModel migration**

```bash
git add teleport/ViewModels/AppViewModel.swift scripts/verify_connection_provider.swift
git commit -m "🤖 refactor: drive app connection UI from provider state"
```

---

### Task 5: Make app termination await provider disconnect

**Files:**
- Modify: `teleport/teleportApp.swift`
- Modify: `teleport/ViewModels/AppViewModel.swift`
- Modify: `scripts/verify_connection_provider.swift`

**Interfaces:**
- Consumes: asynchronous `ConnectionProvider.disconnect()`.
- Produces: bounded application termination that replies to AppKit only after provider cleanup completes.

- [ ] **Step 1: Add failing source-contract assertions**

Assert `teleportApp.swift` contains `.terminateLater` and `reply(toApplicationShouldTerminate:)`, and that `AppViewModel.handleAppTermination` accepts a completion closure and awaits `connectionProvider.disconnect()`.

- [ ] **Step 2: Run and verify RED**

Run `just verify-connection-provider`. Expected: source assertions fail.

- [ ] **Step 3: Implement AppKit termination deferral**

Change `cleanupHandler` to `((@escaping () -> Void) -> Void)?`. In `applicationShouldTerminate`, return `.terminateNow` when no cleanup handler exists; otherwise guard repeated requests, invoke cleanup, and return `.terminateLater`. The completion closure calls:

```swift
sender.reply(toApplicationShouldTerminate: true)
```

- [ ] **Step 4: Implement async view-model cleanup**

Change `handleAppTermination` to capture the provider and launch a task that awaits `disconnect()`, ignores cleanup errors because termination cannot present recoverable UI, then invokes completion on `MainActor`. Cancel the state observer only after disconnect completes.

- [ ] **Step 5: Run focused and full verification**

Run:

```bash
just verify-connection-provider
just build-debug
```

Expected: both pass.

- [ ] **Step 6: Commit termination integration**

```bash
git add teleport/teleportApp.swift teleport/ViewModels/AppViewModel.swift scripts/verify_connection_provider.swift
git commit -m "🤖 fix: await provider cleanup before app termination"
```

---

### Task 6: Complete Phase 2 guards and documentation

**Files:**
- Modify: `scripts/verify_architecture_layout.swift`
- Modify: `docs/runtime-source-layout.md`
- Modify: `docs/xray-bundling-and-release.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: final Phase 2 source layout.
- Produces: durable dependency guards and current documentation.

- [ ] **Step 1: Strengthen architecture checks**

Require all provider-domain/coordinator/facade files. Assert `AppViewModel.swift` contains no `ConnectionBackend`, `PrivilegedHelperClient`, `PrivilegedXrayRuntimeManager`, `XrayTunRouteInspector`, `XrayConfigurationWriter`, PID-file path, helper version, or `utun` literal. Assert `ConnectionBackendFactory.swift` is absent.

- [ ] **Step 2: Run and verify checks**

Run `just verify-architecture-layout`. Expected: all checks pass only on the final layout.

- [ ] **Step 3: Update runtime layout documentation**

Document that:

- `AppViewModel` consumes one provider stream;
- mode providers own lifecycle sequencing;
- synchronous backends are transitional Phase 2 adapters below providers;
- generated `ConnectionSession.id` is UI identity only until Phase 3/4 helper protocol work;
- XPC, authoritative root sessions, and `SMAppService` are not yet implemented.

Do not describe future phases as shipping behavior.

- [ ] **Step 4: Run complete fresh verification**

Run:

```bash
git diff --check
just clean
just verify
```

Expected: build succeeds and every script prints `all checks passed`.

- [ ] **Step 5: Audit the final diff**

Verify:

- helper target sources and IPC are unchanged;
- route shell text is unchanged;
- backend start/reconnect/stop call arguments and ordering are unchanged;
- `AppViewModel` lifecycle presentation comes from one `ConnectionState`;
- no sibling feature work entered the branch;
- app/helper signing and embedded-helper layout remain valid.

- [ ] **Step 6: Commit Phase 2 guards**

```bash
git add README.md docs scripts/verify_architecture_layout.swift
git commit -m "🤖 docs: describe connection provider boundaries"
```

- [ ] **Step 7: Request review before Phase 3**

Review specifically:

1. State transition ordering and concurrent-operation rejection.
2. Initial active-runtime and saved-proxy recovery behavior.
3. App termination cleanup completion.
4. Absence of backend/helper/process details in `AppViewModel`.
5. Behavior parity of System Proxy and root-Xray VPN adapters.
