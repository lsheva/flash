import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var loader: ImageLoader
    @FocusState private var focused: Bool

    var body: some View {
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
        .frame(minWidth: 720, minHeight: 480)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .modifier(ArrowKeyHandler(onLeft: loader.previous, onRight: loader.next))
        .onAppear { focused = true }
        .navigationTitle(windowTitle)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if loader.showsMetadata {
                MetadataBar()
            }
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
                LoadLogOverlay(log: loader.log) {
                    loader.showsLog = false
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: loader.showsLog)
    }

    @ViewBuilder
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
                    Label("Hidden",   systemImage: "rectangle").tag(ThumbnailPosition.hidden)
                    Label("Bottom",   systemImage: "rectangle.bottomthird.inset.filled").tag(ThumbnailPosition.bottom)
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

    private var thumbnailIcon: String {
        switch loader.thumbnailPosition {
        case .hidden:   "square.grid.2x2"
        case .bottom:   "rectangle.bottomthird.inset.filled"
        case .trailing: "rectangle.trailingthird.inset.filled"
        }
    }

    /// "Fit" while in fit mode, otherwise the absolute scale rounded to a
    /// percentage. Uses the live effective scale that `ZoomableImage`
    /// publishes back so "Fit" is shown alongside the user's current view.
    private var zoomLabel: String {
        switch loader.zoom {
        case .fit:           return "Fit"
        case .scale(let s):  return "\(Int((s * 100).rounded()))%"
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
        guard let url = loader.currentURL else { return "Photo Viewer" }
        return url.lastPathComponent
    }
}

// MARK: - Photographic background

/// Neutral mid-gray backdrop with a faint radial vignette, so colors are
/// easy to judge and the image has a subtle "studio" depth.
private struct PhotographicBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.18, green: 0.18, blue: 0.18)
            RadialGradient(
                colors: [Color.white.opacity(0.05), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 900
            )
            .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Zoomable image

/// Mutable bag of "current frame" values that the scroll-wheel monitor
/// needs but can't easily capture from a SwiftUI value-type view.
/// We update the fields from `body` on every render and the monitor reads
/// them at event time.
private final class ZoomGeometryBox {
    var viewport: CGSize = .zero
    var scaled:   CGSize = .zero
    var hovered:  Bool   = false
}

/// Owns a single `NSEvent` local monitor for scroll-wheel events. The
/// payload closure can be reassigned at any time; the monitor itself is
/// installed once.
private final class ScrollWheelHandler {
    var handler: ((NSEvent) -> NSEvent?)?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handler?(event) ?? event
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { uninstall() }
}

/// Displays the image at "fit-to-window × zoom factor".
///
/// We render the image directly with `.offset` + `.frame` (no `ScrollView`)
/// so we have pixel-level control over the pan offset. That lets us anchor
/// pinch-to-zoom around the cursor: the point under the user's fingers at
/// the start of the gesture stays under the cursor as the factor changes.
///
/// An `NSImageView` wrapped to opt in to EDR (Extended Dynamic Range)
/// rendering. When the backing display supports it, pixel values above
/// SDR white (> 1.0 in the image's color space) are rendered at their
/// true luminance rather than being clipped, so HDR images — HEIC gain-map,
/// AVIF HDR, OpenEXR, Radiance HDR, etc. — look as intended.
///
/// Interpolation at the `CALayer` level mirrors SwiftUI's `.interpolation`:
/// nearest-neighbour (sharp pixels) when zoomed in past 1:1, trilinear
/// (smooth) when zoomed out.
private struct HDRImageView: NSViewRepresentable {
    let image: NSImage
    /// `true` → nearest-neighbour magnification (zoomed in ≥ 100%).
    let pixelated: Bool
    /// Synchronous hook invoked the instant we're about to swap the
    /// bitmap. Implementations capture per-commit state (e.g. the
    /// pending navigation press timestamp) and return a closure that
    /// fires once the CATransaction commit has been handed off to the
    /// render server. Returning `nil` means "no follow-up needed".
    /// Used by the loader to log press → first-frame latency without
    /// races when the user arrow-keys faster than commits land.
    let prepareImageSwap: () -> (() -> Void)?

    func makeNSView(context: Context) -> CGImageHostingView {
        let v = CGImageHostingView()
        v.wantsLayer = true
        // Replace the default action map with no-op CAActions so
        // implicit `contents`/`bounds`/`position` animations don't
        // cross-fade between images on navigation.
        v.layer?.actions = Self.disabledLayerActions
        return v
    }

    func updateNSView(_ v: CGImageHostingView, context: Context) {
        if v.displayedImage !== image {
            // Capture per-commit follow-up *before* we set up the
            // transaction. That way the press time logged on completion
            // is the one that triggered THIS swap, even if the user
            // fires another nav before this commit lands.
            let onRendered = prepareImageSwap()
            // Prefer the pre-rendered IOSurface stashed on the NSImage
            // during decode. CALayer treats an IOSurface as a Mach-port
            // reference into shared memory: the WindowServer already
            // has the bytes, and the swap-to-paint hop drops from a
            // ~95 ms cross-process bitmap copy to a single-frame
            // pointer assignment. CGImage fallback covers HDR / float
            // images where we deliberately skip the BGRA8 surface so
            // extended dynamic range survives.
            let nextContents: AnyObject? =
                image.displaySurface
                ?? image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            // Wrap the contents swap in a transaction with actions
            // disabled, belt-and-braces alongside the layer-level
            // action override above. (AppKit can replace the layer or
            // its action map during view-controller transitions,
            // full-screen toggles, backing-display changes, etc.) The
            // completion block fires after the transaction is flushed
            // to the render server, which is the closest hook we have
            // to "the new image is actually on screen".
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let onRendered {
                CATransaction.setCompletionBlock {
                    // CATransaction completion blocks for app-side
                    // transactions fire on the main thread already, so
                    // we don't need a GCD hop. We do need
                    // `assumeIsolated` to call back into our
                    // main-actor-isolated closure synchronously without
                    // tripping strict-concurrency.
                    MainActor.assumeIsolated { onRendered() }
                }
            }
            v.layer?.contents = nextContents
            v.displayedImage = image
            CATransaction.commit()
        }
        // Layer may be recreated by AppKit; re-assert EDR opt-in every update.
        v.layer?.wantsExtendedDynamicRangeContent = true
        v.layer?.magnificationFilter = pixelated ? .nearest : .linear
        v.layer?.minificationFilter  = .trilinear
        // `.resize` stretches the bitmap to layer bounds (the parent
        // SwiftUI `.frame(width:height:)` already computed the right
        // size for the current zoom); equivalent to NSImageView with
        // `.scaleAxesIndependently`.
        v.layer?.contentsGravity = .resize
        if v.layer?.actions == nil {
            v.layer?.actions = Self.disabledLayerActions
        }
    }

    /// CAAction map that no-ops the implicit animations CALayer would
    /// otherwise install for `contents`, `bounds`, and `position`. Cached
    /// once because building it on every update would churn allocations
    /// during pinch-zoom and pan.
    fileprivate static let disabledLayerActions: [String: CAAction] = [
        "contents": NSNull(),
        "bounds":   NSNull(),
        "position": NSNull(),
    ]
}

/// Plain layer-backed `NSView` used as a thin host for the image
/// bitmap. We assign the `CGImage` directly to `layer.contents` from
/// `HDRImageView.updateNSView(_:context:)`, bypassing `NSImageView`'s
/// `NSBitmapImageRep` round-trip that was adding ~95 ms per swap on
/// 24-megapixel CR3 previews.
///
/// Returning `nil` from `hitTest` makes the view invisible to AppKit's
/// event dispatch so mouse/pinch events flow through to SwiftUI's
/// gesture recognizers. `intrinsicContentSize` is `.noIntrinsicMetric`
/// so SwiftUI doesn't try to size around the image's natural pixel
/// dimensions and fight our explicit `.frame(width:height:)`.
final class CGImageHostingView: NSView {
    /// Identity of the most recently committed `NSImage`. Used by
    /// `HDRImageView.updateNSView` to detect actual changes — comparing
    /// `layer.contents` directly is unreliable because the contents can
    /// be either an IOSurface or a CGImage and CALayer's internal
    /// representation may transform it on the way in.
    var displayedImage: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
        layer?.actions = HDRImageView.disabledLayerActions
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    /// Layer-backed NSViews redraw their contents at the backing
    /// scale; opting into `contentsScale = 1.0` keeps CALayer from
    /// doing its own resampling pass on top of our `magnificationFilter`.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2.0
    }
}

/// Panning sources:
/// - Mouse drag (`DragGesture`)
/// - Trackpad two-finger swipe / mouse wheel (a local `NSEvent` scroll-wheel
///   monitor that updates `offset` directly when zoomed in and the cursor
///   is over the image).
///
/// When zoomed in, lightweight overlay scrollbars on the right and bottom
/// edges show the visible portion, fading themselves out automatically
/// after a short idle period.
private struct ZoomableImage: View {
    let image: NSImage
    @EnvironmentObject var loader: ImageLoader

    /// Backing scale factor of the display the view is currently on
    /// (1.0 on a 1× monitor, 2.0 on Retina, etc.). Used to convert between
    /// "absolute zoom" (image-pixel : screen-backing-pixel) and SwiftUI's
    /// "points per image pixel" rendering metric.
    @Environment(\.displayScale) private var displayScale: CGFloat

    /// Resting pan offset, in viewport-center coordinates (i.e. (0,0) means
    /// the image is centered in the viewport). Positive x moves the image
    /// to the right, positive y moves it down. Measured in points.
    @State private var offset: CGSize = .zero

    /// Most recent cursor position, also in viewport-center coordinates.
    @State private var cursor: CGPoint? = nil

    /// Live pinch multiplier (resets to 1.0 between gestures).
    @GestureState private var pinch: CGFloat = 1.0

    /// Snapshot taken at the moment a pinch begins. We record the *points
    /// per image pixel* in effect at that moment so we can scale linearly
    /// from a single source of truth, even if the user starts pinching
    /// while in `.fit` mode.
    @State private var pinchStart: PinchStart? = nil

    /// In-progress mouse-drag translation (resets on release).
    @GestureState private var dragDelta: CGSize = .zero

    @State private var geom = ZoomGeometryBox()
    @State private var scrollHandler = ScrollWheelHandler()

    /// Bumped on every pan event so the scrollbar overlay can fade out
    /// after a brief idle period.
    @State private var lastInteraction = Date.distantPast
    @State private var scrollbarsVisible = false

    private struct PinchStart: Equatable {
        var ppp:    CGFloat   // points per image pixel at gesture start
        var offset: CGSize
        var cursor: CGPoint
    }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let imgSize  = image.size
            let fitPPP   = fitScale(image: imgSize, into: viewport)
            let restPPP  = restingPPP(fit: fitPPP)
            let livePPP: CGFloat = {
                if let start = pinchStart {
                    return clampPPP(start.ppp * pinch, fit: fitPPP)
                }
                return restPPP
            }()

            let scaledSize = CGSize(
                width:  imgSize.width  * livePPP,
                height: imgSize.height * livePPP
            )

            let liveOffset = clampOffset(
                rawOffset(forPPP: livePPP),
                scaled: scaledSize,
                viewport: viewport
            )

            // Push current frame metrics to objects that need them outside
            // the view tree (scroll-wheel monitor, toolbar). Wrapped in a
            // let-bound closure because @ViewBuilder rejects bare
            // assignment statements.
            let _: Void = {
                geom.viewport = viewport
                geom.scaled   = scaledSize
                loader.currentEffectiveScale = livePPP * displayScale
            }()

            Color.clear
                .overlay {
                    HDRImageView(
                        image: image,
                        pixelated: livePPP * displayScale >= 1.0,
                        prepareImageSwap: { [loader] in
                            // Snapshot the press info now (clearing it
                            // from the loader) so the latency we log
                            // matches THIS commit, even under rapid
                            // arrow-key fire. Then split the timeline
                            // into two halves so the dev overlay shows
                            // where the time actually goes:
                            //
                            //   press → swap   (SwiftUI body + view update)
                            //   swap  → paint  (CALayer commit + GPU
                            //                   upload + WindowServer)
                            //
                            // We always return a follow-up closure (even
                            // when there's no press to log) because the
                            // loader uses the paint-completion signal to
                            // *defer* neighbour prefetching until after
                            // the foreground GPU upload — without it,
                            // ImageIO's hardware JPEG decoder contends
                            // with the WindowServer's IOSurface upload
                            // for shared silicon and adds ~100 ms to the
                            // visible swap-to-paint window.
                            let nav = loader.takeNavStart()
                            let log = loader.log
                            let swapTime = Date()
                            if let nav {
                                let toSwapMs = Int((swapTime.timeIntervalSince(nav.timestamp) * 1000).rounded())
                                log.info("swap  \(nav.label): +\(toSwapMs) ms (press → swap)")
                            }
                            return {
                                if let nav {
                                    let now = Date()
                                    let totalMs = Int((now.timeIntervalSince(nav.timestamp) * 1000).rounded())
                                    let commitMs = Int((now.timeIntervalSince(swapTime) * 1000).rounded())
                                    log.info("paint \(nav.label): \(totalMs) ms total (\(commitMs) ms swap → render)")
                                }
                                loader.notePaintCommitted()
                            }
                        }
                    )
                    .frame(width: scaledSize.width, height: scaledSize.height)
                    .offset(liveOffset)
                }
                .frame(width: viewport.width, height: viewport.height)
                .clipped()
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    if scaledSize.width > viewport.width + 0.5 {
                        ScrollIndicator(
                            axis: .horizontal,
                            visibleFraction: viewport.width / scaledSize.width,
                            position: scrollPosition(offsetAxis: liveOffset.width,
                                                    scaledExtent: scaledSize.width,
                                                    viewportExtent: viewport.width)
                        )
                        .frame(width: viewport.width - 16, height: 6)
                        .padding(.bottom, 5)
                        .opacity(scrollbarsVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: scrollbarsVisible)
                    }
                }
                .overlay(alignment: .trailing) {
                    if scaledSize.height > viewport.height + 0.5 {
                        ScrollIndicator(
                            axis: .vertical,
                            visibleFraction: viewport.height / scaledSize.height,
                            position: scrollPosition(offsetAxis: liveOffset.height,
                                                    scaledExtent: scaledSize.height,
                                                    viewportExtent: viewport.height)
                        )
                        .frame(width: 6, height: viewport.height - 16)
                        .padding(.trailing, 5)
                        .opacity(scrollbarsVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: scrollbarsVisible)
                    }
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        cursor = CGPoint(
                            x: p.x - viewport.width  / 2,
                            y: p.y - viewport.height / 2
                        )
                        geom.hovered = true
                    case .ended:
                        cursor = nil
                        geom.hovered = false
                    }
                }
                .gesture(magnify(fit: fitPPP, restPPP: restPPP, imgSize: imgSize, viewport: viewport))
                .simultaneousGesture(pan(scaled: scaledSize, viewport: viewport))
                .onChange(of: liveOffset) { _, _ in flashScrollbars() }
                .onChange(of: loader.zoom) { _, new in
                    if new.isFit {
                        withAnimation(.spring(duration: 0.18)) { offset = .zero }
                    }
                    flashScrollbars()
                }
                .onChange(of: loader.currentURL) { _, _ in
                    // Reset pan when the user navigates to a different file.
                    // We deliberately key on URL (not on `image`) so that an
                    // in-place RAW preview → full-resolution upgrade for the
                    // *same* file doesn't snap the user away from where they
                    // were panned.
                    offset = .zero
                }
                .onAppear {
                    installScrollMonitor()
                }
                .onDisappear {
                    scrollHandler.uninstall()
                }
        }
    }

    // MARK: Zoom math

    /// "Resting" points-per-image-pixel value implied by the loader's
    /// current zoom mode (i.e. ignoring any in-progress pinch).
    private func restingPPP(fit: CGFloat) -> CGFloat {
        switch loader.zoom {
        case .fit:           return fit
        case .scale(let s):  return s / displayScale
        }
    }

    /// Clamp a candidate PPP so the resulting absolute scale stays within
    /// `Zoom.min ... Zoom.max`, but never let the user shrink the image
    /// smaller than fit-to-window — that would just leave empty space.
    private func clampPPP(_ raw: CGFloat, fit: CGFloat) -> CGFloat {
        let minPPP = max(Zoom.min / displayScale, fit)
        let maxPPP = Zoom.max / displayScale
        return min(max(raw, minPPP), maxPPP)
    }

    // MARK: Scroll wheel / trackpad pan

    private func installScrollMonitor() {
        scrollHandler.handler = { [self] event in
            guard geom.hovered,
                  geom.scaled.width  > geom.viewport.width  + 0.5 ||
                  geom.scaled.height > geom.viewport.height + 0.5
            else { return event }

            let raw = CGSize(
                width:  offset.width  + event.scrollingDeltaX,
                height: offset.height + event.scrollingDeltaY
            )
            offset = clampOffset(raw, scaled: geom.scaled, viewport: geom.viewport)
            flashScrollbars()
            return nil
        }
        scrollHandler.install()
    }

    private func flashScrollbars() {
        lastInteraction = Date()
        scrollbarsVisible = true
        let tag = lastInteraction
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if tag == lastInteraction { scrollbarsVisible = false }
        }
    }

    /// Maps an offset on a single axis to a 0…1 scrollbar position
    /// (0 = thumb at start of track, 1 = thumb at end).
    private func scrollPosition(offsetAxis: CGFloat, scaledExtent: CGFloat, viewportExtent: CGFloat) -> CGFloat {
        let range = scaledExtent - viewportExtent
        guard range > 0 else { return 0.5 }
        return min(max(0.5 - offsetAxis / range, 0), 1)
    }

    // MARK: Gesture builders

    private func magnify(fit: CGFloat, restPPP: CGFloat, imgSize: CGSize, viewport: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .updating($pinch) { value, state, _ in
                state = value.magnification
            }
            .onChanged { _ in
                if pinchStart == nil {
                    pinchStart = PinchStart(
                        ppp:    restPPP,
                        offset: offset,
                        cursor: cursor ?? .zero
                    )
                }
            }
            .onEnded { value in
                let start = pinchStart
                    ?? PinchStart(ppp: restPPP, offset: offset, cursor: cursor ?? .zero)
                let newPPP = clampPPP(start.ppp * value.magnification, fit: fit)
                let r = newPPP / start.ppp
                let committed = CGSize(
                    width:  start.cursor.x * (1 - r) + start.offset.width  * r,
                    height: start.cursor.y * (1 - r) + start.offset.height * r
                )
                let scaled = CGSize(width: imgSize.width * newPPP,
                                    height: imgSize.height * newPPP)
                loader.zoom = .scale(newPPP * displayScale)
                offset = clampOffset(committed, scaled: scaled, viewport: viewport)
                pinchStart = nil
            }
    }

    private func pan(scaled: CGSize, viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dragDelta) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let raw = CGSize(
                    width:  offset.width  + value.translation.width,
                    height: offset.height + value.translation.height
                )
                offset = clampOffset(raw, scaled: scaled, viewport: viewport)
            }
    }

    // MARK: Geometry helpers

    /// Compose the live offset for the current frame: anchored-pinch offset
    /// (if a pinch is active) plus any in-progress mouse-drag delta.
    private func rawOffset(forPPP livePPP: CGFloat) -> CGSize {
        var base: CGSize
        if let start = pinchStart {
            let r = livePPP / start.ppp
            base = CGSize(
                width:  start.cursor.x * (1 - r) + start.offset.width  * r,
                height: start.cursor.y * (1 - r) + start.offset.height * r
            )
        } else {
            base = offset
        }
        base.width  += dragDelta.width
        base.height += dragDelta.height
        return base
    }

    /// Keep the image from being dragged completely outside the viewport.
    /// When the image is smaller than the viewport on an axis, force-center
    /// it on that axis; otherwise allow it to move within
    /// `±(scaledSize - viewport) / 2`.
    private func clampOffset(_ raw: CGSize, scaled: CGSize, viewport: CGSize) -> CGSize {
        let maxX = max(0, (scaled.width  - viewport.width)  / 2)
        let maxY = max(0, (scaled.height - viewport.height) / 2)
        return CGSize(
            width:  min(max(raw.width,  -maxX), maxX),
            height: min(max(raw.height, -maxY), maxY)
        )
    }

    private func fitScale(image: CGSize, into viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0,
              viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / image.width, viewport.height / image.height)
    }
}

// MARK: - Scroll indicator (custom overlay scrollbar)

private struct ScrollIndicator: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    let visibleFraction: CGFloat   // viewport / content, in (0, 1]
    let position: CGFloat          // 0…1, where the thumb sits on the track

    var body: some View {
        GeometryReader { geo in
            let trackLen = (axis == .horizontal) ? geo.size.width : geo.size.height
            let thumbLen = max(24, trackLen * min(max(visibleFraction, 0), 1))
            let thumbPos = (trackLen - thumbLen) * min(max(position, 0), 1)

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(.black.opacity(0.18))
                Capsule()
                    .fill(.white.opacity(0.7))
                    .frame(
                        width:  axis == .horizontal ? thumbLen     : geo.size.width,
                        height: axis == .horizontal ? geo.size.height : thumbLen
                    )
                    .offset(
                        x: axis == .horizontal ? thumbPos : 0,
                        y: axis == .horizontal ? 0        : thumbPos
                    )
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Bottom metadata bar

private struct MetadataBar: View {
    @EnvironmentObject var loader: ImageLoader

    /// Shown on the right of the metadata summary when the on-screen
    /// bitmap differs from the source pixel dimensions (e.g. capped
    /// HEIC, embedded RAW preview, RAW awaiting full-res upgrade).
    private var renderedSizeText: String? {
        guard
            let rendered = loader.renderedBitmapSize,
            let meta     = loader.metadata
        else { return nil }
        let rw = Int(rendered.width.rounded())
        let rh = Int(rendered.height.rounded())
        // Allow off-by-one rounding so we don't flag identical sizes.
        guard abs(rw - meta.pixelWidth) > 1 || abs(rh - meta.pixelHeight) > 1
        else { return nil }
        return "rendered \(rw) × \(rh)"
    }

    var body: some View {
        HStack(spacing: 12) {
            if let url = loader.currentURL {
                Text(url.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider().frame(height: 14)

            if let meta = loader.metadata {
                Text(meta.summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("Loading metadata…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let renderedSizeText {
                Text(renderedSizeText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .help("Pixel dimensions of the bitmap currently on screen. The source file is larger; the displayed copy was downsampled or is a smaller embedded preview.")
            }

            if loader.metadata?.isRaw == true {
                StatusBadge(
                    label: "RAW",
                    help:  "Camera RAW container. Demosaiced on the fly; embedded JPEG preview is used until you zoom past it."
                )
            }
            if loader.metadata?.isHDR == true {
                StatusBadge(
                    label: "HDR",
                    help:  "High Dynamic Range image (>8 bits per component or with an HDR gain map). Rendered with extended luminance on capable displays."
                )
            }
            if loader.isShowingRawPreview {
                RawPreviewBadge()
            }

            Spacer(minLength: 12)

            if loader.siblings.count > 1 {
                Text("\(loader.currentIndex + 1) / \(loader.siblings.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .animation(.easeInOut(duration: 0.18), value: loader.isShowingRawPreview)
        .animation(.easeInOut(duration: 0.18), value: loader.metadata)
    }
}

/// Compact pill used for boolean status flags in the metadata bar
/// (`RAW`, `HDR`). Visually mirrors `RawPreviewBadge` but keeps a
/// tighter footprint and exposes a tooltip via `help`.
private struct StatusBadge: View {
    let label: String
    let help: String

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5))
            .help(help)
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

/// Small pill rendered in the status bar while we're still showing the
/// camera-embedded JPEG preview of a RAW file. Disappears as soon as the
/// background full-resolution decode lands.
private struct RawPreviewBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "camera.aperture")
                .imageScale(.small)
            Text("Embedded preview")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary))
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5))
        .help("Showing the camera-embedded JPEG preview. The full-resolution RAW decodes in the background and replaces this when you zoom in past the preview's pixel count.")
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

// MARK: - Developer log overlay

/// Floating panel showing recent decode / prefetch / upgrade events with
/// timestamps. Toggled by ⌘⇧L. Auto-scrolls to the newest entry.
private struct LoadLogOverlay: View {
    @ObservedObject var log: LoadLog
    let onClose: () -> Void

    /// Briefly flips to `true` after a successful copy so the button
    /// icon swaps to a checkmark, then resets.
    @State private var justCopied: Bool = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(log.entries) { entry in
                            row(for: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: log.entries.last?.id) { _, newID in
                    guard let newID else { return }
                    withAnimation(.linear(duration: 0.08)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(width: 460, height: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Load log")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(log.entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                copyEntriesToPasteboard()
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help("Copy log to clipboard")
            .disabled(log.entries.isEmpty)
            Button {
                log.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Clear log")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .help("Close (⌘⇧L)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Tab-separated, one entry per line: `HH:mm:ss.SSS<TAB>LEVEL<TAB>message`.
    /// Tabs (rather than fixed-width padding) so the result pastes
    /// cleanly into spreadsheets, GitHub issue templates, Slack code
    /// blocks, etc.
    private func copyEntriesToPasteboard() {
        let lines = log.entries.map { entry in
            "\(Self.timeFormatter.string(from: entry.timestamp))\t\(entry.level.rawValue.uppercased())\t\(entry.message)"
        }
        let text = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashCopied()
    }

    private func flashCopied() {
        withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation(.easeIn(duration: 0.2)) { justCopied = false }
        }
    }

    private func row(for entry: LoadLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
            Text(entry.message)
                .font(.caption.monospaced())
                .foregroundStyle(color(for: entry.level))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func color(for level: LoadLog.Level) -> Color {
        switch level {
        case .info:  return .primary
        case .warn:  return .orange
        case .error: return .red
        }
    }
}

// MARK: - Thumbnail strip

private struct ThumbnailStrip: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis

    @EnvironmentObject var loader: ImageLoader

    private let spacing: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let cellSide = max(40, perpendicular(of: geo.size) - spacing * 2)

            ScrollViewReader { proxy in
                ScrollView(scrollAxis, showsIndicators: true) {
                    stack {
                        ForEach(Array(loader.siblings.enumerated()), id: \.element) { index, url in
                            ThumbnailCell(
                                url: url,
                                isSelected: index == loader.currentIndex,
                                side: cellSide
                            ) {
                                loader.select(url)
                            }
                            .id(url)
                        }
                    }
                    .padding(spacing)
                }
                .scrollIndicators(.visible, axes: scrollAxis)
                .onChange(of: loader.currentIndex) { _, _ in
                    guard loader.siblings.indices.contains(loader.currentIndex) else { return }
                    let target = loader.siblings[loader.currentIndex]
                    withAnimation(.easeInOut(duration: 0.15)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
                .onAppear {
                    guard loader.siblings.indices.contains(loader.currentIndex) else { return }
                    proxy.scrollTo(loader.siblings[loader.currentIndex], anchor: .center)
                }
            }
        }
        .background(.regularMaterial)
    }

    private var scrollAxis: SwiftUI.Axis.Set {
        axis == .horizontal ? .horizontal : .vertical
    }

    private func perpendicular(of size: CGSize) -> CGFloat {
        axis == .horizontal ? size.height : size.width
    }

    @ViewBuilder
    private func stack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        switch axis {
        case .horizontal:
            LazyHStack(spacing: spacing, content: content)
        case .vertical:
            LazyVStack(spacing: spacing, content: content)
        }
    }
}

private struct ThumbnailCell: View {
    let url: URL
    let isSelected: Bool
    let side: CGFloat
    let action: () -> Void

    @EnvironmentObject var loader: ImageLoader

    private enum LoadState: Equatable {
        case loading
        case loaded(NSImage)
        case failed
    }
    @State private var state: LoadState = .loading

    var body: some View {
        Button(action: action) {
            ZStack {
                switch state {
                case .loaded(let image):
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                case .loading:
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                                .opacity(0.6)
                        }
                case .failed:
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.black.opacity(0.15),
                        lineWidth: isSelected ? 3 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .help(url.lastPathComponent)
        .task(id: url) {
            // Reset to loading on (re-)appearance so a previous .failed
            // state doesn't get carried over forever.
            state = .loading
            if let img = await loader.thumbnail(for: url) {
                state = .loaded(img)
            } else {
                state = .failed
            }
        }
    }
}

// MARK: - Arrow-key handler

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
            case 123: onLeft();  return nil
            case 124: onRight(); return nil
            default:  return event
            }
        }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
