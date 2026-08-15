#!/usr/bin/env bash
# Push the rendered cask to pmbrull/homebrew-tap (ADR-0018). This is the step ADR-0017 predicted
# would be forgotten — "forgetting to update it strands users on the old version" — so it stopped
# being a paste and became a script.
#
# Needs:
#   .build/dist/onair.rb     from scripts/make-cask.sh (hash the PUBLISHED asset, not --local)
#   $HOMEBREW_TAP_TOKEN      a token with contents:write on pmbrull/homebrew-tap, and nothing else
#
# The token is passed to git through GIT_ASKPASS rather than embedded in the remote URL: a URL-
# embedded credential lands in the clone's .git/config and in any error message git prints, and a
# `-c http.extraheader=` one lands in the process table.
set -euo pipefail
cd "$(dirname "$0")/.."

tap_repo=${TAP_REPO:-pmbrull/homebrew-tap}
cask_path=${CASK_PATH:-Casks/onair.rb}
rendered=.build/dist/onair.rb

die() {
    echo "error: $1" >&2
    exit 1
}

[ -f "$rendered" ] || die "$rendered not found — run ./scripts/make-cask.sh first"
[ -n "${HOMEBREW_TAP_TOKEN:-}" ] || die "HOMEBREW_TAP_TOKEN is not set; it is the only way in"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
grep -q "version \"${version}\"" "$rendered" ||
    die "$rendered does not declare version $version — regenerate it against this plist"

work=$(mktemp -d)
askpass="$work/askpass.sh"
trap 'rm -rf "$work"' EXIT

# git calls this for the password on an https remote whose username is already in the URL.
printf '#!/bin/sh\nprintf %%s "$HOMEBREW_TAP_TOKEN"\n' > "$askpass"
chmod +x "$askpass"
export GIT_ASKPASS="$askpass"
export GIT_TERMINAL_PROMPT=0

clone="$work/tap"
git clone --depth 1 --quiet "https://x-access-token@github.com/${tap_repo}.git" "$clone" ||
    die "cannot clone ${tap_repo} — check HOMEBREW_TAP_TOKEN's scope and expiry"

mkdir -p "$(dirname "$clone/$cask_path")"
cp "$rendered" "$clone/$cask_path"

# Stage before comparing: `git diff` reports nothing for a path git has never heard of, so on a tap
# that does not have the cask yet an unstaged check would call a first publish a no-op.
git -C "$clone" add -- "$cask_path"
if git -C "$clone" diff --cached --quiet; then
    echo "${tap_repo}:${cask_path} already matches the rendered cask for $version — nothing to push"
    exit 0
fi

branch=$(git -C "$clone" symbolic-ref --short HEAD)
git -C "$clone" -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit --quiet -m "onair ${version}"
git -C "$clone" push --quiet origin "HEAD:refs/heads/${branch}"

echo "pushed ${tap_repo}:${cask_path} at version ${version}"
