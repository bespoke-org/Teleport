#!/usr/bin/env bash
# The single-quoted Perl substitutions below expand $ENV{...} in Perl, not in the shell.
# shellcheck disable=SC2016
#
# Updates the bundled Xray to a release of XTLS/Xray-core. Fetches it with
# scripts/fetch-xray.sh --update-pin, then writes the version, the digests and
# the commit and Go version `xray version` reports into fetch-xray.sh,
# README.md and THIRD_PARTY_NOTICES.md, and a line into the Unreleased section
# of CHANGELOG.md when the version changes.
#
# The script works on a copy of those files and changes the repository only
# when the copy differs from it. It prints one line to stdout when something
# changed and nothing otherwise; everything else goes to stderr. The Updatecli
# shell target in updatecli/updatecli.d/xray.yaml reads a change from stdout.
# With DRY_RUN=true (set by `updatecli pipeline diff`) the change is reported
# but not written.
#
# Usage: scripts/bump-xray.sh [--verify] vX.Y.Z
#   --verify   run `just verify` after writing a change; a failure fails the script
set -euo pipefail

verify=false
if [ "${1:-}" = "--verify" ]; then
    verify=true
    shift
fi
if [ $# -ne 1 ] || ! [[ "$1" =~ ^v[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Usage: $0 [--verify] vX.Y.Z" >&2
    exit 1
fi

VERSION="$1"
NUMBER="${VERSION#v}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILES="scripts/fetch-xray.sh teleport/HelperInstallation/BundledArtifactPolicy.swift README.md THIRD_PARTY_NOTICES.md CHANGELOG.md"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
for file in $FILES; do
    mkdir -p "$work_dir/$(dirname "$file")"
    cp -p "$REPO_ROOT/$file" "$work_dir/$file"
done
# fetch-xray.sh installs the binary here; git ignores it, so it is not compared.
mkdir -p "$work_dir/teleport/Resources"

current_version=$(sed -n 's/^VERSION="${1:-\(v[0-9.]*\)}"$/\1/p' "$work_dir/scripts/fetch-xray.sh")
"$work_dir/scripts/fetch-xray.sh" --update-pin "$VERSION" >&2

xray="$work_dir/teleport/Resources/xray"
pin=$(sed -n 's/.*xraySHA256: "\([0-9a-f]\{64\}\)".*/\1/p' "$work_dir/teleport/HelperInstallation/BundledArtifactPolicy.swift")
lipo -thin arm64 "$xray" -output "$work_dir/xray-arm64"
lipo -thin x86_64 "$xray" -output "$work_dir/xray-x86_64"
arm64_sha256=$(shasum -a 256 "$work_dir/xray-arm64" | awk '{print $1}')
x86_64_sha256=$(shasum -a 256 "$work_dir/xray-x86_64" | awk '{print $1}')

# For example: Xray 26.10.21 (Xray, Penetrates Everything.) 1b1647c (go1.27.3 darwin/arm64)
version_line=$("$xray" version)
version_line="${version_line%%$'\n'*}"
reported_number=$(echo "$version_line" | awk '{print $2}')
commit=$(echo "$version_line" | sed -n 's/.*) \([0-9a-f]\{7,\}\) (go.*/\1/p')
go_version=$(echo "$version_line" | sed -n 's/.* (\(go[0-9.]*\) .*/\1/p')
if [ "$reported_number" != "$NUMBER" ] || [ -z "$commit" ] || [ -z "$go_version" ]; then
    echo "Unexpected \`xray version\` output for $VERSION: $version_line" >&2
    exit 1
fi

# Applies a Perl substitution to a whole file and fails when it matches nothing.
substitute() {
    perl -0777 -pi -e "$2 or die \"no match in $1\\n\"" "$work_dir/$1"
}

export VERSION NUMBER pin arm64_sha256 x86_64_sha256 commit go_version
substitute scripts/fetch-xray.sh 's/^VERSION="\$\{1:-v[0-9.]+\}"$/VERSION="\${1:-$ENV{VERSION}}"/m'
substitute README.md 's/^scripts\/fetch-xray\.sh v[0-9.]+$/scripts\/fetch-xray.sh $ENV{VERSION}/m'
substitute THIRD_PARTY_NOTICES.md 's/^- Version: .*$/- Version: $ENV{NUMBER} (`xray version` reports `Xray $ENV{NUMBER} ... $ENV{commit} ($ENV{go_version} darwin\/arm64)` or `darwin\/amd64`, depending on the slice that runs)/m'
substitute THIRD_PARTY_NOTICES.md 's/^(- Source: https:\/\/github\.com\/XTLS\/Xray-core, tag )`v[0-9.]+`$/$1`$ENV{VERSION}`/m'
substitute THIRD_PARTY_NOTICES.md 's/(universal binary \(SHA-256\s+)`[0-9a-f]{64}`/$1`$ENV{pin}`/'
substitute THIRD_PARTY_NOTICES.md 's/(`Xray-macos-arm64-v8a\.zip`, arm64 slice, SHA-256\s+)`[0-9a-f]{64}`/$1`$ENV{arm64_sha256}`/'
substitute THIRD_PARTY_NOTICES.md 's/(`Xray-macos-64\.zip`, x86_64 slice, SHA-256\s+)`[0-9a-f]{64}`/$1`$ENV{x86_64_sha256}`/'

# The changelog gets a line only for a new version, not for a refetch of the
# current one. An existing "Bundled Xray runtime updated to" line in Unreleased
# gets the new version; otherwise the line goes under "### Changed", which is
# added before Deprecated/Removed/Fixed/Security when missing.
if [ "$current_version" != "$VERSION" ]; then
    substitute CHANGELOG.md 's{^(## \[Unreleased\]\n)(.*?)(?=^## \[|\z)}{
        my ($heading, $body) = ($1, $2);
        my $line = "- Bundled Xray runtime updated to $ENV{NUMBER}.";
        unless ($body =~ s/^(- Bundled Xray runtime updated to )[0-9.]+/$1$ENV{NUMBER}/m
            or $body =~ s/^(### Changed\n)/$1$line\n/m
            or $body =~ s/^(?=### (?:Deprecated|Removed|Fixed|Security)\n)/### Changed\n$line\n\n/m) {
            $body =~ s/\s*\z//;
            $body = ($body eq "" ? "" : "$body\n\n") . "### Changed\n$line\n\n";
        }
        "$heading$body";
    }mse'
fi

changed_files=""
for file in $FILES; do
    if ! cmp -s "$work_dir/$file" "$REPO_ROOT/$file"; then
        changed_files="$changed_files $file"
    fi
done

if [ -z "$changed_files" ]; then
    echo "Xray $VERSION is already bundled; nothing to change" >&2
    exit 0
fi

if [ "${DRY_RUN:-false}" = true ]; then
    echo "Would update Xray from $current_version to $VERSION:$changed_files"
    exit 0
fi

for file in $changed_files; do
    cp -p "$work_dir/$file" "$REPO_ROOT/$file"
done
install -m 755 "$xray" "$REPO_ROOT/teleport/Resources/xray"

if [ "$verify" = true ]; then
    (cd "$REPO_ROOT" && just verify) >&2
fi

echo "Updated Xray from $current_version to $VERSION:$changed_files"
