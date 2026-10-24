# Teleport

[![Buy us some tokens](https://img.shields.io/badge/buy%20us%20some%20tokens-USDT-26A17B)](#buy-us-some-tokens)

Teleport is a macOS menu bar client for the [Xray](https://github.com/XTLS/Xray-core) proxy core. It keeps a list of VLESS, Trojan and WireGuard connections, imports them from subscription URLs, and sends traffic through the selected one either by setting the macOS system proxy or by routing the whole machine through a TUN interface.

<!-- Screenshot: the menu bar popover with the connection picker and the connect button. Add the image as docs/screenshot-menu.png and reference it here. -->

## Buy us some tokens

Despite much of Teleport's code being written by LLMs, we usually read the code they produce, and keeping the project working takes our time and attention.

You can support us with USDT. Check the network before sending: a transfer on a network not listed here can be lost.

| Network | Address |
|---|---|
| TRON (TRC20) | `TFKx2Mhwqkx94LSq9zbYAXj27yxPcTwqG1` |
| Ethereum (ERC20), BNB Chain (BEP20) | `0xe87761Cc781270389D2F55e2c7bA64E2cebb78E2` |

## Features

- Connections from `vless://`, `trojan://` and `wireguard://` links and from WireGuard `[Interface]` configuration files.
- Subscriptions from `http://` and `https://` URLs, with periodic refresh and duplicate filtering.
- Two connection modes: **System Proxy** (no administrator rights) and **TUN** (the whole machine is routed through a tunnel interface; needs a root helper).
- Split tunneling: rules by domain, IP range, geosite category or geoip country, grouped in named profiles. A rule can send its traffic through a different saved connection, so one session can dial several servers.
- Geodata (`geoip.dat`, `geosite.dat`) bundled, with optional downloads from a source of your choice.
- An optional pf-based leak guard (off by default) that keeps traffic off the physical network while a TUN session is being rebuilt.
- TCP latency checks for every connection, shown in the menu bar picker.

## Requirements

- macOS 26 or later (the project's deployment target).
- Apple Silicon or Intel.
- To build: Xcode 26 or later, and optionally [just](https://github.com/casey/just) for the command-line recipes.
- TUN mode asks for an administrator password once, to install the helper.

## Install

There is no signed or notarized download yet. Build from source:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
# edit Config/Local.xcconfig: set DEVELOPMENT_TEAM (see Development > Signing)
just install              # builds Release, installs Teleport.app into /Applications
```

Or open `teleport.xcodeproj` in Xcode and run the `teleport` scheme.

Without a `DEVELOPMENT_TEAM` the build is signed ad hoc. System Proxy mode works in such a build; TUN mode refuses to install the helper, because the app and the helper verify each other by Team ID (see Security model and Development > Signing).

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

DNS is answered by Xray inside the tunnel; the helper publishes a resolver entry for it (`State:/Network/Service/dev.x.teleport/DNS`) and removes it on stop. Split-tunnel rules with the `direct` action leave through the physical interface. When the machine wakes from sleep or the network changes, the session is torn down and rebuilt on the new uplink.

If another VPN owns the default `utun` route, Teleport refuses to start TUN mode. Disconnect it first, or use System Proxy mode.

## Security model

### What runs as root

TUN mode installs a LaunchDaemon, `dev.x.teleport.PrivilegedHelper`, which runs as root and stays resident. Its whole code is in `TeleportPrivilegedHelper/`. It does six things on request: report status, start a session, stop a session, read its own logs, engage the leak guard, release the leak guard. Starting a session means running the root copy of Xray with a configuration the app sends over, installing the routes above and publishing the DNS entry. The shell it runs for this is generated in `Routing/XrayTunScriptBuilder.swift` with every value quoted; the app supplies data (the Xray configuration, the server addresses), not commands.

The helper accepts an XPC connection only when both hold:

- the caller runs as the user currently at the console (not root, not another logged-in user);
- the caller's code signature satisfies `identifier "dev.x.teleport" and anchor apple generic and certificate leaf[subject.OU] = <Team ID>`, where the Team ID is read from the helper's own signature.

Requests and responses are typed, size-bounded messages; the helper refuses what does not parse. Each request carries an ID, and a repeated ID within ten minutes gets the first answer again instead of a second execution.

### What the app checks before installing anything

Before the administrator prompt, the app runs `codesign --verify --strict` against the same Team ID requirement on itself and on the bundled helper, and compares the bundled Xray against a SHA-256 pinned in `teleport/HelperInstallation/BundledArtifactPolicy.swift`. The install transaction repeats those checks on the staged copies as root. A failed install puts the previous installation back. These checks establish that what gets installed is what this build shipped; they say nothing about notarization, which the project does not have yet.

The helper and its files:

```text
/Library/PrivilegedHelperTools/dev.x.teleport.PrivilegedHelper
/Library/PrivilegedHelperTools/dev.x.teleport.xray
/Library/PrivilegedHelperTools/dev.x.teleport.installation.json
/Library/LaunchDaemons/dev.x.teleport.PrivilegedHelper.plist
/var/db/dev.x.teleport/                      (session state, config, logs; root only)
/var/log/teleport-privileged-helper.log
```

### Leak guard

While TUN mode is on, a pf ruleset in the anchor `com.apple/dev.x.teleport` blocks outbound traffic that would otherwise leave on the physical interface. It allows: loopback; the tunnel interface; DHCP; private, link-local and multicast IPv4 destinations; link-local, unique-local and multicast IPv6 destinations; DNS to any resolver on ports 53 and 853; the proxy servers of the current session; and, during a session, traffic of root processes, because Xray's `direct` outbound runs as root. Everything else outbound, IPv4 and IPv6, is dropped. Inbound traffic is not filtered.

The guard is held on a lease: the app renews it every 45 seconds and the helper drops it after 180 seconds without renewal, so a crashed app leaves the machine without network for at most three minutes. The helper also drops a guard it finds at its own start. The switch is in Settings > General; it is off by default.

### Stored data

Connection links, which contain credentials, are stored in the login Keychain (service `dev.x.teleport.configuration`), not in plain files. Logs are written under `~/Library/Application Support/teleport/` and, for the helper, under `/var/db/dev.x.teleport/`.

## Uninstall

1. If you used TUN mode, remove the helper in Settings > General > TUN mode helper > Uninstall... It asks for an administrator password and also drops the leak guard rules.
2. Quit Teleport and delete `/Applications/Teleport.app`.

If the app is already gone, run `scripts/uninstall.sh` from a checkout (or `just uninstall-helper`). It removes the same files and lists what Teleport keeps in your home folder: `~/Library/Application Support/teleport/` and the `dev.x.teleport.configuration` item in Keychain.

If the machine has no network after a crash, the leak guard is still loaded. It expires within three minutes, or drop it now with `sudo pfctl -a com.apple/dev.x.teleport -F all`.

## Development

### Signing

`DEVELOPMENT_TEAM` is the Apple Developer Team ID that signs the app and the helper. TUN mode needs it: the helper accepts only a caller whose certificate has the same Team ID in its `OU` field.

A free Personal Team is enough, since the project uses no entitlements that need a provisioning profile. Add your Apple ID in Xcode > Settings > Accounts; Xcode creates the team and an "Apple Development" certificate. The Team ID is the `OU` of that certificate:

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
# subject=UID=..., CN=Apple Development: you@example.com (K7LM2PQ9RS), OU=ABCDE12345, ...
```

Here the Team ID is `ABCDE12345`. The ten characters in parentheses in the certificate name identify the certificate, not the team.

`Config/Local.xcconfig` (ignored by git) holds the per-developer `DEVELOPMENT_TEAM`; `Config/Teleport.xcconfig` includes it and is the base configuration of the project. There is no other place where the Team ID appears: the app and the helper derive the signature requirement from their own signatures at run time (`Shared/TeleportCodeSigning.swift`).

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

The script downloads the arm64 and x86_64 release archives, checks each against the digest XTLS publishes, joins them with `lipo` into one universal executable and compares it with the pin in `BundledArtifactPolicy.swift`; when upgrading, update the pin to the digest it prints and run it again. The executable is not kept in git: `just build` runs the script when `teleport/Resources/xray` is missing or does not match the pin, and a build from Xcode fails until the script has been run once. Release builds are universal (`just build-release`), Debug builds are host-only. Licenses of the bundled components are in `THIRD_PARTY_NOTICES.md`.

Formatting follows `.swift-format` (four-space indent, 160 columns). Check with `swift format lint -r teleport Shared TeleportPrivilegedHelper scripts`.

### Tests

There is no XCTest target. Each subsystem has a standalone program in `scripts/verify_*.swift` that is compiled with `swiftc` together with the sources it covers and run directly; a failed check stops the program with a message.

```bash
just verify                           # Debug build, then every verify script
just verify-core                      # link parsing and Xray config generation
just verify-split-tunneling           # rule matching, routing, helper scripts
just verify-leak-guard                # the pf ruleset
just verify-xpc-protocol              # app/helper message contract
just coverage                         # line coverage of the verify scripts
```

The remaining recipes are listed by `just --list`. None of them needs root or a logged-in GUI session; TUN connect/disconnect, helper installation and leak-guard behaviour on a real network are checked by hand (see `docs/xray-bundling-and-release.md`).

## Known limitations

- No signed download yet, build from source.
- Another VPN that owns the default `utun` route blocks TUN mode entirely.
- The leak guard lets DNS queries reach any resolver, and during a session it passes traffic of any root process, not only Xray.

## Comparison with other clients

Only what the other projects' own READMEs state is listed; a blank means the README does not say.

| | Teleport | [V2rayU](https://github.com/yanue/V2rayU) | [Hiddify](https://github.com/hiddify/hiddify-app) | [v2rayN](https://github.com/2dust/v2rayN) |
|---|---|---|---|---|
| Platforms | macOS | macOS | Android, iOS, Windows, macOS, Linux | Windows, Linux, macOS |
| Core | Xray | v2ray-core | sing-box | Xray, sing-box and others |
| Whole-device routing on macOS | TUN through a root helper, plus pf leak guard | System proxy only; the README points to Proxifier for apps that ignore it | TUN mode listed, platform not specified | |
| License | GPL-3.0-or-later | GPLv3 | GPL v3 with Hiddify's additional conditions (non-commercial use among them) | GPL-3.0 |
| Distribution | Source only | | App Store, DMG, PKG | |

Bug reports: https://github.com/bespoke-org/Teleport/issues
