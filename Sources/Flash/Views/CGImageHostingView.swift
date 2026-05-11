import AppKit
import SwiftUI

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

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) unused")
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }

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
