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
coverage_dir := "build/coverage"

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

# Run the XCTest bundles of the teleport scheme; the Debug app is built for the build-approval check
test: fetch-xray
    xcodebuild test \
      -project {{project}} \
      -scheme {{scheme}} \
      -destination '{{debug_destination}}' \
      -derivedDataPath {{derived_data}}

# Run one test class or method of either bundle. Usage: just test-case CoreTests[/testMethod]
test-case name: fetch-xray
    xcodebuild test \
      -project {{project}} \
      -scheme {{scheme}} \
      -destination '{{debug_destination}}' \
      -derivedDataPath {{derived_data}} \
      -only-testing:teleportTests/{{name}} \
      -only-testing:TeleportPrivilegedHelperTests/{{name}}

# Line coverage of the tests over the sources compiled into the two bundles (the app and helper products are not executed)
coverage: fetch-xray
    rm -rf "{{coverage_dir}}" && mkdir -p "{{coverage_dir}}"
    xcodebuild test \
      -project {{project}} \
      -scheme {{scheme}} \
      -destination '{{debug_destination}}' \
      -derivedDataPath {{derived_data}} \
      -enableCodeCoverage YES \
      -resultBundlePath "{{coverage_dir}}/tests.xcresult"
    for bundle in teleportTests.xctest TeleportPrivilegedHelperTests.xctest; do \
      xcrun xccov view --report --files-for-target "$bundle" "{{coverage_dir}}/tests.xcresult"; \
    done | grep -v -E '/(teleportTests|TeleportPrivilegedHelperTests)/[^/]*\.swift ' | tee "{{coverage_dir}}/report.txt"

# Explicitly remove the legacy helper installation before development cutover
reset-legacy-privileged-helper:
    sudo sh scripts/reset_legacy_privileged_helper.sh


# Remove the installed privileged helper and its root-owned files (asks for sudo)
uninstall-helper:
    sudo bash scripts/uninstall.sh

# Print the JSON inside one of the app's sealed snapshot files; the key comes from Keychain. Usage: just decrypt-snapshot [snapshot|retained.<stamp>-<reason>|unreadable.<stamp>]
decrypt-snapshot name="snapshot":
    security find-generic-password -s dev.x.teleport.configuration -a app-snapshot.key -w \
      | swift scripts/decrypt-snapshot.swift "$HOME/Library/Application Support/teleport/sealed/app-snapshot/{{name}}"

# Print the changelog section for the commits since the last tag (see cliff.toml)
changelog:
    git-cliff --unreleased

# Prepend the generated section for an untagged version to CHANGELOG.md and set it as the app version. Usage: just prepare-release 0.4.0
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
    # The release workflow refuses a tag that does not match the app's version.
    sed -i '' 's/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = {{version}};/' {{project}}/project.pbxproj

# Fail on commits since a revision that are not Conventional Commits. Usage: just lint-commits [origin/main]
lint-commits since="origin/main":
    GIT_CLIFF__GIT__REQUIRE_CONVENTIONAL=true git-cliff "{{since}}..HEAD" -o /dev/null
