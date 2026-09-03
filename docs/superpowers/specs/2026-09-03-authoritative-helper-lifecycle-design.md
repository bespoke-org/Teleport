# Phase 4: Authoritative Privileged Helper Lifecycle Design

**Date:** 2026-09-03
**Status:** Approved design; pending implementation planning
**Canonical base:** `nrydanov/split-tunneling`

## 1. Purpose

Make the privileged helper the authoritative owner of root-Xray VPN session state, process identity, interface readiness, and route ownership.

Phase 3 established an authenticated exact-revision XPC transport with request/session correlation, bounded payloads, same-daemon request deduplication, and one bounded transport reconciliation attempt. Its session observations are intentionally memory-only. Phase 4 replaces that transitional lifecycle with persisted root authority and deterministic recovery after app, helper, or Xray interruption.

## 2. Scope

### In scope

- An actor-based `VPNSessionController` as the sole owner of privileged VPN lifecycle transitions.
- A versioned, atomic `RootStateStore` for authoritative session state.
- A `RootXraySupervisor` that owns process launch, identity validation, readiness, termination observation, and bounded diagnostics.
- Typed IPv4 `RoutePlan`, `RouteManager`, and crash-safe write-ahead `RouteJournal` components.
- Non-blocking helper lifecycle admission so status and stop remain available while start is in progress.
- Persisted session ownership by active console UID.
- Helper-startup reconciliation before accepting new lifecycle mutations.
- Adoption of a valid persisted running session after helper restart.
- Deterministic cleanup of incomplete, failed, or contradictory sessions.
- Authoritative app/provider restoration through bounded status polling.
- Removal of generated lifecycle shell scripts after behavioral parity is verified.
- An exact helper protocol revision increase for the new status and failure semantics.

### Out of scope

- `SMAppService` registration or replacement of the administrator installer; that remains Phase 5.
- IPv6 routing.
- Network Extension migration.
- Auto-connect or reconnect policy.
- Startup performance work unrelated to non-blocking lifecycle admission.
- Geodata trust redesign.
- Developer ID/notarization pipeline implementation.
- Routing-socket migration; the first `RouteManager` may invoke `/sbin/route` through a testable command executor.
- Backward compatibility with Phase 3 helper protocol or root-state formats.

## 3. Architectural boundaries

Phase 4 remains inside the existing app and privileged-helper Xcode targets. It does not add a Swift package, framework, or executable target.

```text
HelperCommandDispatcher
        ↓
VPNSessionController actor
 ├── RootStateStore
 ├── RootXraySupervisor
 └── RouteManager
       └── RouteJournal
```

### 3.1 `VPNSessionController`

The controller is the sole owner of lifecycle state and command admission. It serializes state transitions but does not hold actor isolation while waiting for process readiness, shell commands, or termination. It starts child tasks and accepts their results only when both the session ID and controller generation still match.

### 3.2 `RootStateStore`

The state store atomically persists one versioned authoritative snapshot containing:

- schema revision;
- session ID;
- owner UID;
- lifecycle phase;
- controller generation;
- process identity evidence when available;
- expected tunnel interface when available;
- timestamps;
- bounded failure and cleanup status.

### 3.3 `RootXraySupervisor`

The supervisor:

- launches exactly one Xray process for a session;
- captures bounded diagnostics;
- obtains and persists process identity evidence;
- waits for the exact tunnel interface associated with that session;
- observes unexpected termination;
- validates ownership immediately before signalling;
- terminates with SIGTERM, bounded wait, then SIGKILL when necessary.

The supervisor emits events to the controller. It does not mutate routes or own lifecycle state.

### 3.4 `RouteManager`

The route manager computes, applies, verifies, inspects, and removes typed IPv4 route tuples. It owns no session state. Every external command runs through an injected executor so planning, parsing, error handling, and rollback are deterministic in tests.

### 3.5 `RouteJournal`

The journal persistently associates exact route mutations with one session ID. It records write-ahead intent before every mutation and records the observed result afterward. Rollback processes entries in reverse order and never performs unconditional destination-only deletion.

### 3.6 Dispatcher and request ledger

`HelperCommandDispatcher` authenticates and decodes requests, delegates lifecycle semantics to `VPNSessionController`, and encodes authoritative responses. It is not a lifecycle owner.

The bounded in-memory request ledger remains a transport-level same-daemon duplicate-reply optimization. Persisted controller state, rather than ledger survival, provides start/stop idempotency across helper restarts.

## 4. Authoritative lifecycle model

The persisted phases are:

```text
idle
→ starting(sessionID)
→ running(sessionID)
→ stopping(sessionID)
→ idle

starting | running | stopping → failedCleanup(sessionID)
```

`idle` has no session owner, process identity, interface, or live route journal. The absence of both state and journal files means `idle` only after startup reconciliation has verified that absence. Every non-idle state is associated with exactly one session ID and owner UID.

### 4.1 Admission rules

- Repeating start with the active session ID returns its current authoritative status without launching another process.
- Starting a different session while any non-idle state exists returns `sessionConflict`.
- Starting while `failedCleanup` exists is rejected until matching cleanup succeeds.
- Stop affects only the matching session ID.
- Repeating stop for a stopping or failed-cleanup session continues or reports the current cleanup operation idempotently.
- A different session ID cannot stop an active session.
- A lifecycle command from an active console UID other than the persisted owner returns `ownedByAnotherUser`.
- Read-only status remains available during start, stop, and startup reconciliation, subject to safe redaction for non-owners.

## 5. Start flow

1. Authenticate the caller and validate protocol/request bounds.
2. Check active console UID, session conflict, reconciliation state, and failed-cleanup gate.
3. Atomically persist `starting` before privileged side effects.
4. Start a background lifecycle task and return authoritative `starting` immediately.
5. Launch Xray through `RootXraySupervisor` and persist its process identity evidence.
6. Wait for and verify the expected tunnel interface.
7. Compute the typed IPv4 route plan.
8. For each planned route:
   1. persist a pending write-ahead intent;
   2. apply the exact tuple;
   3. inspect and verify the exact tuple;
   4. mark the journal entry applied.
9. Atomically persist `running` only after the process, interface, and all routes are verified.
10. Publish the result only if session ID and controller generation still match.

Any start failure triggers matching-process termination followed by reverse journal rollback. If rollback fully succeeds, the terminal result is a typed start failure and authoritative state becomes `idle`. If any owned resource cannot be safely removed, state becomes `failedCleanup` and blocks another start.

## 6. Stop and cleanup retry flow

1. Authenticate the caller and require the persisted owner UID and matching session ID.
2. Persist `stopping` unless cleanup is already active.
3. Start or join one background cleanup operation and return authoritative `stopping` immediately.
4. Validate process identity immediately before signalling and terminate only the matching Xray process.
5. Roll back route journal entries in reverse order.
6. Before deletion, inspect the current route and require an exact family, destination/prefix, gateway/interface, scope, and session-attributable match.
7. Verify every deletion.
8. Remove the journal and session snapshot only after complete process and route cleanup.
9. Transition to `idle` after complete cleanup.

If a journalled destination now points to a different gateway or interface, the helper does not delete it. It preserves a bounded residue record, transitions to `failedCleanup`, and rejects new starts. A repeated matching `stopSession(sessionID)` retries cleanup idempotently. No separate retry command is added, and status remains read-only.

## 7. Crash-safe persistence

The helper uses a root-owned state directory such as `/var/db/dev.x.teleport/` containing:

- `session-state.json`;
- `route-journal.json`;
- separately bounded diagnostics that are not authoritative lifecycle state.

Final paths and constants are selected during implementation without exposing them above the VPN/helper boundary.

### 7.1 File safety

- Parent directories and files are root-owned with restrictive modes.
- Reads reject symlinks, non-regular files, unexpected ownership or mode, and oversized content.
- JSON structures have exact schema revisions and explicit bounds.
- Writes use a same-directory temporary file, complete write validation, `fsync`, atomic rename, and parent-directory synchronization where required for crash durability.
- Sensitive Xray configuration is never persisted in the state snapshot or route journal.

### 7.2 Journal crash windows

A route intent is durable before executing the mutation. On reconciliation:

- pending intent + exact tuple exists: treat it as applied and include it in rollback/adoption validation;
- pending intent + tuple absent: remove the uncommitted intent;
- destination exists with different gateway/interface/scope: preserve residue and fail closed;
- applied entry + exact tuple absent during running adoption: the running state is invalid and enters cleanup;
- applied entry + exact tuple exists: ownership evidence remains valid.

The journal is removed only after verified complete rollback.

### 7.3 Corrupt or incompatible state

Corrupt, truncated, oversized, unsafe, or unknown-revision root state is never interpreted as `idle`. The helper reports `stateCorrupt`, blocks new start operations, and exposes bounded diagnostics. Because backward compatibility is not required, development migration uses the explicit privileged reset procedure rather than silently converting unknown state.

For a corrupt snapshot, the helper may roll back routes only from an independently safe, schema-valid journal whose exact tuples match the routing table. It cannot adopt or signal a process without independently valid process identity evidence. If complete ownership cannot be proven, it remains blocked in `stateCorrupt`/`failedCleanup` and requires the separately authorized administrative reset path. It never deletes a process or route based only on untrusted corrupt bytes.

## 8. Process identity

PID is evidence, not ownership. Persisted process identity includes enough stable information to detect PID reuse and executable replacement, using public macOS process inspection facilities available to the root helper. At minimum it binds:

- PID;
- process start identity;
- resolved executable path;
- executable file identity captured at launch;
- session ID in helper-owned state.

Adoption and termination re-read and compare this evidence immediately before action. A mismatch produces `processIdentityMismatch`; the helper does not signal the unrelated process. The session then proceeds through safe route cleanup and, if ownership cannot be fully resolved, `failedCleanup`.

## 9. Helper startup reconciliation

The helper completes initial reconciliation before accepting new lifecycle mutations. During this window, status reports `reconciling` and mutations return `reconciliationInProgress`.

### 9.1 Persisted running session

A running session is adopted only when all of the following are valid:

- state and journal schemas and file safety checks pass;
- owner UID is present;
- process identity matches;
- the expected tunnel interface exists;
- every applied journal tuple exists exactly;
- no pending or contradictory lifecycle operation remains.

The supervisor attaches termination observation to the adopted process, and the controller resumes `running` authority.

### 9.2 Transitional or contradictory state

Persisted `starting`, `stopping`, missing process, process mismatch, missing interface, incomplete routes, or contradictory evidence does not resume forward execution. The helper terminates only a validated matching process, rolls back exact journalled routes, and reaches `idle` when cleanup succeeds or `failedCleanup` when it does not.

### 9.3 Reboot behavior

If the persisted process no longer exists after reboot, reconciliation treats it as absent evidence rather than success. Route cleanup still follows exact journal inspection; routes already removed by the operating system are marked clean, while mismatches fail closed.

## 10. Unexpected Xray termination

`RootXraySupervisor` reports termination with session ID, generation, and bounded exit evidence. The controller ignores stale events. A matching unexpected exit while starting or running triggers reverse route rollback and persists a typed `xrayExited` result. Complete cleanup reaches `idle` with a retained bounded terminal diagnostic; incomplete cleanup reaches `failedCleanup`.

## 11. Active-user ownership

Every non-idle session persists `ownerUID` from the authenticated active console user that admitted start.

- Only the same active console UID can issue lifecycle commands for that session.
- A different active user receives `ownedByAnotherUser` without configuration, PID, interface, or route details.
- Fast User Switching does not automatically stop or transfer the system-wide VPN.
- Helper-owned crash and restart reconciliation continues regardless of whether the original user is currently active.
- Product removal and development reset remain separately authorized administrative operations.

## 12. App and provider integration

The XPC surface remains bounded request/response. Phase 4 does not add callback or observer interfaces.

### 12.1 Polling

- `startSession` and `stopSession` are short admission calls that return `starting` or `stopping`.
- The app-side VPN provider polls authoritative status at a bounded interval with an overall operation deadline.
- Polling uses fresh status request IDs and never retransmits the lifecycle mutation.
- Transport interruption continues to use Phase 3 connection replacement and bounded status reconciliation.

### 12.2 Cancellation and deadline

Cancelling connect is not abandonment. The provider sends matching stop and waits for authoritative terminal cleanup. If the connect wait deadline expires while the helper remains `starting`, the provider performs a final status query and initiates matching stop rather than reporting a definitive start failure while privileged work continues.

A stop wait deadline that expires with authoritative `stopping` or `failedCleanup` is surfaced as a typed non-terminal cleanup failure; it is never presented as confirmed idle.

### 12.3 App restart restoration

When the helper reports a valid running session owned by the current UID, the provider accepts the helper session ID even if app-side cache is absent or different. It replaces the local cache and restores connected presentation. App cache is only a correlation and startup hint and always yields to authoritative helper state.

The app does not read root state, PID files, interface files, or route journals directly.

## 13. Shared protocol changes

The exact helper protocol revision increases because status phases and failure semantics change incompatibly.

Authoritative status supports at least:

- `idle`;
- `reconciling`;
- `starting`;
- `running`;
- `stopping`;
- `failedCleanup`.

Stable failures include:

- `sessionConflict`;
- `ownedByAnotherUser`;
- `reconciliationInProgress`;
- `stateCorrupt`;
- `processIdentityMismatch`;
- `xrayExited`;
- `interfaceReadiness`;
- `routeApply`;
- `routeVerification`;
- `routeRollback`;
- `failedCleanup`.

Responses retain bounded request/session correlation. User-safe responses never expose raw configuration, PID, full route journal, root paths, or unrestricted logs.

## 14. Removal of generated lifecycle shell scripts

Current generated root lifecycle scripts combine process launch, readiness, route application, and rollback. Phase 4 replaces them with focused Swift components:

- `RootXraySupervisor` uses controlled process APIs;
- `RouteManager` invokes individual `/sbin/route` operations through an injected executor;
- the controller owns ordering and rollback;
- the journal owns durable mutation records.

Generated lifecycle shell code is deleted only after parity tests cover current IPv4 plan generation, process termination order, readiness behavior, route add/delete order, retries, and cleanup branches. General-purpose shell execution does not become a new public or upper-layer abstraction.

## 15. Verification strategy

### 15.1 State-machine tests

- every valid transition and every rejected transition;
- same-session start/stop idempotency;
- different-session conflicts;
- owner UID enforcement;
- failed-cleanup start gate and repeated-stop recovery;
- stale session/generation task completion rejection;
- concurrent status during blocked start and stop.

### 15.2 Persistence and reconciliation tests

- atomic snapshot/journal round trips;
- bounds, ownership, mode, symlink, regular-file, truncation, corruption, and schema rejection;
- crash simulation before and after every journal persistence/mutation step;
- valid running-session adoption;
- starting/stopping reconciliation to cleanup;
- missing process/interface/route evidence;
- helper restart and reboot-like process absence;
- unknown state never interpreted as idle.

### 15.3 Process tests

- exactly one launch per session;
- process identity capture and revalidation;
- PID reuse and executable replacement rejection;
- SIGTERM, bounded wait, and SIGKILL ordering;
- unexpected termination cleanup;
- stale termination events ignored;
- bounded diagnostics and secret redaction.

### 15.4 Route tests

- typed parity with existing IPv4 routes;
- deterministic plan order and reverse rollback;
- intent-before-mutation durability;
- exact tuple verification before deletion;
- changed gateway/interface/scope preserved as residue;
- partial add and partial rollback;
- idempotent absence handling;
- failed cleanup blocks a new start.

### 15.5 App/provider tests

- start/stop admission followed by bounded polling;
- no mutation retransmission;
- connect cancellation sends stop and waits for terminal state;
- deadline while starting initiates cleanup;
- running helper session replaces absent or mismatched app cache;
- non-owner and failed-cleanup presentation;
- XPC interruption during polling.

### 15.6 Composition checks

- app and helper compile one exact shared protocol revision;
- app/provider source contains no PID, root-state, route-journal, or helper-file reads;
- lifecycle shell generation is absent after cutover;
- Phase 3 authenticated XPC and bounds remain intact;
- no `SMAppService`, IPv6, Network Extension, auto-connect, or unrelated feature work enters the diff;
- `git diff --check`, all focused verification recipes, `just clean && just verify`, standalone helper build, and strict signature checks pass.

### 15.7 Manual macOS checkpoint

Manual acceptance must cover:

- real Xray/TUN startup and route application;
- connect/disconnect and exact route cleanup;
- helper termination during starting, running, and stopping;
- valid running-session adoption after helper restart;
- app crash/relaunch and authoritative UI restoration;
- Xray unexpected exit;
- route residue and repeated-stop recovery;
- Fast User Switching ownership policy;
- reboot reconciliation;
- app termination while privileged lifecycle work is pending.

Unperformed manual checks remain explicit release risks and are never reported as validated.

## 16. Completion criteria

Phase 4 is complete when:

- `VPNSessionController` is the sole authoritative lifecycle owner;
- valid running sessions survive helper restart through verified adoption;
- incomplete or contradictory sessions deterministically clean up or become blocking `failedCleanup`;
- process signalling requires stable identity validation rather than PID alone;
- all route mutations are exact, journalled, session-owned, verified, and reversibly ordered;
- status and stop remain available while startup is in progress;
- app/provider state is restored from helper authority and does not read helper files directly;
- generated lifecycle shell scripts are removed after parity verification;
- exact protocol revision and typed errors express the new semantics;
- fresh automated verification passes;
- manual system-test gaps are documented;
- Phase 5 installation work and all other deferred features remain out of scope.
