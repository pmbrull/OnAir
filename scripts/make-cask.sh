#!/usr/bin/env bash
# Render the Homebrew cask with the version and sha256 filled in, so updating
# pmbrull/homebrew-tap is a paste, not a hand-edit (ADR-0017). Writes .build/dist/onair.rb and
# prints it.
#
# By default the sha256 comes from the zip actually PUBLISHED on the GitHub release — downloaded
# fresh — so the cask can never drift from the asset users will fetch (ditto zips are not
# byte-stable across rebuilds, so hashing a local re-run would). `--local` hashes
# .build/dist instead, for exercising the lane before anything is published.
set -euo pipefail
cd "$(dirname "$0")/.."

mode=published
[ "${1:-}" = "--local" ] && mode=local

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
bundle_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)

# Both values are rendered into Ruby that brew EXECUTES on every installing user's machine;
# refuse anything that could escape a string there. The Makefile applies the same version guard.
if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version '$version' from Resources/Info.plist is not X.Y.Z — refusing to render it into the cask" >&2
    exit 1
fi
if ! [[ $bundle_id =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "error: bundle id '$bundle_id' carries characters that cannot go into the cask" >&2
    exit 1
fi

zip_name="OnAir-${version}.zip"
if [ "$mode" = published ]; then
    command -v gh > /dev/null || {
        echo "error: gh is not installed; it is needed to hash the published release asset." >&2
        echo "       For exercising the lane before publishing, use: $0 --local" >&2
        exit 1
    }
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    gh release download "v${version}" --pattern "$zip_name" --dir "$tmp" || {
        echo "error: no release v${version} with ${zip_name} on GitHub — publish it first" >&2
        echo "       (docs/runbooks/release.md §5.4), or use --local for lane testing." >&2
        exit 1
    }
    zip="$tmp/$zip_name"
else
    zip=".build/dist/$zip_name"
    [ -f "$zip" ] || {
        echo "error: $zip not found — run 'make dist' first" >&2
        exit 1
    }
    echo "warning: --local hashes the zip on THIS machine, not the published asset." >&2
    echo "         Do not ship this file; regenerate without --local after publishing." >&2
fi
sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)

# Notes pinned to the values below:
# - `#{version}` is Ruby, evaluated by Homebrew — only version and sha256 change per release.
# - `:sequoia` is the plist's LSMinimumSystemVersion 15.0 by its macOS name; bump them together.
#   The bare symbol *is* the minimum-version form: `MacOSRequirement#initialize` defaults its
#   comparator to `>=`, and Homebrew's own deprecation names `macos: :sequoia` as the replacement
#   for `macos: ">= :sequoia"`. The string form still installs, with a warning, and is on its way
#   to being an error — measured on the v0.1.0 install, which is the only thing that shows it.
# - The caveat's Keychain service name is TokenStore.service
#   (Sources/OnAir/TokenStore.swift), which declares the same id the plist does — if either
#   ever moves, move both.
mkdir -p .build/dist
cat > .build/dist/onair.rb <<CASK
cask "onair" do
  version "${version}"
  sha256 "${sha}"

  url "https://github.com/pmbrull/OnAir/releases/download/v#{version}/OnAir-#{version}.zip"
  name "OnAir"
  desc "Menu-bar app that sets your Slack status when your camera turns on"
  homepage "https://github.com/pmbrull/OnAir"

  depends_on macos: :sequoia

  app "OnAir.app"

  uninstall quit: "${bundle_id}"

  zap trash: [
    "~/Library/Application Support/OnAir",
    "~/Library/Preferences/${bundle_id}.plist",
  ]

  caveats <<~EOS
    Your Slack token lives in the macOS Keychain, which uninstalling — even with
    --zap — does not touch. To remove it too, open Keychain Access and delete the
    items whose service is "${bundle_id}".
  EOS
end
CASK

cat .build/dist/onair.rb
echo "wrote .build/dist/onair.rb — copy to homebrew-tap/Casks/onair.rb" >&2
