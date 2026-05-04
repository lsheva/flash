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
- App-sandboxed with `user-selected.read-only`, plus security-scoped access
  to the parent folder for sibling enumeration.

## Build

Requires Xcode 15+ command line tools (Swift 6, macOS 14+ SDK).

```bash
./build-app.sh
open build/Flash.app
```

The script:

1. `swift build -c release`
2. Wraps the executable into `build/Flash.app/Contents/{MacOS,Info.plist}`
3. Ad-hoc codesigns it with `Resources/Flash.entitlements`
4. Registers the bundle with Launch Services so Finder picks it up

## Usage

- Double-click an image in Finder and pick *Open With ▸ Flash*, or
- `open -a build/Flash.app /path/to/photo.jpg`, or
- Launch the app and choose `File ▸ Open…`

Once an image is shown, use `←` / `→` to flip through the rest of the folder.

## Layout

```
photo-viewer/
├── Package.swift
├── build-app.sh
├── Resources/
│   ├── Info.plist
│   └── Flash.entitlements
└── Sources/Flash/
    ├── FlashApp.swift         # @main App + menu commands + AppDelegate
    ├── ContentView.swift      # SwiftUI view + arrow-key handling
    └── ImageLoader.swift      # Folder scan + navigation state
```
