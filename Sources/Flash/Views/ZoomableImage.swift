import AppKit
import SwiftUI

/// Panning sources:
/// - Mouse drag (`DragGesture`)
/// - Trackpad two-finger swipe / mouse wheel (a local `NSEvent` scroll-wheel
///   monitor that updates `offset` directly when zoomed in and the cursor
///   is over the image).
///
/// When zoomed in, lightweight overlay scrollbars on the right and bottom
/// edges show the visible portion, fading themselves out automatically
/// after a short idle period.
struct ZoomableImage: View {
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
    var ppp: CGFloat // points per image pixel at gesture start
    var offset: CGSize
    var cursor: CGPoint
  }

  var body: some View {
    GeometryReader { geo in
      let viewport = geo.size
      let imgSize = image.size
      let fitPPP = fitScale(image: imgSize, into: viewport)
      let restPPP = restingPPP(fit: fitPPP)
      let livePPP: CGFloat = {
        if let start = pinchStart {
          return clampPPP(start.ppp * pinch, fit: fitPPP)
        }
        return restPPP
      }()

      let scaledSize = CGSize(
        width: imgSize.width * livePPP,
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
        geom.scaled = scaledSize
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
          case let .active(p):
            cursor = CGPoint(
              x: p.x - viewport.width / 2,
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
    case .fit: return fit
    case let .scale(s): return s / displayScale
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
            geom.scaled.width > geom.viewport.width + 0.5 ||
            geom.scaled.height > geom.viewport.height + 0.5
      else { return event }

      let raw = CGSize(
        width: offset.width + event.scrollingDeltaX,
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
            ppp: restPPP,
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
          width: start.cursor.x * (1 - r) + start.offset.width * r,
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
          width: offset.width + value.translation.width,
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
        width: start.cursor.x * (1 - r) + start.offset.width * r,
        height: start.cursor.y * (1 - r) + start.offset.height * r
      )
    } else {
      base = offset
    }
    base.width += dragDelta.width
    base.height += dragDelta.height
    return base
  }

  /// Keep the image from being dragged completely outside the viewport.
  /// When the image is smaller than the viewport on an axis, force-center
  /// it on that axis; otherwise allow it to move within
  /// `±(scaledSize - viewport) / 2`.
  private func clampOffset(_ raw: CGSize, scaled: CGSize, viewport: CGSize) -> CGSize {
    let maxX = max(0, (scaled.width - viewport.width) / 2)
    let maxY = max(0, (scaled.height - viewport.height) / 2)
    return CGSize(
      width: min(max(raw.width, -maxX), maxX),
      height: min(max(raw.height, -maxY), maxY)
    )
  }

  private func fitScale(image: CGSize, into viewport: CGSize) -> CGFloat {
    guard image.width > 0, image.height > 0,
          viewport.width > 0, viewport.height > 0 else { return 1 }
    return min(viewport.width / image.width, viewport.height / image.height)
  }
}

/// Mutable bag of "current frame" values that the scroll-wheel monitor
/// needs but can't easily capture from a SwiftUI value-type view.
/// We update the fields from `body` on every render and the monitor reads
/// them at event time.
private final class ZoomGeometryBox {
  var viewport: CGSize = .zero
  var scaled: CGSize = .zero
  var hovered: Bool = false
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

private struct ScrollIndicator: View {
  enum Axis { case horizontal, vertical }
  let axis: Axis
  let visibleFraction: CGFloat // viewport / content, in (0, 1]
  let position: CGFloat // 0…1, where the thumb sits on the track

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
            width: axis == .horizontal ? thumbLen : geo.size.width,
            height: axis == .horizontal ? geo.size.height : thumbLen
          )
          .offset(
            x: axis == .horizontal ? thumbPos : 0,
            y: axis == .horizontal ? 0 : thumbPos
          )
      }
      .compositingGroup()
      .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
    }
    .allowsHitTesting(false)
  }
}
