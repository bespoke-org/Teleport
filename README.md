# Teleport

Teleport is a small macOS menu bar app for running a local Xray-based proxy with VLESS, Trojan, and subscription-based connection imports.

## Features

- menu bar-only app
- bundled Xray runtime
- support for `vless://` and `trojan://` links
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

## Runtime architecture

See [`docs/runtime-source-layout.md`](docs/runtime-source-layout.md) for the app/helper source boundaries, dependency direction, and verification entry points.

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
