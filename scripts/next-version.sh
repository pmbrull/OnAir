#!/usr/bin/env bash
# The release bump rule (ADR-0018), as a pure function of (current version, commit message).
#
# Every push to main asks this script one question: what version does this commit ship, if any?
# It lives here rather than inline in .github/workflows/release.yml because it decides *whether and
# what* gets released, and a decision in YAML is a decision nobody can test.
#
# Usage:
#   scripts/next-version.sh <current-version> <message-file>
#   scripts/next-version.sh <current-version> -          # message on stdin
#
# Exit codes are the interface — the workflow branches on a number, never on matched text:
#   0  the next version is on stdout, the bump kind on stderr
#   3  this commit releases nothing (docs/chore/ci/test/refactor/style/build alone)
#   1  cannot decide: unparseable subject, unknown type, or a current version that is not X.Y.Z.
#      Refusing beats defaulting to a patch bump — .claude/rules/no-silent-fallbacks.md applies to
#      version numbers too, and a release nobody can attribute to a stated intent is worse than a
#      red job.
set -euo pipefail

die() {
    echo "error: $1" >&2
    exit 1
}

[ $# -eq 2 ] || die "usage: $0 <current-version> <message-file|->"

current=$1
source=$2

# X.Y.Z and nothing else: this value names the zip, the tag and the cask, and is substituted into
# Ruby that Homebrew executes on every installing user's machine. Same guard as `make dist`.
[[ $current =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] ||
    die "current version '$current' is not X.Y.Z (no 'v' prefix, no pre-release suffix)"
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}

if [ "$source" = - ]; then
    message=$(cat)
else
    [ -f "$source" ] || die "no such message file: $source"
    message=$(cat "$source")
fi

subject=${message%%$'\n'*}
[ -n "$subject" ] || die "the commit message is empty; nothing to derive a version from"

# Conventional Commits: type, optional (scope), optional ! for breaking, ": ", description.
# Anything else is not a refusal to release — it is an inability to tell, which is exit 1.
# The description must contain a non-space: a bare `feat:` followed by spaces is a truncated
# subject, and inferring a minor bump from it would be inventing the intent it failed to state.
if ! [[ $subject =~ ^([a-zA-Z]+)(\(([^\)]*)\))?(!)?:[[:space:]]+[^[:space:]] ]]; then
    echo "error: cannot derive a version from this commit subject:" >&2
    echo "         $subject" >&2
    echo "       It is not a Conventional Commit (\"type: description\" or \"type(scope)!: description\")." >&2
    echo "       Refusing to guess a bump — ADR-0018. Amend the subject, or run the release workflow" >&2
    echo "       by hand (workflow_dispatch) with an explicit version." >&2
    exit 1
fi
type=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
bang=${BASH_REMATCH[4]}

# A footer is as breaking as a `!`, and the spec allows either spelling.
breaking=
[ -n "$bang" ] && breaking=yes
grep -qE '^BREAKING[ -]CHANGE:' <<< "$message" && breaking=yes

case $type in
    feat) kind=minor ;;
    fix | perf | revert) kind=patch ;;
    # These change the repository without changing the app a user installs. Releasing them costs
    # every installed user a `brew upgrade` for a byte-identical binary.
    docs | chore | ci | test | refactor | style | build)
        kind=none
        ;;
    *)
        echo "error: unknown commit type '$type' in subject:" >&2
        echo "         $subject" >&2
        echo "       Known and releasing: feat, fix, perf, revert." >&2
        echo "       Known and not releasing: docs, chore, ci, test, refactor, style, build." >&2
        echo "       Refusing to guess a bump for an unknown type — ADR-0018." >&2
        exit 1
        ;;
esac

# A breaking change overrides the type's own bump — but never promotes the project to 1.0.0. While
# the major is 0 the API is unstable by declaration, so breaking is a minor; declaring stability is
# a human's claim, made through workflow_dispatch with an explicit version (ADR-0018).
if [ -n "$breaking" ] && [ "$kind" != none ]; then
    if [ "$major" -eq 0 ]; then
        kind=minor
        echo "note: breaking change on a 0.x version — bumping the minor, not the major." >&2
    else
        kind=major
    fi
fi

case $kind in
    major) next="$((major + 1)).0.0" ;;
    minor) next="${major}.$((minor + 1)).0" ;;
    patch) next="${major}.${minor}.$((patch + 1))" ;;
    none)
        echo "no release: '$type' changes nothing a user installs (ADR-0018)." >&2
        exit 3
        ;;
esac

echo "$kind bump: $current -> $next" >&2
echo "$next"
