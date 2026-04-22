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

.DEFAULT_GOAL := app

.PHONY: help build app run open install uninstall register debug clean distclean verify

help:
	@echo "PhotoViewer make targets:"
	@echo "  build       swift build -c $(CONFIG)"
	@echo "  app         build + assemble + codesign $(BUNDLE) (default)"
	@echo "  run         app + open $(BUNDLE)"
	@echo "  open FILE=… app + open the bundle on FILE"
	@echo "  install     copy $(BUNDLE) into /Applications and re-register"
	@echo "  uninstall   remove /Applications/$(APP_NAME).app"
	@echo "  register    re-run lsregister so Finder picks up the bundle"
	@echo "  debug       CONFIG=debug build (alias)"
	@echo "  verify      print bundle codesign + entitlements info"
	@echo "  clean       rm -rf $(BUILD_DIR) and SwiftPM .build"
	@echo "  distclean   clean + remove SwiftPM caches"

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
	@echo "==> Ad-hoc codesigning"
	@codesign --force --deep --sign - \
		--entitlements "$(ENTITLEMENTS)" \
		"$(BUNDLE)"
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

clean:
	rm -rf "$(BUILD_DIR)" .build

distclean: clean
	rm -rf .swiftpm
