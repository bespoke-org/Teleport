# Teleport

Teleport is a small macOS menu bar app for running a local Xray-based proxy with VLESS, Trojan, WireGuard, and subscription-based connection imports.

## Features

- menu bar-only app
- bundled Xray runtime
- support for `vless://`, `trojan://` and `wireguard://` links, and WireGuard `[Interface]` configuration files
- support for `http://` and `https://` subscription URLs that fetch and import multiple configs
- saved connections with persistent selection across launches
- lightweight server health checks with persisted sampled TCP latency and availability state
- dedicated Settings window for connection and subscription management
- System Proxy mode for apps that respect macOS proxy settings
- VPN mode using Xray's privileged TUN inbound for full-device IPv4 routing

## Connection modes

### System Proxy

System Proxy mode starts the bundled Xray runtime as the current user, exposes local SOCKS/HTTP proxy ports, and enables macOS system proxy settings. It works for apps that honor system proxy configuration and does not require administrator approval.

### VPN

VPN mode starts Xray with its TUN inbound through Teleport's privileged helper. Teleport asks macOS for an admin password the first time it installs or updates the helper because creating a TUN interface and changing routes requires root access. After the helper is installed, normal connect/disconnect operations do not store or require the admin password.

Normal privileged commands use an authenticated launchd XPC Mach service with an exact-revision typed protocol. The helper validates the active console user and Teleport code signature before accepting the connection. Requests and responses are size-bounded and correlated by UUID; after an indeterminate start/stop reply, the app performs one status query and never automatically repeats the mutation.

VPN mode installs split default IPv4 routes:

```text
0.0.0.0/1   -> Xray utun
128.0.0.0/1 -> Xray utun
```

It also protects the selected proxy server with a host route through the original network gateway so Xray's own outbound connection does not loop back into the tunnel.

Disconnect other VPN apps before using VPN mode. If another VPN owns the default `utun` route, Teleport refuses to start VPN mode; use System Proxy mode when another VPN must remain active.

The helper accepts commands only from the active console user and verifies the Teleport app code signature before running privileged actions. It installs these root-owned files:

```text
/Library/PrivilegedHelperTools/dev.x.teleport.PrivilegedHelper
/Library/PrivilegedHelperTools/dev.x.teleport.xray
/Library/LaunchDaemons/dev.x.teleport.PrivilegedHelper.plist
```

Runtime diagnostics for VPN mode are written under:

```text
~/Library/Application Support/teleport/xray.log
~/Library/Application Support/teleport/xray-tun-session.json
/var/db/dev.x.teleport/xray-tun.log
/var/db/dev.x.teleport/xray-tun-control.log
```

## Build

Use the included `justfile` for command-line builds and packaging:

```bash
just build-debug
just build-release
just package
```

Useful recipes:

```bash
just --list
just app-path Debug
just version
just clean
```

You can also open `teleport.xcodeproj` in Xcode and run the `teleport` scheme.

## Project structure

Teleport is two executables plus a shared layer.

### Targets

- `teleport` — the menu bar app.
- `TeleportPrivilegedHelper` — a separate root daemon launched by launchd, used only for VPN mode.
- `Shared/` — compiled into both targets. Holds the XPC protocol with its exact revision number, the typed Codable request/response messages, payload size bounds, and their validation. This is the contract between app and root code.

### App target, from UI down to transport

- **UI**: `teleportApp.swift`, `MenuBarView`, `MenuBarIconView`, `ContentView`, `SettingsView`, and `Views/Settings/*` (connections, subscriptions, split tunneling with profiles and a rule tester, geodata, about, QR and share sheets).
- **ViewModel**: `ViewModels/AppViewModel` is the single orchestrator. It owns CRUD for connections, subscriptions, and split-tunnel rules, picks the mode, and drives connect/disconnect. `ConnectionHealthProbeQueue` schedules latency checks.
- **Models and persistence**: `TeleportModels.swift` defines the persisted snapshot (saved connections, subscriptions, split-tunnel rules). `Persistence/` stores it on disk and seeds it on first launch from `packaging/bundled-connections.json`.
- **Input pipelines**: `Parsing/` parses `vless://`, `trojan://` and `wireguard://` links, WireGuard configuration files, and geodata formats, and holds the split-tunnel rule and geodata matchers. `Subscriptions/` fetches subscription URLs and imports configs with duplicate filtering. `Geodata/` downloads and resolves geoip/geosite assets. `Health/` runs TCP latency probes.
- **Connection abstraction**: `Connection/` is the boundary the ViewModel talks to. `ConnectionProvider` exposes async connect/disconnect and one `ConnectionState` stream. `ConnectionRequest` carries mode-neutral inputs, including split-tunnel rules. `ConnectionProviderFactory` selects one of the two providers.
- **Config generation**: `XrayCore/XrayConfigurationWriter` turns a request into Xray JSON for either mode, including routing rules derived from split tunneling. It never starts processes or touches system state.
- **System Proxy mode**: `SystemProxy/` runs Xray as the current user, exposes local SOCKS/HTTP ports, and toggles macOS proxy settings. No root required.
- **VPN mode**: `VPN/` is the app side of the root path: `RootXrayConnectionProvider` → `XrayTunConnectionBackend` → `PrivilegedXrayRuntimeManager` → `PrivilegedHelperClient` → `XPCVPNHelperTransport`. The client encodes typed messages and performs one bounded status query after an indeterminate reply. The transport owns the `NSXPCConnection`, deadlines, and interruption handling. `XrayTunSessionState` caches correlation IDs for a later stop.
- **Helper installation**: `HelperInstallation/` verifies bundled artifacts and installs the helper, the root Xray binary, an installation manifest, and the LaunchDaemon plist through an admin-authorized shell. This is the only place that asks for a password. Geodata is not installed here; the helper reads the resolved geodata directory from the console user's Application Support at session start.

### Privileged helper target, from ingress to system

- `main.swift` starts an `NSXPCListener` on the Mach service name.
- `IPC/` is the trust boundary. `ClientAuthenticator` checks the active console user and the app code signature. The listener delegate, `HelperXPCService`, and `HelperCommandDispatcher` decode typed commands and serialize them. `HelperRequestLedger` dedupes by request UUID (128 entries, ten minutes).
- `Session/XrayTunController` validates fields and runs start/stop/status/diagnostics in order.
- `Xray/ManagedXrayProcess` manages the root Xray process: PID files, SIGTERM, bounded wait, SIGKILL.
- `Routing/XrayTunScriptBuilder` produces the shell commands for the utun, split default routes, the protected host route to the proxy server, DNS, and cleanup.
- `Support/` holds helper configuration, platform lookups, and bounded shell execution.

### Around the code

- `scripts/verify_*.swift` — standalone verification scripts, one per subsystem, run via `just verify-*`.
- `justfile` — build, DMG packaging, verification, and an architecture-layout check that keeps XPC details out of provider and UI layers.
- `openspec/` — capability specs and in-progress changes.
- `docs/` — source-layout reference and design specs.

## Runtime architecture

`AppViewModel` drives both connection modes through the asynchronous `ConnectionProvider` API and one shared `ConnectionState` stream. Mode-specific providers keep System Proxy and privileged root-Xray lifecycle details below that boundary. The VPN layer hides `NSXPCConnection`, helper revisions, request IDs, and privileged session payloads from providers and UI code.

Phase 3 correlation and helper request deduplication are memory-bounded, not authoritative persisted root ownership. Authoritative sessions/route journals and `SMAppService` installation remain separate future phases.

See [`docs/runtime-source-layout.md`](docs/runtime-source-layout.md) for the app/helper source boundaries, transitional backend adapters, current trust boundary, future-phase exclusions, dependency direction, and verification entry points.

## Built-in subscriptions and configs

Initial subscriptions and manual configs are defined in:

```text
packaging/bundled-connections.json
```

On first launch only, Teleport seeds a missing user state file from this bundled JSON. Subscription entries support `url`, `displayName`, `autoUpdateIntervalMinutes`, and `filterDuplicateImports`. Manual config entries support `link` and optional `displayName`.

## Verification scripts

Use the `justfile` to run focused verification scripts:

```bash
just verify
just verify-core
just verify-subscription-support
just verify-connection-health
```
