# Privileged Helper XPC Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the privileged helper's UNIX socket with an authenticated launchd Mach service and an exact-revision, bounded, typed XPC protocol without changing provider/UI behavior.

**Architecture:** Shared Foundation-only Codable values define the wire contract while an Objective-C-compatible protocol transports only `Data` and `NSError`. The app keeps the existing synchronous `PrivilegedHelperClient` facade over an injected XPC transport because Phase 2 backends are intentionally transitional synchronous adapters; the helper authenticates incoming XPC connections, serializes typed command execution, and keeps a bounded in-memory request ledger for same-daemon deduplication and reconciliation.

**Tech Stack:** Swift 5, Foundation `NSXPCConnection`/`NSXPCListener`, Security code-signing requirements through public XPC APIs, launchd `MachServices`, Codable, Dispatch, existing Xcode app/helper targets, standalone Swift verification scripts, Just.

**Spec:** `docs/superpowers/specs/2026-09-02-xpc-transport-design.md`

## Global Constraints

- Do not create a Swift package, framework, or additional executable target.
- `TeleportPrivilegedHelper/` remains the separate root executable target and explicit trust boundary.
- Keep the current administrator installer in Phase 3; do not introduce `SMAppService`.
- Do not introduce a Network Extension, IPv6 routing, route journals, startup optimization, or auto-connect.
- Do not implement backward protocol compatibility or socket fallback.
- Use exact protocol revision `8`; an incompatible helper must fail closed and be replaced by the existing installation preflight.
- XPC methods carry only bounded `Data` and `NSError`; arbitrary object graphs do not cross the boundary.
- Request bounds: encoded request 1 MiB, config 512 KiB, encoded response 1 MiB, diagnostics 256 KiB.
- Request ledger bounds: 128 entries and 10-minute maximum age.
- Session UUID is correlation identity in Phase 3, not persisted authoritative root ownership.
- Preserve current synchronous `XrayTunController`, process, proxy, route, retry, and cleanup behavior.
- All new comments and `TODO(gpt-5.6-sol)` text must be English.
- Every commit message must contain `🤖`.
- Before implementation, create an isolated worktree from `nrydanov/split-tunneling` using the `using-git-worktrees` skill.

---

### Task 1: Add the shared exact-revision protocol and codec

**Files:**
- Create: `Shared/VPNHelperXPCProtocol.swift`
- Create: `Shared/VPNHelperMessages.swift`
- Create: `Shared/VPNHelperProtocolError.swift`
- Create: `scripts/verify_xpc_protocol.swift`
- Modify: `justfile`
- Modify: `teleport.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: Foundation `Data`, `UUID`, `Codable`, and existing `PrivilegedHelperConstants` naming.
- Produces:
  - `VPNHelperXPCProtocol`
  - `VPNHelperProtocol.revision`
  - `VPNHelperCommand`
  - `VPNHelperRequestEnvelope<Payload>`
  - `VPNHelperResponseEnvelope<Payload>`
  - typed status/start/stop/diagnostics payloads
  - `VPNHelperProtocolFailure`
  - `VPNHelperCodec`

- [ ] **Step 1: Add a failing protocol verification script**

Create `scripts/verify_xpc_protocol.swift` with an `@main` async-free test runner. It must assert:

```swift
precondition(VPNHelperProtocol.revision == 8)

let requestID = UUID()
let sessionID = UUID()
let request = VPNHelperRequestEnvelope(
    revision: VPNHelperProtocol.revision,
    requestID: requestID,
    sessionID: sessionID,
    payload: StartSessionRequest(
        stateDirectoryPath: "/var/db/dev.x.teleport",
        configData: Data("{}".utf8),
        protectedHost: "example.com",
        tunnelInterfaceName: "utun9",
        outboundInterface: "en0"
    )
)
let encoded = try VPNHelperCodec.encodeRequest(request)
let decoded: VPNHelperRequestEnvelope<StartSessionRequest> = try VPNHelperCodec.decodeRequest(encoded)
precondition(decoded == request)
```

Also test all response payload round trips, structured failure round trips, exact revision rejection, a 512 KiB accepted config, a 512 KiB + 1 byte rejected config, a 256 KiB accepted diagnostics response, and a 256 KiB + 1 byte rejected diagnostics response.

- [ ] **Step 2: Add the recipe and verify RED**

Add:

```make
verify-xpc-protocol:
    swiftc Shared/*.swift scripts/verify_xpc_protocol.swift -o /tmp/teleport-verify-xpc-protocol
    /tmp/teleport-verify-xpc-protocol
```

Append `verify-xpc-protocol` to `verify` and run:

```bash
just verify-xpc-protocol
```

Expected: compile failure because `VPNHelperProtocol`, envelopes, payloads, and codec do not exist.

- [ ] **Step 3: Define the XPC surface and protocol constants**

Create `Shared/VPNHelperXPCProtocol.swift`:

```swift
import Foundation

@objc protocol VPNHelperXPCProtocol {
    func getStatus(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func startSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func stopSession(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
    func readDiagnostics(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}

nonisolated enum VPNHelperProtocol {
    static let revision: UInt = 8
    static let machServiceName = "dev.x.teleport.helper"
    static let maximumRequestBytes = 1_048_576
    static let maximumConfigurationBytes = 524_288
    static let maximumResponseBytes = 1_048_576
    static let maximumDiagnosticsBytes = 262_144
}
```

The declarations must remain Foundation-only and compile in both targets.

- [ ] **Step 4: Define typed Codable messages**

Create `Shared/VPNHelperMessages.swift`. Use nonisolated `Codable`, `Sendable`, `Equatable` values with these exact public-in-module names:

```swift
enum VPNHelperCommand: String, Codable, Sendable {
    case status, startSession, stopSession, readDiagnostics
}

enum VPNHelperSessionPhase: String, Codable, Sendable {
    case idle, starting, running, stopping, failed, unknown
}

struct VPNHelperRequestEnvelope<Payload: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    let revision: UInt
    let requestID: UUID
    let sessionID: UUID?
    let payload: Payload
}

struct VPNHelperResponseEnvelope<Payload: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    let revision: UInt
    let requestID: UUID
    let sessionID: UUID?
    let payload: Payload?
    let failure: VPNHelperProtocolFailure?
}
```

Define empty `StatusRequest`; `StartSessionRequest`; `StopSessionRequest`; `ReadDiagnosticsRequest`; and matching response payloads. `StartSessionRequest` carries the current controller inputs. `StopSessionRequest` carries the matching session ID through the envelope plus transitional cleanup inputs. `ReadDiagnosticsRequest` uses a typed `VPNHelperLog` enum (`xray`, `control`) rather than a free-form file name.

- [ ] **Step 5: Define protocol failures and bounded codec**

Create `Shared/VPNHelperProtocolError.swift` with:

```swift
enum VPNHelperFailureCode: String, Codable, Sendable {
    case incompatibleService
    case malformedPayload
    case payloadTooLarge
    case requestConflict
    case inProgress
    case commandFailed
    case unavailable
    case interrupted
    case invalidated
    case deadlineExceeded
    case indeterminate
}

enum VPNHelperRetryDisposition: String, Codable, Sendable {
    case never, reconnectAndQueryStatus, reinstallService
}

struct VPNHelperProtocolFailure: Codable, Sendable, Equatable {
    let code: VPNHelperFailureCode
    let summary: String
    let details: String?
    let retryDisposition: VPNHelperRetryDisposition
}
```

`VPNHelperCodec.encodeRequest`, `decodeRequest`, `encodeResponse`, and `decodeResponse` must enforce encoded-size and revision bounds. Payload-specific `validate()` methods enforce session-ID presence, config size, diagnostics limits, non-empty interface/host fields, and the allowlisted state directory root.

- [ ] **Step 6: Add both shared files to both Xcode targets**

Update `project.pbxproj` so all three new Shared files compile in both `teleport` and `dev.x.teleport.PrivilegedHelper`. Do not add a new target. Keep one file reference and one Sources build-file entry per target for each shared file, matching the existing `PrivilegedHelperConstants.swift` pattern.

- [ ] **Step 7: Run GREEN verification**

Run:

```bash
just verify-xpc-protocol
just build-debug
```

Expected: protocol checks pass and both targets compile the same shared declarations.

- [ ] **Step 8: Commit the shared protocol**

```bash
git add Shared scripts/verify_xpc_protocol.swift justfile teleport.xcodeproj/project.pbxproj
git commit -m "🤖 feat: add shared privileged helper protocol"
```

---

### Task 2: Add bounded helper request deduplication

**Files:**
- Create: `TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift`
- Create: `scripts/verify_helper_request_ledger.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `UUID`, `Data`, `VPNHelperCommand`, response `Data`, and protocol failures from Task 1.
- Produces:
  - `HelperRequestLedger`
  - `HelperRequestFingerprint`
  - `HelperLedgerLookup`
  - deterministic in-progress/completed/conflict decisions.

- [ ] **Step 1: Write failing ledger tests**

Create a standalone async verification script that constructs:

```swift
let clock = MutableTestClock(now: Date(timeIntervalSince1970: 1_000))
let ledger = HelperRequestLedger(maximumEntries: 2, maximumAge: 600, now: { clock.now })
let requestID = UUID()
let fingerprint = HelperRequestFingerprint(command: .startSession, payload: Data("a".utf8))
```

Assert these transitions:

```text
unknown -> begin -> inProgress
same ID + same fingerprint -> inProgress
same ID + different fingerprint -> conflict
complete -> completed(responseData)
third completed request -> oldest entry evicted at count 2
clock + 601 seconds -> old entry evicted by age
```

- [ ] **Step 2: Add recipe and verify RED**

Add:

```make
verify-helper-request-ledger:
    swiftc Shared/*.swift TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift scripts/verify_helper_request_ledger.swift -o /tmp/teleport-verify-helper-request-ledger
    /tmp/teleport-verify-helper-request-ledger
```

Append it to `verify`. Expected RED: missing ledger types.

- [ ] **Step 3: Implement the bounded ledger**

Use a value-owned dictionary inside the helper command dispatcher; the ledger itself does not create threads or locks:

```swift
struct HelperRequestFingerprint: Hashable {
    let command: VPNHelperCommand
    let payloadDigest: Data

    init(command: VPNHelperCommand, payload: Data) {
        self.command = command
        payloadDigest = Data(SHA256.hash(data: payload))
    }
}

enum HelperLedgerLookup: Equatable {
    case unknown
    case inProgress
    case completed(Data)
    case conflict
}
```

Use CryptoKit SHA-256 for fingerprints. Store timestamps and insertion order. Prune by age before every lookup/begin/complete, then prune the oldest completed entry to enforce count. Never evict an in-progress entry solely to admit a duplicate command; return a bounded-capacity failure instead.

- [ ] **Step 4: Run tests**

```bash
just verify-helper-request-ledger
just build-debug
```

Expected: all ledger transitions and both targets pass.

- [ ] **Step 5: Commit**

```bash
git add TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift scripts/verify_helper_request_ledger.swift justfile
git commit -m "🤖 feat: deduplicate privileged helper requests"
```

---

### Task 3: Introduce typed helper command dispatch

**Files:**
- Create: `TeleportPrivilegedHelper/IPC/HelperCommandExecuting.swift`
- Create: `TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift`
- Modify: `TeleportPrivilegedHelper/Session/XrayTunController.swift`
- Create: `scripts/verify_helper_command_dispatch.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: shared typed requests/responses and `HelperRequestLedger`.
- Produces:
  - `HelperCommandExecuting`
  - `XrayTunController: HelperCommandExecuting, Sendable`
  - actor `HelperCommandDispatcher`
  - `dispatch(command:requestData:) async -> Data`.

- [ ] **Step 1: Add failing dispatcher tests**

Create a recording executor and verify:

- each command decodes only its matching envelope/payload;
- status never calls start/stop/diagnostics;
- malformed and oversized data produces structured failure without executor calls;
- revision mismatch produces `incompatibleService`;
- duplicate completed request returns identical bytes and executes once;
- duplicate in-progress request returns `inProgress`;
- request-ID reuse with changed bytes returns `requestConflict`.

The recording executor must block one start with semaphores so the in-progress duplicate is deterministic.

- [ ] **Step 2: Add recipe and verify RED**

Compile shared files, ledger, dispatcher/protocol, and the verification script. Expected RED: missing dispatcher/executor types.

- [ ] **Step 3: Define the executor seam**

Create:

```swift
protocol HelperCommandExecuting: Sendable {
    func status(request: StatusRequest) throws -> StatusResponse
    func start(request: StartSessionRequest, sessionID: UUID) throws -> StartSessionResponse
    func stop(request: StopSessionRequest, sessionID: UUID) throws -> StopSessionResponse
    func readDiagnostics(request: ReadDiagnosticsRequest) throws -> DiagnosticsResponse
}
```

Keep all PID and filesystem evidence inside the implementation.

- [ ] **Step 4: Adapt XrayTunController without changing lifecycle behavior**

Replace `HelperRequest` parameters with typed request values and convert the stateless-reference controller from `final class` to `struct`. Mark `XrayTunController`, `ManagedXrayProcess`, `HelperShellRunner`, and `XrayTunScriptBuilder` as `Sendable`; their stored values are immutable value types. Preserve field validation, start/stop ordering, retries, PID validation, SIGTERM/SIGKILL behavior, route commands, log bounds, and cleanup branches exactly. Map typed `VPNHelperLog` values to the existing fixed root log paths.

Status reports the best current transitional observation from existing state/PID evidence. It must not claim persisted authoritative ownership. Do not introduce `@unchecked Sendable` in the new helper dispatcher path.

- [ ] **Step 5: Implement the serialized dispatcher**

`HelperCommandDispatcher` is an actor owning one executor and one ledger. It validates encoded size before decode, validates envelope and payload, begins the ledger entry before executor invocation, completes it with the exact response bytes, and converts thrown errors into `VPNHelperProtocolFailure(code: .commandFailed, ...)`.

The actor intentionally preserves Phase 3 command serialization. Do not introduce the Phase 4 non-blocking session actor.

- [ ] **Step 6: Run tests and build**

```bash
just verify-helper-command-dispatch
just verify-split-tunneling
just build-debug
```

Expected: all pass with unchanged route-script assertions.

- [ ] **Step 7: Commit**

```bash
git add TeleportPrivilegedHelper/IPC TeleportPrivilegedHelper/Session scripts justfile
git commit -m "🤖 refactor: dispatch typed helper commands"
```

---

### Task 4: Add the authenticated XPC helper endpoint

**Files:**
- Create: `TeleportPrivilegedHelper/IPC/HelperXPCService.swift`
- Create: `TeleportPrivilegedHelper/IPC/HelperXPCListenerDelegate.swift`
- Modify: `TeleportPrivilegedHelper/IPC/ClientAuthenticator.swift`
- Modify: `TeleportPrivilegedHelper/main.swift`
- Create: `scripts/verify_helper_xpc_endpoint.swift`
- Modify: `scripts/verify_architecture_layout.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `VPNHelperXPCProtocol`, `HelperCommandDispatcher`, console-user lookup, approved code-signing requirement.
- Produces:
  - `HelperXPCService: NSObject, VPNHelperXPCProtocol`
  - `HelperXPCListenerDelegate: NSObject, NSXPCListenerDelegate`
  - `ClientAuthenticator.configureAndAuthorize(_:) -> Bool`
  - Mach-listener bootstrap in `main.swift`.

- [ ] **Step 1: Add failing source/composition assertions**

Assert:

```swift
precondition(mainSource.contains("NSXPCListener(machServiceName: VPNHelperProtocol.machServiceName)"))
precondition(mainSource.contains("listener.resume()"))
precondition(authenticatorSource.contains("effectiveUserIdentifier"))
precondition(authenticatorSource.contains("setCodeSigningRequirement"))
precondition(listenerSource.contains("connection.exportedInterface"))
precondition(listenerSource.contains("connection.exportedObject"))
precondition(listenerSource.contains("connection.activate()"))
```

Also instantiate `HelperXPCService` with a recording dispatcher seam and call every exported method directly. Assert each reply fires exactly once with bounded encoded data or one `NSError`.

- [ ] **Step 2: Run and verify RED**

Run the new endpoint recipe. Expected: missing XPC endpoint/listener types and old socket bootstrap still present.

- [ ] **Step 3: Refactor authentication to public XPC APIs**

Implement:

```swift
struct ClientAuthenticator {
    let requirement: String

    func configureAndAuthorize(_ connection: NSXPCConnection) -> Bool {
        let consoleOwner = consoleUserIDs()
        guard consoleOwner.uid != 0,
              connection.effectiveUserIdentifier == consoleOwner.uid else { return false }
        connection.setCodeSigningRequirement(requirement)
        return true
    }
}
```

Use the existing designated requirement and Team ID from one helper configuration constant. Do not use PID lookup as the primary authorization decision. Configure the requirement before connection activation. Fail closed when no active console user exists.

- [ ] **Step 4: Implement endpoint and listener delegate**

Each exported method creates a `Task`, awaits dispatcher execution for its fixed `VPNHelperCommand`, verifies response size, and calls the reply exactly once. Convert transport/setup failures to bounded `NSError`; command failures remain encoded structured responses.

The listener delegate must authenticate first, set `exportedInterface = NSXPCInterface(with: VPNHelperXPCProtocol.self)`, set allowed `NSData` classes for all arguments/replies, assign one exported service object sharing the dispatcher, activate, and return `true`. Rejected connections return `false` without exposing an object.

- [ ] **Step 5: Replace helper bootstrap**

Replace socket/SIGPIPE bootstrap with:

```swift
let dispatcher = HelperCommandDispatcher(executor: XrayTunController())
let delegate = HelperXPCListenerDelegate(dispatcher: dispatcher)
let listener = NSXPCListener(machServiceName: VPNHelperProtocol.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
```

Keep fatal bootstrap diagnostics. Do not add `SMAppService`.

- [ ] **Step 6: Run verification**

```bash
just verify-helper-xpc-endpoint
just verify-architecture-layout
just build-debug
```

Expected: helper endpoint tests and standalone helper target build pass.

- [ ] **Step 7: Commit**

```bash
git add TeleportPrivilegedHelper scripts justfile
git commit -m "🤖 feat: serve privileged commands over XPC"
```

---

### Task 5: Implement the app-side XPC transport

**Files:**
- Create: `teleport/VPN/VPNHelperTransport.swift`
- Create: `teleport/VPN/XPCVPNHelperTransport.swift`
- Create: `scripts/verify_xpc_transport.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `VPNHelperXPCProtocol`, Mach service name, typed command, encoded request, command deadline.
- Produces:
  - `VPNHelperTransport`
  - `XPCVPNHelperTransport`
  - `VPNHelperTransportError`
  - `send(command:requestData:timeout:) throws -> Data`.

- [ ] **Step 1: Write failing transport-seam tests**

Use an injected connection/proxy factory, not a real privileged service. Test:

- each command invokes the corresponding XPC method;
- normal data reply succeeds;
- proxy error maps to unavailable;
- `NSError` reply maps without double completion;
- interruption/invalidation retires the connection;
- next request creates exactly one replacement;
- timeout returns `.deadlineExceeded`;
- a late reply after timeout is ignored;
- every call completes exactly once.

- [ ] **Step 2: Add recipe and verify RED**

Compile app VPN transport files plus Shared files and the script. Expected: missing transport types.

- [ ] **Step 3: Define the transport seam**

```swift
protocol VPNHelperTransport: Sendable {
    func send(command: VPNHelperCommand, requestData: Data, timeout: TimeInterval) throws -> Data
    func invalidate()
}

enum VPNHelperTransportError: Error, Equatable {
    case unavailable(String)
    case interrupted
    case invalidated
    case deadlineExceeded
    case invalidResponse(String)
}
```

- [ ] **Step 4: Implement connection ownership**

`XPCVPNHelperTransport` owns a lock-protected optional connection and generation counter. A new connection sets `remoteObjectInterface`, interruption handler, and invalidation handler before `activate()`. Handlers retire only their matching generation so an old invalidation cannot clear a replacement.

Use `remoteObjectProxyWithErrorHandler` and a one-shot completion box to race reply/error/deadline safely. The synchronous wait occurs only on `BackendConnectionProvider`'s lifecycle queue, never the main actor. Do not use `@unchecked Sendable` without documenting the exact lock-protected mutable fields and obtaining explicit review.

- [ ] **Step 5: Run tests and build**

```bash
just verify-xpc-transport
just build-debug
```

Expected: transport race tests and app/helper build pass.

- [ ] **Step 6: Commit**

```bash
git add teleport/VPN/VPNHelperTransport.swift teleport/VPN/XPCVPNHelperTransport.swift scripts/verify_xpc_transport.swift justfile
git commit -m "🤖 feat: add privileged helper XPC client transport"
```

---

### Task 6: Migrate PrivilegedHelperClient and add bounded reconciliation

**Files:**
- Modify: `teleport/VPN/PrivilegedHelperClient.swift`
- Modify: `teleport/VPN/PrivilegedXrayRuntimeManager.swift`
- Create: `scripts/verify_privileged_helper_client.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `VPNHelperTransport`, typed shared messages, existing `XrayTunLaunchSession`/runtime paths.
- Produces: the existing higher-level `status`, `start`, `stop`, and `readLog` facade backed only by XPC, plus request/session correlation and one reconciliation attempt.

- [ ] **Step 1: Write failing client behavior tests**

Inject a scripted transport and assert:

- status uses a 3-second deadline;
- diagnostics uses 5 seconds and clamps at 256 KiB;
- start uses 20 seconds and supplies one request ID/session ID;
- stop uses 15 seconds and preserves the session ID;
- normal typed replies map to existing runtime-manager return values;
- request/response ID mismatch is rejected;
- revision mismatch maps to `incompatibleService`;
- lost start reply followed by matching running status succeeds;
- lost stop reply followed by matching idle status succeeds;
- matching failed status returns command failure;
- unknown/unavailable reconciliation returns indeterminate with request/session IDs;
- reconciliation occurs once and never reissues the mutating command.

- [ ] **Step 2: Add recipe and verify RED**

Expected RED: existing client has no transport injection, typed envelopes, session correlation, or reconciliation.

- [ ] **Step 3: Replace wire structs and socket code**

Delete `PrivilegedHelperRequest`, `PrivilegedHelperResponse`, `socket`, `connect`, `read`, `write`, `shutdown`, and timeval logic from `PrivilegedHelperClient.swift`.

Add:

```swift
struct PrivilegedHelperClient: Sendable {
    private let transport: any VPNHelperTransport

    init(transport: any VPNHelperTransport = XPCVPNHelperTransport()) {
        self.transport = transport
    }
}
```

Encode/decode only through `VPNHelperCodec`. Validate revision, request ID, session ID, payload, and failure before returning.

- [ ] **Step 4: Add session identity to runtime-manager flow**

Generate a UUID before privileged start and retain it in app-side `XrayTunSessionState`. Pass the same ID to start, stop, and reconciliation. This remains correlation identity only. Update persisted app-side cached state with a reset-compatible schema; backward compatibility is not required.

- [ ] **Step 5: Implement one bounded reconciliation attempt**

On `.interrupted`, `.invalidated`, or `.deadlineExceeded` from start/stop:

1. invalidate the failed transport generation;
2. issue one status request on a replacement connection;
3. compare revision/request/session/phase;
4. return success for matching running start or idle stop;
5. return structured command failure for matching failed status;
6. otherwise throw `PrivilegedHelperClientError.indeterminate(requestID:sessionID:summary:)`.

Never reissue start or stop automatically.

- [ ] **Step 6: Preserve installation preflight behavior**

`PrivilegedXrayRuntimeManager` continues to call `ensureInstalled` before start. Status revision mismatch makes `isInstalledAndRunning` false, causing the existing installer to replace the helper once. Do not trigger installation from the low-level transport.

- [ ] **Step 7: Run focused verification**

```bash
just verify-privileged-helper-client
just verify-connection-provider
just verify-split-tunneling
just build-debug
```

Expected: all pass and no socket symbol remains in the client.

- [ ] **Step 8: Commit**

```bash
git add teleport/VPN scripts/verify_privileged_helper_client.swift justfile
git commit -m "🤖 refactor: use typed XPC helper client"
```

---

### Task 7: Cut the LaunchDaemon over to its Mach service

**Files:**
- Modify: `teleport/HelperInstallation/PrivilegedHelperInstaller.swift`
- Modify: `Shared/PrivilegedHelperConstants.swift`
- Create: `scripts/reset_legacy_privileged_helper.sh`
- Create: `scripts/verify_mach_service_installation.swift`
- Modify: `justfile`

**Interfaces:**
- Consumes: `VPNHelperProtocol.machServiceName`, existing installer paths, launchctl bootstrap flow.
- Produces: a LaunchDaemon plist exposing exactly one Mach service and explicit development reset tooling.

- [ ] **Step 1: Add failing plist/reset assertions**

Extract installer source or an injected plist builder and assert:

```text
MachServices exists
key == dev.x.teleport.helper
value == true
no Sockets dictionary
no socket chmod/chown/unlink command
existing Label/ProgramArguments/log paths remain
```

Assert the reset script contains `launchctl bootout`, removes the old socket/helper/Xray/assets/plist/root-state paths, requires root, and uses `set -eu`.

- [ ] **Step 2: Run and verify RED**

Expected: plist lacks `MachServices`, constants still expose `socketPath`, and reset tooling is absent.

- [ ] **Step 3: Add MachServices to the generated plist**

Add exactly:

```xml
<key>MachServices</key>
<dict>
    <key>dev.x.teleport.helper</key>
    <true/>
</dict>
```

Keep the current root execution, paths, logs, bootstrap, and kickstart behavior. Remove product installer references to the socket. Do not add `SMAppService`.

- [ ] **Step 4: Add explicit legacy reset tooling**

Create a root-only shell script that prints every removed path, boots out the old daemon if present, removes the legacy socket, installed helper/runtime/assets/plist, and `/var/db/dev.x.teleport`, then exits. It must not run automatically from build or app startup.

Add `just reset-legacy-privileged-helper` invoking it with `sudo`.

- [ ] **Step 5: Bump exact helper revision**

Set `PrivilegedHelperConstants.version` to `"8"`, expose the Mach service through the shared protocol constant, and remove `socketPath` from production constants after all consumers are gone.

- [ ] **Step 6: Run verification**

```bash
just verify-mach-service-installation
just verify-xpc-protocol
just build-debug
```

Expected: plist/reset checks and build pass. Do not execute the destructive reset recipe during automated verification.

- [ ] **Step 7: Commit**

```bash
git add teleport/HelperInstallation Shared scripts justfile
git commit -m "🤖 refactor: register helper Mach service"
```

---

### Task 8: Remove the UNIX socket implementation and finalize guards/docs

**Files:**
- Delete: `TeleportPrivilegedHelper/IPC/HelperServer.swift`
- Delete: `TeleportPrivilegedHelper/IPC/HelperMessages.swift`
- Modify: `scripts/verify_architecture_layout.swift`
- Modify: `docs/runtime-source-layout.md`
- Modify: `docs/xray-bundling-and-release.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: completed XPC endpoint, client, Mach-service installer, and all focused recipes.
- Produces: one XPC-only privileged transport, durable architecture guards, and current documentation.

- [ ] **Step 1: Strengthen architecture guards**

Require all shared protocol, helper XPC, dispatcher/ledger, and app transport files. Reject old helper server/message files. Recursively scan production Swift and installer source and fail on:

```text
AF_UNIX
sockaddr_un
LOCAL_PEERPID
getpeereid
socketPath
/var/run/dev.x.teleport.helper.sock
HelperServer
PrivilegedHelperRequest
PrivilegedHelperResponse
```

Allow the literal legacy socket path only in `scripts/reset_legacy_privileged_helper.sh` and migration documentation.

Assert `AppViewModel` and `ConnectionProvider` contain no `NSXPCConnection`, Mach service name, helper revision, request ID, or session transport payload details.

- [ ] **Step 2: Run guard and verify RED before deletion**

Run:

```bash
just verify-architecture-layout
```

Expected: failure because obsolete socket helper files still exist.

- [ ] **Step 3: Delete obsolete socket files**

Delete `HelperServer.swift` and `HelperMessages.swift`. Remove obsolete Darwin socket imports and SIGPIPE/socket comments. Ensure XPC endpoint is the only privileged command ingress.

- [ ] **Step 4: Update documentation**

Document current shipping Phase 3 behavior:

- shared exact-revision typed protocol;
- authenticated XPC Mach-service transport;
- request/session correlation and same-daemon bounded deduplication;
- one bounded reconciliation attempt after indeterminate mutating replies;
- existing administrator installer remains transitional;
- helper controller/process/routes remain synchronous/transitional;
- session/root route ownership is not authoritative until Phase 4;
- `SMAppService` remains Phase 5.

Do not describe Phase 4/5 behavior as implemented.

- [ ] **Step 5: Run focused verification**

```bash
just verify-xpc-protocol
just verify-helper-request-ledger
just verify-helper-command-dispatch
just verify-helper-xpc-endpoint
just verify-xpc-transport
just verify-privileged-helper-client
just verify-mach-service-installation
just verify-architecture-layout
```

Expected: all pass.

- [ ] **Step 6: Run complete fresh verification**

```bash
git diff --check
just clean
just verify
```

Also build the standalone helper and verify signatures through the existing `just verify` flow. Expected: all checks and Debug builds pass.

- [ ] **Step 7: Perform manual trust-boundary checks**

Record, without fabricating results, which checks were performed:

```text
legacy helper reset
fresh helper installation and upgrade/cutover installation
production Developer ID app accepted
unsigned/wrong-team client rejected
System Proxy connect/disconnect
VPN connect/disconnect
live helper interruption during status, start, and stop
app termination during a pending request
Fast User Switching/login-window behavior
hardened-runtime and notarized distribution validation
```

Unperformed checks remain explicit release risks.

- [ ] **Step 8: Request final code review**

Review the full diff against `docs/superpowers/specs/2026-09-02-xpc-transport-design.md`. Block completion on transport duplication, unbounded payloads, authentication bypass, reply double-completion, request replay, upper-layer XPC leakage, or Phase 4/5 scope creep.

- [ ] **Step 9: Commit final cutover**

```bash
git add -A
git commit -m "🤖 refactor: complete privileged helper XPC cutover"
```
