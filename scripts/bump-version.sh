#!/usr/bin/env bash
# Write a version into Resources/Info.plist — the only place OnAir declares one (ADR-0017): the
# Makefile, the zip name, the git tag and the cask URL all read it from there. Sets
# CFBundleShortVersionString to the argument and increments CFBundleVersion, because macOS uses the
# integer to decide what is newer and a repeated value makes an upgrade look like a reinstall.
#
# Usage: scripts/bump-version.sh <X.Y.Z>
set -euo pipefail
cd "$(dirname "$0")/.."

plist=Resources/Info.plist

die() {
    echo "error: $1" >&2
    exit 1
}

[ $# -eq 1 ] || die "usage: $0 <X.Y.Z>"
next=$1

[[ $next =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] ||
    die "'$next' is not X.Y.Z — this value names the zip, the tag and the cask"

current=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist")

[[ $current =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "the plist already holds '$current', which is not X.Y.Z — fix that before bumping"
[[ $build =~ ^[0-9]+$ ]] ||
    die "CFBundleVersion is '$build', not an integer — macOS compares it numerically"

# Refuse to go backwards. A hand-typed workflow_dispatch version is the likely source, and a
# downgrade would publish a tag whose artefact is older than the one brew already serves.
lower=$(printf '%s\n%s\n' "$current" "$next" | sort -V | head -1)
if [ "$current" = "$next" ]; then
    die "the plist already says $current — a release must change the version"
elif [ "$lower" = "$next" ]; then
    die "$next is lower than the current $current — refusing to publish a downgrade"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $next" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((build + 1))" "$plist"
plutil -lint "$plist" > /dev/null || die "$plist is no longer a valid plist after the bump"

echo "bumped $plist: $current -> $next (CFBundleVersion $build -> $((build + 1)))"
