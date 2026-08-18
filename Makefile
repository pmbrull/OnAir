SHELL := /bin/bash
APP_NAME := OnAir
BUNDLE := .build/$(APP_NAME).app
CONFIG ?= debug

## Read from the plist rather than repeated here, so the two cannot drift.
BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist 2>/dev/null)
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null)

## OnAir needs no TCC grant, so signing is not load-bearing for permissions the way it is in an
## app that captures. It still matters for `SMAppService` (launch at login), which refuses to
## register an unsigned bundle. Ask for the identities in order of preference rather than with one
## alternation, which would pick whichever kind `security` happened to list first.
CODESIGN_ID ?= $(shell ids=$$(security find-identity -v -p codesigning 2>/dev/null); \
  pick=$$(printf '%s\n' "$$ids" | grep -oE '"Developer ID Application:[^"]*"' | head -1); \
  [ -n "$$pick" ] || pick=$$(printf '%s\n' "$$ids" | grep -oE '"Apple Development:[^"]*"' | head -1); \
  printf '%s' "$$pick" | tr -d '"')

## XCTest ships with Xcode, not with the Command Line Tools: on a CLT-only machine there is no
## XCTest module and no `xctest` runner, so a test target importing it cannot even build. The
## suite is therefore written against **Swift Testing**, which CLT does ship — but under
## Library/Developer, on no default search or runtime path. These flags put it on both. When a
## full Xcode is installed `xcrun -f xctest` succeeds, the variable is empty, and `make test` is
## a plain `swift test`. See docs/dev-loop.md.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB := /Library/Developer/CommandLineTools/Library/Developer/usr/lib
TEST_FLAGS ?= $(shell if ! xcrun -f xctest >/dev/null 2>&1 && [ -d "$(CLT_FRAMEWORKS)" ]; then \
  printf -- '--disable-xctest -Xswiftc -F -Xswiftc %s -Xlinker -rpath -Xlinker %s -Xlinker -rpath -Xlinker %s' \
    "$(CLT_FRAMEWORKS)" "$(CLT_FRAMEWORKS)" "$(CLT_LIB)"; fi)

.PHONY: help verify build test fmt fmt-check lint arch references version-rule hooks doctor \
        doctor-slack app run install site purge-loopback uninstall clean icon dist notarize release

## The release lane's targets write and then read the same artefacts; running them interleaved
## under -j would zip a bundle mid-signature. Nothing here benefits from parallel make anyway —
## the expensive steps are single swift builds with their own internal parallelism.
.NOTPARALLEL:

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-14s\033[0m %s\n", $$1, $$2}'

## The gate. Every blocking check, ordered so the cheapest failure surfaces first.
verify: references arch version-rule fmt-check lint build test ## Run the full local gate

references: ## ADR/GAP references resolve; records are indexed and their status matches their folder
	@./scripts/check-references.sh

arch: ## ARCHITECTURE.md invariants a grep can decide (A1, A2, A4, A5, A6, A7)
	@./scripts/check-architecture.sh

## The one part of the OAuth flow no Swift test can reach: the relay page runs in a browser, so
## exercising it means serving it and pointing a browser at /callback/ (ADR-0019, invariant A7).
site: ## Serve site/ locally so the callback relay can be driven with a real browser
	@echo "http://127.0.0.1:8787/callback/?code=test&state=test — OnAir must be waiting on $(shell sed -n 's/.*defaultPort: UInt16 = \([0-9]*\).*/\1/p' Sources/SlackKit/OAuth/SlackOAuth.swift)"
	@cd site && python3 -m http.server 8787 --bind 127.0.0.1

## The rule that decides what every push to main ships (ADR-0018). It is shell, so this table is
## the only thing that type-checks it — and a wrong answer here is a wrong version number on a
## signed, notarized, published artefact.
version-rule: ## The release bump rule's table (scripts/next-version.sh)
	@./scripts/check-next-version.sh

hooks: ## Install the pre-commit hooks
	@command -v pre-commit >/dev/null || { echo "pre-commit not installed: brew install pre-commit"; exit 1; }
	pre-commit install
	@echo "hooks installed; run 'pre-commit run --all-files' to check the whole tree"

build: ## Compile every target
	swift build -c $(CONFIG)

test: ## Run the test suite
	swift test $(TEST_FLAGS)

fmt: ## Format Swift sources
	@command -v swiftformat >/dev/null || { echo "swiftformat not installed: brew install swiftformat"; exit 1; }
	swiftformat Sources Tests Package.swift

## The guard and the command must be ONE shell invocation: each recipe line is its own shell, so
## an `exit 0` in a guard line skips that line and make cheerfully runs the next one anyway.
fmt-check: ## Fail if anything is unformatted (skips when swiftformat is absent)
	@# `--lint` takes no value, so it must follow the paths — leading it swallows "Sources".
	@if command -v swiftformat >/dev/null; then \
	  swiftformat Sources Tests Package.swift --lint; \
	else \
	  echo "SKIP fmt-check (swiftformat not installed)"; \
	fi

## SwiftLint loads SourceKit, which ships with Xcode and not with the Command Line Tools — on a
## CLT-only machine it does not report violations, it dies with SIGTRAP inside
## `sourcekitdInProc.framework`. That is a different thing from "the code is clean" and a different
## thing from "the code is dirty", so it is reported as its own outcome. A real violation still
## fails: only the SourceKit crash is downgraded, and only when the output says that is what it was.
lint: ## Run SwiftLint when it can actually run
	@if ! command -v swiftlint >/dev/null; then \
	  echo "SKIP lint (swiftlint not installed)"; \
	else \
	  out=$$(swiftlint lint --quiet 2>&1); code=$$?; \
	  if [ $$code -ne 0 ] && printf '%s' "$$out" | grep -qi 'sourcekitd'; then \
	    echo "SKIP lint (swiftlint needs Xcode's SourceKit; this machine has Command Line Tools only)"; \
	    echo "     CI runs it with --strict — see docs/dev-loop.md"; \
	  else \
	    printf '%s\n' "$$out"; exit $$code; \
	  fi; \
	fi

## Everything the app does, minus the window: which capture devices this Mac has, whether each
## reports "running somewhere" right now, and what the policy engine would decide about it. This
## is how you validate a change without sitting in a meeting.
doctor: build ## Diagnose this machine's devices and the engine's verdict
	@./.build/$(CONFIG)/OnAir doctor

## As `doctor`, plus one real round trip to Slack with the stored token: who you are, which
## workspace, and what your status is right now. Reads only — never writes a status.
doctor-slack: build ## As `doctor`, plus a live read-only Slack round trip
	@./.build/$(CONFIG)/OnAir doctor --slack

## SwiftPM emits a bare executable; macOS needs a bundle for LSUIElement, for SMAppService, and
## for a stable identity in System Settings. This assembles one.
app: build ## Assemble OnAir.app
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS" "$(BUNDLE)/Contents/Resources"
	@cp .build/$(CONFIG)/OnAir "$(BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(BUNDLE)/Contents/Info.plist"
	@cp Resources/AppIcon.icns "$(BUNDLE)/Contents/Resources/AppIcon.icns"
	@printf 'APPL????' > "$(BUNDLE)/Contents/PkgInfo"
	@if [ -n "$(CODESIGN_ID)" ]; then \
	  codesign --force --deep --sign "$(CODESIGN_ID)" "$(BUNDLE)" >/dev/null 2>&1 && \
	    echo "signed with $(CODESIGN_ID)" || \
	    echo "warning: signing with $(CODESIGN_ID) failed"; \
	else \
	  codesign --force --deep --sign - "$(BUNDLE)" >/dev/null 2>&1 || true; \
	  echo "note: ad-hoc signed (no codesigning identity found)."; \
	  echo "      Launch at login needs a real identity; SMAppService will refuse to register."; \
	fi
	@echo "built $(BUNDLE)"

run: app ## Build and launch the app
	@open "$(BUNDLE)"

icon: ## Regenerate Resources/AppIcon.icns from scripts/make-icon.swift
	@./scripts/make-icon.sh

## ---- The release lane (ADR-0017; the walkthrough is docs/runbooks/release.md) ---------------
##
## `dist` refuses to run without a Developer ID Application identity: an ad-hoc or Apple
## Development signature would pass here and then be refused by Gatekeeper on every other Mac,
## which is a silent fallback by another name. To exercise the lane on a machine without the
## certificate: `make dist DIST_SIGN_ID=-` (ad-hoc; --timestamp is dropped because Apple's
## timestamp service refuses ad-hoc signatures).
##
## Two `--triple` builds and a `lipo`, not `--arch arm64 --arch x86_64`: the dual-arch flag
## drives XCBuild, which ships with Xcode and not with the Command Line Tools — measured here
## 2026-08-14 ("xcbuild executable ... does not exist").

DIST_DIR := .build/dist
DIST_BUNDLE := $(DIST_DIR)/$(APP_NAME).app
DIST_ZIP := $(DIST_DIR)/$(APP_NAME)-$(VERSION).zip
NOTARY_PROFILE ?= onair-notary
## How `notarize` proves who it is. The default is the local lane's keychain profile, unchanged.
## CI has no keychain profile and no Apple ID: it overrides this with an App Store Connect API key
## (`--key <file> --key-id <id> --issuer <id>`), which is revocable on its own and keeps the
## maintainer's Apple ID out of Actions entirely (ADR-0018). Both drive this one target, so the
## lane CI runs is the lane a human can run.
NOTARY_AUTH ?= --keychain-profile $(NOTARY_PROFILE)
DIST_SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"Developer ID Application:[^"]*"' | head -1 | tr -d '"')
## `=`, not `:=` — deferred, so only the dist lane pays for the `security` shell-out. And
## `$(subst)` rather than `$(filter -,...)`, which is a word-list match that would also hit an
## identity whose name contains a lone "-" token and silently drop the timestamp.
DIST_TIMESTAMP = $(if $(subst -,,$(DIST_SIGN_ID)),--timestamp,)

## The version guard is load-bearing twice over: an unreadable plist would otherwise produce a
## quietly mislabelled "OnAir-.zip", and $(VERSION) is substituted into recipe text this shell
## executes — X.Y.Z-only means it can never carry shell (or, downstream in the cask, Ruby).
dist: ## Build, sign (hardened runtime) and zip the universal release artefact
	@printf '%s' "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$' || { \
	  echo "error: CFBundleShortVersionString from Resources/Info.plist is '$(VERSION)', not X.Y.Z."; \
	  echo "       The version names the zip, the tag and the cask; refusing a mislabelled artefact."; \
	  exit 1; \
	}
	@if [ -z "$(DIST_SIGN_ID)" ]; then \
	  echo "error: no 'Developer ID Application' identity in the keychain."; \
	  echo "       A release must be Developer-ID signed (ADR-0017) — docs/runbooks/release.md §1."; \
	  echo "       To exercise the lane without the certificate: make dist DIST_SIGN_ID=-"; \
	  exit 1; \
	fi
	swift build -c release --triple arm64-apple-macosx
	swift build -c release --triple x86_64-apple-macosx
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_BUNDLE)/Contents/MacOS" "$(DIST_BUNDLE)/Contents/Resources"
	@lipo -create .build/arm64-apple-macosx/release/OnAir .build/x86_64-apple-macosx/release/OnAir \
	  -output "$(DIST_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@cp Resources/Info.plist "$(DIST_BUNDLE)/Contents/Info.plist"
	@cp Resources/AppIcon.icns "$(DIST_BUNDLE)/Contents/Resources/AppIcon.icns"
	@printf 'APPL????' > "$(DIST_BUNDLE)/Contents/PkgInfo"
	codesign --force --options runtime $(DIST_TIMESTAMP) --sign "$(DIST_SIGN_ID)" "$(DIST_BUNDLE)"
	@ditto -c -k --keepParent "$(DIST_BUNDLE)" "$(DIST_ZIP)"
	@cd "$(DIST_DIR)" && shasum -a 256 "$(notdir $(DIST_ZIP))" > "$(notdir $(DIST_ZIP)).sha256"
	@printf 'archs: ' && lipo -archs "$(DIST_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	@echo "built $(DIST_ZIP) (v$(VERSION), signed as '$(DIST_SIGN_ID)')"

## Assessment runs BEFORE the re-zip: a failed spctl verdict must abort while the stale zip on
## disk is still visibly pre-staple, not after a fresh, publishable-looking zip and checksum
## have already been written.
notarize: ## Submit the dist zip to Apple, staple the bundle, assess, re-zip and re-checksum
	@[ -f "$(DIST_ZIP)" ] || { echo "error: $(DIST_ZIP) not found — run 'make dist' first"; exit 1; }
	xcrun notarytool submit "$(DIST_ZIP)" $(NOTARY_AUTH) --wait
	xcrun stapler staple "$(DIST_BUNDLE)"
	spctl --assess --type exec -vv "$(DIST_BUNDLE)"
	@ditto -c -k --keepParent "$(DIST_BUNDLE)" "$(DIST_ZIP)"
	@cd "$(DIST_DIR)" && shasum -a 256 "$(notdir $(DIST_ZIP))" > "$(notdir $(DIST_ZIP)).sha256"
	@echo "notarized and stapled; the artefact to publish is $(DIST_ZIP)"

## Since ADR-0018 this is the recovery lane, not the usual one: a push to main releases. Run it when
## Actions is down, when a CI run died after it started tagging, or to release from a machine.
release: dist notarize ## The whole lane locally, then the publish steps to run next
	@echo
	@echo "Artefact ready: $(DIST_ZIP)"
	@echo "  sha256: $$(cut -d' ' -f1 < '$(DIST_ZIP).sha256')"
	@echo
	@echo "Next (docs/runbooks/release.md §7):"
	@echo "  git tag v$(VERSION) && git push origin v$(VERSION)"
	@echo "  gh release create v$(VERSION) '$(DIST_ZIP)' --title 'OnAir $(VERSION)'"
	@echo "  ./scripts/make-cask.sh && HOMEBREW_TAP_TOKEN=... ./scripts/publish-cask.sh"
	@echo "  git commit -am 'chore(release): v$(VERSION)' && git push   # or the next release repeats it"

install: app ## Copy the bundle into /Applications
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "installed /Applications/$(APP_NAME).app"

## The token is a Keychain item and the loopback identity is a file; neither goes away when the
## bundle does. Removing the app without this leaves both behind.
## Reports; deletes nothing. The `--apply` run is left to a human because it removes items from
## their login keychain, and the matcher — parsed subject `O=OnAir`, never the `localhost` label —
## is the only thing standing between it and somebody's own development certificate (ADR-0016).
purge-loopback: ## Report the loopback identities stranded in the login keychain before ADR-0016/0019
	@./scripts/purge-loopback-keychain.sh

uninstall: ## Remove the app, its Keychain items and its application-support directory
	@rm -rf "/Applications/$(APP_NAME).app"
	@./scripts/purge-loopback-keychain.sh --apply
	@security delete-generic-password -s "$(BUNDLE_ID)" -a slack-token >/dev/null 2>&1 \
	  && echo "removed the Slack token from the Keychain" || true
	@security delete-generic-password -s "$(BUNDLE_ID)" -a slack-renewal >/dev/null 2>&1 \
	  && echo "removed the Slack renewal record from the Keychain" || true
	@security delete-generic-password -s "$(BUNDLE_ID)" -a slack-client >/dev/null 2>&1 \
	  && echo "removed the Slack client credentials from the Keychain" || true
	@rm -rf "$$HOME/Library/Application Support/$(APP_NAME)"
	@defaults delete "$(BUNDLE_ID)" >/dev/null 2>&1 || true
	@echo "uninstalled"

clean: ## Remove build products
	swift package clean
	@rm -rf "$(BUNDLE)" "$(DIST_DIR)"
