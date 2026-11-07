# Runtime source layout

Teleport keeps app-side connection orchestration separate from the root helper trust boundary. These directories are source boundaries within the existing app and helper targets; they are not Swift packages or frameworks.

## App target

### `teleport/Connection`

Defines the provider-oriented API consumed by upper application layers:

- `ConnectionProvider` exposes asynchronous connect/disconnect operations and one `ConnectionState` stream.
- `ConnectionRequest` carries provider-neutral connection and split routing inputs.
- `ConnectionProviderFactory` selects System Proxy or root-Xray mode.
- `BackendConnectionProvider` serializes lifecycle work around transitional synchronous backends.

`AppViewModel` depends on this domain boundary and contains no helper, XPC, process, route, request-ID, or privileged session payload details.

### `teleport/XrayCore`

Builds Xray JSON for System Proxy and TUN sessions. It does not launch processes, mutate system settings/routes, or contact the helper.

### `teleport/SystemProxy`

Owns the unprivileged System Proxy provider, its transitional backend, the user-level Xray process, and macOS proxy settings.

`SystemProxyService` is the shared, serialized owner of proxy takeover and recovery
for both modes and deferred recovery. `HelperProxyPreferences` sends typed requests
to the approved helper. Shared `SystemProxyPreferences` provides read-only inventory
and observation in the app, and locked preference writes in the helper.
`ProxyJournalStore` retains durable recovery records keyed by service ID and holds
an interprocess lock while a session owns settings. Proxy changes are observed
through preference notifications with periodic provider checks as a fallback.
Conflicts reach the provider as typed failures requiring an explicit reconnect.
See [proxy recovery](proxy-recovery.md) for the conflict and upgrade policy.

### `teleport/TUN`

Owns app-side root-Xray orchestration:

- `RootXrayConnectionProvider` is the provider facade.
- `XrayTunConnectionBackend` remains the transitional synchronous backend.
- `PrivilegedXrayRuntimeManager` coordinates installation preflight, typed helper calls, and app-side cached correlation state.
- `TUNHelperTransport` hides transport details from higher layers.
- `XPCTUNHelperTransport` owns `NSXPCConnection`, deadlines, interruption/invalidation handling, generation-safe replacement, and exactly-once completion.
- `PrivilegedHelperClient` encodes exact-revision typed messages and performs one bounded status reconciliation after an indeterminate mutating reply. It never automatically retransmits start or stop.
- `XrayTunSessionState` persists app-side correlation needed for later stop attempts. It is not authoritative root ownership.

This directory contains no root-executed code.

### `teleport/HelperInstallation`

Owns bundled artifact verification and the current administrator-authorized installation path. `PrivilegedHelperInstaller` installs the helper/runtime/assets and a LaunchDaemon exposing the XPC Mach service. `PrivilegedHelperUninstaller` removes the same set through the same administrator shell, for Settings > General; `scripts/uninstall.sh` does it without the app. This installer remains transitional; `SMAppService` is not implemented in Phase 3.

### `teleport/Geodata`

Owns geodata selection, downloads, and the resolved asset directory consumed by configuration generation. The helper reads that directory from the console user's Application Support at session start after validating its path, ownership, and permissions; geodata is not part of the administrator installation.

## Privileged helper target

`TeleportPrivilegedHelper` remains a separate root executable and explicit trust boundary.

### `IPC`

- `ClientAuthenticator` requires the active console UID and configures the approved code-signing requirement before XPC activation.
- `HelperXPCListenerDelegate` accepts only authenticated Mach-service connections and installs the bounded `Data`/`NSError` interface.
- `HelperXPCService` provides the four explicit XPC methods and exactly-once replies.
- `HelperCommandDispatcher` decodes typed command-specific payloads, serializes execution, and tracks the best same-daemon session correlation.
- `HelperRequestLedger` bounds deduplication to 128 entries and ten minutes. Completed duplicates return identical bytes; in-progress duplicates and request-ID conflicts do not execute again.

The former UNIX-domain socket server and duplicate socket message model have been removed. XPC is the only privileged command ingress.

### `Session`

`XrayTunController` validates request fields and preserves the existing synchronous start/stop/status/diagnostics ordering and cleanup behavior.

### `Xray`

`ManagedXrayProcess` validates PID files and executable paths, then retains the existing SIGTERM, bounded wait, and SIGKILL lifecycle.

### `Routing`

`XrayTunScriptBuilder` generates the current IPv4 TUN readiness, protected-host, DNS, split-default-route, and cleanup commands.

### `Support`

Contains shared helper configuration, platform lookups, and bounded shell execution support.

### `main.swift`

Bootstraps `NSXPCListener` for `TUNHelperProtocol.machServiceName`, installs the authenticated delegate, resumes the listener, and runs the process loop.

## Shared source

The `Shared` directory is compiled into both existing targets:

- `PrivilegedHelperConstants.swift` contains installation compatibility and root-owned paths.
- `TUNHelperXPCProtocol.swift` defines the Foundation-only XPC surface, exact revision 8, Mach-service name, and payload bounds.
- `TUNHelperMessages.swift` defines typed Codable request/response values.
- `TUNHelperProtocolError.swift` validates exact revisions, command payloads, session shapes, and encoded sizes.

## Dependency direction

```text
AppViewModel
    -> ConnectionProvider / ConnectionRequest / ConnectionState
        -> mode-specific provider
            -> BackendConnectionProvider -> transitional backend
                -> PrivilegedXrayRuntimeManager
                    -> PrivilegedHelperClient
                        -> TUNHelperTransport / XPCTUNHelperTransport
                            -> authenticated XPC Mach service
                                -> HelperCommandDispatcher
                                    -> XrayTunController
                                        -> process / shell / route components
```

## Current limits and future phases

Phase 3 session UUIDs provide correlation, not persisted authoritative helper ownership. The helper ledger and observed session identity are memory-only and are lost when the daemon restarts. Root process/route lifecycle remains synchronous and route cleanup is not journaled or session-owned.

Phase 4 is responsible for authoritative persisted helper sessions, reconciliation, and route journals. Phase 5 is responsible for replacing the administrator installer with `SMAppService`. IPv6 routing, Network Extension migration, startup optimization, and auto-connect are not part of the current implementation.

## Verification

Run:

```bash
just test
```

`test-architecture-layout` requires the XPC source boundaries, rejects legacy socket symbols/files, and prevents XPC details from crossing into provider/UI layers.
