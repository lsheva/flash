import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var loader: ImageLoader
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if loader.isFullscreen {
                fullscreenLayout
            } else {
                windowedLayout
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .modifier(ArrowKeyHandler(onLeft: loader.previous, onRight: loader.next))
        .onAppear {
            focused = true
            if let url = AppDelegate.pendingArgvURL {
                AppDelegate.pendingArgvURL = nil
                loader.open(url: url)
            }
        }
        .navigationTitle(windowTitle)
        .toolbar { toolbarContent }
        .toolbar(showsChrome ? .automatic : .hidden, for: .windowToolbar)
        .onChange(of: showsChrome) { _, visible in
            guard loader.isFullscreen else { return }
            NSApp.keyWindow?.toolbar?.isVisible = visible
        }
        .onChange(of: loader.isFullscreen) { _, fs in
            NSApp.keyWindow?.toolbar?.isVisible = fs ? showsChrome : true
        }
        .animation(.easeInOut(duration: 0.25), value: showsChrome)
    }

    private var windowedLayout: some View {
        Group {
            switch loader.thumbnailPosition {
            case .hidden:
                imagePane
            case .bottom:
                VSplitView {
                    imagePane
                    ThumbnailStrip(axis: .horizontal)
                        .frame(minHeight: 48, idealHeight: 60, maxHeight: 220)
                }
            case .trailing:
                HSplitView {
                    imagePane
                    ThumbnailStrip(axis: .vertical)
                        .frame(minWidth: 60, idealWidth: 80, maxWidth: 280)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if loader.showsMetadata {
                MetadataBar()
            }
        }
    }

    private var fullscreenLayout: some View {
        imagePane
            .overlay(alignment: .top) {
                if showsChrome && loader.thumbnailPosition == .trailing {
                    // nothing — trailing strip handled below
                    EmptyView()
                }
            }
            .overlay(alignment: thumbnailOverlayAlignment) {
                if showsChrome, loader.thumbnailPosition != .hidden {
                    thumbnailOverlay
                        .transition(thumbnailTransition)
                }
            }
            .overlay(alignment: .bottom) {
                if showsChrome && loader.showsMetadata {
                    MetadataBar()
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
    }

    @ViewBuilder
    private var thumbnailOverlay: some View {
        switch loader.thumbnailPosition {
        case .bottom:
            ThumbnailStrip(axis: .horizontal)
                .frame(height: 100)
                .background(.ultraThinMaterial)
        case .trailing:
            ThumbnailStrip(axis: .vertical)
                .frame(width: 140)
                .background(.ultraThinMaterial)
        case .hidden:
            EmptyView()
        }
    }

    private var thumbnailOverlayAlignment: Alignment {
        switch loader.thumbnailPosition {
        case .bottom: return .bottom
        case .trailing: return .trailing
        case .hidden: return .center
        }
    }

    private var thumbnailTransition: AnyTransition {
        switch loader.thumbnailPosition {
        case .bottom: return .move(edge: .bottom).combined(with: .opacity)
        case .trailing: return .move(edge: .trailing).combined(with: .opacity)
        case .hidden: return .opacity
        }
    }

    // MARK: - Subviews

    private var imagePane: some View {
        ZStack {
            PhotographicBackground()

            if let image = loader.image {
                ZoomableImage(image: image)
            } else {
                placeholder
            }

            if let error = loader.errorMessage {
                VStack {
                    Spacer()
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: Capsule())
                        .padding(.bottom, 24)
                }
            }

            if loader.showsLog {
                DebugOverlay(log: loader.log) {
                    loader.showsLog = false
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: loader.showsLog)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("Open an image with ⌘O,")
                .foregroundStyle(.secondary)
            Text("or drop a file from Finder.")
                .foregroundStyle(.secondary)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Each control is its own ToolbarItem so the user (and macOS itself,
        // for "Customize Toolbar") sees them as independent buttons with
        // distinct icons rather than fused groups.
        ToolbarItem(id: "previous", placement: .navigation) {
            Button {
                loader.previous()
            } label: {
                Label("Previous", systemImage: "chevron.backward")
            }
            .help("Previous image (←)")
            .disabled(loader.siblings.count <= 1)
        }

        ToolbarItem(id: "next", placement: .navigation) {
            Button {
                loader.next()
            } label: {
                Label("Next", systemImage: "chevron.forward")
            }
            .help("Next image (→)")
            .disabled(loader.siblings.count <= 1)
        }

        ToolbarItem(id: "zoomOut", placement: .principal) {
            Button {
                loader.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .help("Zoom out (⌘−)")
            .disabled(zoomOutDisabled)
        }

        ToolbarItem(id: "zoomFit", placement: .principal) {
            // Click cycles Fit ↔ 100%. Holding ⌥ on click jumps to actual
            // size unconditionally (a power-user shortcut Preview also has).
            Menu {
                Button("Fit to Window") { loader.zoomToFit() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Actual Size (100%)") { loader.zoomToActualSize() }
                    .keyboardShortcut("1", modifiers: .command)
            } label: {
                Text(zoomLabel)
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 52)
            } primaryAction: {
                if loader.zoom.isFit {
                    loader.zoomToActualSize()
                } else {
                    loader.zoomToFit()
                }
            }
            .menuIndicator(.hidden)
            .help("Fit to window (⌘0) / Actual size (⌘1)")
        }

        ToolbarItem(id: "zoomIn", placement: .principal) {
            Button {
                loader.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .help("Zoom in (⌘+)")
            .disabled(zoomInDisabled)
        }

        ToolbarItem(id: "delete", placement: .primaryAction) {
            Button(role: .destructive) {
                loader.deleteCurrent()
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Move to Trash (⌘⌫)")
            .disabled(!loader.canDeleteCurrent)
        }

        ToolbarItem(id: "info", placement: .primaryAction) {
            Button {
                loader.showsMetadata.toggle()
            } label: {
                Label("Info", systemImage: loader.showsMetadata ? "info.circle.fill" : "info.circle")
            }
            .help("Show image info (⌘I)")
        }

        ToolbarItem(id: "thumbnails", placement: .primaryAction) {
            Menu {
                Picker("Thumbnails", selection: $loader.thumbnailPosition) {
                    Label("Hidden", systemImage: "rectangle").tag(ThumbnailPosition.hidden)
                    Label("Bottom", systemImage: "rectangle.bottomthird.inset.filled").tag(ThumbnailPosition.bottom)
                    Label("Trailing", systemImage: "rectangle.trailingthird.inset.filled").tag(ThumbnailPosition.trailing)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Thumbnails", systemImage: thumbnailIcon)
            } primaryAction: {
                loader.thumbnailPosition = (loader.thumbnailPosition == .hidden) ? .bottom : .hidden
            }
            .help("Show thumbnails (⌘T)")
            .menuIndicator(.visible)
        }
    }

    private var showsChrome: Bool {
        !loader.isFullscreen || loader.chromeVisible
    }

    private var thumbnailIcon: String {
        switch loader.thumbnailPosition {
        case .hidden: "square.grid.2x2"
        case .bottom: "rectangle.bottomthird.inset.filled"
        case .trailing: "rectangle.trailingthird.inset.filled"
        }
    }

    /// "Fit" while in fit mode, otherwise the absolute scale rounded to a
    /// percentage. Uses the live effective scale that `ZoomableImage`
    /// publishes back so "Fit" is shown alongside the user's current view.
    private var zoomLabel: String {
        switch loader.zoom {
        case .fit: return "Fit"
        case let .scale(s): return "\(Int((s * 100).rounded()))%"
        }
    }

    private var zoomInDisabled: Bool {
        let current = loader.zoom.absolute ?? loader.currentEffectiveScale
        return current >= Zoom.max - 0.001
    }

    private var zoomOutDisabled: Bool {
        let current = loader.zoom.absolute ?? loader.currentEffectiveScale
        return current <= Zoom.min + 0.001
    }

    private var windowTitle: String {
        guard let url = loader.currentURL else { return "Flash" }
        return url.lastPathComponent
    }
}

/// Wires arrow-key navigation. We always install a local `NSEvent` monitor
/// because `.onKeyPress` only fires when the SwiftUI view actually holds
/// keyboard focus, and on macOS focus can be lost after modal panels close,
/// title-bar clicks, etc. The monitor catches the event regardless and only
/// consumes it when no modifier keys are pressed (so ⌘← still works as a
/// menu shortcut, and Option/Shift+arrow remain available for other uses).
private struct ArrowKeyHandler: ViewModifier {
    let onLeft: () -> Void
    let onRight: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { installMonitor() }
            .onDisappear { removeMonitor() }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only look at the four "real" user modifiers. macOS sets
            // `.numericPad` (and sometimes `.function`) on arrow keys
            // automatically — including those in the check would make the
            // guard always fail and the monitor would never fire.
            let userModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            guard event.modifierFlags.intersection(userModifiers).isEmpty else {
                return event
            }

            switch event.keyCode {
            case 123: onLeft(); return nil
            case 124: onRight(); return nil
            default: return event
            }
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
