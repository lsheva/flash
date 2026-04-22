#!/usr/bin/env bash
# Builds PhotoViewer with SwiftPM and assembles a proper macOS .app bundle.
# The bundle is required so Launch Services can register the app as an image
# viewer (Finder "Open With").

set -euo pipefail

CONFIG="${CONFIG:-release}"
APP_NAME="PhotoViewer"
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

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS"
mkdir -p "${BUNDLE}/Contents/Resources"

cp "${EXEC}"                    "${BUNDLE}/Contents/MacOS/${APP_NAME}"
cp Resources/Info.plist         "${BUNDLE}/Contents/Info.plist"

echo "==> Ad-hoc codesigning with entitlements"
codesign --force --deep \
    --sign - \
    --entitlements Resources/PhotoViewer.entitlements \
    "${BUNDLE}"

echo "==> Registering bundle with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
    -f "${BUNDLE}" >/dev/null 2>&1 || true

echo
echo "Done.  Bundle: $(pwd)/${BUNDLE}"
echo "Run with:    open ${BUNDLE}"
echo "Open file:   open -a ${BUNDLE} /path/to/image.jpg"
