<p align="center">
  <img src="teleport/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Teleport icon">
</p>

<h1 align="center">Teleport</h1>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15%2B-000000?logo=apple&logoColor=white" alt="macOS 15+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-GPL--3.0--or--later-blue" alt="License: GPL-3.0-or-later"></a>
  <a href="#buy-us-some-tokens"><img src="https://img.shields.io/badge/donate-USDT-26A17B?logo=tether&logoColor=white" alt="Donate USDT"></a>
</p>

Teleport is a macOS menu bar client for the [Xray](https://github.com/XTLS/Xray-core) proxy core. It keeps a list of VLESS, Trojan, Hysteria 2 and WireGuard connections, imports them from subscription URLs, and sends traffic through the selected one either by setting the macOS system proxy or by routing the whole machine through a TUN interface.

## Features

- Connections from `vless://`, `trojan://`, `hysteria2://` (`hy2://`) and `wireguard://` links and from WireGuard `[Interface]` configuration files. Hysteria 2 details are in [docs/hysteria2.md](docs/hysteria2.md).
- Subscriptions from `http://` and `https://` URLs, with periodic refresh and duplicate filtering. [WireGuard subscription formats](docs/wireguard-subscriptions.md).
- Two connection modes: **System Proxy** (no administrator rights) and **TUN** (the whole machine is routed through a tunnel interface; needs a root helper).
- Split routing: rules by domain, IP range, geosite category or geoip country, grouped in named profiles. A rule can send its traffic through a different saved connection, so one session can dial several servers.
- Geodata (`geoip.dat`, `geosite.dat`) bundled, with optional downloads from a source of your choice.
- An optional pf-based leak guard (off by default) that keeps traffic off the physical network while a TUN session is being rebuilt.
- TCP latency checks for every connection, shown in the menu bar picker.

## Requirements

- macOS 15 or later. Tested on macOS 27.
- Apple Silicon or Intel.
- To build: Xcode 26 or later, and optionally [just](https://github.com/casey/just) for the command-line recipes.
- TUN mode asks for an administrator password to install the helper and approve a changed build.

## Install

There is no signed or notarized download yet. Build from source:

```bash
just install              # builds Release, installs Teleport.app into /Applications
```

Or open `teleport.xcodeproj` in Xcode and run the `teleport` scheme.

Without a `DEVELOPMENT_TEAM` the build is signed ad hoc. Both System Proxy and TUN modes work. TUN mode asks an administrator to approve the app and helper build; updating either can require approval again.

On first launch the app has no connections. Add a link or a subscription URL in Settings > Connections. The same page can add two community subscription lists that ship with the app (`packaging/bundled-connections.json`, from [igareck/vpn-configs-for-russia](https://github.com/igareck/vpn-configs-for-russia)). They are not added on their own: the servers in those lists are run by people nobody here knows, and everything sent through them can be read or altered by whoever operates them.

## Connection modes

### System Proxy

Starts the bundled Xray as the current user, listens on local HTTP and SOCKS5 ports (8080 and 1080 by default) and enables the macOS system proxy for the active network service. Applications that ignore the system proxy are not routed. No root access is involved, and the proxy settings are restored on disconnect, on quit, and on the next launch if the app did not get to it.

### TUN

Starts Xray as root through Teleport's privileged helper with a TUN inbound, and routes the machine through it:

```text
0.0.0.0/1, 128.0.0.0/1   -> Teleport's utun          (IPv4)
::/1, 8000::/1           -> Teleport's utun          (IPv6, only when the uplink has global IPv6)
<each proxy server>/32   -> the original gateway    (so Xray's own connection stays outside the tunnel)
```

DNS is answered by Xray inside the tunnel; the helper publishes a resolver entry for it (`State:/Network/Service/dev.x.teleport/DNS`) and removes it on stop. Split routing rules with the `direct` action leave through the physical interface. When the machine wakes from sleep or the network changes, the session is torn down and rebuilt on the new uplink.

If another VPN owns the default `utun` route, Teleport refuses to start TUN mode. Disconnect it first, or use System Proxy mode.

#### Leak guard (optional, off by default)

Settings > General > Leak guard. When on, a pf ruleset (anchor `com.apple/dev.x.teleport`) drops any outbound traffic that would bypass the tunnel.

- Allowed: loopback, the tunnel interface, DHCP, local and link-local destinations, DNS (ports 53 and 853), the servers of the current session, and root processes (Xray's `direct` outbound runs as root).
- Everything else outbound, IPv4 and IPv6, is dropped. Inbound traffic is not filtered.
- The guard is held on a lease: the app renews it every 45 seconds, the helper releases it after 180 seconds without renewal. A crashed app leaves the machine offline for at most three minutes. The helper also releases a guard it finds at its own start.

## Security model

### What runs as root

TUN mode installs a LaunchDaemon (`dev.x.teleport.PrivilegedHelper`) that runs as root and stays resident. Source: `TeleportPrivilegedHelper/`.

- It can only: report status, start or stop a session, read its own logs, engage or release the leak guard.
- Starting a session runs the root copy of Xray with the configuration the app sends, installs the routes above and publishes the DNS entry. The app passes data, never commands.
- The caller must be the user at the console and match the app code-signing hash approved during installation. Approval is stored in a root-owned manifest; a changed build needs approval again.

### Stored data

Connection links, which contain credentials, are stored encrypted under `~/Library/Application Support/teleport/sealed/`, with the key in the login Keychain (service `dev.x.teleport.configuration`). Logs are written under `~/Library/Application Support/teleport/` and, for the helper, under `/var/db/dev.x.teleport/`.

## Uninstall

1. If you used TUN mode, remove the helper in Settings > General > TUN mode helper > Uninstall... It asks for an administrator password and also drops the leak guard rules.
2. Quit Teleport and delete `/Applications/Teleport.app`.

If the app is already gone, run `scripts/uninstall.sh` from a checkout (or `just uninstall-helper`). It removes the same files and lists what Teleport keeps in your home folder: `~/Library/Application Support/teleport/` and the `dev.x.teleport.configuration` item in Keychain.

If the machine has no network after a crash, the leak guard is still loaded. It expires within three minutes, or drop it now with `sudo pfctl -a com.apple/dev.x.teleport -F all`.

## Known limitations

- No signed download yet, build from source.
- Another VPN that owns the default `utun` route blocks TUN mode entirely.
- The leak guard lets DNS queries reach any resolver, and during a session it passes traffic of any root process, not only Xray.

Bug reports: https://github.com/bespoke-org/Teleport/issues

## Development

### Signing

No Apple account or Team ID is required for local TUN mode. The installer verifies the app and helper code signatures and the pinned Xray digest, then repeats verification during administrator-authorized installation. The helper accepts only the approved app build running as the active console user. Approval does not notarize the app for distribution.

To use an Apple signing certificate, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`. The optional file is ignored by git and applies to both targets. Ad hoc and Apple-signed builds use the same approval mechanism.

### Building

```bash
just --list                 # all recipes
just build-debug            # Debug build into build/DerivedData
just build-release          # Release build into build/DerivedData
just install                # Release build, installed into /Applications
just package                # Release build plus a .dmg in build/dist
just clean
```

To replace the bundled Xray with the official release build for a given version:

```bash
scripts/fetch-xray.sh v26.10.21
```

The script downloads the arm64 and x86_64 release archives, checks each against the digest XTLS publishes, joins them with `lipo` into one universal executable and compares it with the pin in `BundledArtifactPolicy.swift`; when upgrading, update the pin to the digest it prints and run it again. `scripts/bump-xray.sh vX.Y.Z` does the whole update: it fetches the release, writes the new pin and puts the version into this README, `THIRD_PARTY_NOTICES.md` and `CHANGELOG.md`. The `.github/workflows/xray-update.yml` workflow runs it through Updatecli once a day and opens a pull request when XTLS publishes a new stable release. The executable is not kept in git: `just build` runs the script when `teleport/Resources/xray` is missing or does not match the pin, and a build from Xcode fails until the script has been run once. Release builds are universal (`just build-release`), Debug builds are host-only. Licenses of the bundled components are in `THIRD_PARTY_NOTICES.md`.

Formatting follows `.swift-format` (four-space indent, 160 columns). Check with `swift format lint -r teleport Shared TeleportPrivilegedHelper teleportTests TeleportPrivilegedHelperTests`.

### Tests

```bash
just test
```

Checks are XCTest cases in `teleportTests/` (app and shared code) and `TeleportPrivilegedHelperTests/` (helper code); both bundles compile the sources they test, so no app or helper process runs. Run one class or method with `just test-case <Class>[/<method>]`, e.g. `just test-case CoreTests`, or press Cmd-U in Xcode. `just coverage` prints line coverage. Connecting, helper installation and the leak guard on a real network are tested by hand.

## Buy us some tokens

Although Teleport is built with LLMs, we put a lot of time and tokens into its stability and UX. If Teleport is useful to you, you can support that work with USDT.

Check the network before sending: a transfer on a network not listed here can be lost.

| Network | Address |
|---|---|
| TRON (TRC20) | `TFKx2Mhwqkx94LSq9zbYAXj27yxPcTwqG1` |
| Ethereum (ERC20), BNB Chain (BEP20) | `0xe87761Cc781270389D2F55e2c7bA64E2cebb78E2` |

## License

Teleport is licensed under GPL-3.0-or-later, see [`LICENSE`](LICENSE). Copyright (C) 2026 Michael Chernigin, Nikita Rydanov. Licenses of the bundled components are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
