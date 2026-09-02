# Xray bundling and release notes

## Bundled runtime layout

The app now expects these bundled resources under the app target directory:

- `teleport/Resources/xray` — arm64 executable used as the bundled Xray runtime
- `teleport/Resources/xray-assets/geoip.dat`
- `teleport/Resources/xray-assets/geosite.dat`

The runtime manager resolves `xray` from the main bundle and sets `XRAY_LOCATION_ASSET` to the bundled `xray-assets` directory before launch.

## Runtime source boundaries

- `teleport/XrayCore` builds Xray JSON and has no process or privilege code.
- `teleport/Connection` defines the asynchronous provider API and shared connection state consumed by `AppViewModel`.
- `teleport/SystemProxy` owns the System Proxy provider, user Xray process, and macOS proxy settings.
- `teleport/VPN` owns the root-Xray provider and app-side privileged VPN orchestration.
- `teleport/HelperInstallation` owns the current helper deployment path.
- `teleport/Geodata` owns geodata selection and updates.
- `TeleportPrivilegedHelper` contains root-only IPC, process, and route code.

The synchronous System Proxy and VPN backends are transitional adapters below `BackendConnectionProvider`. The root provider still uses the existing Unix-socket helper protocol and app-side session identity. XPC, authoritative helper sessions, and `SMAppService` registration are planned follow-up work, not current release behavior.

## Runtime refresh notes

The current bundled runtime was copied from a local Homebrew-installed Xray distribution.

If the bundled runtime is refreshed later, replace both the executable and the asset directory together so the binary and data files stay in sync.

## Packaging considerations

- The bundled executable must remain executable inside the built app bundle.
- Release builds will require valid code signing for the app and any embedded executable content.
- Hardened runtime and notarization should be validated specifically with the bundled Xray binary in place.
- If App Sandbox stays enabled, verify that launching the bundled executable and changing system proxy settings still works in the intended distribution model.

## Proxy management considerations

- Proxy changes are currently implemented through `/usr/sbin/networksetup`.
- This affects macOS network services outside the app process and should be tested on real user environments.
- A failed proxy update should always be recoverable by disabling the proxy from the app or manually resetting macOS proxy settings.

## Verification status

### Completed from CLI

A Swift smoke-check script is available at `scripts/verify_core.swift` and currently verifies:

- valid VLESS parsing
- malformed/unsupported VLESS rejection
- Xray JSON config generation
- startup failure behavior when no bundled runtime is present in the executing bundle
- proxy enablement rejection before runtime readiness

Run it with:

```bash
just verify-core
```

### Still required in Xcode / app runtime

The full end-to-end product flow still needs manual verification in the actual macOS app build:

1. Launch the menu bar app
2. Save a working VLESS link
3. Start bundled Xray
4. Enable system proxy
5. Confirm traffic routes through the local proxy endpoint
6. Disable proxy
7. Stop Xray

Run `just verify` before release to execute the focused checks and fresh Xcode builds. The end-to-end proxy and VPN traffic flows above still require manual validation on a real macOS host.
