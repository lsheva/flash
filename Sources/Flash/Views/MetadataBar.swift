import SwiftUI

struct MetadataBar: View {
  @EnvironmentObject var loader: ImageLoader

  /// Shown on the right of the metadata summary when the on-screen
  /// bitmap differs from the source pixel dimensions (e.g. capped
  /// HEIC, embedded RAW preview, RAW awaiting full-res upgrade).
  private var renderedSizeText: String? {
    guard
      let rendered = loader.renderedBitmapSize,
      let meta = loader.metadata
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
          help: "Camera RAW container. Demosaiced on the fly; embedded JPEG preview is used until you zoom past it."
        )
      }
      if loader.metadata?.isHDR == true {
        StatusBadge(
          label: "HDR",
          help: "High Dynamic Range image (>8 bits per component or with an HDR gain map). Rendered with extended luminance on capable displays."
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
