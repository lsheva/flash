import SwiftUI

struct ThumbnailStrip: View {
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
        case let .loaded(image):
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
