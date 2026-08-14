#!/usr/bin/env bash
# Remove the loopback identities that OnAir stranded in the login keychain before ADR-0016.
#
# Until the `kSecImportToMemoryOnly` fix, every distinct PKCS#12 archive OnAir minted left a
# certificate *and its private key* in the login keychain permanently — one per connect, one per
# test that minted, and `make verify` mints. The keys are what matter: each carries an ACL naming
# the binary that imported it, so a rebuilt OnAir makes macOS ask the user for their login password.
#
# Reports by default and deletes nothing. `--apply` deletes.
set -euo pipefail

apply=false
[ "${1:-}" = "--apply" ] && apply=true

keychain="$HOME/Library/Keychains/login.keychain-db"
[ -f "$keychain" ] || { echo "no login keychain at $keychain"; exit 0; }

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Matched on the certificate's *parsed subject*, never on the `localhost` label. A label match would
# take a user's own development certificate with it, and this script's whole licence to run on
# somebody's login keychain is that it cannot.
#
# `while read` rather than `mapfile`: /bin/bash on macOS is 3.2, which has no `mapfile`, and a
# cleanup script that only runs under Homebrew's bash is a cleanup script that does not run.
matched="$scratch/matched"
: >"$matched"
security find-certificate -a -c localhost -Z -p "$keychain" 2>/dev/null |
    awk -v dir="$scratch" '
        /^SHA-1 hash: / { hash = $3; next }
        /BEGIN CERTIFICATE/ { file = dir "/" hash ".pem"; printing = 1 }
        printing { print > file }
        /END CERTIFICATE/ { printing = 0; print hash }
    ' |
    while IFS= read -r hash; do
        subject=$(/usr/bin/openssl x509 -in "$scratch/$hash.pem" -noout -subject 2>/dev/null || true)
        case "$subject" in
            *"O = OnAir"* | *"O=OnAir"*) printf '%s\n' "$hash" >>"$matched" ;;
        esac
    done

count=$(wc -l <"$matched" | tr -d ' ')
if [ "$count" -eq 0 ]; then
    echo "no OnAir loopback identities in the login keychain"
    exit 0
fi

if [ "$apply" = false ]; then
    echo "$count OnAir loopback identit(ies) in the login keychain, CN=localhost O=OnAir:"
    sed 's/^/  /' "$matched"
    echo
    echo "nothing deleted. re-run with --apply to remove them."
    exit 0
fi

# `delete-identity` removes the certificate and its private key together; deleting the certificate
# alone would leave the key, which is the half that raises the password prompt. Deleting a private
# key is authorised per item, so macOS may ask — see ADR-0016 for the Keychain Access alternative
# if that becomes unworkable.
removed=0
failed=0
while IFS= read -r hash; do
    if security delete-identity -Z "$hash" "$keychain" >/dev/null 2>&1; then
        removed=$((removed + 1))
    else
        failed=$((failed + 1))
        echo "  could not delete $hash"
    fi
done <"$matched"

echo "removed $removed OnAir loopback identit(ies) from the login keychain"
# A partial purge must say so rather than reporting the removals and stopping
# (`.claude/rules/no-silent-fallbacks.md`): the ones left behind are the ones still prompting.
if [ "$failed" -gt 0 ]; then
    echo "$failed could not be removed — re-run, or delete them in Keychain Access (ADR-0016)"
    exit 1
fi
