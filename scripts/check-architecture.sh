#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
status=0
kits=(DeviceKit StatusKit SlackKit)

fail() {
    printf '  \033[31m✗\033[0m %s\n' "$1"
    status=1
}

echo "A2 — kits are headless"
forbidden_imports='^import (AppKit|SwiftUI|Cocoa|UIKit|ServiceManagement|Carbon|ApplicationServices)'
for kit in "${kits[@]}"; do
    if hits=$(grep -rnE "$forbidden_imports" "Sources/$kit" 2>/dev/null); then
        while IFS= read -r hit; do
            fail "$hit — kits must not import a UI or app-lifecycle framework (A2, ADR-0002)"
        done <<<"$hits"
    fi
done

echo "A1 — dependency direction is one-way"
for kit in "${kits[@]}"; do
    if hits=$(grep -rn '^import OnAir$' "Sources/$kit" 2>/dev/null); then
        while IFS= read -r hit; do
            fail "$hit — a kit must not import the app (A1)"
        done <<<"$hits"
    fi
done
# SlackKit → StatusKit is the ONE permitted sibling edge; everything else is a cycle waiting to be.
for pair in "DeviceKit:StatusKit" "DeviceKit:SlackKit" "StatusKit:DeviceKit" "StatusKit:SlackKit" \
            "SlackKit:DeviceKit"; do
    from="${pair%%:*}"
    to="${pair##*:}"
    if hits=$(grep -rn "^import $to\$" "Sources/$from" 2>/dev/null); then
        while IFS= read -r hit; do
            fail "$hit — $from must not depend on $to (A1; see the table in ARCHITECTURE.md)"
        done <<<"$hits"
    fi
done

echo "A4 — the Slack token lives in the Keychain and nowhere else"
if hits=$(grep -rnE 'xox[abepsr]-[A-Za-z0-9-]{8,}' Sources Tests 2>/dev/null); then
    while IFS= read -r hit; do
        fail "${hit%%:*} — a Slack token literal (A4, ADR-0006)"
    done <<<"$hits"
fi
# The token is passed as an argument and never persisted by a kit; only the app's TokenStore may
# reach the Keychain, and nothing may put a token in UserDefaults.
for kit in "${kits[@]}"; do
    if hits=$(grep -rnE 'SecItemAdd|SecItemCopyMatching|kSecClassGenericPassword' "Sources/$kit" 2>/dev/null); then
        while IFS= read -r hit; do
            fail "$hit — a kit never stores a credential; only the app's TokenStore does (A4)"
        done <<<"$hits"
    fi
done
if hits=$(grep -rn 'SecItemAdd\|SecItemCopyMatching\|SecItemDelete\|SecItemUpdate' Sources/OnAir |
    grep -v 'TokenStore\.swift' 2>/dev/null); then
    while IFS= read -r hit; do
        fail "$hit — reach the Keychain only through TokenStore (A4, ADR-0006)"
    done <<<"$hits"
fi
# `verifier` is in the alternation because the PKCE verifier is now the system's second secret:
# during the connect window, verifier + intercepted code = token (ADR-0012).
if hits=$(grep -rniE 'UserDefaults[^\n]*\b(token|accessToken|clientSecret|verifier)\b' Sources 2>/dev/null); then
    while IFS= read -r hit; do
        fail "$hit — a credential must never reach UserDefaults (A4, ADR-0006)"
    done <<<"$hits"
fi
# String interpolation is how a credential reaches a log line, an error message, or a diagnostic
# somebody pastes into an issue. The Authorization header is the one place it must happen, so that
# line is named rather than the rule being weakened to "…unless it looks like a header".
if hits=$(grep -rnE '\\\([^)]*\b(token|accessToken|clientSecret|verifier)\b' Sources 2>/dev/null |
    grep -v 'SlackClient\.swift:[0-9]*: *request\.setValue("Bearer'); then
    while IFS= read -r hit; do
        fail "$hit — a credential must never be interpolated into a string (A4, ADR-0006/0012)"
    done <<<"$hits"
fi

echo "A5 — OnAir never opens a camera or microphone stream"
capture_apis='AVCaptureSession|AVCaptureDevice|AVCaptureDeviceInput|CMSampleBuffer|AudioDeviceStart|AudioUnitInitialize|AudioQueueStart|CMIODeviceStartStream|AVAudioEngine|AVAudioRecorder'
if hits=$(grep -rnE "$capture_apis" Sources 2>/dev/null); then
    while IFS= read -r hit; do
        fail "$hit — OnAir reads 'is running', never a stream; this would trigger a TCC prompt (A5, ADR-0001)"
    done <<<"$hits"
fi
# Matched as a plist `<key>` element, not as a bare word: Info.plist carries a comment saying these
# keys are deliberately absent, and a substring match would flag the explanation as the violation.
if hits=$(grep -rn '<key>NS\(Camera\|Microphone\)UsageDescription</key>' Resources 2>/dev/null); then
    while IFS= read -r hit; do
        fail "$hit — a usage-description key means something started capturing (A5, ADR-0001)"
    done <<<"$hits"
fi

echo "A6 — OnAir imports no PKCS#12 archive at all"
# `SecPKCS12Import` on macOS imports into the *default* keychain unless `kSecImportToMemoryOnly`
# says otherwise, so the obvious call leaves a certificate and a private key behind on every
# distinct archive — and each key's ACL names the importing binary, which is how the user ends up
# typing their login password for OnAir. 268 stranded keys on the machine that found it (ADR-0016).
#
# Since ADR-0019 there is no loopback certificate to import, so the invariant is stronger than the
# one it replaces: not "pass the right option" but "there is no import". The check stays because the
# thing it guards against is a *reintroduction* — a future TLS listener bringing the whole problem
# back with it — and a check is cheaper than remembering why the certificate left.
if hits=$(grep -rn 'SecPKCS12Import' Sources 2>/dev/null); then
    while IFS= read -r hit; do
        fail "$hit — OnAir imports no PKCS#12; the callback is a hosted relay now (A6, ADR-0019)"
    done <<<"$hits"
fi

echo "A7 — the relay page and the listener agree"
# The redirect URL is a page on the public internet (ADR-0019). It ships from this repository so it
# cannot drift from the app, but "cannot" is only true if something checks: a page pointing at the
# wrong port hands the callback to a closed door, and the user sees a browser error with nothing in
# it that names OnAir. Every value below appears in exactly two files, and this is the seam.
relay=site/callback/index.html
for required in site/index.html "$relay" site/style.css site/CNAME; do
    [ -f "$required" ] || fail "$required is missing — the redirect URL would 404 (A7, ADR-0019)"
done
if [ -f "$relay" ]; then
    swift_port=$(sed -n 's/.*defaultPort: UInt16 = \([0-9]*\).*/\1/p' \
        Sources/SlackKit/OAuth/SlackOAuth.swift)
    grep -q "DEFAULT_PORT = $swift_port;" "$relay" ||
        fail "$relay does not hand back to port $swift_port (A7, ADR-0019)"
    swift_path=$(sed -n 's/.*callbackPath = "\([^"]*\)".*/\1/p' \
        Sources/SlackKit/OAuth/LoopbackReceiver.swift)
    grep -q "CALLBACK_PATH = \"$swift_path\";" "$relay" ||
        fail "$relay does not hand back to $swift_path (A7, ADR-0019)"
fi
if [ -f site/CNAME ]; then
    # The domain is asserted from the CNAME file rather than written out again here: the file is
    # what GitHub Pages actually serves the site under, so it is the one that can be wrong.
    domain=$(tr -d '[:space:]' <site/CNAME)
    grep -q "redirectURI = \"https://$domain/callback/\"" \
        Sources/SlackKit/OAuth/SlackOAuth.swift ||
        fail "SlackOAuth.redirectURI does not point at https://$domain/callback/ (A7, ADR-0019)"
fi

if [ "$status" -eq 0 ]; then
    printf '\033[32marchitecture invariants hold\033[0m\n'
fi
exit "$status"
