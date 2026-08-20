#!/usr/bin/env bash
# Cut a Flash release: bump version files, ad-hoc-sign a zip, tag, upload to
# GitHub Releases, and point the lsheva/homebrew-tap cask at it.

set -euo pipefail

APP_NAME="Flash"
APP_REPO="lsheva/flash"
TAP_REPO="lsheva/homebrew-tap"
CASK_TOKEN="flash-viewer"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage:
  Scripts/release.sh <version> [--notes '...']
  Scripts/release.sh <version> --dry-run
  make release VERSION=0.1.2
  make release VERSION=0.1.2 NOTES='What changed.'

Needs macOS arm64, Xcode, gh (logged in), and push access to lsheva/flash
and lsheva/homebrew-tap. Does not rewrite git history.
EOF
}

VERSION=""
NOTES=""
DRY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notes)
            [[ $# -ge 2 ]] || die "--notes needs a string"
            NOTES="$2"
            shift 2
            ;;
        --dry-run)
            DRY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            die "unknown flag: $1"
            ;;
        *)
            [[ -z "$VERSION" ]] || die "unexpected argument: $1"
            VERSION="$1"
            shift
            ;;
    esac
done

[[ -n "$VERSION" ]] || die "usage: Scripts/release.sh <version> [--notes '...']"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 0.1.2, got '$VERSION'"
[[ "$(uname -s)" == Darwin ]] || die "releases are macOS-only"
[[ "$(uname -m)" == arm64 ]] || die "release zips are Apple Silicon (arm64) only"
command -v gh >/dev/null || die "gh is not on PATH"
command -v git >/dev/null || die "git is not on PATH"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (gh auth status)"

plist="$ROOT/Resources/Info.plist"
[[ -f "$plist" ]] || die "missing $plist"

current="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
[[ "$build" =~ ^[0-9]+$ ]] || die "CFBundleVersion is not an integer: $build"

git rev-parse --is-inside-work-tree >/dev/null
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit or stash first"

if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    die "tag v$VERSION already exists"
fi
if gh release view "v$VERSION" --repo "$APP_REPO" >/dev/null 2>&1; then
    die "GitHub release v$VERSION already exists"
fi

TAG="v$VERSION"
ZIP="$ROOT/dist/${APP_NAME}-${VERSION}.zip"
NEW_BUILD=$((build + 1))
[[ -n "$NOTES" ]] || NOTES="Flash ${VERSION}"

echo "==> Release $TAG  (was $current build $build → build $NEW_BUILD)"

if [[ "$DRY" -eq 1 ]]; then
    echo "dry-run: would bump plist/Makefile/README, make dist, tag $TAG,"
    echo "         gh release create, and bump $TAP_REPO cask $CASK_TOKEN"
    exit 0
fi

# ------------------------------------------------------------------ bump ----

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$plist"

perl -pi -e "s/^APP_VERSION := .*/APP_VERSION := ${VERSION}/" "$ROOT/Makefile"

if [[ "$current" != "$VERSION" ]]; then
    perl -pi -e "
        s/\Q${APP_NAME}-${current}.zip\E/${APP_NAME}-${VERSION}.zip/g;
        s|/download/v${current}/|/download/v${VERSION}/|g;
    " "$ROOT/README.md"
fi

git add Resources/Info.plist Makefile README.md
if git diff --cached --quiet; then
    die "version files did not change (already at $VERSION?)"
fi
git commit -m "Release ${VERSION}."
git push origin HEAD

# ------------------------------------------------------------------ build ---

echo "==> Building ad-hoc zip"
make dist
[[ -f "$ZIP" ]] || die "expected zip at $ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> sha256  $SHA"

# ------------------------------------------------------------------ github --

echo "==> Tagging $TAG"
git tag -a "$TAG" -m "${APP_NAME} ${VERSION}"
git push origin "$TAG"

echo "==> Uploading GitHub Release"
gh release create "$TAG" "$ZIP" \
    --repo "$APP_REPO" \
    --title "${APP_NAME} ${VERSION}" \
    --notes "$NOTES"

# ------------------------------------------------------------------ brew ----

echo "==> Updating Homebrew tap $TAP_REPO"
TAP="$(mktemp -d)"
trap 'rm -rf "$TAP"' EXIT
gh repo clone "$TAP_REPO" "$TAP" -- --depth 1
CASK="$TAP/Casks/${CASK_TOKEN}.rb"
[[ -f "$CASK" ]] || die "missing cask $CASK"

perl -pi -e "
    s/^  version \".*\"/  version \"${VERSION}\"/;
    s/^  sha256 \"[0-9a-f]+\"/  sha256 \"${SHA}\"/;
" "$CASK"

git -C "$TAP" add "Casks/${CASK_TOKEN}.rb"
git -C "$TAP" diff --cached --quiet && die "cask did not change"
git -C "$TAP" commit -m "Point ${CASK_TOKEN} at the ${VERSION} release."
git -C "$TAP" push origin HEAD

echo
echo "Done."
echo "  Release: https://github.com/${APP_REPO}/releases/tag/${TAG}"
echo "  Cask:    brew update && brew upgrade --cask ${CASK_TOKEN}"
echo "  sha256:  ${SHA}"
