#!/usr/bin/env bash
# Fetches the official Xray-core release for macOS on Apple Silicon and on
# Intel, joins the two executables into one universal binary with lipo and
# places it at teleport/Resources/xray.
#
# Each zip is checked against the digest XTLS publishes next to it, and the
# universal executable against the SHA-256 pinned in
# teleport/HelperInstallation/BundledArtifactPolicy.swift, which is what the app
# verifies before it installs the binary as root. A mismatch stops the script:
# when the pin is meant to change, update it to the digest printed here and run
# the script again.
#
# Usage: scripts/fetch-xray.sh [vX.Y.Z]   (default: the version the pin was made for)
set -euo pipefail

VERSION="${1:-v26.10.21}"
# One release zip per architecture slice of the universal binary.
ASSETS="Xray-macos-arm64-v8a.zip Xray-macos-64.zip"
REQUIRED_ARCHS="arm64 x86_64"
BASE_URL="https://github.com/XTLS/Xray-core/releases/download/$VERSION"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="$REPO_ROOT/teleport/HelperInstallation/BundledArtifactPolicy.swift"
DESTINATION="$REPO_ROOT/teleport/Resources/xray"

pinned_sha256=$(sed -n 's/.*xraySHA256: "\([0-9a-f]\{64\}\)".*/\1/p' "$POLICY")
if [ -z "$pinned_sha256" ]; then
    echo "No xraySHA256 pin found in $POLICY" >&2
    exit 1
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

slices=()
for asset in $ASSETS; do
    echo "Downloading $BASE_URL/$asset"
    curl -fsSL -o "$work_dir/$asset" "$BASE_URL/$asset"
    curl -fsSL -o "$work_dir/$asset.dgst" "$BASE_URL/$asset.dgst"

    published_zip_sha256=$(sed -n 's/^SHA2-256= *//p' "$work_dir/$asset.dgst")
    actual_zip_sha256=$(shasum -a 256 "$work_dir/$asset" | awk '{print $1}')
    if [ -z "$published_zip_sha256" ] || [ "$published_zip_sha256" != "$actual_zip_sha256" ]; then
        echo "$asset does not match the published .dgst file:" >&2
        echo "  published: ${published_zip_sha256:-missing}" >&2
        echo "  actual:    $actual_zip_sha256" >&2
        exit 1
    fi

    slice_dir="$work_dir/${asset%.zip}"
    unzip -q -o "$work_dir/$asset" xray -d "$slice_dir"
    slices+=("$slice_dir/xray")
done

# Fixed slice alignment: the Xcode lipo aligns arm64 to 2^15 and the Command Line
# Tools lipo to 2^14, so without it the digest depends on the toolchain.
lipo -create "${slices[@]}" -segalign arm64 4000 -segalign x86_64 1000 -output "$work_dir/xray"
actual_archs=$(lipo -archs "$work_dir/xray")
for arch in $REQUIRED_ARCHS; do
    case " $actual_archs " in
        *" $arch "*) ;;
        *)
            echo "Universal executable lacks the $arch slice (has: $actual_archs)" >&2
            exit 1
            ;;
    esac
done
lipo -info "$work_dir/xray"
file "$work_dir/xray"

actual_sha256=$(shasum -a 256 "$work_dir/xray" | awk '{print $1}')
if [ "$actual_sha256" != "$pinned_sha256" ]; then
    echo "Universal executable digest does not match the pin in BundledArtifactPolicy.swift:" >&2
    echo "  pinned: $pinned_sha256" >&2
    echo "  actual: $actual_sha256" >&2
    echo "If $VERSION is the intended runtime, set xraySHA256 to the actual value and rerun." >&2
    exit 1
fi

install -m 755 "$work_dir/xray" "$DESTINATION"
echo "Installed $VERSION to $DESTINATION (sha256 $actual_sha256)"
