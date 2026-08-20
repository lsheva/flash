# Flash

A small SwiftUI photo viewer for macOS 14+ (Apple Silicon).

- Native SwiftUI UI, AppKit `NSImage` for decoding.
- Supports every format ImageIO knows about (JPEG, PNG, TIFF, GIF, BMP, ICO,
  HEIC/HEIF, WebP, most camera RAWs, ...). The list is discovered at runtime
  via `CGImageSourceCopyTypeIdentifiers()`.
- Left/Right arrows navigate to sibling images in the same folder.
- `File ▸ Open…` (`⌘O`) presents an `NSOpenPanel`.
- Registers as an image viewer via `CFBundleDocumentTypes`, so it appears in
  Finder's *Open With* menu.
- Not sandboxed (intentional — sibling-folder enumeration needs parent-folder
  read access, which the sandbox doesn't grant for `user-selected.read-only`).

## Install

The published app is **ad-hoc signed, not notarized**. macOS 15+ will often
block the first launch of a download. If that happens: open the app once,
then **System Settings → Privacy & Security → Open Anyway**.

### Homebrew

```bash
brew tap lsheva/flash
brew install --cask flash-viewer
```

That installs `Flash.app` into `/Applications`. The cask is named
`flash-viewer` because `brew install flash` is already an SD-card tool.

### Download

1. Get [Flash-0.1.0.zip](https://github.com/lsheva/flash/releases/download/v0.1.0/Flash-0.1.0.zip) from [Releases](https://github.com/lsheva/flash/releases).
2. Unzip and drag `Flash.app` into `/Applications`.
3. If macOS refuses to open it, strip quarantine, then try again:

```bash
xattr -cr /Applications/Flash.app
open /Applications/Flash.app
```

## Usage

- Double-click an image in Finder and pick *Open With ▸ Flash*, or
- `open -a Flash /path/to/photo.jpg`, or
- Launch the app and choose `File ▸ Open…`

Once an image is shown, use `←` / `→` to flip through the rest of the folder.

To skip per-folder permission prompts (Desktop, Documents, Downloads, Photos):
**System Settings → Privacy & Security → Full Disk Access** → add Flash.

## Build

Requires macOS 14+ and Xcode 15+ (Swift 6). Command Line Tools alone are
enough; there is no `.xcodeproj`.

```bash
make run     # builds Flash.app, codesigns, opens it
make dev     # debug build and open the app
make help    # see all targets
```

The `app` target:

1. `swift build -c release`
2. Wraps the executable into `Flash.app/Contents/{MacOS,Info.plist,Resources}`
3. Codesigns it with `Resources/Flash.entitlements` (using the strongest
   available identity, falling back to ad-hoc)
4. Registers the bundle with Launch Services so Finder picks it up

## Build and sign on another Mac

Signing identities live in that Mac's keychain. Do **not** copy certs or
keys from this machine — create a new identity there (or use Xcode's
Apple Development cert if that Mac is already signed into an Apple ID).

A stable identity matters: ad-hoc signatures change on every rebuild, so
macOS forgets Gatekeeper / TCC consent. A named identity makes those
decisions stick across rebuilds. This is still not notarization; the app
is only for machines you control.

### 1. Clone

```bash
git clone git@github.com:lsheva/flash.git
cd flash
xcode-select --install          # skip if Xcode is already installed
swift --version                 # expect Swift 6.x
```

### 2. One-time signing identity

If Xcode → Settings → Accounts already has an **Apple Development** or
**Developer ID Application** certificate, skip this step. `make app`
prefers those automatically.

Otherwise:

```bash
make setup-signing
```

That installs a self-signed **Flash Local Signing** identity in the login
keychain. On first `codesign`, macOS asks to use the key — click
**Always Allow**.

Optionally trust the cert so verification is quieter (one GUI prompt):

1. Open **Keychain Access**
2. Find **Flash Local Signing** in the login keychain
3. Double-click → **Trust** → set **Code Signing** to **Always Trust**

### 3. Build and install

```bash
make install                    # builds, signs, copies to /Applications
```

### 4. First-launch Gatekeeper approval (once)

macOS Sequoia removed `spctl --add`. Approve the app once:

- Right-click `/Applications/Flash.app` → **Open** → **Open**, or
- Launch it, then **System Settings → Privacy & Security** → **Open Anyway**

`make trust-app` prints the current assessment and walks through the same
flow. After this, rebuilds stay approved as long as the signing identity
does not change.

### 5. Optional: Full Disk Access

Flash is not sandboxed (it needs to list sibling files in the opened
image's folder). To skip per-folder TCC prompts for Desktop / Documents /
Downloads / Photos:

**System Settings → Privacy & Security → Full Disk Access** → add Flash.

### 6. Check the signature

```bash
make verify
```

You want a named `Authority=` (Apple Development or Flash Local Signing),
not `Signature=adhoc`.

Day to day after that: `git pull && make install`.

## Layout

```
photo-viewer/
├── Package.swift
├── Makefile
├── Resources/
│   ├── Info.plist
│   └── Flash.entitlements
└── Sources/Flash/
    ├── FlashApp.swift         # @main App + menu commands + AppDelegate
    ├── ContentView.swift      # SwiftUI view + arrow-key handling
    └── ImageLoader.swift      # Folder scan + navigation state
```
