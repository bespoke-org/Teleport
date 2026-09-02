# Xray and macOS Runtime Architecture

**Date:** 2026-09-02
**Status:** Approved direction; ready for implementation planning
**Canonical base:** `nrydanov/split-tunneling`

## 1. Context

Teleport currently groups several different responsibilities under `teleport/Xray` and a single large privileged-helper source file:

1. Xray JSON generation.
2. User-owned Xray process management for System Proxy mode.
3. App-side VPN orchestration and privileged IPC.
4. Privileged-helper installation and service registration.
5. Root Xray process supervision and macOS route mutation.
6. Geodata download, selection, validation, and privileged installation.

The problem is not that one product feature has several internal components. The problem is that the components have no enforced or even consistently expressed boundaries:

- `AppViewModel` manages low-level lifecycle flags.
- `PrivilegedXrayRuntimeManager` mixes installation, IPC, app-side session persistence, process checks, and diagnostics.
- `PrivilegedHelperInstaller` mixes artifact verification, geodata resolution, privilege elevation, file deployment, plist generation, and `launchctl` lifecycle.
- `TeleportPrivilegedHelper/main.swift` mixes IPC transport, peer authentication, request decoding, input validation, root state, Xray process supervision, route planning, shell generation, logging, and executable entry point.
- App and helper duplicate wire types instead of compiling one shared protocol.
- Feature branches repeatedly modify the same large files, creating unnecessary merge conflicts and mixed-scope branches.

## 2. Decisions

The following decisions are approved:

- Use `nrydanov/split-tunneling` as the canonical implementation base.
- Make the first implementation phase strictly behavior-preserving.
- Initially express boundaries with directories and small types inside the existing app and helper Xcode targets. Do not create framework targets or a Swift Package in phase one.
- Backward compatibility is not required. IPC formats, state formats, paths, settings, and helper versions may be reset.
- Preserve the current root-Xray VPN model for now.
- Replace manual AppleScript/`launchctl` helper installation with `SMAppService` LaunchDaemon registration.
- Replace the UNIX-domain socket with a launchd Mach service and `NSXPCConnection`.
- Register the privileged service lazily on the first VPN connect.
- Make upper application layers depend on an asynchronous `ConnectionProvider` abstraction so a future `NetworkExtensionProvider` can replace root Xray without changing `AppViewModel`.
- Support bundled geodata plus curated HTTPS providers backed by a signed manifest and trusted hashes.
- Include Developer ID signing, notarization, stapling, and final artifact verification in the architecture cycle.
- A future Network Extension implementation is explicitly deferred.

## 3. Goals

1. Give each component one clear responsibility.
2. Keep Xray as an external networking engine rather than the owner of all macOS infrastructure.
3. Remove helper, PID, route, socket, and Xray details from upper application layers.
4. Make the helper the authoritative owner of VPN session state.
5. Make connect, disconnect, timeout, cancellation, crash, and restart behavior deterministic.
6. Make route mutation transactional and session-owned.
7. Remove manual root shell installation and the world-reachable UNIX socket.
8. Establish a production-ready signing and notarization pipeline.
9. Permit later replacement of `RootXrayVPNProvider` with `NetworkExtensionProvider`.
10. Port work from sibling branches one feature at a time after structural boundaries exist.

## 4. Non-goals

- Implementing Network Extension in this project.
- Preserving compatibility with previous app snapshots, helper protocol revisions, or root-state formats.
- Supporting arbitrary geodata URLs.
- Implementing MDM-only per-app VPN.
- Creating multiple embedded framework targets during the first phase.
- Rewriting Xray itself.

## 5. Target component structure

```text
teleport/
├── Connection/
│   ├── ConnectionProvider.swift
│   ├── ConnectionRequest.swift
│   ├── ConnectionState.swift
│   └── ConnectionProviderFactory.swift
│
├── XrayCore/
│   ├── XrayConfigBuilder.swift
│   └── XrayConfigModels.swift
│
├── SystemProxy/
│   ├── SystemProxyProvider.swift
│   ├── UserXrayProcess.swift
│   └── SystemProxySettings.swift
│
├── VPN/
│   ├── RootXrayVPNProvider.swift
│   ├── VPNServiceClient.swift
│   ├── VPNServiceRegistrar.swift
│   └── NetworkEnvironmentInspector.swift
│
├── HelperInstallation/
│   └── BundledArtifactVerifier.swift
│
└── Geodata/
    ├── GeodataRepository.swift
    ├── GeodataManifest.swift
    └── GeodataVerifier.swift

Shared/
└── HelperProtocol/
    ├── VPNHelperXPCProtocol.swift
    ├── HelperRequests.swift
    ├── HelperResponses.swift
    ├── VPNSessionStatus.swift
    └── HelperConstants.swift

TeleportPrivilegedHelper/
├── IPC/
│   ├── HelperServer.swift
│   └── ClientAuthenticator.swift
├── Session/
│   ├── VPNSessionController.swift
│   └── RootStateStore.swift
├── Xray/
│   └── RootXraySupervisor.swift
├── Routing/
│   ├── RouteManager.swift
│   ├── RoutePlan.swift
│   └── RouteJournal.swift
└── main.swift
```

Phase one may retain existing type names while moving and splitting code. Renames and protocol changes occur only after the behavior-preserving extraction is verified.

## 6. Dependency rules

```text
AppViewModel
    └── ConnectionProvider + ConnectionState only

SystemProxyProvider
    ├── XrayConfigBuilder
    ├── UserXrayProcess
    └── SystemProxySettings

RootXrayVPNProvider
    ├── VPNServiceRegistrar
    ├── VPNServiceClient
    ├── NetworkEnvironmentInspector
    └── GeodataRepository

VPNServiceClient
    └── Shared/HelperProtocol

PrivilegedHelper
    ├── Shared/HelperProtocol
    ├── VPNSessionController
    ├── RootXraySupervisor
    ├── RouteManager
    └── RootStateStore
```

Hard rules:

- `AppViewModel` must not know PID values, XPC service names, helper revisions, `utun` names, route details, Xray paths, or Xray JSON.
- The app must not directly read helper-owned files under `/var/db`.
- The helper target must not import UI or app orchestration code.
- Route mutation exists only in the helper target.
- `XrayCore` must not import AppKit, ServiceManagement, XPC transport, process-management, or route-management code.
- Shared protocol files compile into both app and helper targets; wire structures are not duplicated.
- Service registration is separate from normal session disconnect.
- Geodata crosses the privilege boundary only as a verified artifact described by a trusted manifest.

## 7. Upper connection API

```swift
protocol ConnectionProvider: Sendable {
    func currentState() async -> ConnectionState
    func stateUpdates() -> AsyncStream<ConnectionState>

    func connect(_ request: ConnectionRequest) async throws
    func disconnect() async throws
}
```

```swift
enum ConnectionState: Sendable, Equatable {
    case idle
    case preparing
    case awaitingUserApproval
    case connecting
    case connected(ConnectionSession)
    case disconnecting
    case failed(ConnectionFailure)
}
```

```swift
struct ConnectionSession: Sendable, Equatable {
    let id: UUID
    let mode: ConnectionMode
    let connectedAt: Date
}
```

```swift
struct ConnectionRequest: Sendable {
    let configuration: ConnectionConfiguration
    let localProxy: LocalProxySettings
    let splitTunnelPolicy: SplitTunnelPolicy
}
```

`ConnectionSession` is user-facing state and deliberately excludes helper implementation details.

`AppViewModel` remains a `@MainActor` UI model. It starts one task that consumes provider state updates and derives UI presentation from one state value rather than independently mutating connection and proxy phase flags.

## 8. Provider lifecycle

### 8.1 System Proxy

```text
idle
→ preparing
→ connecting
→ connected
→ disconnecting
→ idle
```

`SystemProxyProvider` owns rollback between `UserXrayProcess` and `SystemProxySettings`. An unexpected Xray termination causes the provider to restore system proxy settings and publish a failed state.

### 8.2 Root Xray VPN, first connect

```text
idle
→ preparing
→ VPNServiceRegistrar.ensureAvailable()
→ awaitingUserApproval, when required
→ connecting
→ connected
```

### 8.3 Root Xray VPN, subsequent connect

```text
idle
→ preparing
→ query authoritative helper status
→ reconcile any existing session
→ connecting
→ connected
```

### 8.4 Cancellation

Cancelling a connect task is not equivalent to abandoning the request. The provider sends `stopSession(sessionID)`, waits for an authoritative terminal status, and only then publishes idle or failed.

## 9. Session identity and authoritative state

Every VPN connect creates a UUID before any privileged work begins.

```text
idle
→ starting(sessionID)
→ running(sessionID)
→ stopping(sessionID)
→ idle
```

Rules:

- Repeating start with the same session ID is idempotent and returns current status.
- Starting a different ID while a session is active returns an explicit conflict.
- Stop affects only the matching session ID.
- Numeric PID is helper-internal evidence, never session identity.
- The helper validates PID ownership and executable identity before signalling a process.
- The helper persists enough root state to recover or rollback after daemon restart.

## 10. SMAppService registration

The app bundle contains the LaunchDaemon plist and privileged service according to the `SMAppService` daemon layout. The plist declares a Mach service rather than a filesystem socket.

```xml
<key>MachServices</key>
<dict>
    <key>dev.x.teleport.helper</key>
    <true/>
</dict>
```

`VPNServiceRegistrar` wraps:

```swift
SMAppService.daemon(plistName: "dev.x.teleport.PrivilegedHelper.plist")
```

Status handling:

- `.enabled`: connect through XPC.
- `.notRegistered`: call `register()` and wait for service availability.
- `.requiresApproval`: publish `awaitingUserApproval` and direct the user to the appropriate System Settings approval surface.
- `.notFound`: report a packaging failure.
- Unknown future status: fail closed with diagnostics.

The app no longer:

- executes an administrator AppleScript;
- writes `/Library/LaunchDaemons` directly;
- copies the helper to `/Library/PrivilegedHelperTools` itself;
- shells out to `launchctl` for registration;
- creates or chmods a UNIX socket.

A matching unregister path is required for diagnostics/development and product removal.

Because backward compatibility is out of scope, the transition requires a clean
service installation rather than an in-product migration from the manually copied
LaunchDaemon. Development tooling must explicitly stop and remove the legacy daemon,
socket, helper, Xray, assets, plist, and root state before registering the
`SMAppService` version. The two service models must never run concurrently.

## 11. XPC protocol

The helper uses a launchd Mach service and `NSXPCConnection`.

```swift
@objc protocol VPNHelperXPCProtocol {
    func getStatus(withReply reply: @escaping (Data?, NSError?) -> Void)
    func startSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func stopSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func readDiagnostics(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}
```

Objective-C-compatible XPC methods carry bounded `Data` payloads. Shared Swift `Codable` values define the actual domain protocol.

Every request includes:

- exact protocol revision;
- request ID;
- session ID where applicable;
- bounded typed payload.

No backward protocol compatibility is implemented. Revision mismatch returns `incompatibleService`; the provider can unregister/register the current bundled service and retry once.

`VPNServiceClient` handles XPC interruption, invalidation, request timeout, reconnection, and status reconciliation. Timeout never proves that privileged work failed.

## 12. XPC client authentication

Mach service lookup is transport access, not authorization. `ClientAuthenticator` validates every accepted XPC connection using its audit token:

1. Resolve effective UID and process identity.
2. Require the intended active-user policy.
3. Resolve the connecting `SecCode`.
4. Validate the production designated requirement and Team ID.
5. Reject before exposing the exported helper object.

Fast User Switching, login-window ownership, and approval behavior require explicit system tests. Authentication must use production Developer ID identity in release artifacts rather than development-only assumptions.

## 13. Non-blocking helper execution

XPC request handlers do not block until TUN readiness.

```text
startSession
→ authenticate and decode
→ validate
→ record starting(sessionID)
→ create background startup task
→ immediately return starting status
```

`getStatus` and `stopSession` remain available while startup is in progress.

`VPNSessionController` is an actor that serializes session-state transitions. Slow process readiness and command execution happen in child tasks whose completion is applied back through the actor. This prevents concurrent route mutation without blocking status inspection or cancellation.

## 14. Root process and route ownership

### 14.1 RootXraySupervisor

Responsibilities:

- resolve and validate the bundled Xray executable;
- launch exactly one process for a session ID;
- capture bounded logs;
- verify process identity;
- wait for the exact TUN interface created for that session;
- observe unexpected termination;
- terminate gracefully, then forcefully if necessary.

The supervisor emits lifecycle events to `VPNSessionController`; it does not mutate routes.

### 14.2 RoutePlan

A route plan is a typed value computed before mutation. It includes:

- IPv4 capture routes;
- IPv6 capture routes when dual-stack support is enabled;
- proxy-server escape routes for every resolved address used by Xray;
- DNS policy routes, if still required;
- direct split-tunnel escape routes;
- expected interfaces and gateways.

### 14.3 RouteJournal

Every successful route mutation is recorded with its exact tuple:

- address family;
- destination/prefix;
- gateway or interface;
- scope;
- session ID.

Rollback removes only journaled entries in reverse order and reports cleanup failures. It never performs unconditional destination-only deletion of routes it cannot attribute to the session.

The first route-manager implementation may wrap `/sbin/route` behind a testable command executor. Moving to routing sockets can be evaluated later without affecting provider/helper APIs.

### 14.4 Failure and crash behavior

Any startup failure triggers:

```text
terminate matching Xray
→ rollback RouteJournal
→ persist failed status
```

Unexpected Xray termination triggers the same rollback. On helper restart, `RootStateStore`, process identity, interface state, and the route journal are reconciled before accepting new lifecycle commands.

## 15. Geodata trust model

Arbitrary user URLs are removed.

Supported sources:

1. Geodata bundled and signed with the app.
2. Curated HTTPS providers described by a signed manifest.

A manifest contains at least:

- provider ID;
- artifact kind (`geoip` or `geosite`);
- exact version;
- download URL;
- expected byte length and maximum length;
- SHA-256 digest;
- signature and signing-key identifier.

The app download path:

```text
fetch signed manifest
→ validate HTTPS origin and manifest signature
→ stream artifact with a strict size bound
→ hash while streaming
→ validate expected format
→ atomically store verified artifact
```

Before root use, the helper revalidates the artifact after privilege elevation:

- open with symlink-resistant flags;
- require a regular file;
- validate ownership and maximum size;
- hash the already-open descriptor;
- compare against the signed manifest;
- copy atomically into a root-owned session asset directory;
- point Xray only at that immutable verified directory.

UI cancellation cancels the underlying network task rather than merely ignoring its eventual result.

## 16. Release and distribution pipeline

Release packaging is part of the architecture, not a later manual checklist.

Required pipeline:

1. Archive with Developer ID Application identity and Hardened Runtime.
2. Sign app, privileged service, Xray executable, and any other executable code with appropriate entitlements and timestamping.
3. Verify nested code before packaging.
4. Produce a signed DMG.
5. Submit the final distributable to Apple notarization with `notarytool`.
6. Wait for and validate successful notarization.
7. Staple the ticket to the app/DMG as appropriate.
8. Verify with `codesign --verify --deep --strict`, `spctl`, and stapler validation.
9. Validate `SMAppService` registration from the final distributed artifact, not only an Xcode development build.
10. Publish checksums, provenance, third-party notices, and Xray/geodata license information.

Packaging must fail if Xray/geodata/helper layout differs from runtime expectations.

## 17. Error model and diagnostics

Errors cross component boundaries as typed categories rather than concatenated strings:

```text
serviceRegistration
serviceApprovalRequired
serviceUnavailable
protocolMismatch
clientUnauthorized
invalidConfiguration
assetVerification
xrayLaunch
xrayExited
interfaceReadiness
routeApply
routeVerification
routeRollback
sessionConflict
reconciliation
```

Each failure has:

- stable category;
- user-safe summary;
- bounded diagnostic details;
- request/session ID;
- underlying exit code or OSStatus where applicable.

Sensitive Xray configuration is never exposed as an unrestricted “log” command. Diagnostic endpoints use an allowlist and redact credentials.

## 18. Branch integration strategy

Do not merge sibling branches wholesale into the architectural refactor.

### Canonical base

All implementation starts from `nrydanov/split-tunneling`.

### IPv6 branches

`worktree-nrydanov+vpn-ipv6-routing` contains the initial dual-stack implementation. `nrydanov/startup-perf` already contains equivalent IPv6 work. Port the behavior and tests once into `RoutePlan`, `RouteManager`, and `XrayConfigBuilder`.

Before considering IPv6 complete:

- IPv6 route-add failures must not be ignored;
- lower and upper IPv6 capture routes must be verified;
- proxy-server IPv6 escape routes must be verified;
- direct split-tunnel IPv6 behavior must be tested;
- conflicting IPv6 VPN routes must be detected;
- rollback must remove only session-owned IPv6 routes.

### Startup performance branch

Port the readiness fast path after `RootXraySupervisor` exists. Do not directly port the five-second socket timeout because XPC and session reconciliation replace that transport behavior.

### Auto-connect worktree

Port auto-connect after the provider state API and authoritative helper status exist. Startup logic must query provider state before connecting:

```text
connected  → restore UI
idle       → auto-connect when policy allows
connecting → observe existing operation
failed     → expose diagnostics/retry policy
```

## 19. Implementation phases

### Phase 0: Baseline and inventory

- Preserve all existing uncommitted work.
- Record current branch/worktree commit relationships.
- Run the full existing verification suite.
- Establish behavior snapshots for generated configs and helper shell output.

### Phase 1: Behavior-preserving structural extraction

- Split Xray config generation from runtime management.
- Move System Proxy types into one vertical slice.
- Move app-side VPN types into one vertical slice.
- Split privileged-helper `main.swift` into IPC, authentication, controller, process, routing, state, and entry-point files without changing behavior.
- Separate installer, artifact verification, and geodata files.
- Keep current APIs, socket protocol, shell behavior, and tests intact during this phase.
- Build and verify after each extraction.

### Phase 2: Provider API

- Introduce `ConnectionProvider`, `ConnectionState`, and `ConnectionRequest`.
- Adapt System Proxy and current VPN implementations behind providers.
- Convert `AppViewModel` to one provider state stream.
- Remove direct low-level lifecycle state from upper layers.

### Phase 3: Shared protocol and XPC

- Create shared request/response/status types.
- Add Mach service and `NSXPCConnection` transport.
- Add audit-token/code-signature authentication.
- Add session IDs, request IDs, exact protocol revision, and reconciliation.
- Remove UNIX socket transport after XPC tests pass.

### Phase 4: Authoritative helper lifecycle

- Introduce `VPNSessionController` actor.
- Introduce `RootXraySupervisor` with termination observation.
- Introduce `RoutePlan`, `RouteManager`, and `RouteJournal`.
- Remove generated lifecycle shell scripts after behavioral and system tests pass.
- Make root state authoritative and remove direct app reads of helper files.

### Phase 5: SMAppService

- Add an explicit development cleanup command for the legacy manually installed service and state.
- Require a clean legacy-service state before new registration; do not run old and new daemons concurrently.
- Add bundled LaunchDaemon plist and Mach service declaration.
- Add lazy registration and approval UI state.
- Add unregister path.
- Remove AppleScript installer, manual plist generation, file deployment, and manual `launchctl` registration.

### Phase 6: Geodata and distribution trust

- Add curated signed manifests and bounded cancellable downloads.
- Add root-side descriptor-based revalidation.
- Remove arbitrary URL support.
- Implement Developer ID archive, notarization, stapling, and final artifact verification.

### Phase 7: Port sibling feature work

- Port and harden IPv6.
- Port startup readiness optimization.
- Port auto-connect/reconnect policy.
- Run full integration and system verification after each port.

## 20. Testing strategy

### Unit tests

- Xray config generation for both providers.
- Split-tunnel rule generation.
- Provider state transitions.
- Session ID idempotency and conflict rules.
- XPC payload bounds and decoding rejection.
- Protocol revision mismatch.
- Route-plan generation for IPv4 and IPv6.
- Route-journal reverse rollback.
- Geodata manifest signature/hash/size validation.
- Typed error mapping and redaction.

### Integration tests with fakes

Inject protocols for:

- process execution;
- route command execution;
- network environment inspection;
- root state persistence;
- service registration;
- XPC transport;
- geodata downloading.

Test:

- delayed TUN readiness;
- Xray exit during startup and after connected;
- connect cancellation;
- XPC interruption after start acceptance;
- helper restart with starting/running/stopping state;
- partial route application;
- rollback failure reporting;
- conflicting session IDs;
- identical repeated start/stop requests.

### Signed macOS system tests

- First-connect service registration and approval.
- XPC authentication rejection for unsigned/wrong-team clients.
- Connect/disconnect using final signed layout.
- IPv4 and IPv6 capture and leak checks.
- DNS behavior.
- Proxy-server anti-loop behavior for IPv4 and IPv6.
- Sleep/wake during every lifecycle phase.
- App crash, helper crash, and Xray crash.
- Fast User Switching and login window.
- Concurrent connect/disconnect requests.
- Upgrade/re-registration within the new exact-revision model.
- Unregister/removal.
- Gatekeeper launch from the notarized DMG.

## 21. Completion criteria

The architecture cycle is complete when:

- `AppViewModel` depends only on `ConnectionProvider` and domain state.
- System Proxy and root-Xray VPN both implement the provider contract.
- The helper is registered through `SMAppService` and reached through authenticated XPC.
- No app code directly reads root helper state.
- Helper status is authoritative and session-ID based.
- Status and stop remain available while start is pending.
- Unexpected Xray/helper interruption produces deterministic reconciliation and route rollback.
- Route cleanup is journaled and session-owned.
- IPv4 and IPv6 behavior is tested end to end.
- Only bundled or curated signed geodata reaches root Xray.
- The package recipe produces and verifies a notarized Developer ID artifact.
- Sibling branch features have been ported intentionally rather than merged wholesale.
- A future `NetworkExtensionProvider` can satisfy `ConnectionProvider` without changing `AppViewModel`.
