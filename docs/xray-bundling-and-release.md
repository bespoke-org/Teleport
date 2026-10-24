# Xray bundling and release notes

## Bundled runtime layout

The app expects:

- `teleport/Resources/xray` — bundled universal (arm64 + x86_64) Xray executable; not kept in git, `scripts/fetch-xray.sh` creates it and `just build` runs that script when the file is missing or does not match the pin
- `teleport/Resources/xray-assets/geoip.dat`
- `teleport/Resources/xray-assets/geosite.dat`

The System Proxy runtime resolves these resources from the app bundle. TUN mode installation verifies and copies the approved runtime and assets into root-owned paths.

## Runtime boundaries

- `teleport/XrayCore` builds Xray JSON without process or privilege code.
- `teleport/Connection` defines the provider API and state consumed by `AppViewModel`.
- `teleport/SystemProxy` owns the unprivileged provider, user Xray process, and proxy settings.
- `teleport/TUN` owns the root-Xray provider, typed helper client, and XPC transport.
- `teleport/HelperInstallation` owns the transitional administrator installer.
- `TeleportPrivilegedHelper` is the separate root executable containing authenticated XPC ingress, synchronous command dispatch, process lifecycle, and routes.

The app and helper compile one Foundation-only exact-revision protocol. Revision 8 exposes four explicit `Data`/`NSError` XPC methods over launchd Mach service `dev.x.teleport.helper`. Requests and responses are typed Codable values with request/session UUIDs and fixed bounds. The helper authenticates the active console UID and applies the Teleport code-signing requirement before activating a connection.

The helper keeps a bounded, ten-minute/128-entry in-memory request ledger for same-daemon deduplication. The app performs one status reconciliation after an interrupted, invalidated, or timed-out start/stop and never automatically retransmits that mutation.

These UUIDs and observations are correlation only. Helper state is not persisted authoritatively across daemon restart, route cleanup is not journaled/session-owned, and process/routing operations remain synchronous. Those are Phase 4 concerns. `SMAppService` installation remains Phase 5.

## Runtime refresh notes

WireGuard connections are Xray outbounds, not a separate engine: the bundled binary must be a build that includes the `wireguard` outbound, and macOS uses its userspace (gVisor) tunnel because `kernelMode` is Linux-only. Confirm after every runtime refresh with `xray run -test -c` against a config containing a WireGuard outbound; a build without it fails there rather than at connect time.

The bundled executable is a `lipo` of the `xray` files from the official `Xray-macos-arm64-v8a.zip` and `Xray-macos-64.zip` release assets; `scripts/fetch-xray.sh` downloads both, checks each against its published digest, joins them, and checks the result against the pin in `BundledArtifactPolicy.swift`. Refresh the executable and asset directory together so binary and data remain synchronized, then update the approved digest and repeat signing verification.

## Packaging considerations

- Preserve executable permissions inside the app bundle.
- App, helper, and bundled executable content require valid release signing.
- Validate hardened runtime and notarization with the bundled Xray binary.
- Release testing must check Developer ID signing and notarization separately from local administrator approval.
- The current installer still requests administrator authorization and writes the LaunchDaemon/helper/runtime directly; it is intentionally transitional.

### Signing and notarization: what the code checks, and what it cannot

The installer verifies the app and helper against their exact code-directory
hashes, and Xray against the SHA-256 pinned in `BundledArtifactPolicy`. It repeats
signature verification in the administrator transaction and verifies the staged
helper before installation. Administrator approval records both code hashes in
`/Library/PrivilegedHelperTools/dev.x.teleport.installation.json` alongside the
helper version and Xray hash. The manifest is installed atomically as root-owned,
mode 0644, and participates in installation rollback.

The helper rejects missing, invalid, outdated, symlinked, non-root-owned, or
writable approval files and unsafe parent directories. Each new XPC connection
must come from the active console user and satisfy the approved app's `cdhash`
requirement. Ad-hoc builds are supported. A changed app or helper needs approval
again; legacy manifests without an app hash require reinstallation.

This local approval does not establish distribution trust. Published artifacts
still need Developer ID signing, hardened runtime, notarization, and a stapled
ticket, checked with `spctl --assess --type execute` and `stapler validate`.
Installation continues to use the existing administrator-authorized `launchctl`
transaction.

## Manual release checks

Automated verification does not replace real macOS checks for:

1. explicit legacy-helper reset, fresh installation, and upgrade/cutover installation;
2. acceptance of the approved build and rejection of unsigned or different-build clients, including clients with the same bundle identifier;
3. System Proxy connect/disconnect;
4. TUN connect/disconnect and current IPv4 route cleanup;
5. WireGuard connect/disconnect against a real peer in both modes, including a large-transfer check for the MTU the peer advertises;
6. live helper interruption during status, start, and stop;
7. app termination during a pending request;
8. Fast User Switching and login-window behavior;
9. hardened-runtime and notarized distribution validation.

These checks remain release risks until actually performed; do not infer them from unit/source verification.

## Automated verification

Run:

```bash
just clean
just test
```

The suite checks shared protocol bounds/revision, helper ledger and dispatch, authenticated endpoint composition, client transport races, reconciliation behavior, Mach-service plist generation, architecture boundaries, both Debug builds, helper embedding, and signatures covered by the existing flow.
