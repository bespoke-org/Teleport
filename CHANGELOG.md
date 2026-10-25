# Changelog

Format is based on [_Keep a changelog_](https://keepachangelog.com) and uses
[_Semantic versioning_](https://semver.org).

## [Unreleased]
### Added
- Split tunneling: destination rules, geosite category rules, custom geosite/geoip sources, named profiles with a per-profile default action, and a rule tester that matches against geodata. A rule can name the connection its traffic leaves through, and a session dials every connection the active rules route through.
- WireGuard connections from `wireguard://` links and `[Interface]` files. Names routed to a peer are resolved through that peer's own DNS servers.
- Hysteria 2 connections from `hy2://` links and subscriptions, with obfuscation and port hopping.
- Subscriptions can carry standalone Xray JSON profiles (VLESS and Trojan) alongside URI lists.
- Saved connections can be renamed; the name survives subscription refreshes. A manually added connection's link or `[Interface]` text can be edited; it keeps its id and the split-tunnel rules that point at it.
- The server can be switched while connected or connecting.
- macOS 15 is supported.
- TUN mode routes IPv6 and DNS through the tunnel. IPv6 is only claimed when the uplink has global IPv6.
- Leak guard: pf rules keep traffic off the physical uplink while a TUN session is being rebuilt, after a wake or an uplink change. Settings has a switch for it; it is off by default.
- A TUN session is rebuilt when the machine wakes from sleep or the uplink changes, and torn down by the helper when its Xray exits.
- A log that outlives the session it describes, readable from the Nerd shit settings page.
- The menu shows when a connect is installing the helper.
- Plain-TLS links use a browser-like TLS fingerprint.
- `scripts/fetch-xray.sh` downloads the official Xray release for both architectures, checks each archive against the published digest and joins them with `lipo` into the bundled executable, which is compared with the pinned digest.
- Release builds of the app and the privileged helper are universal (arm64 and x86_64); Debug builds stay host-only. Intel Macs were previously unsupported.
- The privileged helper can be removed from Settings > General (disconnects first, one administrator prompt), or with `just uninstall-helper` / `scripts/uninstall.sh` when the app is already gone.

### Changed
- The bundled community subscription lists are no longer imported on first launch. The Connections settings page offers them, with a note on who runs those servers.
- The Team ID used for signing and for the app/helper signature checks comes from `Config/Local.xcconfig` instead of the project file and source.
- The app talks to the privileged helper over an authenticated launchd XPC Mach service with typed, size-bounded messages. The previous helper installation is removed with `just reset-legacy-privileged-helper`.
- Bundled Xray runtime updated to 26.10.21, as a universal (arm64 and x86_64) executable.
- The Xray executable is no longer kept in the repository. `just build` fetches it with `scripts/fetch-xray.sh` when it is missing or does not match the pin.
- A rebuilt helper is detected by its code-directory hash; a rebuild that only re-signs the helper no longer asks for an administrator password.
- The helper is installed before a connect changes anything else on the machine, and a failed install puts the previous installation back.
- The start script undoes its routes and stops Xray on any failure, including one `set -e` stops on.
- Xray owns DNS for the tunnel; QUIC is blocked in tunnel routing so domain rules see the name.
- Proxy mode gives Xray the same geodata TUN mode gets.
- Saved state: a snapshot this build cannot read is never overwritten, a save is never the only copy, and the snapshot and its backup copies are files encrypted with a key kept in the Keychain, so an update asks for the Keychain password once instead of once per copy.
- `just install` installs the Release build into /Applications, quitting and relaunching a running Teleport; `just build-release` only builds; `just coverage` reports line coverage of the tests. The checks run as XCTest bundles: `just test` runs all of them, `just test-case <Class>` one class.
- The connection mode formerly called VPN is called TUN in the UI and the docs.
- TUN mode works in ad hoc signed builds after an administrator approves the build; a changed build asks again.
- The menu bar popover no longer has the Connection and Actions headings or the Open Settings button.

### Fixed
- Health probes no longer report what they did not measure.
- Secrets are kept out of the log.
- The control log and the tunnel Xray log are read through the helper; the previous tunnel log is kept instead of truncated.
- Polling loops use a clock that stops during sleep; waits for `dscacheutil` and `route` are capped at 5 seconds.
- A disconnect or quit cancels a connect that has not touched the machine yet; a quit finishes after 20 seconds when teardown does not return.
- Only one deferred proxy restore runs at a time, with a pause after a failure.
- A session is marked lost only after two missed checks, and the log says what each miss saw.
- Helper script failures name the script, its exit status and its stderr.
- The Settings window takes focus when opened from the menu bar; split-tunnel rules can be reordered again; the About page's Xray version probe no longer blocks the window.
- System proxy settings are read through SystemConfiguration and written only when they change.
- Geodata is validated before it reaches the helper.
- Direct traffic no longer loops back into Xray (`routeOnly` sniffing).
- The About page shows both authors and no longer falls back to a stale version string.
- Hostnames with Cyrillic labels are shown decoded instead of as punycode.
- Credentials and names containing percent sequences are decoded the same way on every macOS version.
- UDP connections in TUN mode, WireGuard included: Xray 26.10.21 failed every UDP dial on macOS (XTLS/Xray-core#7228).

## [0.3.0] - 2026-05-10
### Added
- Added General settings for launch at login, subscription config ordering, menu bar picker latency display, and menu bar icon animation.
- Added latency-based ordering for subscription configs in Settings and the menu bar picker.
- Added a subtle animated menu bar icon with cached portal particle frames.
- Added app icon, helper version, copyright, and license information to the About settings page.

### Changed
- Reworked Settings to use a native macOS sidebar/form layout.
- Simplified Nerd Shit settings to focus on logs with direct refresh and copy actions.
- Improved Teleport mode labeling and disabled mode changes while a connection session is active.
- Updated bundled subscription defaults.

### Fixed
- Stabilized the menu bar connection picker during subscription and health updates.
- Avoided blocking the UI when switching Teleport modes while disconnected.
- Disabled subscription health-check actions while checks are queued or running.

## [0.2.0] - 2026-05-10
### Added
- VPN mode is now the default connection mode.
- Bundled subscription sources are seeded on first launch.

### Changed
- Privileged helper runtime state, VPN logs, and VPN config now live under a root-owned private helper directory.
- App configuration secrets are migrated from plaintext state to Keychain-backed storage.
- VPN logs are read through authenticated helper IPC instead of direct world-readable files.

### Fixed
- Hardened privileged helper request validation, peer authorization, process termination, and shell output handling.
- Verified privileged install artifacts before installing helper/Xray binaries as root.
- Rejected duplicate connection query parameters instead of crashing on malformed subscription links.
- Improved subscription list display and duplicate display-name handling.

## [0.1.0] - 2025-05-07
### Added
- Initial version
