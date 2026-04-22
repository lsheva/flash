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
        }
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
            .disabled(loader.zoom.factor <= Zoom.min + 0.001)
        }

        ToolbarItem(id: "zoomFit", placement: .principal) {
            Button {
                loader.zoomToFit()
            } label: {
                Text("\(loader.zoom.displayPercent)%")
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 52)
            }
            .help("Fit to window (⌘0)")
        }

        ToolbarItem(id: "zoomIn", placement: .principal) {
            Button {
                loader.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .help("Zoom in (⌘+)")
            .disabled(loader.zoom.factor >= Zoom.max - 0.001)
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
    var imgSize:  CGSize = .zero
    var fit:      CGFloat = 1
    var hovered:  Bool = false
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

    @State private var offset: CGSize = .zero
    @State private var cursor: CGPoint? = nil
    @GestureState private var pinch: CGFloat = 1.0
    @State private var pinchStart: PinchStart? = nil
    @GestureState private var dragDelta: CGSize = .zero

    @State private var geom = ZoomGeometryBox()
    @State private var scrollHandler = ScrollWheelHandler()

    /// Bumped on every pan event (drag, wheel, pinch) so the scrollbar
    /// overlay can fade itself out after a brief idle period.
    @State private var lastInteraction = Date.distantPast
    @State private var scrollbarsVisible = false

    private struct PinchStart: Equatable {
        var factor: CGFloat
        var offset: CGSize
        var cursor: CGPoint
    }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size
            let imgSize = image.size
            let fit = fitScale(image: imgSize, into: viewport)

            // Refresh the scroll-wheel monitor's data every render. Wrapped
            // in a let-bound closure because @ViewBuilder rejects bare
            // assignment statements.
            let _: Void = {
                geom.viewport = viewport
                geom.imgSize  = imgSize
                geom.fit      = fit
            }()

            let liveFactor: CGFloat = {
                if let start = pinchStart {
                    return clamp(start.factor * pinch, Zoom.min, Zoom.max)
                }
                return loader.zoom.factor
            }()

            let liveOffset = clampOffset(
                rawOffset(for: liveFactor),
                factor: liveFactor, image: imgSize, fit: fit, viewport: viewport
            )

            let scaledSize = CGSize(
                width:  imgSize.width  * fit * liveFactor,
                height: imgSize.height * fit * liveFactor
            )

            Color.clear
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
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
                .gesture(magnify(viewport: viewport, fit: fit, imgSize: imgSize))
                .simultaneousGesture(pan(factor: liveFactor, fit: fit, imgSize: imgSize, viewport: viewport))
                .onChange(of: liveOffset) { _, _ in flashScrollbars() }
                .onChange(of: loader.zoom) { _, new in
                    if new.isFit {
                        withAnimation(.spring(duration: 0.18)) { offset = .zero }
                    }
                    flashScrollbars()
                }
                .onChange(of: image) { _, _ in
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

    // MARK: Scroll wheel / trackpad pan

    private func installScrollMonitor() {
        scrollHandler.handler = { [self] event in
            let factor = loader.zoom.factor
            guard geom.hovered, factor > 1 else { return event }

            let scaledW = geom.imgSize.width  * geom.fit * factor
            let scaledH = geom.imgSize.height * geom.fit * factor
            let maxX = max(0, (scaledW - geom.viewport.width)  / 2)
            let maxY = max(0, (scaledH - geom.viewport.height) / 2)

            // `scrollingDeltaX/Y` already respect the user's "natural scroll"
            // preference, so adding them directly to the offset moves the
            // image the same way macOS would scroll a native NSScrollView.
            let raw = CGSize(
                width:  offset.width  + event.scrollingDeltaX,
                height: offset.height + event.scrollingDeltaY
            )
            offset = CGSize(
                width:  min(max(raw.width,  -maxX), maxX),
                height: min(max(raw.height, -maxY), maxY)
            )
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
        // offset = +max ⇒ image shifted right ⇒ leftmost portion visible ⇒ thumb at 0
        // offset = -max ⇒ image shifted left  ⇒ rightmost portion visible ⇒ thumb at 1
        return min(max(0.5 - offsetAxis / range, 0), 1)
    }

    // MARK: Gesture builders

    private func magnify(viewport: CGSize, fit: CGFloat, imgSize: CGSize) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.005)
            .updating($pinch) { value, state, _ in
                state = value.magnification
            }
            .onChanged { _ in
                if pinchStart == nil {
                    pinchStart = PinchStart(
                        factor: loader.zoom.factor,
                        offset: offset,
                        cursor: cursor ?? .zero
                    )
                }
            }
            .onEnded { value in
                let start = pinchStart
                    ?? PinchStart(factor: loader.zoom.factor, offset: offset, cursor: cursor ?? .zero)
                let newFactor = clamp(start.factor * value.magnification, Zoom.min, Zoom.max)
                let r = newFactor / start.factor
                let committed = CGSize(
                    width:  start.cursor.x * (1 - r) + start.offset.width  * r,
                    height: start.cursor.y * (1 - r) + start.offset.height * r
                )
                loader.zoom = Zoom(factor: newFactor)
                offset = clampOffset(committed, factor: newFactor, image: imgSize, fit: fit, viewport: viewport)
                pinchStart = nil
            }
    }

    private func pan(factor: CGFloat, fit: CGFloat, imgSize: CGSize, viewport: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($dragDelta) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                let raw = CGSize(
                    width:  offset.width  + value.translation.width,
                    height: offset.height + value.translation.height
                )
                offset = clampOffset(raw, factor: factor, image: imgSize, fit: fit, viewport: viewport)
            }
    }

    // MARK: Math

    /// Compose the live offset for the current frame: anchored-pinch offset
    /// (if a pinch is active) plus any in-progress mouse-drag delta.
    private func rawOffset(for liveFactor: CGFloat) -> CGSize {
        var base: CGSize
        if let start = pinchStart {
            let r = liveFactor / start.factor
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
    /// it on that axis (offset = 0); otherwise allow it to move within
    /// `±(scaledSize - viewport) / 2`.
    private func clampOffset(_ raw: CGSize, factor: CGFloat, image: CGSize, fit: CGFloat, viewport: CGSize) -> CGSize {
        let scaledW = image.width  * fit * factor
        let scaledH = image.height * fit * factor
        let maxX = max(0, (scaledW - viewport.width)  / 2)
        let maxY = max(0, (scaledH - viewport.height) / 2)
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

    private func clamp(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(x, lo), hi)
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
    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                                .opacity(0.6)
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
            image = await loader.thumbnail(for: url)
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
