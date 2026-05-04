#!/usr/bin/env bash
# Generate a macOS .icns file from a square 1024×1024 (or larger) PNG
# using the system tools `sips` and `iconutil`. Apple's tooling doesn't
# accept vector input for app icons; .icns is a multi-resolution
# bitmap container, and this script populates the canonical slots
# (16, 32, 128, 256, 512 at @1x and @2x) by resampling the source.
#
# Usage: scripts/make-icon.sh <input.png> <output.icns>
#
# Idempotent: safe to call from build pipelines. Both the Makefile
# and `build-app.sh` invoke it with timestamp-based freshness checks.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <input.png> <output.icns>" >&2
    exit 64
fi

SRC="$1"
DST="$2"

if [[ ! -f "$SRC" ]]; then
    echo "Source PNG not found: $SRC" >&2
    exit 1
fi

# Work in a unique temp directory so concurrent builds (e.g. Xcode +
# CLI) don't stomp on each other; remove on exit even on failure.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/icon.iconset"
mkdir -p "$ICONSET"

# `iconutil` requires this exact naming convention. The @2x slot for
# 512×512 is the full 1024×1024 source; we copy it verbatim instead of
# resampling to itself (cheaper + bit-identical).
sips -z 16 16     "$SRC" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$SRC" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$SRC" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$SRC" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$SRC" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$SRC" "$ICONSET/icon_512x512@2x.png"

mkdir -p "$(dirname "$DST")"
iconutil --convert icns "$ICONSET" -o "$DST"
echo "==> Generated $DST"
