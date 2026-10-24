set shell := ["bash", "-euo", "pipefail", "-c"]

project := "teleport.xcodeproj"
scheme := "teleport"
app_name := "Teleport"
helper_name := "dev.x.teleport.PrivilegedHelper"
derived_data := "build/DerivedData"
dist_dir := "build/dist"
# Debug builds target only the host architecture; Release builds are universal (arm64 + x86_64).
debug_destination := "platform=macOS,arch=" + `uname -m`
release_destination := "generic/platform=macOS"
# Extra swiftc flags for the test binaries; `coverage` sets the profiling ones.
test_flags := ""
coverage_dir := "build/coverage"
test_sources := "teleport/TeleportModels.swift teleport/App/*.swift teleport/Connection/*.swift teleport/Parsing/*.swift teleport/Persistence/*.swift teleport/Subscriptions/*.swift teleport/XrayCore/*.swift teleport/SystemProxy/*.swift teleport/TUN/*.swift teleport/HelperInstallation/*.swift teleport/Geodata/*.swift teleport/Health/*.swift teleport/ViewModels/*.swift Shared/*.swift"
# Scripts compiled with test_sources into the one test-app binary, plus the helper files they use.
test_app_sources := "TeleportPrivilegedHelper/Support/HelperPlatform.swift TeleportPrivilegedHelper/Routing/XrayTunScriptBuilder.swift scripts/test_app.swift scripts/test_core.swift scripts/test_subscription_support.swift scripts/test_connection_health.swift scripts/test_connection_provider.swift scripts/test_split_tunneling.swift scripts/test_geodata.swift scripts/test_persistence.swift scripts/test_uplink_reconciliation.swift scripts/test_privileged_helper_client.swift scripts/test_mach_service_installation.swift"

# List available recipes
default:
    @just --list

# Remove build and packaging artifacts
clean:
    rm -rf {{derived_data}} {{dist_dir}}

# Download teleport/Resources/xray unless it is already there and matches the pin in BundledArtifactPolicy.swift
fetch-xray:
    #!/usr/bin/env bash
    set -euo pipefail
    pin=$(sed -n 's/.*xraySHA256: "\([0-9a-f]\{64\}\)".*/\1/p' teleport/HelperInstallation/BundledArtifactPolicy.swift)
    if [[ -f teleport/Resources/xray && "$(shasum -a 256 teleport/Resources/xray | awk '{print $1}')" == "$pin" ]]; then
      exit 0
    fi
    scripts/fetch-xray.sh

# Build the app. Usage: just build [Debug|Release]
build configuration="Debug": fetch-xray
    xcodebuild \
      -project {{project}} \
      -scheme {{scheme}} \
      -configuration {{configuration}} \
      -destination '{{ if configuration == "Release" { release_destination } else { debug_destination } }}' \
      -derivedDataPath {{derived_data}} \
      build

# Build Debug
build-debug:
    just build Debug

# Build Release
build-release:
    just build Release

# Build Release and install it into /Applications, quitting and relaunching a running Teleport
install: build-release
    #!/usr/bin/env bash
    set -euo pipefail

    APP="{{derived_data}}/Build/Products/Release/{{app_name}}.app"
    TARGET="/Applications/{{app_name}}.app"
    STAGING="/Applications/.{{app_name}}.app.new"
    EXECUTABLE="$TARGET/Contents/MacOS/{{app_name}}"

    is_running() { pgrep -f "^$EXECUTABLE" >/dev/null; }

    WAS_RUNNING=false
    if is_running; then
      WAS_RUNNING=true
      # A quit removes the routes, DNS entry and system proxy settings the app set.
      osascript -e 'tell application id "dev.x.teleport" to quit'
      for _ in $(seq 1 20); do
        is_running || break
        sleep 0.5
      done
      if is_running; then
        echo "{{app_name}} did not quit within 10 seconds; quit it and run just install again" >&2
        exit 1
      fi
    fi

    rm -rf "$STAGING"
    trap 'rm -rf "$STAGING"' EXIT
    ditto "$APP" "$STAGING"
    rm -rf "$TARGET"
    mv "$STAGING" "$TARGET"
    trap - EXIT

    if [[ "$WAS_RUNNING" == true ]]; then
      open "$TARGET"
    fi

# Print the built .app path. Usage: just app-path [Debug|Release]
app-path configuration="Release":
    @echo "{{derived_data}}/Build/Products/{{configuration}}/{{app_name}}.app"

# Print the Release app version from the built bundle
version: (build "Release")
    @/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '{{derived_data}}/Build/Products/Release/{{app_name}}.app/Contents/Info.plist'

# Build and open the app. Usage: just run [Debug|Release]
run configuration="Debug": (build configuration)
    open "{{derived_data}}/Build/Products/{{configuration}}/{{app_name}}.app"

# Build Release and create a versioned .app copy plus .dmg in build/dist
package: (build "Release")
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
test: build-debug test-app test-hysteria test-leak-guard test-xpc-protocol test-helper-request-ledger test-helper-command-dispatch test-helper-xpc-endpoint test-xpc-transport

# Compile the scripts that need the app sources into one binary and run the named suites, or all of
# them. Usage: just test-app [suite...], e.g. just test-app core geodata
test-app *suites:
    swiftc {{test_flags}} {{test_sources}} {{test_app_sources}} -o /tmp/teleport-test-app
    /tmp/teleport-test-app {{suites}}

# Run core parser/config verification
test-core: (test-app "core")

# Run subscription import verification
test-subscription-support: (test-app "subscription-support")

# Verify Hysteria 2 import, persistence, sharing and bundled-core configuration
test-hysteria: fetch-xray
    swiftc {{test_flags}} {{test_sources}} scripts/test_hysteria.swift -o /tmp/teleport-test-hysteria
    /tmp/teleport-test-hysteria

# Exercise TCP/UDP through a local Hysteria 2 server without changing macOS networking
test-hysteria-integration: test-hysteria
    python3 scripts/test_hysteria_integration.py /tmp/teleport-test-hysteria

# Run connection health metadata verification
test-connection-health: (test-app "connection-health")

# Run connection provider state and presentation verification
test-connection-provider: (test-app "connection-provider")

# Run split-tunnel rule classification/matching/routing verification
test-split-tunneling: (test-app "split-tunneling")

# Run geodata settings/model verification
test-geodata: (test-app "geodata")

# Run ConfigurationStore Keychain-failure-handling verification
test-persistence: (test-app "persistence")

# Check how a running session reacts to the uplink underneath it changing
test-uplink-reconciliation: (test-app "uplink-reconciliation")

# Check the pf ruleset that keeps traffic off the uplink between sessions
test-leak-guard:
    swiftc {{test_flags}} Shared/LeakGuardRuleset.swift Shared/TUNHelperXPCProtocol.swift teleport/TUN/ProbeHostExemptions.swift scripts/test_leak_guard.swift -o /tmp/teleport-test-leak-guard
    /tmp/teleport-test-leak-guard

# Test the shared privileged-helper XPC protocol and payload bounds
test-xpc-protocol:
    swiftc {{test_flags}} Shared/*.swift scripts/test_xpc_protocol.swift -o /tmp/teleport-test-xpc-protocol
    /tmp/teleport-test-xpc-protocol

# Test bounded same-daemon privileged-helper request deduplication
test-helper-request-ledger:
    swiftc {{test_flags}} Shared/*.swift TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift scripts/test_helper_request_ledger.swift -o /tmp/teleport-test-helper-request-ledger
    /tmp/teleport-test-helper-request-ledger

# Test typed privileged-helper command dispatch and request deduplication
test-helper-command-dispatch:
    swiftc {{test_flags}} Shared/*.swift TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift TeleportPrivilegedHelper/IPC/HelperCommandExecuting.swift TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift scripts/test_helper_command_dispatch.swift -o /tmp/teleport-test-helper-command-dispatch
    /tmp/teleport-test-helper-command-dispatch

# Test the authenticated privileged-helper XPC endpoint composition
test-helper-xpc-endpoint:
    swiftc {{test_flags}} Shared/*.swift TeleportPrivilegedHelper/IPC/HelperRequestLedger.swift TeleportPrivilegedHelper/IPC/HelperCommandExecuting.swift TeleportPrivilegedHelper/IPC/HelperCommandDispatcher.swift TeleportPrivilegedHelper/IPC/HelperXPCService.swift scripts/test_helper_xpc_endpoint.swift -o /tmp/teleport-test-helper-xpc-endpoint
    /tmp/teleport-test-helper-xpc-endpoint

# Test app-side XPC connection ownership and transport races
test-xpc-transport:
    swiftc {{test_flags}} Shared/*.swift teleport/TUN/TUNHelperTransport.swift teleport/TUN/XPCTUNHelperTransport.swift scripts/test_xpc_transport.swift -o /tmp/teleport-test-xpc-transport
    /tmp/teleport-test-xpc-transport

# Test the typed privileged-helper client and bounded reconciliation
test-privileged-helper-client: (test-app "privileged-helper-client")

# Test the LaunchDaemon Mach service and explicit legacy reset tooling
test-mach-service-installation: (test-app "mach-service-installation")

# Line coverage of the test scripts over the sources they compile (views and most helper sources are not among them)
coverage:
    rm -rf "{{coverage_dir}}" && mkdir -p "{{coverage_dir}}"
    LLVM_PROFILE_FILE="{{coverage_dir}}/%m.profraw" just test_flags="-profile-generate -profile-coverage-mapping" test-app test-hysteria test-leak-guard test-xpc-protocol test-helper-request-ledger test-helper-command-dispatch test-helper-xpc-endpoint test-xpc-transport
    xcrun llvm-profdata merge -sparse "{{coverage_dir}}"/*.profraw -o "{{coverage_dir}}/merged.profdata"
    xcrun llvm-cov report $(for binary in /tmp/teleport-test-*; do printf -- '-object %s ' "$binary"; done) -instr-profile "{{coverage_dir}}/merged.profdata" -ignore-filename-regex='scripts/' | tee "{{coverage_dir}}/report.txt"

# Explicitly remove the legacy helper installation before development cutover
reset-legacy-privileged-helper:
    sudo sh scripts/reset_legacy_privileged_helper.sh


# Remove the installed privileged helper and its root-owned files (asks for sudo)
uninstall-helper:
    sudo bash scripts/uninstall.sh

# Print the changelog section for the commits since the last tag (see cliff.toml)
changelog:
    git-cliff --unreleased

# Prepend the generated section for an untagged version to CHANGELOG.md. Usage: just prepare-release 0.4.0
prepare-release version:
    #!/usr/bin/env bash
    set -euo pipefail

    [[ "{{version}}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Usage: just prepare-release X.Y.Z" >&2; exit 2; }
    if git rev-parse -q --verify "refs/tags/v{{version}}" >/dev/null; then
      echo "Tag v{{version}} already exists" >&2
      exit 1
    fi
    if ! git diff --quiet HEAD -- CHANGELOG.md; then
      echo "CHANGELOG.md has uncommitted changes" >&2
      exit 1
    fi
    # --prepend would put the new section above a hand-written one, not replace it.
    if grep -q '^## \[Unreleased\]' CHANGELOG.md; then
      echo "CHANGELOG.md still has a hand-written [Unreleased] section; move or remove it first" >&2
      exit 1
    fi
    git-cliff --unreleased --tag "v{{version}}" --prepend CHANGELOG.md

# Fail on commits since a revision that are not Conventional Commits. Usage: just lint-commits [origin/main]
lint-commits since="origin/main":
    GIT_CLIFF__GIT__REQUIRE_CONVENTIONAL=true git-cliff "{{since}}..HEAD" -o /dev/null
