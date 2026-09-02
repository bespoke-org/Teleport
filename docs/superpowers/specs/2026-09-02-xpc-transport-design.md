# Phase 3: Privileged Helper XPC Transport Design

**Date:** 2026-09-02
**Status:** Approved for implementation planning

## 1. Purpose

Replace Teleport's JSON-over-UNIX-socket privileged-helper transport with a launchd Mach service and `NSXPCConnection`, while preserving the current System Proxy and root-Xray VPN behavior.

Phase 3 introduces a shared typed wire protocol, exact protocol revision, request/session correlation, bounded payloads, public-API client authentication, and transport-level reconciliation. It does not redesign root process/routing ownership or helper installation.

## 2. Scope

### In scope

- A shared Objective-C-compatible XPC interface compiled into the app and helper targets.
- Shared Swift `Codable` request and response values.
- Exact protocol revision with no compatibility fallback.
- Request UUIDs and VPN session UUIDs.
- A launchd Mach service declared by the existing generated LaunchDaemon plist.
- App-side `NSXPCConnection` lifecycle, command deadlines, interruption handling, invalidation handling, and one bounded reconciliation attempt.
- Helper-side XPC listener, authentication, payload validation, command dispatch, and bounded in-memory request-result deduplication.
- Removal of the UNIX socket client/server and socket constants after XPC verification passes.
- A clean reset of the installed helper and root state during development migration.

### Out of scope

- `SMAppService`; the existing administrator installer remains until Phase 5.
- A Network Extension provider.
- A full `VPNSessionController` actor or non-blocking root startup; those belong to Phase 4.
- Authoritative persisted helper session state across daemon restart.
- Route journaling/session-owned rollback.
- IPv6 routing, startup optimization, or auto-connect.
- Backward compatibility with the socket helper or older protocol revisions.

## 3. Source boundaries

No Swift package, framework, or additional executable target is added.

### Shared source

Create shared files compiled into both existing targets:

- `Shared/VPNHelperXPCProtocol.swift`
- `Shared/VPNHelperMessages.swift`
- `Shared/VPNHelperProtocolError.swift`

The shared source contains only Foundation-compatible transport declarations and value types. It must not import AppKit, ServiceManagement, process-management, route-management, or app presentation code.

### App target

Replace the socket implementation in `teleport/VPN/PrivilegedHelperClient.swift` with an XPC-backed client. The existing higher-level methods (`status`, `start`, `stop`, and `readLog`) remain the boundary consumed by `PrivilegedXrayRuntimeManager` during this phase so provider and UI layers do not change.

An internal connection owner is responsible for constructing, activating, invalidating, and replacing `NSXPCConnection` instances. XPC names, revisions, deadlines, and payload encoding do not escape the VPN transport layer.

### Helper target

Replace `HelperServer` with:

- an `NSXPCListener` bootstrap for the launchd Mach service;
- a listener delegate that authenticates connections and installs the exported interface/object;
- an endpoint that decodes bounded requests and dispatches to the existing `XrayTunController`.

`XrayTunController`, `ManagedXrayProcess`, and `XrayTunScriptBuilder` remain behavior-preserving Phase 3 dependencies.

## 4. XPC interface

The Objective-C-compatible interface carries only `Data` and `NSError`:

```swift
@objc protocol VPNHelperXPCProtocol {
    func getStatus(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func startSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func stopSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func readDiagnostics(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}
```

Separate methods keep the exported surface explicit and allow per-command payload types and deadlines. Generic string command dispatch is removed.

The XPC interface configures allowed classes explicitly for request and reply arguments. No arbitrary object graph crosses the connection.

## 5. Shared message model

Every request includes:

```text
revision: UInt
requestID: UUID
sessionID: UUID?  // required for start/stop, absent for status/diagnostics
payload: command-specific Codable value
```

Every successful response includes:

```text
revision: UInt
requestID: UUID
sessionID: UUID?
result: command-specific Codable value
```

Every protocol failure is represented by a stable structured error:

```text
code
summary
details?
retryDisposition
```

The protocol uses an exact numeric revision. A mismatch returns `incompatibleService`; neither side attempts schema negotiation or socket fallback.

### Command payloads

- `StatusRequest` contains only envelope metadata.
- `StartSessionRequest` contains configuration bytes, protected host, requested tunnel interface, outbound interface, and helper-owned path selectors required by the current controller.
- `StopSessionRequest` contains the matching session ID and current cleanup inputs required by the transitional controller.
- `ReadDiagnosticsRequest` contains a typed log selector and bounded byte count.

Raw filesystem paths are retained only where the current controller requires them and are validated against existing allowlisted roots. They remain transitional and must not reach `AppViewModel`.

### Response payloads

- `StatusResponse` reports helper revision plus the best available transitional session observation: idle, starting, running, stopping, failed, or unknown.
- `StartSessionResponse` echoes request/session IDs and the accepted/resulting status. PID evidence remains helper-internal and is not the session identity.
- `StopSessionResponse` echoes request/session IDs and terminal cleanup status.
- `DiagnosticsResponse` separates metadata from bounded text.

## 6. Bounds and decoding

Bounds are checked before decoding and again after decoding:

- maximum encoded request: 1 MiB;
- maximum configuration payload: 512 KiB;
- maximum encoded response: 1 MiB;
- maximum diagnostics text: 256 KiB;
- maximum request-ledger entries: 128;
- maximum ledger age: 10 minutes.

Oversized data, invalid UUID/revision combinations, absent required session IDs, unknown enum values, invalid paths, and unsupported log selectors fail before command execution.

The helper never includes secrets or unbounded root log content in an error response.

## 7. Authentication and trust boundary

Mach-service lookup grants transport reachability, not authorization.

The listener delegate applies these checks before accepting messages:

1. Require the connection's effective UID to match the active console user policy.
2. Set the production designated code-signing requirement on the incoming `NSXPCConnection` using the public macOS `setCodeSigningRequirement(_:)` API before activation.
3. Configure exported/remote interfaces and the exported object only for an accepted connection.
4. Fail closed for login-window, missing-console-user, malformed-requirement, or mismatched-signature cases.

Foundation does not expose the full incoming XPC audit token as public Swift API. `setCodeSigningRequirement(_:)` is therefore the supported enforcement mechanism; launchd/XPC evaluates the sender identity from message audit credentials. Direct PID-only signature lookup is not used as the primary authorization decision because it is vulnerable to process-lifetime races.

Fast User Switching and login-window behavior require explicit system tests. Release validation must use the production Developer ID requirement rather than assuming an Apple Development identity.

## 8. Helper execution and request identity

The current controller remains synchronous and lifecycle commands remain serialized in Phase 3. XPC eliminates socket framing and accepted-client read blocking, but does not yet make `start`, `status`, and `stop` independently concurrent.

Before command execution, the helper records the request ID in a bounded in-memory ledger:

- a duplicate completed request returns the recorded result;
- a duplicate in-progress request returns `inProgress`;
- reuse of a request ID with different payload bytes returns `requestConflict`;
- eviction follows age and count bounds.

This ledger prevents accidental duplicate execution after a lost reply during one helper process lifetime. It is not authoritative persisted session state and is intentionally replaced by the Phase 4 root state store.

A start session ID is generated in the app provider path before privileged work begins and is echoed by every relevant response. During Phase 3 it is correlation identity. Stop validates the requested ID against the best available transitional state but full session-owned process/routes authority remains Phase 4.

## 9. App-side transport lifecycle

The XPC client creates a fresh connection owner when none is active or after invalidation. It configures the remote interface and handlers before calling `activate()`.

### Interruption

An interruption invalidates the current proxy reference but does not prove command failure. The client obtains a replacement connection and performs one status query using the original request/session IDs.

### Invalidation

Invalidation marks that connection unusable. The next request creates a new connection. An outstanding mutating request follows the same reconciliation path as an interrupted request.

### Deadlines

Deadlines are command-specific and implemented in the app without cancelling helper execution:

- status: 3 seconds;
- diagnostics: 5 seconds;
- start: 20 seconds for the transitional synchronous controller;
- stop: 15 seconds.

When a mutating command deadline expires, the client performs one bounded status reconciliation. It never reports that start/stop failed solely because the reply was lost.

### Reconciliation outcomes

- matching terminal success: return success;
- matching in-progress observation: return a typed indeterminate/in-progress failure for the provider to surface without issuing a duplicate command;
- matching failed observation: return the helper's structured failure;
- incompatible revision: return `incompatibleService`; the existing installation preflight treats that helper as stale, reinstalls the bundled revision, and the higher-level startup flow retries once;
- unavailable or unknown after the one reconciliation attempt: return an indeterminate transport error carrying request/session IDs.

Phase 3 does not claim safe recovery after helper restart because the ledger/session observation is not yet persisted authoritatively.

## 10. LaunchDaemon and installer cutover

The generated LaunchDaemon plist keeps its existing label, program path, root execution, logging, and current installation mechanism. It adds:

```xml
<key>MachServices</key>
<dict>
    <key>dev.x.teleport.helper</key>
    <true/>
</dict>
```

The helper no longer creates, owns, chmods, accepts, or unlinks a filesystem socket. The installer no longer removes the socket during installation.

Because compatibility is not required, development cutover performs an explicit full reset before installing the XPC helper:

- boot out the legacy daemon;
- remove the legacy socket;
- remove installed helper, Xray, assets, plist, and obsolete root state;
- install the current artifacts and Mach-service plist;
- bootstrap the daemon once.

The product must never run socket and Mach-service helper models concurrently.

## 11. Error propagation

Transport and protocol errors remain distinct from helper command failures:

- unavailable service;
- connection interrupted;
- connection invalidated;
- deadline exceeded with indeterminate result;
- incompatible service revision;
- authentication rejected;
- malformed/oversized payload;
- request conflict;
- helper command failure.

`PrivilegedHelperClientError` maps these failures into stable `LocalizedError` summaries/details consumed by the existing provider state. Upper layers receive no XPC objects, `NSError` domains, process IDs, route details, or service names.

Termination continues to wait for provider disconnect. If XPC disconnect becomes indeterminate, the provider publishes failure and AppKit termination completes according to the existing bounded cleanup policy; Phase 4 authoritative reconciliation will strengthen this guarantee.

## 12. Verification strategy

### Shared protocol tests

- exact revision acceptance and mismatch rejection;
- round-trip encoding for every request/response/error type;
- missing/invalid session IDs;
- payload and diagnostics bounds;
- malformed data and unknown values;
- request-ID/payload conflict detection.

### Helper endpoint tests

- authentication rejection configuration;
- each XPC method dispatches only its matching typed payload;
- malformed or oversized data never reaches `XrayTunController`;
- duplicate request behavior for in-progress/completed/conflicting requests;
- lifecycle serialization remains behavior-preserving.

### Client tests

Use an injected transport seam to verify:

- normal replies;
- interruption and invalidation replacement;
- per-command deadlines;
- lost start/stop reply followed by reconciliation;
- incompatible revision propagation to the installation preflight and its one-retry limit;
- indeterminate outcome propagation;
- exactly-once reply continuation completion.

### Build and composition checks

- both targets compile the same shared protocol files;
- helper and app link Foundation XPC APIs without a new target;
- LaunchDaemon plist contains exactly one Mach service;
- app bundle still embeds the helper at the expected path;
- UNIX socket constants, client code, server code, and architecture references are absent after cutover;
- helper standalone build and strict code-signature verification pass;
- `just clean && just verify` passes.

### Manual system tests

- first install and upgrade after explicit legacy reset;
- valid signed app connection;
- wrong-team/unsigned client rejection;
- Fast User Switching and login-window behavior;
- helper interruption during status/start/stop;
- app termination during a pending command;
- System Proxy behavior remains unchanged;
- VPN connect/disconnect still configures and cleans the current IPv4 routes.

## 13. Completion criteria

Phase 3 is complete when:

- app/helper share one exact-revision typed protocol;
- all privileged commands use authenticated XPC over the launchd Mach service;
- mutating-command timeout/interruption triggers bounded reconciliation rather than being treated as definitive failure;
- duplicate request execution is prevented within one helper process lifetime;
- provider and UI layers contain no XPC details;
- the legacy UNIX socket implementation and constants are removed;
- no `SMAppService`, authoritative Phase 4 lifecycle, route journal, IPv6, startup optimization, or auto-connect work is mixed into the change;
- fresh automated verification passes and manual trust-boundary tests remain explicitly documented where automation is unavailable.
