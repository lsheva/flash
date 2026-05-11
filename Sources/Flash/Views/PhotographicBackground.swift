import SwiftUI

// MARK: - Photographic background

/// Neutral mid-gray backdrop with a faint radial vignette, so colors are
/// easy to judge and the image has a subtle "studio" depth.
struct PhotographicBackground: View {
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
