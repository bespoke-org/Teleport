#!/bin/sh
# Fetches the official Xray-core release for macOS on Apple Silicon and places
# the executable at teleport/Resources/xray.
#
# The zip is checked against the digest XTLS publishes next to it, and the
# executable against the SHA-256 pinned in
# teleport/HelperInstallation/BundledArtifactPolicy.swift, which is what the app
# verifies before it installs the binary as root. A mismatch stops the script:
# when the pin is meant to change, update it to the digest printed here and run
# the script again.
#
# Usage: scripts/fetch-xray.sh [vX.Y.Z]   (default: the version the pin was made for)
set -eu

VERSION="${1:-v26.6.27}"
ASSET="Xray-macos-arm64-v8a.zip"
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

echo "Downloading $BASE_URL/$ASSET"
curl -fsSL -o "$work_dir/$ASSET" "$BASE_URL/$ASSET"
curl -fsSL -o "$work_dir/$ASSET.dgst" "$BASE_URL/$ASSET.dgst"

published_zip_sha256=$(sed -n 's/^SHA2-256= *//p' "$work_dir/$ASSET.dgst")
actual_zip_sha256=$(shasum -a 256 "$work_dir/$ASSET" | awk '{print $1}')
if [ -z "$published_zip_sha256" ] || [ "$published_zip_sha256" != "$actual_zip_sha256" ]; then
    echo "Archive digest does not match the published .dgst file:" >&2
    echo "  published: ${published_zip_sha256:-missing}" >&2
    echo "  actual:    $actual_zip_sha256" >&2
    exit 1
fi

unzip -q -o "$work_dir/$ASSET" xray -d "$work_dir"
actual_sha256=$(shasum -a 256 "$work_dir/xray" | awk '{print $1}')
if [ "$actual_sha256" != "$pinned_sha256" ]; then
    echo "Executable digest does not match the pin in BundledArtifactPolicy.swift:" >&2
    echo "  pinned: $pinned_sha256" >&2
    echo "  actual: $actual_sha256" >&2
    echo "If $VERSION is the intended runtime, set xraySHA256 to the actual value and rerun." >&2
    exit 1
fi

install -m 755 "$work_dir/xray" "$DESTINATION"
echo "Installed $VERSION to $DESTINATION (sha256 $actual_sha256)"
