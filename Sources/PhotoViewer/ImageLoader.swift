import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

/// Where the thumbnail browser is displayed relative to the main image.
enum ThumbnailPosition: String, CaseIterable, Identifiable {
    case hidden, bottom, trailing
    var id: String { rawValue }
}

/// Zoom factor relative to "fit to window".
/// `1.0` means the image fills the viewport with `.scaledToFit()`; values
/// above 1 are zoomed in (and the image becomes pannable).
struct Zoom: Equatable {
    var factor: CGFloat = 1.0
    static let min: CGFloat = 0.2
    static let max: CGFloat = 8.0
    static let step: CGFloat = 1.5

    static let fit = Zoom(factor: 1.0)

    var isFit: Bool { abs(factor - 1.0) < 0.0005 }
    var displayPercent: Int { Int((factor * 100).rounded()) }

    func zoomedIn()  -> Zoom { Zoom(factor: Swift.min(factor * Zoom.step, Zoom.max)) }
    func zoomedOut() -> Zoom { Zoom(factor: Swift.max(factor / Zoom.step, Zoom.min)) }
}

/// Lightweight, decoded-from-EXIF metadata used by the bottom info bar.
struct ImageMetadata: Equatable {
    var pixelWidth: Int
    var pixelHeight: Int
    var fileSize: Int64?
    var camera: String?
    var lens: String?
    var iso: Int?
    var aperture: Double?
    var shutter: String?
    var focalLengthMM: Double?
    var dateTaken: Date?
    var colorModel: String?

    /// Compact one-line summary for the status bar.
    var summary: String {
        var parts: [String] = ["\(pixelWidth) × \(pixelHeight) px"]
        if let fileSize { parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)) }
        if let camera   { parts.append(camera) }
        if let focalLengthMM { parts.append(String(format: "%.0f mm", focalLengthMM)) }
        if let aperture { parts.append(String(format: "f/%.1f", aperture)) }
        if let shutter  { parts.append("\(shutter) s") }
        if let iso      { parts.append("ISO \(iso)") }
        return parts.joined(separator: "  ·  ")
    }
}

/// Reactive store that owns the currently displayed image, the list of
/// sibling images in the same folder, and the navigation cursor.
///
/// Performance design:
/// - Decoding happens on a detached background task; the main actor is never
///   blocked by ImageIO.
/// - Decoding goes through `CGImageSourceCreateThumbnailAtIndex` with a
///   pixel cap derived from the largest connected display, which is up to
///   ~10× faster than `NSImage(contentsOf:)` for large HEIC/RAW files and
///   uses a fraction of the memory.
/// - A small `NSCache` keeps recently viewed images warm; the immediate
///   ±1 neighbours are prefetched at `.utility` priority so arrow-key
///   navigation feels instantaneous.
/// - A separate, larger cache holds 200-px thumbnails for the browser
///   strip; those are decoded on demand off the main actor.
@MainActor
final class ImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var currentURL: URL?
    @Published private(set) var siblings: [URL] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var errorMessage: String?
    @Published var thumbnailPosition: ThumbnailPosition = .hidden
    @Published var zoom: Zoom = .fit
    @Published var showsMetadata: Bool = true
    @Published private(set) var metadata: ImageMetadata?

    /// Every UTType that ImageIO can decode on this system. Computed once.
    static let supportedTypes: [UTType] = {
        let ids = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return ids.compactMap { UTType($0) }
    }()

    /// File extensions corresponding to `supportedTypes`, lower-cased.
    static let supportedExtensions: Set<String> = {
        Set(supportedTypes.flatMap { $0.tags[.filenameExtension] ?? [] }
            .map { $0.lowercased() })
    }()

    /// Tracks security-scoped access so we can stop it when switching folders.
    private var scopedFolder: URL?

    /// LRU cache of decoded images keyed by URL. `NSCache` evicts under
    /// memory pressure automatically.
    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 7    // current ± 3 neighbours, comfortably
        return c
    }()

    /// Larger cache for the small thumbnails shown in the browser strip.
    private let thumbnailCache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 512
        return c
    }()

    /// Pixel size of thumbnails (Retina-aware: 200 pt × 2x scale).
    static let thumbnailPixelSize: CGFloat = 400

    /// In-flight foreground decode (the image the user is waiting on).
    private var showTask: Task<Void, Never>?

    /// In-flight metadata read for the foreground image.
    private var metadataTask: Task<Void, Never>?

    /// In-flight background prefetches, keyed by URL so we don't double-queue.
    private var prefetchTasks: [URL: Task<Void, Never>] = [:]

    /// Maximum pixel dimension we decode at. Sized for the largest connected
    /// screen (in physical pixels) so the image stays sharp even when the
    /// window is fullscreen on a Retina display, but never huge enough to
    /// matter for memory.
    private static let decodeMaxPixel: CGFloat = {
        let candidates = NSScreen.screens.map {
            max($0.frame.width, $0.frame.height) * $0.backingScaleFactor
        }
        let largest = candidates.max() ?? 4096
        return min(max(largest, 2048), 8192)
    }()

    deinit {
        scopedFolder?.stopAccessingSecurityScopedResource()
    }

    func open(url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        let folder = resolved.deletingLastPathComponent()

        // Acquire security-scoped access to the parent folder. This is a no-op
        // when the app is not sandboxed, but keeping the dance means the code
        // still works if sandboxing is re-enabled later AND the folder URL was
        // vended by Powerbox / a bookmark.
        if scopedFolder != folder {
            scopedFolder?.stopAccessingSecurityScopedResource()
            scopedFolder = folder.startAccessingSecurityScopedResource() ? folder : nil
        }

        do {
            let neighbours = try scanFolder(folder)
            siblings = neighbours
            currentIndex = neighbours.firstIndex(of: resolved) ?? 0
        } catch {
            siblings = [resolved]
            currentIndex = 0
            errorMessage = "Couldn't read folder \(folder.lastPathComponent): \(error.localizedDescription)"
        }

        show(resolved)
    }

    func next() {
        guard !siblings.isEmpty else { return }
        currentIndex = (currentIndex + 1) % siblings.count
        show(siblings[currentIndex])
    }

    func previous() {
        guard !siblings.isEmpty else { return }
        currentIndex = (currentIndex - 1 + siblings.count) % siblings.count
        show(siblings[currentIndex])
    }

    // MARK: - Zoom

    func zoomIn()    { zoom = zoom.zoomedIn() }
    func zoomOut()   { zoom = zoom.zoomedOut() }
    func zoomToFit() { zoom = .fit }

    // MARK: - Private

    /// Display `url`, replacing any in-flight foreground decode. Cache hits
    /// are committed synchronously so navigation feels instant when the
    /// neighbour was already prefetched.
    private func show(_ url: URL) {
        showTask?.cancel()
        showTask = nil
        metadataTask?.cancel()
        currentURL = url
        zoom = .fit
        loadMetadata(for: url)

        if let cached = cache.object(forKey: url as NSURL) {
            image = cached
            errorMessage = nil
            schedulePrefetch()
            return
        }

        let maxPixel = Self.decodeMaxPixel
        showTask = Task { [weak self] in
            let decoded = await Self.decode(url: url, maxPixel: maxPixel)
            guard let self else { return }
            // Bail if a newer navigation has already moved on, or if this
            // task was cancelled by a subsequent `show()`.
            if Task.isCancelled || self.currentURL != url { return }

            if let decoded {
                self.cache.setObject(decoded, forKey: url as NSURL)
                self.image = decoded
                self.errorMessage = nil
            } else {
                self.image = nil
                self.errorMessage = "Could not decode \(url.lastPathComponent)"
            }
            self.schedulePrefetch()
        }
    }

    /// Kick off background decodes for the immediate neighbours and cancel
    /// any prefetches that are no longer adjacent.
    private func schedulePrefetch() {
        guard siblings.count > 1 else { return }
        let nextIdx = (currentIndex + 1) % siblings.count
        let prevIdx = (currentIndex - 1 + siblings.count) % siblings.count
        let neighbours: [URL] = [siblings[nextIdx], siblings[prevIdx]]

        for url in neighbours { prefetch(url) }

        let keep = Set(neighbours)
        for (url, task) in prefetchTasks where !keep.contains(url) {
            task.cancel()
            prefetchTasks.removeValue(forKey: url)
        }
    }

    private func prefetch(_ url: URL) {
        if cache.object(forKey: url as NSURL) != nil { return }
        if prefetchTasks[url] != nil { return }

        let maxPixel = Self.decodeMaxPixel
        prefetchTasks[url] = Task(priority: .utility) { [weak self] in
            let decoded = await Self.decode(url: url, maxPixel: maxPixel)
            guard let self else { return }
            if !Task.isCancelled, let decoded {
                self.cache.setObject(decoded, forKey: url as NSURL)
            }
            self.prefetchTasks.removeValue(forKey: url)
        }
    }

    /// Off-main-actor decode via ImageIO. Produces an image no larger than
    /// `maxPixel` on either side, with EXIF orientation already baked in
    /// and the bitmap eagerly materialised (so first draw doesn't stutter).
    ///
    /// We hand back a `CGImage` (wrapped to silence Sendable warnings on
    /// macOS 13 where `NSImage: Sendable` isn't yet available) and let the
    /// caller construct the `NSImage` on the main actor.
    private static func decode(url: URL, maxPixel: CGFloat) async -> NSImage? {
        let result = await Task.detached(priority: .userInitiated) { () -> SendableCGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform:   true,
                kCGImageSourceShouldCacheImmediately:         true,
                kCGImageSourceThumbnailMaxPixelSize:          maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                return nil
            }
            return SendableCGImage(cg)
        }.value
        guard let cg = result?.image else { return nil }
        // size: .zero makes NSImage adopt the CGImage's pixel dimensions
        // as its point size, which `.scaledToFit()` then handles.
        return NSImage(cgImage: cg, size: .zero)
    }

    /// Public, cache-backed accessor for the small browser thumbnails.
    /// Returns immediately on a cache hit; otherwise decodes on a background
    /// task at `.utility` priority so it doesn't compete with the main
    /// foreground decode.
    ///
    /// Decoding cascades through three strategies — embedded thumbnail,
    /// full-image thumbnail, then `NSImage(contentsOf:)` — because some
    /// HEIC files (Live Photos, edited screenshots, etc.) silently fail
    /// the first path and would otherwise leave the cell on a forever
    /// spinner.
    func thumbnail(for url: URL) async -> NSImage? {
        if let cached = thumbnailCache.object(forKey: url as NSURL) {
            return cached
        }
        let pixel = Self.thumbnailPixelSize
        let result = await Task.detached(priority: .utility) { () -> SendableCGImage? in
            Self.decodeThumbnailCG(url: url, maxPixel: pixel)
        }.value

        if let cg = result?.image {
            let nsImage = NSImage(cgImage: cg, size: .zero)
            thumbnailCache.setObject(nsImage, forKey: url as NSURL)
            return nsImage
        }

        // Last-ditch fallback: let AppKit have a go. Slow and full-resolution,
        // but it handles formats / quirks that ImageIO's thumbnail API trips on.
        let fallback = await Task.detached(priority: .utility) { () -> NSImage? in
            NSImage(contentsOf: url)
        }.value
        if let fallback {
            thumbnailCache.setObject(fallback, forKey: url as NSURL)
            return fallback
        }

        return nil
    }

    /// Try the fast embedded-thumbnail path first; if ImageIO can't or
    /// won't produce one, ask it to decode from the full image data.
    nonisolated private static func decodeThumbnailCG(url: URL, maxPixel: CGFloat) -> SendableCGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let baseOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately:       true,
            kCGImageSourceThumbnailMaxPixelSize:        maxPixel,
        ]

        // 1. Fast: use the embedded thumbnail if one exists and is large enough.
        var opts = baseOpts
        opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false
        opts[kCGImageSourceCreateThumbnailFromImageAlways]   = false
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return SendableCGImage(cg)
        }

        // 2. Slower: force ImageIO to decode the full frame and downsample it.
        opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
        if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            return SendableCGImage(cg)
        }

        return nil
    }

    /// Jump directly to a sibling URL (used by the thumbnail strip).
    func select(_ url: URL) {
        guard let idx = siblings.firstIndex(of: url) else { return }
        currentIndex = idx
        show(url)
    }

    // MARK: - Metadata

    private func loadMetadata(for url: URL) {
        metadata = nil
        metadataTask = Task { [weak self] in
            let meta = await Self.readMetadata(url: url)
            guard let self else { return }
            if Task.isCancelled || self.currentURL != url { return }
            self.metadata = meta
        }
    }

    private static func readMetadata(url: URL) async -> ImageMetadata? {
        await Task.detached(priority: .utility) { () -> ImageMetadata? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            else { return nil }

            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

            let width  = (props[kCGImagePropertyPixelWidth]  as? Int) ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0

            let make  = tiff[kCGImagePropertyTIFFMake]  as? String
            let model = tiff[kCGImagePropertyTIFFModel] as? String
            let camera: String? = {
                switch (make, model) {
                case let (m?, mm?) where !mm.lowercased().contains(m.lowercased()):
                    return "\(m) \(mm)"
                case let (_, mm?): return mm
                case let (m?, _):  return m
                default:           return nil
                }
            }()

            let lens = (exif[kCGImagePropertyExifLensModel] as? String)
                    ?? (exif[kCGImagePropertyExifLensMake]  as? String)

            let iso: Int? = {
                if let arr = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
                   let first = arr.first { return first }
                return exif[kCGImagePropertyExifISOSpeed] as? Int
            }()

            let aperture = exif[kCGImagePropertyExifFNumber] as? Double

            let shutter: String? = {
                guard let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0
                else { return nil }
                if exposure >= 1 { return String(format: "%.1f", exposure) }
                return "1/\(Int((1.0 / exposure).rounded()))"
            }()

            let focal = exif[kCGImagePropertyExifFocalLength] as? Double

            let date: Date? = {
                guard let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
                let f = DateFormatter()
                f.dateFormat = "yyyy:MM:dd HH:mm:ss"
                f.locale = Locale(identifier: "en_US_POSIX")
                return f.date(from: s)
            }()

            let colorModel = props[kCGImagePropertyColorModel] as? String

            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { Int64($0) }

            return ImageMetadata(
                pixelWidth:    width,
                pixelHeight:   height,
                fileSize:      fileSize,
                camera:        camera,
                lens:          lens,
                iso:           iso,
                aperture:      aperture,
                shutter:       shutter,
                focalLengthMM: focal,
                dateTaken:     date,
                colorModel:    colorModel
            )
        }.value
    }

    private func scanFolder(_ folder: URL) throws -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey]
        let contents = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )

        let supported = Self.supportedTypes
        let filtered = contents.filter { url in
            if let values = try? url.resourceValues(forKeys: Set(keys)),
               values.isRegularFile == true,
               let type = values.contentType {
                return supported.contains { type.conforms(to: $0) }
            }
            return Self.supportedExtensions.contains(url.pathExtension.lowercased())
        }

        return filtered.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}

/// `CGImage` is reference-counted and immutable once created by ImageIO,
/// so it's safe to pass between concurrency domains, but the SDK on
/// macOS 13 doesn't formally mark it `Sendable`. This wrapper makes the
/// guarantee explicit so we don't trip the strict-concurrency checker.
private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
