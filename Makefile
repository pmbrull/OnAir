SHELL := /bin/bash
APP_NAME := OnAir
BUNDLE := .build/$(APP_NAME).app
CONFIG ?= debug

## Read from the plist rather than repeated here, so the two cannot drift.
BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist 2>/dev/null)

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

.PHONY: help verify build test fmt fmt-check lint arch references hooks doctor doctor-slack \
        app run install purge-loopback uninstall clean

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-14s\033[0m %s\n", $$1, $$2}'

## The gate. Every blocking check, ordered so the cheapest failure surfaces first.
verify: references arch fmt-check lint build test ## Run the full local gate

references: ## ADR/GAP references resolve; records are indexed and their status matches their folder
	@./scripts/check-references.sh

arch: ## ARCHITECTURE.md invariants a grep can decide (A1, A2, A4, A5)
	@./scripts/check-architecture.sh

hooks: ## Install the pre-commit hooks
	@command -v pre-commit >/dev/null || { echo "pre-commit not installed: brew install pre-commit"; exit 1; }
	pre-commit install
	@echo "hooks installed; run 'pre-commit run --all-files' to check the whole tree"

build: ## Compile every target
	swift build

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

install: app ## Copy the bundle into /Applications
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(BUNDLE)" "/Applications/$(APP_NAME).app"
	@echo "installed /Applications/$(APP_NAME).app"

## The token is a Keychain item and the loopback identity is a file; neither goes away when the
## bundle does. Removing the app without this leaves both behind.
## Reports; deletes nothing. The `--apply` run is left to a human because it removes items from
## their login keychain, and the matcher — parsed subject `O=OnAir`, never the `localhost` label —
## is the only thing standing between it and somebody's own development certificate (ADR-0016).
purge-loopback: ## Report the loopback identities stranded in the login keychain before ADR-0016
	@./scripts/purge-loopback-keychain.sh

uninstall: ## Remove the app, its Keychain items and its application-support directory
	@rm -rf "/Applications/$(APP_NAME).app"
	@./scripts/purge-loopback-keychain.sh --apply
	@security delete-generic-password -s "$(BUNDLE_ID)" -a slack-token >/dev/null 2>&1 \
	  && echo "removed the Slack token from the Keychain" || true
	@security delete-generic-password -s "$(BUNDLE_ID)" -a slack-client >/dev/null 2>&1 \
	  && echo "removed the Slack client credentials from the Keychain" || true
	@rm -rf "$$HOME/Library/Application Support/$(APP_NAME)"
	@defaults delete "$(BUNDLE_ID)" >/dev/null 2>&1 || true
	@echo "uninstalled"

clean: ## Remove build products
	swift package clean
	@rm -rf "$(BUNDLE)"
