# Flash

A small SwiftUI photo viewer for macOS 14+.

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

## Build

Requires Xcode 15+ command line tools (Swift 6, macOS 14+ SDK).

```bash
make run     # builds Flash.app, codesigns, opens it
make dev     # debug build with stdout streaming to your terminal
make help    # see all targets
```

The `app` target:

1. `swift build -c release`
2. Wraps the executable into `Flash.app/Contents/{MacOS,Info.plist}`
3. Codesigns it with `Resources/Flash.entitlements` (using the strongest
   available identity, falling back to ad-hoc)
4. Registers the bundle with Launch Services so Finder picks it up

## Usage

- Double-click an image in Finder and pick *Open With ▸ Flash*, or
- `open -a Flash.app /path/to/photo.jpg`, or
- Launch the app and choose `File ▸ Open…`

Once an image is shown, use `←` / `→` to flip through the rest of the folder.

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
