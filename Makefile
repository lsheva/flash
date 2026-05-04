# PhotoViewer — common dev tasks.
# Usage: `make`, `make run`, `make open FILE=~/Pictures/foo.jpg`, etc.

APP_NAME    := PhotoViewer
CONFIG      ?= release
BUILD_DIR   := build
BUNDLE      := $(BUILD_DIR)/$(APP_NAME).app
EXEC        := $(BUNDLE)/Contents/MacOS/$(APP_NAME)
ENTITLEMENTS := Resources/$(APP_NAME).entitlements
INFO_PLIST   := Resources/Info.plist
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Stable signing identity (created by `make setup-signing`). When present,
# the build uses it instead of an ephemeral ad-hoc signature, which is what
# lets macOS remember per-app consent decisions across rebuilds.
SIGN_NAME   := PhotoViewer Local Signing

.DEFAULT_GOAL := app

.PHONY: help build app run open install uninstall register debug clean distclean verify setup-signing trust-app remove-signing

help:
	@echo "PhotoViewer make targets:"
	@echo "  build           swift build -c $(CONFIG)"
	@echo "  app             build + assemble + codesign $(BUNDLE) (default)"
	@echo "  run             app + open $(BUNDLE)"
	@echo "  open FILE=…     app + open the bundle on FILE"
	@echo "  install         copy $(BUNDLE) into /Applications and re-register"
	@echo "  uninstall       remove /Applications/$(APP_NAME).app"
	@echo "  register        re-run lsregister so Finder picks up the bundle"
	@echo "  debug           CONFIG=debug build (alias)"
	@echo "  verify          print bundle codesign + entitlements info"
	@echo "  setup-signing   one-time: install a stable self-signed identity"
	@echo "  trust-app       whitelist the installed bundle with Gatekeeper"
	@echo "  remove-signing  delete the stable identity from the keychain"
	@echo "  clean           rm -rf $(BUILD_DIR) and SwiftPM .build"
	@echo "  distclean       clean + remove SwiftPM caches"

build:
	swift build -c $(CONFIG)

debug:
	$(MAKE) build CONFIG=debug

# Assemble the .app bundle: copy the SwiftPM-built executable + Info.plist
# into a Cocoa bundle layout, then ad-hoc codesign with the entitlements
# and re-register it with Launch Services.
$(BUNDLE): build $(INFO_PLIST) $(ENTITLEMENTS)
	@echo "==> Assembling $(BUNDLE)"
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(BUNDLE)/Contents/MacOS"
	@mkdir -p "$(BUNDLE)/Contents/Resources"
	@cp "$$(swift build -c $(CONFIG) --show-bin-path)/$(APP_NAME)" "$(EXEC)"
	@cp "$(INFO_PLIST)" "$(BUNDLE)/Contents/Info.plist"
	@# Pick the strongest stable signing identity available, in this order:
	@#   1. Apple Development / Developer ID  - Apple-trusted, Gatekeeper-ready
	@#   2. PhotoViewer Local Signing         - our self-signed cert
	@#   3. ad-hoc (-)                        - rebuilt-each-time signature
	@#
	@# Detection uses `find-identity` without -v so we still pick up the
	@# self-signed cert even when it isn't user-trusted: codesign only
	@# needs the private key to *produce* a signature; trust only matters
	@# for *verifying* it (which we handle separately via `make trust-app`).
	@IDENT=$$( { security find-identity -p codesigning 2>/dev/null; } | \
		awk -F'"' '/"Developer ID Application/ {print $$2; found=1; exit} \
		           /"Apple Development:/      {print $$2; found=1; exit} \
		           /"$(SIGN_NAME)"/           {print $$2; found=1; exit} \
		           END {exit !found}' ); \
	if [ -n "$$IDENT" ]; then \
		echo "==> Codesigning with '$$IDENT'"; \
		codesign --force --deep --sign "$$IDENT" \
			--entitlements "$(ENTITLEMENTS)" \
			"$(BUNDLE)"; \
	else \
		echo "==> Ad-hoc codesigning  (run 'make setup-signing' for a stable identity)"; \
		codesign --force --deep --sign - \
			--entitlements "$(ENTITLEMENTS)" \
			"$(BUNDLE)"; \
	fi
	@# A quarantined app makes Sequoia's Gatekeeper prompt for every file
	@# the app reads. Locally-built bundles shouldn't be quarantined, but
	@# strip it defensively so we never fall into that trap.
	@xattr -dr com.apple.quarantine "$(BUNDLE)" 2>/dev/null || true
	@$(MAKE) -s register
	@echo "==> Done: $(abspath $(BUNDLE))"

app: $(BUNDLE)

run: app
	open "$(BUNDLE)"

# `make open FILE=~/Pictures/foo.jpg`
open: app
	@if [ -z "$(FILE)" ]; then echo "Usage: make open FILE=/path/to/image.jpg" >&2; exit 1; fi
	open -a "$(BUNDLE)" "$(FILE)"

install: app
	@echo "==> Installing to /Applications/$(APP_NAME).app"
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(BUNDLE)" /Applications/
	@xattr -dr com.apple.quarantine "/Applications/$(APP_NAME).app" 2>/dev/null || true
	@$(LSREGISTER) -f "/Applications/$(APP_NAME).app" >/dev/null 2>&1 || true
	@echo "Installed. It should now appear in Finder's Open With menu."

uninstall:
	@rm -rf "/Applications/$(APP_NAME).app"
	@$(LSREGISTER) -u "/Applications/$(APP_NAME).app" >/dev/null 2>&1 || true
	@echo "Uninstalled /Applications/$(APP_NAME).app"

register:
	@$(LSREGISTER) -f "$(BUNDLE)" >/dev/null 2>&1 || true

verify:
	@echo "== codesign =="
	@codesign -dv "$(BUNDLE)" 2>&1 || true
	@echo
	@echo "== entitlements =="
	@codesign -d --entitlements - "$(BUNDLE)" 2>&1 || true
	@echo
	@echo "== gatekeeper =="
	@spctl -a -vvv "$(BUNDLE)" 2>&1 || true

# One-time: create a stable self-signed code-signing identity in the user's
# login keychain. After this, subsequent `make app` invocations sign with
# the same identity instead of producing a fresh ad-hoc signature.
setup-signing:
	@./scripts/setup-signing.sh

# Report the current Gatekeeper assessment of the installed bundle and,
# if it's rejected, walk the user through the (now manual) approval flow.
#
# In macOS Sequoia (15+) Apple removed `spctl --add` — the only
# sanctioned way to whitelist a non-notarized app is via System Settings
# → Privacy & Security → "Open Anyway", or right-click → Open from
# Finder on first launch. Once approved, the override persists across
# rebuilds *as long as the codesign identity is stable* (which it is
# with our Apple Development / self-signed identity flow).
trust-app:
	@if [ ! -d "/Applications/$(APP_NAME).app" ]; then \
		echo "Bundle not installed. Run 'make install' first." >&2; \
		exit 1; \
	fi
	@echo "==> Gatekeeper assessment:"
	@spctl -a -vvv "/Applications/$(APP_NAME).app" 2>&1 || true
	@echo
	@if spctl -a "/Applications/$(APP_NAME).app" >/dev/null 2>&1; then \
		echo "Already accepted by Gatekeeper. No action needed."; \
	else \
		echo "Bundle is not yet approved. To approve it (one-time):"; \
		echo; \
		echo "  Option A (Finder):"; \
		echo "    1. Open /Applications in Finder."; \
		echo "    2. Right-click PhotoViewer → Open."; \
		echo "    3. Click 'Open' / 'Open Anyway' in the dialog."; \
		echo; \
		echo "  Option B (System Settings):"; \
		echo "    1. Try to launch the app once (it'll be blocked)."; \
		echo "    2. System Settings → Privacy & Security → scroll to"; \
		echo "       the bottom → click 'Open Anyway' next to PhotoViewer."; \
		echo; \
		echo "  After approval, the decision sticks across rebuilds because"; \
		echo "  the codesign identity stays the same."; \
		open "/Applications/$(APP_NAME).app" >/dev/null 2>&1 || true; \
	fi

# Inverse of setup-signing: remove the identity from the keychain (e.g.
# before regenerating it, or to revert to ad-hoc-only builds).
remove-signing:
	@echo "==> Removing identity '$(SIGN_NAME)' from login keychain"
	@security delete-identity -c "$(SIGN_NAME)" \
		"$(HOME)/Library/Keychains/login.keychain-db" 2>/dev/null \
		|| echo "  (no identity by that name found)"
	@security delete-certificate -c "$(SIGN_NAME)" \
		"$(HOME)/Library/Keychains/login.keychain-db" 2>/dev/null || true
	@echo "Done."

clean:
	rm -rf "$(BUILD_DIR)" .build

distclean: clean
	rm -rf .swiftpm
