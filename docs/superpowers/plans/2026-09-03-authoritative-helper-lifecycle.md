# Authoritative Privileged Helper Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the privileged helper the persisted authoritative owner of VPN session, Xray process, tunnel interface, and exact IPv4 route lifecycle across app/helper/Xray interruption.

**Architecture:** Replace the synchronous shell-owned `XrayTunController` lifecycle with an actor-based `VPNSessionController`, atomic root state, a write-ahead route journal, a process-identity-validating supervisor, and exact route management. Lifecycle XPC calls become short admission operations; the app polls authoritative status and always yields its local cache to helper state.

**Tech Stack:** Swift 5, Foundation, Darwin/libproc, `NSXPCConnection`, launchd Mach services, Codable JSON with POSIX-safe atomic files, `/sbin/route` and `/sbin/ifconfig` behind injected executors, standalone Swift verification programs, Xcode/just.

**Spec:** `docs/superpowers/specs/2026-09-03-authoritative-helper-lifecycle-design.md`

## Global Constraints

- Keep `TeleportPrivilegedHelper/` as the existing separate root executable target and explicit trust boundary.
- Do not add a Swift package, framework, or executable target.
- Keep upper layers dependent on provider abstractions; `AppViewModel` must not know helper, process, route, XPC, or root-state details.
- Keep authenticated XPC over the launchd Mach service `dev.x.teleport.helper`; do not add a second transport or socket fallback.
- Increase the exact helper revision from `8` to `9`; backward compatibility is not required.
- Keep protocol bounds: 1 MiB encoded request/response, 512 KiB configuration, and 256 KiB diagnostics.
- Persist root state only below `/var/db/dev.x.teleport` with root ownership, restrictive permissions, no symlink traversal, bounded files, and atomic replacement.
- Treat session UUID as authoritative root ownership only after the Phase 4 state has been persisted.
- Persist `ownerUID`; only the same active console UID may mutate the session.
- Adopt a valid persisted `running` session after helper restart; clean up transitional or contradictory state.
- Never signal a process based on PID alone.
- Never remove a route unless its complete journalled tuple matches current system state.
- A cleanup residue becomes `failedCleanup`, blocks start, and is retried by matching `stopSession(sessionID)`.
- Status and diagnostics are read-only; status never performs cleanup.
- Keep Phase 4 IPv4-only. Do not port IPv6, auto-connect, startup-performance branches, Network Extension, geodata redesign, release pipeline, or `SMAppService`.
- `/sbin/route` may remain behind a typed injected executor; routing sockets are out of scope.
- Remove generated lifecycle shell scripts only after parity verification passes.
- Do not introduce a new `@unchecked Sendable`; any retained existing use must remain lock/serialization justified.
- New comments and any `gpt-5.6-sol` annotation text must be English.
- Do not run `scripts/reset_legacy_privileged_helper.sh` during automated implementation.
- Every commit message must contain `🤖`.
- Manual macOS acceptance results must never be fabricated.

## File map

### Shared protocol

- Modify `Shared/PrivilegedHelperConstants.swift`: exact compatibility revision `9` and authoritative root filenames.
- Modify `Shared/VPNHelperMessages.swift`: authoritative phases and admission/status payloads.
- Modify `Shared/VPNHelperProtocolError.swift`: new typed lifecycle failures and shape validation.
- Modify `scripts/verify_xpc_protocol.swift`: exact revision, phase, payload, and error contract tests.

### Helper support and persistence

- Create `TeleportPrivilegedHelper/Session/RootSessionState.swift`: persisted session/process/failure value types.
- Create `TeleportPrivilegedHelper/Session/RootStateStore.swift`: safe bounded load/save/remove and atomic replacement.
- Create `TeleportPrivilegedHelper/Session/RootConfigurationStore.swift`: safe root-owned Xray configuration write/removal without persisting secrets in lifecycle state.
- Create `TeleportPrivilegedHelper/Support/RootAtomicFileStore.swift`: reusable same-directory atomic file primitive.
- Create `scripts/verify_root_state_store.swift`: deterministic state/config file safety, schema, corruption, and atomicity checks.

### Routing

- Create `TeleportPrivilegedHelper/Routing/RoutePlan.swift`: exact typed IPv4 tuples, resolved address targets, and deterministic plan order.
- Create `TeleportPrivilegedHelper/Routing/RouteJournal.swift`: write-ahead journal model/store.
- Create `TeleportPrivilegedHelper/Routing/RouteManager.swift`: exact apply/inspect/rollback behavior.
- Create `TeleportPrivilegedHelper/Routing/RouteCommandExecutor.swift`: production command execution and bounded parsing seam.
- Create `scripts/verify_route_journal.swift`: crash-window and journal persistence tests.
- Create `scripts/verify_route_manager.swift`: route parity, exact ownership, order, mismatch, and rollback tests.

### Process supervision

- Create `TeleportPrivilegedHelper/Xray/RootXraySupervisor.swift`: actor-isolated launch/adopt/observe/terminate operations.
- Create `TeleportPrivilegedHelper/Xray/RootProcessInspector.swift`: process-start and executable-file identity inspection.
- Create `TeleportPrivilegedHelper/Xray/RootXrayDiagnostics.swift`: bounded allowlisted root log reader.
- Create `scripts/verify_root_xray_supervisor.swift`: PID reuse, executable replacement, readiness, termination, and stale-event tests.

### Authoritative controller and XPC composition

- Create `TeleportPrivilegedHelper/Session/VPNSessionController.swift`: actor state machine, background effects, and startup reconciliation.
- Modify `TeleportPrivilegedHelper/Support/HelperPlatform.swift`: injectable active-console identity and interface inspection.
- Modify `TeleportPrivilegedHelper/IPC/HelperCommandExecuting.swift`: async context-aware command boundary.
- Modify `TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift`: delegate lifecycle authority and retain only request-ledger behavior.
- Modify `TeleportPrivilegedHelper/IPC/HelperXPCService.swift`: per-connection caller context.
- Modify `TeleportPrivilegedHelper/IPC/HelperXPCListenerDelegate.swift`: create one exported service per authenticated UID.
- Modify `TeleportPrivilegedHelper/IPC/ClientAuthenticator.swift`: return authenticated caller context.
- Modify `TeleportPrivilegedHelper/main.swift`: production composition and startup reconciliation task.
- Create `scripts/verify_vpn_session_controller.swift`: actor transition, ownership, concurrency, cleanup, and reconciliation tests.
- Modify `scripts/verify_helper_command_dispatch.swift` and `scripts/verify_helper_xpc_endpoint.swift`: async/context-aware dispatch tests.

### App/provider integration

- Modify `teleport/VPN/PrivilegedHelperClient.swift`: admission responses and authoritative typed status mapping.
- Modify `teleport/VPN/PrivilegedXrayRuntimeManager.swift`: actor-isolated bounded polling, cancellation-safe cleanup, and no helper-file fallback.
- Modify `teleport/VPN/RootXrayConnectionProvider.swift`: dedicated async VPN provider lifecycle and startup restoration.
- Create `teleport/VPN/XrayTunLaunchSessionBuilder.swift`: validated physical-network inspection and Xray configuration construction.
- Delete `teleport/VPN/XrayTunConnectionBackend.swift` after its responsibilities move to the async provider/session builder.
- Create `teleport/VPN/XrayTunSessionCache.swift`: user-owned correlation cache and bounded atomic cache access.
- Delete `teleport/VPN/XrayTunSessionState.swift` after launch inputs and cache move to focused files.
- Modify `scripts/verify_privileged_helper_client.swift`: new response semantics and failures.
- Create `scripts/verify_authoritative_vpn_runtime.swift`: polling, deadline cleanup, cache replacement, and dedicated provider concurrency tests.
- Modify `scripts/verify_connection_provider.swift`: replace the coordinator-backed VPN-provider construction assertion.

### Cutover and documentation

- Delete `TeleportPrivilegedHelper/Session/XrayTunController.swift` after composition moves to the controller.
- Delete `TeleportPrivilegedHelper/Routing/XrayTunScriptBuilder.swift` after route parity passes.
- Delete `TeleportPrivilegedHelper/Xray/ManagedXrayProcess.swift` after supervisor parity passes.
- Delete `TeleportPrivilegedHelper/Support/HelperShellRunner.swift` after all uses move to focused executors.
- Modify `TeleportPrivilegedHelper/Support/HelperConfiguration.swift`: only current bounds/signing constants.
- Modify `scripts/verify_architecture_layout.swift`: authoritative boundary and legacy lifecycle guards.
- Modify `justfile`: focused Phase 4 verification recipes.
- Modify `README.md`, `docs/runtime-source-layout.md`, and `docs/xray-bundling-and-release.md`: implemented behavior and manual risks.
- Modify `scripts/reset_legacy_privileged_helper.sh`: fail before bootout/removal when an exact installed-Xray command line is active; verify statically but never execute automatically.

---

### Task 1: Revise the shared protocol for authoritative lifecycle semantics

**Files:**
- Modify: `Shared/PrivilegedHelperConstants.swift`
- Modify: `Shared/VPNHelperMessages.swift`
- Modify: `Shared/VPNHelperProtocolError.swift`
- Modify: `scripts/verify_xpc_protocol.swift`

**Interfaces:**
- Consumes: Phase 3 `VPNHelperRequestEnvelope`, `VPNHelperResponseEnvelope`, and `VPNHelperCodec`.
- Produces: revision `9`; `VPNHelperSessionPhase`; `StatusResponse`; empty `StopSessionRequest`; typed authoritative `VPNHelperFailureCode` values used by all later tasks.

- [ ] **Step 1: Extend the protocol verification with the new exact contract**

Add assertions equivalent to:

```swift
try expect(VPNHelperProtocol.revision == 9, "Phase 4 must use exact protocol revision 9")
try expect(Set(VPNHelperSessionPhase.allCases) == [
    .idle, .reconciling, .starting, .running, .stopping, .failedCleanup
], "authoritative phases must be exact")

let stop = StopSessionRequest()
let stopEnvelope = VPNHelperRequestEnvelope(
    revision: VPNHelperProtocol.revision,
    requestID: UUID(),
    sessionID: UUID(),
    payload: stop
)
_ = try VPNHelperCodec.decodeRequest(VPNHelperCodec.encodeRequest(stopEnvelope)) as VPNHelperRequestEnvelope<StopSessionRequest>

for code in [
    VPNHelperFailureCode.sessionConflict,
    .ownedByAnotherUser,
    .reconciliationInProgress,
    .stateCorrupt,
    .processIdentityMismatch,
    .xrayExited,
    .interfaceReadiness,
    .routeApply,
    .routeVerification,
    .routeRollback,
    .failedCleanup
] {
    let failure = VPNHelperProtocolFailure(
        code: code,
        summary: "safe",
        details: nil,
        retryDisposition: .queryAuthoritativeStatus
    )
    try expect(try roundTrip(failure) == failure, "failure code must round trip")
}
```

Also assert that revision `8`, `.failed`, `.unknown`, and stop payload fields `stateDirectoryPath`, `protectedHost`, and `outboundInterface` are rejected or absent.

- [ ] **Step 2: Run the protocol verification to observe RED**

Run:

```bash
swiftc Shared/*.swift scripts/verify_xpc_protocol.swift -o /tmp/teleport-verify-xpc-protocol
/tmp/teleport-verify-xpc-protocol
```

Expected: compilation failures for `allCases`, `.reconciling`, `.failedCleanup`, new failure codes, `.queryAuthoritativeStatus`, and `StopSessionRequest()`.

- [ ] **Step 3: Implement revision 9 and exact authoritative messages**

Use this public shape:

```swift
nonisolated enum VPNHelperSessionPhase: String, Codable, Sendable, CaseIterable {
    case idle
    case reconciling
    case starting
    case running
    case stopping
    case failedCleanup
}

nonisolated struct StopSessionRequest: Codable, Sendable, Equatable {
    init() {}
}

nonisolated struct StatusResponse: Codable, Sendable, Equatable {
    let helperVersion: String
    let phase: VPNHelperSessionPhase
    let summary: String?
    let details: String?
}
```

Keep `StartSessionRequest` fields `configData`, `protectedHost`, `tunnelInterfaceName`, and `outboundInterface`, but remove `stateDirectoryPath`. Add the listed failure codes and:

```swift
case queryAuthoritativeStatus
case retryMatchingStop
case administrativeResetRequired
```

to `VPNHelperRetryDisposition`. Set `PrivilegedHelperConstants.version = "9"`. Add shared constants:

```swift
static let sessionStateFileName = "session-state.json"
static let routeJournalFileName = "route-journal.json"
```

Update payload validators and exact JSON-shape tests. Status allows a session ID only for `starting`, `running`, `stopping`, and `failedCleanup`; enforce phase/session pairing in response construction tests because the generic codec cannot inspect the envelope session from a payload-only validator.

- [ ] **Step 4: Run focused and Phase 3 regression verification**

Run:

```bash
swiftc Shared/*.swift scripts/verify_xpc_protocol.swift -o /tmp/teleport-verify-xpc-protocol
/tmp/teleport-verify-xpc-protocol
swiftc Shared/*.swift TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift scripts/verify_helper_request_ledger.swift -o /tmp/teleport-verify-helper-request-ledger
/tmp/teleport-verify-helper-request-ledger
git diff --check
```

Expected: all checks pass.

- [ ] **Step 5: Commit the protocol revision**

```bash
git add Shared/PrivilegedHelperConstants.swift Shared/VPNHelperMessages.swift Shared/VPNHelperProtocolError.swift scripts/verify_xpc_protocol.swift
git commit -m "🤖 feat: define authoritative helper protocol"
```

---

### Task 2: Add safe authoritative root-state persistence

**Files:**
- Create: `TeleportPrivilegedHelper/Support/RootAtomicFileStore.swift`
- Create: `TeleportPrivilegedHelper/Session/RootSessionState.swift`
- Create: `TeleportPrivilegedHelper/Session/RootStateStore.swift`
- Create: `TeleportPrivilegedHelper/Session/RootConfigurationStore.swift`
- Create: `scripts/verify_root_state_store.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `PrivilegedHelperConstants.helperStateDirectoryPath`, session phase semantics from Task 1.
- Produces:

```swift
struct RootProcessIdentity: Codable, Sendable, Equatable
struct RootSessionState: Codable, Sendable, Equatable
protocol RootStatePersisting: Sendable
struct RootStateStore: RootStatePersisting, Sendable
protocol RootConfigurationPersisting: Sendable
struct RootConfigurationStore: RootConfigurationPersisting, Sendable
```

- [ ] **Step 1: Write failing persistence and safety tests**

Create `scripts/verify_root_state_store.swift` with a temporary directory owned by the test UID and tests for:

```swift
let state = RootSessionState(
    schemaRevision: 1,
    sessionID: UUID(),
    ownerUID: UInt32(getuid()),
    phase: .starting,
    generation: 1,
    process: nil,
    tunnelInterfaceName: "utun7",
    failure: nil,
    updatedAtMilliseconds: 1_000
)
try store.save(state)
try expect(try store.load() == .state(state), "saved state must round trip")
try store.remove()
try expect(try store.load() == .absent, "removed state must be absent")
```

Add cases that reject a symlink state file, directory in place of file, wrong owner expectation, group/world-writable file, payload above 256 KiB, malformed JSON, schema revision `2`, and truncated JSON. Add an injected failpoint between temporary-file sync and rename; after the simulated failure, loading must return the old complete state, never partial data. Test absent-parent creation with mode `0700` and expected owner. Test that `RootConfigurationStore` accepts non-empty configuration up to 512 KiB, writes mode `0600`, returns only the UUID-derived root-owned path, rejects oversize/empty data, and removes only that session's exact regular file/directory.

- [ ] **Step 2: Run the new recipe to observe RED**

Run:

```bash
swiftc Shared/*.swift TeleportPrivilegedHelper/Support/RootAtomicFileStore.swift TeleportPrivilegedHelper/Session/RootSessionState.swift TeleportPrivilegedHelper/Session/RootStateStore.swift TeleportPrivilegedHelper/Session/RootConfigurationStore.swift scripts/verify_root_state_store.swift -o /tmp/teleport-verify-root-state-store
```

Expected: input files/types do not exist.

- [ ] **Step 3: Implement exact state values**

Use:

```swift
nonisolated struct RootProcessIdentity: Codable, Sendable, Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let executablePath: String
    let executableDevice: UInt64
    let executableInode: UInt64
}

nonisolated struct RootSessionFailure: Codable, Sendable, Equatable {
    let code: VPNHelperFailureCode
    let summary: String
    let details: String?
}

nonisolated struct RootSessionState: Codable, Sendable, Equatable {
    static let currentSchemaRevision: UInt = 1
    let schemaRevision: UInt
    let sessionID: UUID
    let ownerUID: UInt32
    let phase: VPNHelperSessionPhase
    let generation: UInt64
    let process: RootProcessIdentity?
    let tunnelInterfaceName: String?
    let failure: RootSessionFailure?
    let updatedAtMilliseconds: Int64
}

nonisolated enum RootStateLoadResult: Sendable, Equatable {
    case absent
    case state(RootSessionState)
}
```

Reject `.idle` and `.reconciling` as persisted session phases. Bound summary/details to shared diagnostic limits.

- [ ] **Step 4: Implement safe atomic storage**

Define:

```swift
protocol RootStatePersisting: Sendable {
    func load() throws -> RootStateLoadResult
    func save(_ state: RootSessionState) throws
    func remove() throws
}

protocol RootConfigurationPersisting: Sendable {
    func write(_ configuration: Data, sessionID: UUID) throws -> String
    func path(sessionID: UUID) -> String
    func remove(sessionID: UUID) throws
}
```

`RootAtomicFileStore` must use `lstat`, `open` with `O_NOFOLLOW | O_CLOEXEC`, `fstat`, bounded descriptor reads, a same-directory temporary filename, mode `0600`, `fchown`, complete write loops handling `EINTR`, `fsync`, `rename`, and directory `fsync`. If the exact configured parent is absent, create it once with mode `0700`, set the expected owner, then open and validate it descriptor-first; never create through a symlinked ancestor. Validate an existing parent as a real directory with expected owner and no group/world write bits. Production uses expected owner UID `0`; tests inject `getuid()`.

Return a typed `RootStateStoreError` with cases `unsafePath`, `oversized`, `corrupt`, `incompatibleSchema`, and `io(Int32)`; never interpret these as `.absent`. `RootConfigurationStore` uses the same atomic primitive, mode `0600`, and the shared 512 KiB bound. Its path is derived only from the UUID as `/var/db/dev.x.teleport/sessions/<sessionID>/xray.json`; it creates each root-owned session directory with mode `0700`. The unique path closes the crash window between process launch and identity persistence because reconciliation can inspect the exact executable plus exact config argument. Authoritative snapshots store no configuration bytes or user-owned path.

- [ ] **Step 5: Add and run the focused recipe**

Add to `justfile`:

```make
verify-root-state-store:
    swiftc Shared/*.swift TeleportPrivilegedHelper/Support/RootAtomicFileStore.swift TeleportPrivilegedHelper/Session/RootSessionState.swift TeleportPrivilegedHelper/Session/RootStateStore.swift TeleportPrivilegedHelper/Session/RootConfigurationStore.swift scripts/verify_root_state_store.swift -o /tmp/teleport-verify-root-state-store
    /tmp/teleport-verify-root-state-store
```

Run:

```bash
just verify-root-state-store
git diff --check
```

Expected: all state and failpoint checks pass.

- [ ] **Step 6: Commit root-state persistence**

```bash
git add TeleportPrivilegedHelper/Support/RootAtomicFileStore.swift TeleportPrivilegedHelper/Session/RootSessionState.swift TeleportPrivilegedHelper/Session/RootStateStore.swift TeleportPrivilegedHelper/Session/RootConfigurationStore.swift scripts/verify_root_state_store.swift justfile
git commit -m "🤖 feat: persist authoritative root sessions"
```

---

### Task 3: Add typed route plans and a write-ahead journal

**Files:**
- Create: `TeleportPrivilegedHelper/Routing/RoutePlan.swift`
- Create: `TeleportPrivilegedHelper/Routing/RouteJournal.swift`
- Create: `scripts/verify_route_journal.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `RootAtomicFileStore` from Task 2.
- Produces:

```swift
struct IPv4RouteTarget: Codable, Hashable, Sendable
struct RouteTuple: Codable, Hashable, Sendable
struct RoutePlan: Sendable, Equatable
struct RouteJournalEntry: Codable, Sendable, Equatable
enum RouteJournalLoadResult: Sendable, Equatable
protocol RouteJournalPersisting: Sendable
struct RouteJournalStore: RouteJournalPersisting, Sendable
```

- [ ] **Step 1: Write failing typed-plan and crash-window tests**

Cover deterministic order:

```swift
let plan = try RoutePlan.ipv4(
    protectedTargets: [IPv4RouteTarget(address: "203.0.113.8", gateway: "192.0.2.1")],
    dnsTargets: [
        IPv4RouteTarget(address: "8.8.8.8", gateway: "192.0.2.1"),
        IPv4RouteTarget(address: "1.1.1.1", gateway: "192.0.2.1")
    ],
    directGateway: "192.0.2.1",
    tunnelInterface: "utun7",
    outboundInterface: "en0"
)
try expect(plan.routes.map(\.role) == [
    .protectedHost,
    .directLowerHalf,
    .directUpperHalf,
    .dnsEscape,
    .dnsEscape,
    .captureLowerHalf,
    .captureUpperHalf
], "IPv4 route order must preserve escape routes before capture routes")
```

Test canonical sorting/deduplication of protected and DNS IPv4 targets, rejection of unresolved hostnames and malformed IPv4/prefix/interface/gateway values, and absence of IPv6. The untrusted `protectedHost` string never becomes a route destination; production planning must first resolve it to bounded concrete IPv4 addresses.

For the journal, test `recordIntent`, `markApplied`, reverse-order `entriesForRollback`, `removeEntry`, complete removal, session mismatch rejection, pending/applied round trips, oversized/corrupt/schema rejection, and atomic failpoint preservation.

- [ ] **Step 2: Run the journal recipe to observe RED**

Run:

```bash
swiftc Shared/*.swift TeleportPrivilegedHelper/Support/RootAtomicFileStore.swift TeleportPrivilegedHelper/Routing/RoutePlan.swift TeleportPrivilegedHelper/Routing/RouteJournal.swift scripts/verify_route_journal.swift -o /tmp/teleport-verify-route-journal
```

Expected: route and journal source files do not exist.

- [ ] **Step 3: Implement exact route values**

Use:

```swift
nonisolated enum RouteAddressFamily: String, Codable, Sendable { case inet }
nonisolated struct IPv4RouteTarget: Codable, Hashable, Sendable {
    let address: String
    let gateway: String
}
nonisolated enum RouteRole: String, Codable, Sendable {
    case protectedHost, dnsEscape, directLowerHalf, directUpperHalf
    case captureLowerHalf, captureUpperHalf
}
nonisolated struct RouteTuple: Codable, Hashable, Sendable {
    let family: RouteAddressFamily
    let destination: String
    let prefixLength: UInt8
    let gateway: String?
    let interface: String?
    let scopeInterface: String?
}
nonisolated struct PlannedRoute: Codable, Hashable, Sendable {
    let role: RouteRole
    let tuple: RouteTuple
}
nonisolated struct RoutePlan: Sendable, Equatable {
    let routes: [PlannedRoute]
}
```

Capture routes are `0.0.0.0/1` and `128.0.0.0/1` through the selected TUN. Direct half routes are scoped to a concrete outbound interface and use the physical gateway; omit them when outbound is `auto`. Escape host routes use `/32` through a pre-tunnel physical gateway. Sort and deduplicate concrete protected/DNS targets, with at most 16 protected and 16 public DNS IPv4 targets. Route-plan construction rejects hostnames so every persisted tuple remains exact and replayable.

- [ ] **Step 4: Implement the versioned write-ahead journal**

Use:

```swift
nonisolated enum RouteJournalEntryState: String, Codable, Sendable { case pending, applied }
nonisolated struct RouteJournalEntry: Codable, Sendable, Equatable {
    let sequence: UInt64
    let sessionID: UUID
    let route: PlannedRoute
    var state: RouteJournalEntryState
}
nonisolated struct RouteJournalSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaRevision: UInt = 1
    let schemaRevision: UInt
    let sessionID: UUID
    var entries: [RouteJournalEntry]
}
```

Define the exact store boundary:

```swift
nonisolated enum RouteJournalLoadResult: Sendable, Equatable {
    case absent
    case snapshot(RouteJournalSnapshot)
}

protocol RouteJournalPersisting: Sendable {
    func load() throws -> RouteJournalLoadResult
    func recordIntent(sessionID: UUID, route: PlannedRoute) throws -> RouteJournalEntry
    func markApplied(sessionID: UUID, sequence: UInt64) throws
    func removeEntry(sessionID: UUID, sequence: UInt64) throws
    func removeAll(sessionID: UUID) throws
}
```

Every mutator saves a complete bounded snapshot through `RootAtomicFileStore`; cap entries at 64 and reject duplicate sequence/tuple, mixed session IDs, invalid order, and schema mismatch.

- [ ] **Step 5: Add and run the focused recipe**

Add `verify-route-journal` to `justfile` and run:

```bash
just verify-route-journal
just verify-root-state-store
git diff --check
```

Expected: all checks pass.

- [ ] **Step 6: Commit route domain and journal**

```bash
git add TeleportPrivilegedHelper/Routing/RoutePlan.swift TeleportPrivilegedHelper/Routing/RouteJournal.swift scripts/verify_route_journal.swift justfile
git commit -m "🤖 feat: journal privileged route ownership"
```

---

### Task 4: Implement exact IPv4 route application and rollback

**Files:**
- Create: `TeleportPrivilegedHelper/Routing/RouteCommandExecutor.swift`
- Create: `TeleportPrivilegedHelper/Routing/RouteManager.swift`
- Create: `scripts/verify_route_manager.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `RoutePlan` and `RouteJournalPersisting` from Task 3.
- Produces:

```swift
protocol RouteCommandExecuting: Sendable
protocol RouteInspecting: Sendable
protocol RouteManaging: Sendable
struct RouteManager: RouteManaging, Sendable
struct RouteRollbackResult: Sendable, Equatable
```

- [ ] **Step 1: Write failing route-manager tests with a fake routing table**

Test these exact sequences:

```text
record pending protectedHost → add → inspect exact → mark applied
...
record pending captureUpperHalf → add → inspect exact → mark applied
```

Verify:

- escapes precede capture routes;
- any apply/verification failure initiates reverse rollback;
- rollback inspects before every delete;
- exact match deletes and verifies absence;
- absent tuple is treated as already clean;
- same destination with different gateway/interface/scope is preserved and returned as residue;
- delete failure remains journalled;
- pending intent with exact tuple is rolled back;
- pending intent with absent tuple is removed without delete;
- capture-route conflict fails without destination-only deletion;
- protected hostname resolution is bounded to 16 unique IPv4 addresses and each becomes an exact `/32` target;
- empty resolution fails before route mutation;
- public IPv4 DNS targets are sorted/deduplicated, bounded to 16, and non-public/IPv6 answers are excluded in this phase;
- no command contains unvalidated user text or `/bin/sh -c`.

- [ ] **Step 2: Run the route-manager recipe to observe RED**

Run:

```bash
swiftc Shared/*.swift TeleportPrivilegedHelper/Support/RootAtomicFileStore.swift TeleportPrivilegedHelper/Routing/RoutePlan.swift TeleportPrivilegedHelper/Routing/RouteJournal.swift TeleportPrivilegedHelper/Routing/RouteCommandExecutor.swift TeleportPrivilegedHelper/Routing/RouteManager.swift scripts/verify_route_manager.swift -o /tmp/teleport-verify-route-manager
```

Expected: executor and manager files/types do not exist.

- [ ] **Step 3: Implement typed route execution and inspection seams**

Define:

```swift
protocol RouteCommandExecuting: Sendable {
    func add(_ route: RouteTuple) throws
    func delete(_ route: RouteTuple) throws
}
protocol RouteInspecting: Sendable {
    func route(forDestination destination: String, prefixLength: UInt8) throws -> RouteTuple?
    func resolveIPv4(host: String, maximumResults: Int) throws -> [String]
    func dnsServers() throws -> [String]
    func gateway(toIPv4Address address: String) throws -> String
}
```

The production executor invokes `/sbin/route` directly with an argument array via `Process`; it never invokes a shell. Capture bounded stdout/stderr and expose only safe typed errors. Build arguments exclusively from validated `RouteTuple` fields. Inspection parses bounded `route -n get` output into a complete tuple. Resolve `protectedHost` with bounded `getaddrinfo(AF_INET)` results, canonicalize addresses with `inet_ntop`, and resolve each physical gateway before capture routes exist.

- [ ] **Step 4: Implement transactional apply and exact rollback**

Expose:

```swift
struct RouteRollbackResult: Sendable, Equatable {
    let removed: [PlannedRoute]
    let residues: [PlannedRoute]
}

protocol RouteManaging: Sendable {
    func makePlan(
        protectedHost: String,
        tunnelInterface: String,
        outboundInterface: String
    ) throws -> RoutePlan
    func apply(_ plan: RoutePlan, sessionID: UUID) throws
    func validateRunningRoutes(sessionID: UUID) throws -> Bool
    func rollback(sessionID: UUID) throws -> RouteRollbackResult
}

struct RouteManager: RouteManaging, Sendable {
    init(
        executor: any RouteCommandExecuting,
        inspector: any RouteInspecting,
        journal: any RouteJournalPersisting
    )
}
```

`makePlan` converts the protected hostname and current DNS configuration into bounded concrete IPv4 targets and resolves their pre-tunnel gateways. `apply` persists intent before add and marks applied only after exact inspection. It calls rollback after the first failure and throws a typed error containing whether residue remains. `rollback` iterates descending sequence, preserves mismatches, removes clean entries from the journal, and deletes the journal only when empty.

- [ ] **Step 5: Run focused route verification**

Add `verify-route-manager` to `justfile` and run:

```bash
just verify-route-manager
just verify-route-journal
git diff --check
```

Expected: all checks pass.

- [ ] **Step 6: Commit exact route management**

```bash
git add TeleportPrivilegedHelper/Routing/RouteCommandExecutor.swift TeleportPrivilegedHelper/Routing/RouteManager.swift scripts/verify_route_manager.swift justfile
git commit -m "🤖 feat: apply session-owned IPv4 routes"
```

---

### Task 5: Introduce stable Xray process supervision

**Files:**
- Create: `TeleportPrivilegedHelper/Xray/RootProcessInspector.swift`
- Create: `TeleportPrivilegedHelper/Xray/RootXraySupervisor.swift`
- Create: `TeleportPrivilegedHelper/Xray/RootXrayDiagnostics.swift`
- Create: `scripts/verify_root_xray_supervisor.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `RootProcessIdentity` from Task 2 and installed Xray/config/log paths.
- Produces:

```swift
protocol RootProcessInspecting: Sendable
protocol RootProcessSignalling: Sendable
protocol TunnelInterfaceInspecting: Sendable
protocol LifecycleSleeping: Sendable
protocol RootXraySupervising: Sendable
actor RootXraySupervisor: RootXraySupervising
struct RootXrayTerminationEvent: Sendable, Equatable
protocol RootDiagnosticsReading: Sendable
```

- [ ] **Step 1: Write failing process identity and supervisor tests**

Use injected fake inspector, signaller, tunnel inspector, and sleeper values to test:

- launch exactly once and return complete identity;
- discover a launch candidate only when executable path and the complete `run -c <session-derived-config-path>` arguments match;
- reject a second launch while the exact process is active;
- compare PID, start seconds/microseconds, resolved executable path, device, and inode;
- reject same PID with changed start time;
- reject replaced executable inode;
- never signal a mismatched process;
- SIGTERM → ten 200 ms checks → SIGKILL ordering;
- ESRCH is successful absence;
- exact requested TUN or allowed fallback discovery;
- process exit during readiness returns `xrayExited`;
- readiness after 20 × 500 ms failure returns `interfaceReadiness`;
- termination callback carries session ID and generation;
- the root log is truncated/rotated at a 1 MiB on-disk bound by the actor monitor and configuration bytes are not included in errors;
- diagnostics reader accepts only `.xray` and `.control`, rejects unsafe files, and returns no more than the requested 256 KiB bound.

- [ ] **Step 2: Run the supervisor recipe to observe RED**

Run:

```bash
swiftc Shared/*.swift TeleportPrivilegedHelper/Session/RootSessionState.swift TeleportPrivilegedHelper/Xray/RootProcessInspector.swift TeleportPrivilegedHelper/Xray/RootXraySupervisor.swift TeleportPrivilegedHelper/Xray/RootXrayDiagnostics.swift scripts/verify_root_xray_supervisor.swift -o /tmp/teleport-verify-root-xray-supervisor
```

Expected: process inspector and supervisor files/types do not exist.

- [ ] **Step 3: Implement public-API process identity inspection**

Define:

```swift
protocol RootProcessInspecting: Sendable {
    func identity(pid: pid_t) throws -> RootProcessIdentity?
    func matches(_ expected: RootProcessIdentity) throws -> Bool
    func launchCandidates(configPath: String, maximumResults: Int) throws -> [RootProcessIdentity]
}
protocol RootProcessSignalling: Sendable {
    func send(_ signal: Int32, to identity: RootProcessIdentity) throws
}
protocol TunnelInterfaceInspecting: Sendable {
    func exists(_ name: String) throws -> Bool
    func discoverTeleportTunnel() throws -> String?
}
protocol LifecycleSleeping: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}
```

Use `proc_pidpath`, `proc_pidinfo(PROC_PIDTBSDINFO, ...)`, bounded public process-argument inspection, and `stat` on the resolved executable to capture start time and file device/inode. Require the resolved path to equal `PrivilegedHelperConstants.installedXrayPath`. `launchCandidates` accepts only the complete argument shape `run -c <UUID-derived-root-config-path>`, returns at most four identities, and rejects truncation. Re-read all evidence on every `matches` call.

- [ ] **Step 4: Implement launch, readiness, adoption, observation, and termination**

Define:

```swift
nonisolated struct RootXrayTerminationEvent: Sendable, Equatable {
    let sessionID: UUID
    let generation: UInt64
    let terminationStatus: Int32
}

protocol RootXraySupervising: Sendable {
    func launch(configPath: String, sessionID: UUID, generation: UInt64) async throws -> RootProcessIdentity
    func waitForTunnel(requested: String, process: RootProcessIdentity) async throws -> String
    func adopt(_ identity: RootProcessIdentity, sessionID: UUID, generation: UInt64) async throws
    func terminate(_ identity: RootProcessIdentity) async throws
    func isAlive(_ identity: RootProcessIdentity) async throws -> Bool
    func terminationEvents() async -> AsyncStream<RootXrayTerminationEvent>
}

protocol RootDiagnosticsReading: Sendable {
    func read(_ request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse
}

actor RootXraySupervisor: RootXraySupervising {
    init(
        installedXrayPath: String,
        assetDirectoryPath: String,
        processInspector: any RootProcessInspecting,
        signaller: any RootProcessSignalling,
        tunnelInspector: any TunnelInterfaceInspecting,
        sleeper: any LifecycleSleeping
    )
}
```

Launch the executable directly with arguments `run -c <configPath>`, set `XRAY_LOCATION_ASSET`, redirect stdin from `/dev/null`, and append stdout/stderr to a root-owned mode-`0600` log. The actor monitor checks the log with `O_NOFOLLOW`, preserves only the newest bytes through atomic rotation when it exceeds 1 MiB, and performs the same bound check immediately during adoption. Keep `Process`, stream continuation, and monitor-task state actor-isolated so no new `@unchecked Sendable` is needed. Observation must not retain unbounded callbacks. Adoption validates identity before installing observation; because `Process` cannot attach to a non-child process, use a bounded low-frequency identity monitor task owned by the supervisor. `RootXrayDiagnostics` performs allowlisted descriptor-based tail reads from fixed log names and never returns config data.

- [ ] **Step 5: Add and run focused verification**

Add `verify-root-xray-supervisor` to `justfile` and run:

```bash
just verify-root-xray-supervisor
git diff --check
```

Expected: all checks pass.

- [ ] **Step 6: Commit process supervision**

```bash
git add TeleportPrivilegedHelper/Xray/RootProcessInspector.swift TeleportPrivilegedHelper/Xray/RootXraySupervisor.swift TeleportPrivilegedHelper/Xray/RootXrayDiagnostics.swift scripts/verify_root_xray_supervisor.swift justfile
git commit -m "🤖 feat: supervise authoritative Xray process"
```

---

### Task 6: Implement the actor lifecycle state machine

**Files:**
- Create: `TeleportPrivilegedHelper/Session/VPNSessionController.swift`
- Modify: `TeleportPrivilegedHelper/Support/HelperPlatform.swift`
- Create: `scripts/verify_vpn_session_controller.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `RootStatePersisting`, `RootConfigurationPersisting`, `RootXraySupervising`, `RouteManaging`, `RootDiagnosticsReading`, and revision-9 messages.
- Produces:

```swift
actor VPNSessionController
struct HelperClientContext: Sendable, Equatable
struct PrivilegedSessionSnapshot: Sendable, Equatable
protocol ActiveConsoleUserProviding: Sendable
```

- [ ] **Step 1: Write failing admission and concurrency tests**

Use in-memory state/config, route, supervisor, diagnostics, active-console identity, and clock fakes. Test:

- initial status is `.reconciling` until explicit reconciliation finishes;
- status remains responsive while launch/readiness or a route command is blocked;
- accepted start persists `.starting` before supervisor launch and immediately returns `.starting`;
- duplicate same-ID start returns current state without another launch;
- different-ID start returns `sessionConflict`;
- different UID receives `ownedByAnotherUser`;
- a previously authenticated connection is rejected after active console UID changes;
- start while `failedCleanup` is rejected;
- matching stop during blocked start invalidates the old generation and starts cleanup;
- stale readiness and termination completions cannot publish running/idle;
- stop with wrong ID fails;
- repeated matching stop joins/reports one cleanup operation;
- complete cleanup reaches idle only after state and journal removal;
- residue persists `failedCleanup` and matching repeated stop retries it;
- concurrent status/diagnostics never wait behind slow lifecycle effects;
- diagnostics from a session are denied to a different active UID;
- successful cleanup truncates/removes session logs before ownership is discarded.

- [ ] **Step 2: Run the controller recipe to observe RED**

Run:

```bash
swiftc Shared/*.swift TeleportPrivilegedHelper/Session/RootSessionState.swift TeleportPrivilegedHelper/Session/VPNSessionController.swift scripts/verify_vpn_session_controller.swift -o /tmp/teleport-verify-vpn-session-controller
```

Expected: controller source/types do not exist.

- [ ] **Step 3: Implement explicit actor state and caller context**

Use:

```swift
nonisolated struct HelperClientContext: Sendable, Equatable {
    let effectiveUID: UInt32
}

nonisolated struct PrivilegedSessionSnapshot: Sendable, Equatable {
    let phase: VPNHelperSessionPhase
    let sessionID: UUID?
    let failure: RootSessionFailure?
}

protocol ActiveConsoleUserProviding: Sendable {
    func activeConsoleUID() -> UInt32?
}

actor VPNSessionController {
    private enum MemoryState {
        case reconciling
        case idle
        case active(RootSessionState)
    }

    func status(for context: HelperClientContext) throws -> PrivilegedSessionSnapshot
    func start(
        request: StartSessionRequest,
        sessionID: UUID,
        context: HelperClientContext
    ) throws -> PrivilegedSessionSnapshot
    func stop(
        sessionID: UUID,
        context: HelperClientContext
    ) throws -> PrivilegedSessionSnapshot
}
```

`PrivilegedSessionSnapshot` is an internal value mapped to wire responses by the dispatcher. Every command rechecks that `context.effectiveUID` still equals the injected active console UID, closing the Fast User Switching window after XPC connection acceptance. Mutating admission increments `generation`, synchronously persists the new state, creates one stored `Task.detached` worker, and returns. Slow supervisor waits and synchronous route commands run outside controller actor isolation; each durable intermediate transition is applied by awaiting a short actor method. Child completions call actor methods with session ID and generation, and those methods discard stale results. Every stored worker is awaited or cancelled during replacement/shutdown so unobserved work cannot outlive controller ownership.

- [ ] **Step 4: Implement start and stop effect ordering with fakes**

Start child ordering must be:

```text
write root-owned config → launch → persist process identity
→ wait for tunnel → persist interface → resolve exact IPv4 plan
→ apply journalled plan → persist running
```

Failure ordering must be:

```text
validate/terminate matching process → reverse journal rollback
→ remove fixed root config and session logs
→ remove state when clean OR persist failedCleanup with residue
```

Stop uses the same cleanup function. A stop admitted while start is blocked changes generation before cleanup so late start completion is stale.

- [ ] **Step 5: Implement termination-event consumption**

The controller starts one task consuming `terminationEvents()`. A matching starting/running event increments generation, persists failure evidence, and runs cleanup. Events for another session/generation are ignored. Bound retained exit details to 4 KiB. Route diagnostics through the controller so owner UID is enforced while a session exists; successful cleanup clears session logs before removing owner state.

- [ ] **Step 6: Add and run focused verification**

Add `verify-vpn-session-controller` to `justfile` with every Task 2–5 source dependency, then run:

```bash
just verify-vpn-session-controller
just verify-root-state-store
just verify-route-manager
just verify-root-xray-supervisor
git diff --check
```

Expected: all checks pass.

- [ ] **Step 7: Commit the actor state machine**

```bash
git add TeleportPrivilegedHelper/Session/VPNSessionController.swift TeleportPrivilegedHelper/Support/HelperPlatform.swift scripts/verify_vpn_session_controller.swift justfile
git commit -m "🤖 feat: own VPN lifecycle in helper actor"
```

---

### Task 7: Add startup reconciliation and production helper composition

**Files:**
- Modify: `TeleportPrivilegedHelper/Session/VPNSessionController.swift`
- Modify: `TeleportPrivilegedHelper/IPC/HelperCommandExecuting.swift`
- Modify: `TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift`
- Modify: `TeleportPrivilegedHelper/IPC/ClientAuthenticator.swift`
- Modify: `TeleportPrivilegedHelper/IPC/HelperXPCService.swift`
- Modify: `TeleportPrivilegedHelper/IPC/HelperXPCListenerDelegate.swift`
- Modify: `TeleportPrivilegedHelper/main.swift`
- Modify: `scripts/verify_vpn_session_controller.swift`
- Modify: `scripts/verify_helper_command_dispatch.swift`
- Modify: `scripts/verify_helper_xpc_endpoint.swift`

**Interfaces:**
- Consumes: complete controller dependencies from Tasks 2–6 and Phase 3 XPC endpoint.
- Produces: `VPNSessionController.reconcileAtStartup()`, `HelperCommandResult<Payload>`, async context-aware command execution, and one exported service per authenticated UID.

- [ ] **Step 1: Add failing startup reconciliation tests**

Cover:

- no state + no journal → idle;
- valid running state + exact process/interface/routes → adopt and running;
- starting/stopping state → cleanup, never resume forward work;
- crash after launch but before process identity persistence → discover exact executable/config-argument candidate and terminate it by freshly captured full identity;
- missing process/interface/applied route → cleanup;
- process identity mismatch → do not signal, roll back only exact journal routes;
- pending intent + exact route → include in rollback;
- pending intent + absent route → remove journal entry without delete;
- changed route tuple → preserve route and enter failedCleanup;
- process absent after reboot → route reconciliation then idle/failedCleanup;
- corrupt state + independently valid journal → clean only exact journal routes, then remain blocked because process ownership is unknown;
- mutation during reconciliation → `reconciliationInProgress`;
- status during reconciliation → `.reconciling`.

- [ ] **Step 2: Add failing caller-context endpoint tests**

Change dispatcher tests to require:

```swift
await dispatcher.dispatch(
    command: .status,
    requestData: request,
    context: HelperClientContext(effectiveUID: 501)
)
```

Assert the dispatcher has no `observedSessionID`, `queuedSessionID`, `correlationGeneration`, or lifecycle `executionTail`. Assert caller UID reaches the executor. Endpoint tests must prove each accepted XPC connection receives a distinct `HelperXPCService` bound to the authenticated effective UID.

- [ ] **Step 3: Run focused recipes to observe RED**

Run:

```bash
just verify-vpn-session-controller
just verify-helper-command-dispatch
just verify-helper-xpc-endpoint
```

Expected: missing reconciliation API/context signatures and old dispatcher assumptions fail.

- [ ] **Step 4: Implement startup reconciliation**

Add:

```swift
func reconcileAtStartup() async
```

It loads state and journal independently, follows the exact matrix in the spec, and changes `.reconciling` only after adoption or cleanup reaches a durable result. Valid running adoption requires owner UID, matching process identity, expected interface, and all exact applied journal tuples. Every other non-corrupt transitional condition uses the shared cleanup path. If `.starting` has no persisted process identity, derive its root-only config path from the session UUID, enumerate bounded exact launch candidates, capture full identities, and terminate only those exact matches before route cleanup. Zero candidates means no process work; ambiguous or truncated inspection fails closed instead of signalling.

- [ ] **Step 5: Make command execution async and context-aware**

Use:

```swift
nonisolated struct HelperCommandResult<Payload: Codable & Sendable & Equatable>: Sendable {
    let sessionID: UUID?
    let payload: Payload
}

protocol HelperCommandExecuting: Sendable {
    func status(request: StatusRequest, context: HelperClientContext) async throws -> HelperCommandResult<StatusResponse>
    func start(request: StartSessionRequest, sessionID: UUID, context: HelperClientContext) async throws -> HelperCommandResult<StartSessionResponse>
    func stop(request: StopSessionRequest, sessionID: UUID, context: HelperClientContext) async throws -> HelperCommandResult<StopSessionResponse>
    func readDiagnostics(request: ReadDiagnosticsRequest, context: HelperClientContext) async throws -> HelperCommandResult<DiagnosticsResponse>
}
```

The dispatcher retains payload validation and `HelperRequestLedger`, but delegates immediately to this executor. Remove Phase 3 observed/queued session correlation and serial `executionTail`; response session IDs come only from `HelperCommandResult`. Preserve typed `VPNHelperProtocolFailure` values thrown by the controller rather than collapsing them into `commandFailed`. Status results use the authoritative snapshot session ID; start/stop operation replies echo the requested matching session ID even when stop has just reached idle.

- [ ] **Step 6: Bind authenticated caller identity per XPC connection**

Change authentication to:

```swift
func authorize(_ connection: NSXPCConnection) -> HelperClientContext?
```

It still checks non-root active console UID and installs the code-signing requirement before acceptance. `HelperXPCListenerDelegate` constructs a new `HelperXPCService(dispatcher:context:)` for each connection instead of sharing one service. The service passes its immutable context to every dispatch, while the controller independently rechecks the current active console UID on every command.

- [ ] **Step 7: Compose production dependencies and start reconciliation**

In `main.swift`, construct the atomic state/config/journal stores, diagnostics reader, active-console provider, process inspector, actor supervisor, route executor/inspector, route manager, controller, and dispatcher. Start one task:

```swift
Task { await controller.reconcileAtStartup() }
```

before resuming the listener. Status remains available as `.reconciling`; mutations fail typed until the task completes. Keep all dependencies alive through the existing run loop.

- [ ] **Step 8: Run endpoint/controller regressions**

Run:

```bash
just verify-vpn-session-controller
just verify-helper-command-dispatch
just verify-helper-xpc-endpoint
just verify-xpc-transport
just verify-xpc-protocol
git diff --check
```

Expected: all checks pass.

- [ ] **Step 9: Commit reconciliation and composition**

```bash
git add TeleportPrivilegedHelper/Session/VPNSessionController.swift TeleportPrivilegedHelper/IPC/HelperCommandExecuting.swift TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift TeleportPrivilegedHelper/IPC/ClientAuthenticator.swift TeleportPrivilegedHelper/IPC/HelperXPCService.swift TeleportPrivilegedHelper/IPC/HelperXPCListenerDelegate.swift TeleportPrivilegedHelper/main.swift scripts/verify_vpn_session_controller.swift scripts/verify_helper_command_dispatch.swift scripts/verify_helper_xpc_endpoint.swift
git commit -m "🤖 feat: reconcile authoritative helper state"
```

---

### Task 8: Migrate the app to authoritative admission and bounded polling

**Files:**
- Modify: `teleport/VPN/PrivilegedHelperClient.swift`
- Modify: `teleport/VPN/PrivilegedXrayRuntimeManager.swift`
- Modify: `teleport/VPN/RootXrayConnectionProvider.swift`
- Create: `teleport/VPN/XrayTunLaunchSessionBuilder.swift`
- Delete: `teleport/VPN/XrayTunConnectionBackend.swift`
- Create: `teleport/VPN/XrayTunSessionCache.swift`
- Delete: `teleport/VPN/XrayTunSessionState.swift`
- Modify: `scripts/verify_privileged_helper_client.swift`
- Create: `scripts/verify_authoritative_vpn_runtime.swift`
- Modify: `scripts/verify_connection_provider.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: revision-9 admission/status protocol from Task 1 and authoritative helper behavior from Task 7.
- Produces:

```swift
PrivilegedHelperClient.start(session:sessionID:) throws -> PrivilegedHelperStatus
PrivilegedHelperClient.stop(sessionID:) throws -> PrivilegedHelperStatus
PrivilegedXrayRuntimeManager.start(...) async throws
PrivilegedXrayRuntimeManager.stop() async throws
actor RootXrayConnectionProvider: ConnectionProvider
```

- [ ] **Step 1: Change client tests to admission semantics**

Assert:

- start accepts `.starting` or same-session `.running` and rejects other phases;
- stop accepts `.stopping`, `.failedCleanup`, or `.idle` with exact response-session rules;
- status validates idle/reconciling as sessionless and active phases as session-bound;
- all new protocol failures map to stable `PrivilegedHelperClientError` cases;
- transport interruption queries authoritative status once and never retransmits mutation;
- stop payload is empty;
- no app request carries user state directory or cleanup route inputs.

- [ ] **Step 2: Write failing runtime polling tests**

Create a scripted fake client/clock and cover:

```text
start returns starting → status starting → status running → cache authoritative ID
start deadline while starting → one stop → status stopping → status idle → throw startup timeout
stop returns stopping → status stopping → status idle → remove cache
status running with absent/different cache → replace cache and report running
status failedCleanup → never report idle and preserve session ID for retry
transport failure → no PID/helper-file fallback
```

Also assert 200 ms polling steps, a 20-second start deadline, a 15-second stop deadline, and cancellation checks between polls. Tests must use an injected async sleeper/clock and never sleep in wall-clock time. Add provider tests proving initial authoritative restoration, serialized connect/disconnect, disconnect interleaving with a suspended connect, and one state stream driven only by authoritative runtime outcomes.

- [ ] **Step 3: Run client/runtime recipes to observe RED**

Run:

```bash
just verify-privileged-helper-client
swiftc teleport/TeleportModels.swift teleport/App/*.swift teleport/Connection/*.swift teleport/Parsing/*.swift teleport/Persistence/*.swift teleport/Subscriptions/*.swift teleport/XrayCore/*.swift teleport/SystemProxy/*.swift teleport/VPN/*.swift teleport/HelperInstallation/*.swift teleport/Geodata/*.swift teleport/Health/*.swift teleport/ViewModels/*.swift Shared/*.swift scripts/verify_authoritative_vpn_runtime.swift -o /tmp/teleport-verify-authoritative-vpn-runtime
```

Expected: old running/idle-only client assumptions and missing runtime seams fail.

- [ ] **Step 4: Implement strict authoritative client mapping**

Change start and stop to return `PrivilegedHelperStatus`. Keep Phase 3 transport deadlines for each admission request, but reconcile interruption against authoritative status. Add explicit client errors for conflict, ownership, reconciliation, corruption, identity, route, and cleanup categories; preserve bounded summary/details.

Validate phase/session shape after decoding:

```swift
switch status.phase {
case .idle, .reconciling:
    guard status.sessionID == nil else { throw invalidResponse }
case .starting, .running, .stopping, .failedCleanup:
    guard status.sessionID != nil else { throw invalidResponse }
}
```

- [ ] **Step 5: Replace app-side PID/file authority with polling**

Create the focused cache value/store:

```swift
struct XrayTunSessionCache: Codable, Sendable, Equatable {
    let sessionID: UUID
    let connectedAt: Date?
}

protocol XrayTunSessionCaching: Sendable {
    func load() -> XrayTunSessionCache?
    func save(_ cache: XrayTunSessionCache) throws
    func remove() throws
}
```

The production store uses only `~/Library/Application Support/teleport/xray-tun-session.json`, a 16 KiB read bound, regular-file/symlink checks, and atomic user-owned writes. Add malformed, oversized, symlink, absent, save, replacement, and removal cases to the runtime harness. Remove PID, protected-host, interface, config-path reads, `XrayTunRuntimePaths`, `readPID`, `readProtectedHost`, direct root control-log reads, and `kill(pid, 0)` fallback. `isRunning()` returns true only for authoritative `.running` with the expected helper version. A running same-owner helper status always overwrites absent/different cache.

Inject:

```swift
protocol VPNLifecycleWaiting: Sendable {
    func now() -> Date
    func sleep(for interval: TimeInterval) async throws
    func checkCancellation() throws
}

struct SystemVPNLifecycleWaiter: VPNLifecycleWaiting {
    func now() -> Date { Date() }
    func sleep(for interval: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    func checkCancellation() throws { try Task.checkCancellation() }
}
```

Make `PrivilegedXrayRuntimeManager` an actor, removing its existing `@unchecked Sendable`. Poll every 200 ms with `await` between requests. On start deadline/cancellation while starting, send one matching stop and poll cleanup. Never retransmit start. On stop timeout or failedCleanup, retain cache/session correlation and throw a non-idle cleanup error.

- [ ] **Step 6: Replace the transitional VPN backend with a dedicated async provider**

Move physical-interface conflict checks, outbound-interface selection, tunnel-name selection, and Xray config construction into `XrayTunLaunchSessionBuilder`. Implement `RootXrayConnectionProvider` as an actor with a `nonisolated let stateStore` used by `stateUpdates()`. Its `connect` and `disconnect` call the runtime actor directly, publish the existing domain states, and use a generation/task handle so disconnect can invalidate and clean up a suspended connect. Initial reconciliation queries helper status: running restores `.connected(ConnectionSession(id: authoritativeSessionID, ...))`, idle becomes `.idle`, and transitional/failed-cleanup states remain visible as preparing/disconnecting/failed rather than false idle. Delete `XrayTunConnectionBackend.swift`; System Proxy continues using `BackendConnectionProvider`.

- [ ] **Step 7: Add and run app-focused recipes**

Add `verify-authoritative-vpn-runtime` to `justfile` with the exact app/shared source set needed by the standalone harness. Run:

```bash
just verify-privileged-helper-client
just verify-authoritative-vpn-runtime
just verify-connection-provider
just verify-xpc-transport
git diff --check
```

Expected: all checks pass.

- [ ] **Step 8: Commit app authoritative reconciliation**

```bash
git add teleport/VPN/PrivilegedHelperClient.swift teleport/VPN/PrivilegedXrayRuntimeManager.swift teleport/VPN/RootXrayConnectionProvider.swift teleport/VPN/XrayTunLaunchSessionBuilder.swift teleport/VPN/XrayTunSessionCache.swift scripts/verify_privileged_helper_client.swift scripts/verify_authoritative_vpn_runtime.swift scripts/verify_connection_provider.swift justfile
git add -u teleport/VPN/XrayTunConnectionBackend.swift teleport/VPN/XrayTunSessionState.swift
git commit -m "🤖 refactor: trust authoritative helper sessions"
```

---

### Task 9: Remove shell lifecycle ownership and enforce architecture boundaries

**Files:**
- Delete: `TeleportPrivilegedHelper/Session/XrayTunController.swift`
- Delete: `TeleportPrivilegedHelper/Routing/XrayTunScriptBuilder.swift`
- Delete: `TeleportPrivilegedHelper/Xray/ManagedXrayProcess.swift`
- Delete: `TeleportPrivilegedHelper/Support/HelperShellRunner.swift`
- Modify: `TeleportPrivilegedHelper/Support/HelperConfiguration.swift`
- Modify: `scripts/verify_architecture_layout.swift`
- Modify: `justfile`
- Modify: `README.md`
- Modify: `docs/runtime-source-layout.md`
- Modify: `docs/xray-bundling-and-release.md`
- Modify: `scripts/reset_legacy_privileged_helper.sh`
- Modify: `scripts/verify_mach_service_installation.swift`

**Interfaces:**
- Consumes: verified replacement controller, route manager, supervisor, and app polling from Tasks 1–8.
- Produces: one authoritative production composition with no generated lifecycle shell or app-side root-state authority.

- [ ] **Step 1: Add failing architecture assertions before deleting legacy files**

Extend `verify_architecture_layout.swift` recursively over production Swift sources. Require the new files and reject:

```text
XrayTunController
XrayTunScriptBuilder
ManagedXrayProcess
HelperShellRunner
XrayTunConnectionBackend
makeStartScript
makeStopScript
/bin/sh
xray-tun.pid
xray-tun-protected-host
kill(pid, 0)
readPID(
readProtectedHost(
```

Permit `/bin/sh` only in explicitly allowlisted non-lifecycle tooling outside production Swift. Assert `AppViewModel` and app VPN sources do not reference `RootSessionState`, `RouteJournal`, `RootProcessIdentity`, `/var/db/dev.x.teleport`, or route command details. Assert production source does not reference `SMAppService` or IPv6 route implementation.

- [ ] **Step 2: Run the guard to confirm RED**

Run:

```bash
swiftc scripts/verify_architecture_layout.swift -o /tmp/teleport-verify-architecture-layout
/tmp/teleport-verify-architecture-layout
```

Expected: obsolete lifecycle files and symbols are reported.

- [ ] **Step 3: Re-run parity tests before removal**

Run:

```bash
just verify-route-manager
just verify-root-xray-supervisor
just verify-vpn-session-controller
just verify-authoritative-vpn-runtime
```

Expected: IPv4 order, readiness, termination, cleanup, and app semantics pass through replacement components.

- [ ] **Step 4: Delete legacy lifecycle implementation and clean constants**

Delete the four obsolete files. Remove shell-output bounds and legacy PID/protected-host helpers from `HelperConfiguration.swift`. Keep only current protocol/config/diagnostic/signing constants. Update any Xcode file membership references if the filesystem-synchronized groups do not remove them automatically.

- [ ] **Step 5: Update verification composition and documentation**

Add all Phase 4 recipes to the aggregate `verify` recipe in dependency order:

```text
verify-root-state-store
verify-route-journal
verify-route-manager
verify-root-xray-supervisor
verify-vpn-session-controller
verify-authoritative-vpn-runtime
```

Document:

- helper-authoritative persisted sessions;
- owner UID and Fast User Switching behavior;
- valid-running adoption and transitional cleanup;
- exact route journal and `failedCleanup` retry via stop;
- non-blocking admission plus app polling;
- removed lifecycle shell and PID/file fallbacks;
- Phase 5 `SMAppService` and IPv6 remain future work;
- manual kill/restart/reboot/route-residue acceptance remains unperformed release risk.

Do not claim any manual system scenario passed.

Update the destructive reset script so Phase 3→4 development cutover cannot boot out the helper or remove state while an old exact installed-Xray command line is active. As the first destructive preflight, enumerate candidate command lines and fail with an instruction to disconnect Teleport VPN when any command begins with `/Library/PrivilegedHelperTools/dev.x.teleport.xray run -c `. Do not signal that process or delete routes/state, because Phase 3 has no exact route journal. Extend `verify_mach_service_installation.swift` with static assertions that this check precedes `launchctl bootout` and every removal. Keep the script manual; do not execute it.

- [ ] **Step 6: Run focused and full clean verification**

Run:

```bash
swiftc scripts/verify_architecture_layout.swift -o /tmp/teleport-verify-architecture-layout
/tmp/teleport-verify-architecture-layout
git diff --check
just verify-mach-service-installation
just clean && just verify
```

Expected: architecture guard, Debug app/helper build, and every standalone verification pass.

- [ ] **Step 7: Build and verify the helper independently**

Run the helper source list shown by the current `justfile` standalone helper recipe, then verify the resulting binary and app:

```bash
codesign --verify --strict build/DerivedData/Build/Products/Debug/dev.x.teleport.PrivilegedHelper
codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Teleport.app
```

Expected: both signatures verify. This is development-signature evidence only, not Developer ID/notarization acceptance.

- [ ] **Step 8: Commit the authoritative cutover**

```bash
git add -A
git commit -m "🤖 refactor: complete authoritative helper lifecycle"
```

---

### Task 10: Whole-branch review and release-risk checkpoint

**Files:**
- Review: all changes from the Phase 4 baseline through Task 9
- Modify if required: only files implicated by concrete review findings

**Interfaces:**
- Consumes: complete Phase 4 implementation.
- Produces: independent spec/quality verdicts and an explicit manual-risk inventory.

- [ ] **Step 1: Run an independent spec review**

Review the full branch against `docs/superpowers/specs/2026-09-03-authoritative-helper-lifecycle-design.md`. Block completion on:

- non-authoritative app/file/PID fallback;
- state interpreted as idle after corruption;
- PID-only signalling;
- route mutation without durable prior intent;
- destination-only or mismatched route deletion;
- start allowed during residue;
- status side effects;
- blocking actor/XPC lifecycle execution;
- stale task completion changing current state;
- cross-UID mutation;
- Phase 5/IPv6/auto-connect scope creep.

Expected reviewer output: `SPEC VERDICT: APPROVED` or concrete file/line findings.

- [ ] **Step 2: Run an independent quality/concurrency review**

Inspect atomic-file durability, actor reentrancy, cancellation, process monitor lifetime, request-ledger interaction, bounded polling, exact route parsing, secret redaction, and unsafe sendability. Require deterministic tests for every reported race or crash window.

Expected reviewer output: `QUALITY VERDICT: APPROVED` or concrete file/line findings.

- [ ] **Step 3: Resolve findings with focused RED/GREEN cycles**

For each valid finding, first add the smallest standalone failing assertion to the owning `scripts/verify_*.swift`, run it to observe failure, implement the narrow correction, rerun focused verification, and commit with a message containing `🤖`. Do not combine unrelated findings.

- [ ] **Step 4: Run final fresh verification**

Run:

```bash
git diff --check
just clean && just verify
codesign --verify --strict build/DerivedData/Build/Products/Debug/dev.x.teleport.PrivilegedHelper
codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Teleport.app
git status --short
```

Expected: all commands pass and the worktree is clean after final review commits.

- [ ] **Step 5: Record manual acceptance risks**

Confirm the release checklist explicitly leaves these unverified until performed on real macOS:

- Xray/TUN startup and exact IPv4 routes;
- helper kill/restart during starting, running, and stopping;
- valid running adoption;
- app crash/relaunch restoration;
- unexpected Xray exit;
- route residue and repeated-stop recovery;
- reboot reconciliation;
- Fast User Switching ownership;
- app termination during pending lifecycle work;
- production Developer ID/hardened-runtime/notarized artifact behavior.

Do not run the destructive reset script or represent these checks as complete during automated development.
