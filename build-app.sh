#!/usr/bin/env bash
# Builds Flash with SwiftPM and assembles a proper macOS .app bundle.
# The bundle is required so Launch Services can register the app as an image
# viewer (Finder "Open With").

set -euo pipefail

CONFIG="${CONFIG:-release}"
APP_NAME="Flash"
BUNDLE="build/${APP_NAME}.app"

cd "$(dirname "$0")"

echo "==> Building (${CONFIG})"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)"
EXEC="${BIN_PATH}/${APP_NAME}"

if [[ ! -x "${EXEC}" ]]; then
    echo "Executable not found at ${EXEC}" >&2
    exit 1
fi

# Refresh the .icns whenever the source PNG is newer than (or before)
# the current icns. Cheap when up-to-date; rebuilds in well under a
# second when stale.
ICON_SRC="icon.png"
ICON_OUT="Resources/${APP_NAME}.icns"
if [[ -f "${ICON_SRC}" ]]; then
    if [[ ! -f "${ICON_OUT}" ]] || [[ "${ICON_SRC}" -nt "${ICON_OUT}" ]]; then
        echo "==> Generating app icon"
        ./scripts/make-icon.sh "${ICON_SRC}" "${ICON_OUT}"
    fi
fi

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${EXEC}"                    "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist         "${BUNDLE}/Contents/Info.plist"
if [[ -f "${ICON_OUT}" ]]; then
    cp "${ICON_OUT}"            "${BUNDLE}/Contents/Resources/"
fi

echo "==> Ad-hoc codesigning with entitlements"
codesign --force --deep \
    --sign - \
    --entitlements Resources/Flash.entitlements \
    "${BUNDLE}"

# Strip any quarantine attribute the bundle (or its files) might have
# inherited. A quarantined app gets *all* of its file-read operations
# scrutinised by Gatekeeper, which on Sequoia means a dialog per file.
echo "==> Removing quarantine attribute"
xattr -dr com.apple.quarantine "${BUNDLE}" 2>/dev/null || true

echo "==> Registering bundle with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "${BUNDLE}" >/dev/null 2>&1 || true

echo
echo "Done.  Bundle: $(pwd)/${BUNDLE}"
echo "Run with:    open ${BUNDLE}"
echo "Open file:   open -a ${BUNDLE} /path/to/image.jpg"
