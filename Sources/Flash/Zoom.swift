import AppKit

/// How the image is currently sized relative to the viewport.
///
/// - `.fit` is a *mode*: the image is scaled-to-fit the viewport and follows
///   any window resize.
/// - `.scale(s)` is an *absolute* zoom level expressed as
///   `source pixel : screen backing pixel`. `s == 1.0` means each image
///   pixel is rendered onto exactly one physical screen pixel — i.e. the
///   "100%" or "Actual Size" convention used by Preview, Photoshop, etc.
enum Zoom: Equatable {
    case fit
    case scale(CGFloat)

    /// Absolute scale bounds and step factor. `step` is √2 so two clicks
    /// double the zoom, which lines up with the percentage labels people
    /// expect (50, 71, 100, 141, 200, 283, 400…).
    static let min:  CGFloat = 0.05
    static let max:  CGFloat = 16.0
    static let step: CGFloat = 1.4142135623730951

    var isFit: Bool {
        if case .fit = self { return true } else { return false }
    }

    /// The absolute scale, when in `.scale` mode.
    var absolute: CGFloat? {
        if case .scale(let s) = self { return s } else { return nil }
    }
}