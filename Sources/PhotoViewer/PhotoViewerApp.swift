import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct PhotoViewerApp: App {
    @StateObject private var loader = ImageLoader()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Bridge AppKit -> SwiftUI store so files opened by Launch Services
        // (Finder "Open With", `open -a`, dock drops, etc.) reach our model
        // even before any SwiftUI scene exists.
        AppDelegate.openHandler = { [loader = _loader] url in
            Task { @MainActor in loader.wrappedValue.open(url: url) }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(loader)
                .onOpenURL { url in loader.open(url: url) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            // Menu items use ⌘←/⌘→ so they don't shadow the bare arrow-key
            // handler in `ArrowKeyHandler`. Bare arrows as menu key-equivalents
            // are unreliable on macOS and end up swallowing the event.
            CommandGroup(after: .sidebar) {
                Button("Previous Image") { loader.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(loader.siblings.isEmpty)
                Button("Next Image") { loader.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                    .disabled(loader.siblings.isEmpty)

                Divider()

                Button(loader.thumbnailPosition == .hidden ? "Show Thumbnails" : "Hide Thumbnails") {
                    loader.thumbnailPosition = (loader.thumbnailPosition == .hidden) ? .bottom : .hidden
                }
                .keyboardShortcut("t", modifiers: .command)

                Menu("Thumbnail Position") {
                    Picker("", selection: $loader.thumbnailPosition) {
                        Text("Hidden").tag(ThumbnailPosition.hidden)
                        Text("Bottom").tag(ThumbnailPosition.bottom)
                        Text("Trailing").tag(ThumbnailPosition.trailing)
                    }
                    .pickerStyle(.inline)
                }

                Divider()

                Button("Zoom In") { loader.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(loader.zoom.factor >= Zoom.max - 0.001)
                Button("Zoom Out") { loader.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(loader.zoom.factor <= Zoom.min + 0.001)
                Button("Fit to Window") { loader.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button(loader.showsMetadata ? "Hide Image Info" : "Show Image Info") {
                    loader.showsMetadata.toggle()
                }
                .keyboardShortcut("i", modifiers: .command)
            }
        }
    }

    @MainActor
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ImageLoader.supportedTypes
        panel.message = "Choose an image to open"
        if panel.runModal() == .OK, let url = panel.url {
            loader.open(url: url)
        }
    }
}

/// Minimal AppDelegate to receive Launch Services file-open events and
/// forward them to whichever ImageLoader is currently alive.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openHandler: ((URL) -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in Self.openHandler?(url) }
    }
}
