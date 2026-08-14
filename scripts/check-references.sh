#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
status=0

fail() {
    printf '  \033[31m✗\033[0m %s\n' "$1"
    status=1
}

# Makefile included by name: the release lane references ADR-0017 there, and a grep that never
# scans it would let those references dangle unproven.
includes=(--include='*.md' --include='*.swift' --include='*.sh' --include='*.yml' --include='Makefile')

echo "references resolve"
while IFS=: read -r file line id; do
    number="${id#GAP-}"
    if ! find docs/gaps/open docs/gaps/closed -maxdepth 1 -name "${number}-*.md" | grep -q .; then
        fail "$file:$line dangling $id"
    fi
done < <(grep -rno "GAP-[0-9]\{4\}" "${includes[@]}" --exclude-dir=.git . | sort -u)

while IFS=: read -r file line id; do
    number="${id#ADR-}"
    if ! find docs/decisions -maxdepth 1 -name "${number}-*.md" | grep -q .; then
        fail "$file:$line dangling $id"
    fi
done < <(grep -rno "ADR-[0-9]\{4\}" "${includes[@]}" --exclude-dir=.git . | sort -u)

echo "record ids match their filenames"
for record in docs/gaps/open/*.md docs/gaps/closed/*.md; do
    [ -e "$record" ] || continue
    expected="GAP-$(basename "$record" | cut -d- -f1)"
    actual=$(grep -m1 '^id: ' "$record" | awk '{print $2}')
    [ "$expected" = "$actual" ] || fail "$record declares '$actual', filename says '$expected'"
done

echo "gap status matches its folder"
for record in docs/gaps/open/*.md; do
    [ -e "$record" ] || continue
    grep -q '^status: open' "$record" || fail "$record is in open/ but does not say 'status: open'"
done
for record in docs/gaps/closed/*.md; do
    [ -e "$record" ] || continue
    grep -q '^status: closed' "$record" ||
        fail "$record is in closed/ but does not say 'status: closed'"
    grep -qE '^closed_by: +\S' "$record" ||
        fail "$record is closed with an empty closed_by — a gap closes only by a decision"
done

echo "every record is indexed"
for record in docs/gaps/open/*.md docs/gaps/closed/*.md; do
    [ -e "$record" ] || continue
    number=$(basename "$record" | cut -d- -f1)
    grep -q "($(dirname "$record" | sed 's|docs/gaps/||')/$(basename "$record"))" docs/gaps/README.md ||
        fail "GAP-$number is not linked from the index in docs/gaps/README.md"
done
for record in docs/decisions/[0-9]*.md; do
    [ -e "$record" ] || continue
    grep -q "($(basename "$record"))" docs/decisions/README.md ||
        fail "$(basename "$record") is not linked from the index in docs/decisions/README.md"
done

echo "completed plans do not still read Active"
for plan in docs/plans/completed/*.md; do
    [ -e "$plan" ] || continue
    grep -qE '^- Status: \*\*Built\*\*' "$plan" ||
        fail "$plan is in completed/ but its Status line does not say Built"
done

if [ "$status" -eq 0 ]; then
    printf '\033[32mreferences and record status are consistent\033[0m\n'
fi
exit "$status"
