#!/usr/bin/env bash
# The release bump rule's table (ADR-0018). `make version-rule`, and part of `make verify`.
#
# The rule decides what every push to main ships. It is shell, so nothing else in this repo type-
# checks it — this table is the only thing standing between a subtle edit and a wrong version
# number on a signed, notarized, published artefact. Three of the rows are refusals; those are the
# ones worth keeping.
set -euo pipefail
cd "$(dirname "$0")/.."

rule=./scripts/next-version.sh
passed=0
failed=0

# expect_version <current> <message> <expected-version>
expect_version() {
    local current=$1 message=$2 want=$3 got code
    set +e
    got=$(printf '%s' "$message" | "$rule" "$current" - 2> /dev/null)
    code=$?
    set -e
    if [ "$code" -ne 0 ]; then
        printf '  \033[31m✗\033[0m %-8s %-46s exited %s, wanted %s\n' "$current" "${message%%$'\n'*}" "$code" "$want"
        failed=$((failed + 1))
    elif [ "$got" != "$want" ]; then
        printf '  \033[31m✗\033[0m %-8s %-46s gave %s, wanted %s\n' "$current" "${message%%$'\n'*}" "$got" "$want"
        failed=$((failed + 1))
    else
        passed=$((passed + 1))
    fi
}

# expect_exit <current> <message> <expected-code>   — 3 is "releases nothing", 1 is "cannot decide"
expect_exit() {
    local current=$1 message=$2 want=$3 code
    set +e
    printf '%s' "$message" | "$rule" "$current" - > /dev/null 2>&1
    code=$?
    set -e
    if [ "$code" -ne "$want" ]; then
        printf '  \033[31m✗\033[0m %-8s %-46s exited %s, wanted %s\n' "$current" "${message%%$'\n'*}" "$code" "$want"
        failed=$((failed + 1))
    else
        passed=$((passed + 1))
    fi
}

echo "the bump rule"

# What actually lands on main: squash-merge subjects, PR number suffix and all.
expect_version 0.1.0 'fix(release): emit the non-deprecated form (#6)' 0.1.1
expect_version 0.1.0 'fix: keep the loopback key out of the keychain' 0.1.1
expect_version 0.1.0 'perf: stop re-reading the profile on every tick' 0.1.1
expect_version 0.1.0 'revert: back out the microphone default' 0.1.1
expect_version 0.1.0 'feat: release lane — icon, signed universal dist (#4)' 0.2.0
expect_version 0.1.0 'feat(oauth): PKCE exchange' 0.2.0

# Rollover, and the two-digit case a naive string bump gets wrong.
expect_version 0.9.9 'feat: something' 0.10.0
expect_version 0.9.9 'fix: something' 0.9.10
expect_version 1.0.0 'fix: something' 1.0.1
expect_version 1.2.3 'feat: something' 1.3.0

# Breaking, both spellings. Below 1.0.0 it is a minor: CI must not declare the project stable.
expect_version 0.1.0 'feat!: drop the microphone switch' 0.2.0
expect_version 0.1.0 $'fix: rename the token key\n\nBREAKING CHANGE: stored tokens are dropped' 0.2.0
expect_version 0.1.0 $'fix: rename the token key\n\nBREAKING-CHANGE: stored tokens are dropped' 0.2.0
expect_version 1.2.3 'feat!: drop the microphone switch' 2.0.0
expect_version 1.2.3 $'fix: rename the token key\n\nBREAKING CHANGE: dropped' 2.0.0
expect_version 1.2.3 'feat(engine)!: new intent shape' 2.0.0

# Nothing a user installs → no release (exit 3), not a patch bump.
for type in docs chore ci test refactor style build; do
    expect_exit 0.1.0 "$type: touch nothing that ships" 3
done
# The workflow's own bump commit, which must never itself release.
expect_exit 0.1.0 'chore(release): v0.1.1 [skip ci]' 3
# A breaking footer does not resurrect a non-releasing type: a docs commit ships no code to break.
expect_exit 0.1.0 $'docs: rewrite the runbook\n\nBREAKING CHANGE: the old steps are gone' 3

# Cannot decide → exit 1, never a default (.claude/rules/no-silent-fallbacks.md).
expect_exit 0.1.0 'Render the emoji, invert the pause switch (#2)' 1 # a real commit in this history
expect_exit 0.1.0 'Initial commit' 1
expect_exit 0.1.0 'wip: half a thing' 1                  # conventional shape, unknown type
expect_exit 0.1.0 'feat missing the colon' 1
expect_exit 0.1.0 'feat:' 1                              # no description
expect_exit 0.1.0 'feat:   ' 1
expect_exit 0.1.0 '' 1
expect_exit 0.1 'fix: something' 1                       # current version not X.Y.Z
expect_exit v0.1.0 'fix: something' 1
expect_exit 0.1.0-rc1 'fix: something' 1

# Uppercase types are still conventional enough to read; scopes may contain anything but ')'.
expect_version 0.1.0 'Fix: capitalised type' 0.1.1
expect_version 0.1.0 'fix(slack/status): scoped with a slash' 0.1.1

if [ "$failed" -eq 0 ]; then
    printf '\033[32m%s bump-rule cases pass\033[0m\n' "$passed"
    exit 0
fi
printf '\033[31m%s of %s bump-rule cases failed\033[0m\n' "$failed" "$((passed + failed))"
exit 1
