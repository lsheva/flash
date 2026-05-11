import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct FlashApp: App {
    @StateObject private var loader = ImageLoader()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(loader)
                .onOpenURL { url in loader.open(url: url) }
                .onAppear {
                    AppDelegate.openHandler = {
                        url in Task {
                            @MainActor in loader.open(url: url)
                        }
                    }
                    AppDelegate.fullscreenHandler = {
                        isFullscreen in Task {
                            @MainActor in loader.isFullscreen = isFullscreen
                        }
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)

                Divider()

                Button("Move to Trash") { loader.deleteCurrent() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!loader.canDeleteCurrent)
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
                    .disabled((loader.zoom.absolute ?? loader.currentEffectiveScale) >= Zoom.max - 0.001)
                Button("Zoom Out") { loader.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled((loader.zoom.absolute ?? loader.currentEffectiveScale) <= Zoom.min + 0.001)
                Button("Actual Size") { loader.zoomToActualSize() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Fit to Window") { loader.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)

                Divider()

                Button(loader.showsMetadata ? "Hide Image Info" : "Show Image Info") {
                    loader.showsMetadata.toggle()
                }
                .keyboardShortcut("i", modifiers: .command)

                Divider()

                Button("Toggle Load Log") {
                    loader.showsLog.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
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
    @MainActor static var fullscreenHandler: ((Bool) -> Void)?
    /// File passed on argv when the binary is run directly (e.g. `make dev`).
    /// Launch Services doesn't deliver argv via `application(_:open:)`, so we
    /// stash it here and `ContentView` consumes it on first appear.
    @MainActor static var pendingArgvURL: URL?

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    func application(_: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in Self.openHandler?(url) }
    }

    func applicationDidFinishLaunching(_: Notification) {
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: url.path) {
                Self.pendingArgvURL = url
                break
            }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nil, queue: .main) {
            _ in
            Task {
                @MainActor in Self.fullscreenHandler?(true)
            }
        }
        nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) {
            _ in
            Task {
                @MainActor in Self.fullscreenHandler?(false)
            }
        }
    }
}
