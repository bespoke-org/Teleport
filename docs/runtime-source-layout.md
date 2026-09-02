# Runtime source layout

Teleport keeps the app-side connection orchestration separate from the root helper boundary. The folders below are source boundaries inside the existing app and helper targets; they are not separate Swift packages or frameworks.

## App target

### `teleport/XrayCore`

Builds Xray JSON for System Proxy and VPN/TUN sessions.

- Depends on connection and split-tunnel domain models.
- Does not launch processes.
- Does not change macOS proxy settings or routes.
- Does not communicate with the privileged helper.

### `teleport/SystemProxy`

Owns the unprivileged System Proxy execution path.

- `SystemProxyConnectionProvider` is the mode-specific provider facade selected by the app.
- `SystemProxyConnectionBackend` is the transitional synchronous adapter below that provider.
- `XrayRuntimeManager` owns the user-level Xray child process and logs.
- `SystemProxyService` reads and changes macOS network proxy settings.

### `teleport/VPN`

Owns app-side VPN/TUN orchestration.

- `RootXrayConnectionProvider` is the mode-specific provider facade selected by the app.
- `XrayTunConnectionBackend` is the transitional synchronous adapter that prepares and starts VPN sessions below the provider.
- `PrivilegedXrayRuntimeManager` coordinates helper installation, IPC, and app-side session state.
- `PrivilegedHelperClient` implements the JSON-over-Unix-socket client.
- `XrayTunRouteInspector` performs read-only network inspection before startup.
- `XrayTunSessionState` contains app-side launch and cached-state values.

This directory contains no root-executed code. The helper is authoritative for privileged operations.

### `teleport/HelperInstallation`

Owns deployment and verification of bundled privileged artifacts.

- `BundledArtifactPolicy` contains the approved signing requirement and Xray digest.
- `BundledArtifactVerifier` verifies the app, helper, and bundled Xray runtime.
- `PrivilegedHelperInstaller` installs the helper, runtime, geodata, and LaunchDaemon.
- `PrivilegedShellRunner` is the current administrator-authorization bridge used only during installation or update.

### `teleport/Geodata`

Owns geodata source selection, downloads, and resolved asset preparation. Geodata is consumed by configuration generation and copied into the helper-owned asset directory during privileged installation.

### `teleport/Connection`

Contains the provider-oriented API consumed by upper application layers:

- `ConnectionProvider` defines asynchronous connect/disconnect operations and one `ConnectionState` stream.
- `ConnectionRequest` carries provider-neutral connection and split-tunnel inputs.
- `ConnectionProviderFactory` selects the System Proxy or root-Xray provider for the persisted mode.
- `BackendConnectionProvider` serializes lifecycle work and adapts the current synchronous implementations.
- `ConnectionBackend` remains a transitional Phase 2 adapter below providers; it is not consumed by `AppViewModel`.

`ConnectionSession.id` is currently generated in the app provider layer and identifies a UI connected interval only. It is not yet an authoritative helper-owned VPN session identifier.

## Privileged helper target

`TeleportPrivilegedHelper` remains a separate executable target and the explicit root trust boundary.

### `IPC`

- Defines helper request and response messages.
- Authenticates the console-user client and its code signature.
- Owns the Unix-domain socket server and command dispatch.

### `Session`

`XrayTunController` validates request fields, manages root-owned state files, and preserves the ordering of start, stop, and log operations.

### `Xray`

`ManagedXrayProcess` validates PID files and executable paths, then performs the existing SIGTERM, bounded wait, and SIGKILL lifecycle.

### `Routing`

`XrayTunScriptBuilder` generates the current shell commands for TUN readiness, protected host and DNS routes, split default routes, and cleanup.

### `Support`

Contains module-wide constants, platform helpers, and bounded shell execution support used by the helper components.

### `main.swift`

Contains only process bootstrap behavior: ignore `SIGPIPE`, start `HelperServer`, report a fatal startup error, and exit.

## Shared source

`Shared/PrivilegedHelperConstants.swift` is compiled into both targets. It is the single source for protocol compatibility version, socket path, helper label, and root-owned installation paths.

## Dependency direction

```text
AppViewModel
    -> ConnectionProvider / ConnectionRequest / ConnectionState
        -> ConnectionProviderFactory
            -> SystemProxyConnectionProvider
                -> BackendConnectionProvider -> SystemProxyConnectionBackend
            -> RootXrayConnectionProvider
                -> BackendConnectionProvider -> XrayTunConnectionBackend
                    -> HelperInstallation
                    -> PrivilegedHelperClient

XrayCore <- SystemProxy and VPN configuration preparation
Geodata  <- app settings and helper installation

PrivilegedHelperClient
    -> authenticated helper IPC
        -> XrayTunController
            -> ManagedXrayProcess
            -> HelperShellRunner
            -> XrayTunScriptBuilder
```

`AppViewModel` consumes one provider state stream and does not coordinate process, proxy, helper, or route details directly. App code must not import helper implementation files. Root-only process and route mutations must not move into the app target.

The current root path still uses JSON over a Unix-domain socket, app-generated session identity, the existing privileged installer, and synchronous backend adapters. XPC/Mach services, authoritative helper-owned sessions, reconciliation, and `SMAppService` registration are future architecture phases and are not shipping behavior in this layout.

## Verification

Run the complete build and smoke-test suite:

```bash
just verify
```

The `verify-architecture-layout` recipe guards required source locations, rejects obsolete mixed-responsibility files, and verifies that helper `main.swift` remains entry-only.
