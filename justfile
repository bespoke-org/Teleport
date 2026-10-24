set shell := ["bash", "-euo", "pipefail", "-c"]

project := "teleport.xcodeproj"
scheme := "teleport"
app_name := "Teleport"
helper_name := "dev.x.teleport.PrivilegedHelper"
derived_data := "build/DerivedData"
dist_dir := "build/dist"
destination := "platform=macOS,arch=arm64"
# Extra swiftc flags for the verify binaries; `coverage` sets the profiling ones.
verify_flags := ""
coverage_dir := "build/coverage"
verify_sources := "teleport/TeleportModels.swift teleport/App/*.swift teleport/Connection/*.swift teleport/Parsing/*.swift teleport/Persistence/*.swift teleport/Subscriptions/*.swift teleport/XrayCore/*.swift teleport/SystemProxy/*.swift teleport/TUN/*.swift teleport/HelperInstallation/*.swift teleport/Geodata/*.swift teleport/Health/*.swift teleport/ViewModels/*.swift Shared/*.swift"

# List available recipes
default:
    @just --list

# Remove build and packaging artifacts
clean:
    rm -rf {{derived_data}} {{dist_dir}}

# Build the app. Usage: just build [Debug|Release]
build configuration="Debug":
    xcodebuild \
      -project {{project}} \
      -scheme {{scheme}} \
      -configuration {{configuration}} \
      -destination '{{destination}}' \
      -derivedDataPath {{derived_data}} \
      build

# Build Debug
build-debug:
    just build Debug

# Build Release and install it into /Applications
build-release:
    just build Release
    rm -rf "/Applications/{{app_name}}.app"
    ditto "{{derived_data}}/Build/Products/Release/{{app_name}}.app" "/Applications/{{app_name}}.app"

# Print the built .app path. Usage: just app-path [Debug|Release]
app-path configuration="Release":
    @echo "{{derived_data}}/Build/Products/{{configuration}}/{{app_name}}.app"

# Print the Release app version from the built bundle
version: build-release
    @/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '{{derived_data}}/Build/Products/Release/{{app_name}}.app/Contents/Info.plist'

# Build and open the app. Usage: just run [Debug|Release]
run configuration="Debug": (build configuration)
    open "{{derived_data}}/Build/Products/{{configuration}}/{{app_name}}.app"

# Build Release and create a versioned .app copy plus .dmg in build/dist
package: build-release
    #!/usr/bin/env bash
    set -euo pipefail

    APP="{{derived_data}}/Build/Products/Release/{{app_name}}.app"
    DIST="{{dist_dir}}"

    test -d "$APP"
    test -x "$APP/Contents/Resources/xray"
    test -x "$APP/Contents/Library/PrivilegedHelperTools/{{helper_name}}"

    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
    PACKAGE_NAME="{{app_name}}-$VERSION"
    PACKAGE_APP="$DIST/$PACKAGE_NAME.app"
    DMG_ROOT="$DIST/dmg-root"
    PACKAGE_DMG="$DIST/$PACKAGE_NAME.dmg"
    RW_DMG="$DIST/$PACKAGE_NAME-rw.dmg"
    MOUNT_DIR=""

    cleanup() {
      if [[ -n "${MOUNT_DIR:-}" && -d "$MOUNT_DIR" ]]; then
        hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
      fi
      rm -rf "$DMG_ROOT" "$RW_DMG"
    }
    trap cleanup EXIT

    mkdir -p "$DIST"
    rm -rf "$PACKAGE_APP" "$DMG_ROOT" "$PACKAGE_DMG" "$RW_DMG"

    ditto "$APP" "$PACKAGE_APP"

    mkdir -p "$DMG_ROOT/.background"
    ditto "$APP" "$DMG_ROOT/{{app_name}}.app"
    ln -s /Applications "$DMG_ROOT/Applications"

    DMG_BACKGROUND="${DMG_BACKGROUND:-packaging/dmg-background.png}"
    cp "$DMG_BACKGROUND" "$DMG_ROOT/.background/dmg-background.png"

    hdiutil create \
      -volname "{{app_name}}" \
      -srcfolder "$DMG_ROOT" \
      -ov \
      -format UDRW \
      -fs HFS+ \
      "$RW_DMG"

    MOUNT_DIR=$(hdiutil attach "$RW_DMG" -nobrowse -noverify | awk '/Apple_HFS/ {for (i = 3; i <= NF; i++) printf "%s%s", (i == 3 ? "" : OFS), $i; print ""; exit}')
    if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
      echo "Failed to mount writable DMG" >&2
      exit 1
    fi
    chflags hidden "$MOUNT_DIR/.background" || true

    osascript <<EOF
    tell application "Finder"
      set dmgFolder to POSIX file "$MOUNT_DIR" as alias
      set backgroundFile to POSIX file "$MOUNT_DIR/.background/dmg-background.png" as alias
      open dmgFolder
      delay 0.2
      set dmgWindow to Finder window 1
      set current view of dmgWindow to icon view
      set toolbar visible of dmgWindow to false
      set statusbar visible of dmgWindow to false
      set bounds of dmgWindow to {80, 80, 740, 496}
      set viewOptions to icon view options of dmgWindow
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 128
      set background picture of viewOptions to backgroundFile
      set position of item "{{app_name}}.app" of dmgWindow to {170, 194}
      set position of item "Applications" of dmgWindow to {490, 194}
      update dmgFolder without registering applications
      delay 1
      close dmgWindow
    end tell
    EOF

    sync
    hdiutil detach "$MOUNT_DIR" -quiet
    MOUNT_DIR=""
    sleep 1

    hdiutil convert "$RW_DMG" \
      -format UDZO \
      -imagekey zlib-level=9 \
      -o "$PACKAGE_DMG" \
      -ov

    rm -rf "$DMG_ROOT" "$RW_DMG"
    trap - EXIT

    echo "Packaged app: $PACKAGE_APP"
    echo "Packaged dmg: $PACKAGE_DMG"

# Build Release package and open build/dist in Finder
package-open: package
    open {{dist_dir}}

# Run all verification scripts after an Xcode build, so the privileged helper target
# and app copy/sign phases are checked alongside the lightweight Swift scripts.
verify: build-debug verify-core verify-subscription-support verify-connection-health verify-connection-provider verify-split-tunneling verify-geodata verify-persistence verify-uplink-reconciliation verify-leak-guard verify-xpc-protocol verify-helper-request-ledger verify-helper-command-dispatch verify-helper-xpc-endpoint verify-xpc-transport verify-privileged-helper-client verify-mach-service-installation

# Run core parser/config verification
verify-core:
    swiftc {{verify_flags}} {{verify_sources}} scripts/verify_core.swift -o /tmp/teleport-verify-core
    /tmp/teleport-verify-core

# Run subscription import verification
verify-subscription-support:
    swiftc {{verify_flags}} {{verify_sources}} scripts/verify_subscription_support.swift -o /tmp/teleport-verify-subscription-support
    /tmp/teleport-verify-subscription-support

# Run connection health metadata verification
verify-connection-health:
    swiftc {{verify_flags}} {{verify_sources}} scripts/verify_connection_health.swift -o /tmp/teleport-verify-connection-health
    /tmp/teleport-verify-connection-health

# Run connection provider state and presentation verification
verify-connection-provider:
    swiftc {{verify_flags}} {{verify_sources}} scripts/verify_connection_provider.swift -o /tmp/teleport-verify-connection-provider
    /tmp/teleport-verify-connection-provider

# Run split-tunnel rule classification/matching/routing verification
verify-split-tunneling:
    swiftc {{verify_flags}} {{verify_sources}} TeleportPrivilegedHelper/Support/HelperPlatform.swift TeleportPrivilegedHelper/Routing/XrayTunScriptBuilder.swift scripts/verify_split_tunneling.swift -o /tmp/teleport-verify-split-tunneling
    /tmp/teleport-verify-split-tunneling

# Run geodata settings/model verification
verify-geodata:
    swiftc {{verify_flags}} {{verify_sources}} scripts/verify_geodata.swift -o /tmp/teleport-verify-geodata
    /tmp/teleport-verify-geodata

# Run ConfigurationStore Keychain-failure-handling verification
verify-persistence:
    swiftc {{verify_flags}} {{verify_sources}} scripts/verify_persistence.swift -o /tmp/teleport-verify-persistence
    /tmp/teleport-verify-persistence

# Check how a running session reacts to the uplink underneath it changing
verify-uplink-reconciliation:
    swiftc {{verify_flags}} {{verify_sources}} scripts/verify_uplink_reconciliation.swift -o /tmp/teleport-verify-uplink-reconciliation
    /tmp/teleport-verify-uplink-reconciliation

# Check the pf ruleset that keeps traffic off the uplink between sessions
verify-leak-guard:
    swiftc {{verify_flags}} Shared/LeakGuardRuleset.swift Shared/TUNHelperXPCProtocol.swift teleport/TUN/ProbeHostExemptions.swift scripts/verify_leak_guard.swift -o /tmp/teleport-verify-leak-guard
    /tmp/teleport-verify-leak-guard

# Verify the shared privileged-helper XPC protocol and payload bounds
verify-xpc-protocol:
    swiftc {{verify_flags}} Shared/*.swift scripts/verify_xpc_protocol.swift -o /tmp/teleport-verify-xpc-protocol
    /tmp/teleport-verify-xpc-protocol

# Verify bounded same-daemon privileged-helper request deduplication
verify-helper-request-ledger:
    swiftc {{verify_flags}} Shared/*.swift TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift scripts/verify_helper_request_ledger.swift -o /tmp/teleport-verify-helper-request-ledger
    /tmp/teleport-verify-helper-request-ledger

# Verify typed privileged-helper command dispatch and request deduplication
verify-helper-command-dispatch:
    swiftc {{verify_flags}} Shared/*.swift TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift TeleportPrivilegedHelper/IPC/HelperCommandExecuting.swift TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift scripts/verify_helper_command_dispatch.swift -o /tmp/teleport-verify-helper-command-dispatch
    /tmp/teleport-verify-helper-command-dispatch

# Verify the authenticated privileged-helper XPC endpoint composition
verify-helper-xpc-endpoint:
    swiftc {{verify_flags}} Shared/*.swift TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift TeleportPrivilegedHelper/IPC/HelperCommandExecuting.swift TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift TeleportPrivilegedHelper/IPC/HelperXPCService.swift scripts/verify_helper_xpc_endpoint.swift -o /tmp/teleport-verify-helper-xpc-endpoint
    /tmp/teleport-verify-helper-xpc-endpoint

# Verify app-side XPC connection ownership and transport races
verify-xpc-transport:
    swiftc {{verify_flags}} Shared/*.swift teleport/TUN/TUNHelperTransport.swift teleport/TUN/XPCTUNHelperTransport.swift scripts/verify_xpc_transport.swift -o /tmp/teleport-verify-xpc-transport
    /tmp/teleport-verify-xpc-transport

# Verify the typed privileged-helper client and bounded reconciliation
verify-privileged-helper-client:
    swiftc {{verify_flags}} {{verify_sources}} scripts/verify_privileged_helper_client.swift -o /tmp/teleport-verify-privileged-helper-client
    /tmp/teleport-verify-privileged-helper-client

# Verify the LaunchDaemon Mach service and explicit legacy reset tooling
verify-mach-service-installation:
    swiftc {{verify_flags}} {{verify_sources}} scripts/verify_mach_service_installation.swift -o /tmp/teleport-verify-mach-service-installation
    /tmp/teleport-verify-mach-service-installation

# Line coverage of the verify scripts over the sources they compile (views and most helper sources are not among them)
coverage:
    rm -rf "{{coverage_dir}}" && mkdir -p "{{coverage_dir}}"
    LLVM_PROFILE_FILE="{{coverage_dir}}/%m.profraw" just verify_flags="-profile-generate -profile-coverage-mapping" verify-core verify-subscription-support verify-connection-health verify-connection-provider verify-split-tunneling verify-geodata verify-persistence verify-uplink-reconciliation verify-leak-guard verify-xpc-protocol verify-helper-request-ledger verify-helper-command-dispatch verify-helper-xpc-endpoint verify-xpc-transport verify-privileged-helper-client verify-mach-service-installation
    xcrun llvm-profdata merge -sparse "{{coverage_dir}}"/*.profraw -o "{{coverage_dir}}/merged.profdata"
    xcrun llvm-cov report $(for binary in /tmp/teleport-verify-*; do printf -- '-object %s ' "$binary"; done) -instr-profile "{{coverage_dir}}/merged.profdata" -ignore-filename-regex='scripts/' | tee "{{coverage_dir}}/report.txt"

# Explicitly remove the legacy helper installation before development cutover
reset-legacy-privileged-helper:
    sudo sh scripts/reset_legacy_privileged_helper.sh


# Remove the installed privileged helper and its root-owned files (asks for sudo)
uninstall-helper:
    sudo bash scripts/uninstall.sh
