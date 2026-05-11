import AppKit
import SwiftUI

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
struct HDRImageView: NSViewRepresentable {
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

  func makeNSView(context _: Context) -> CGImageHostingView {
    let v = CGImageHostingView()
    v.wantsLayer = true
    // Replace the default action map with no-op CAActions so
    // implicit `contents`/`bounds`/`position` animations don't
    // cross-fade between images on navigation.
    v.layer?.actions = Self.disabledLayerActions
    return v
  }

  func updateNSView(_ v: CGImageHostingView, context _: Context) {
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
    v.layer?.minificationFilter = .trilinear
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
  static let disabledLayerActions: [String: CAAction] = [
    "contents": NSNull(),
    "bounds": NSNull(),
    "position": NSNull(),
  ]
}
