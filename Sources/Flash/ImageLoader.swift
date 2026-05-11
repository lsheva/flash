import AppKit
import Combine
import CoreVideo
import ImageIO
import IOSurface
import UniformTypeIdentifiers

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
    /// `true` when the bitmap currently being shown is the camera-embedded
    /// preview from a RAW file rather than a full-resolution demosaic.
    /// Flips to `false` once the background upgrade decode lands. Used by
    /// the status bar to disclose the (slight, transient) loss of fidelity
    /// to the user.
    @Published private(set) var isShowingRawPreview: Bool = false

    /// Pixel dimensions of the bitmap currently being rendered, derived
    /// from the underlying CGImage (not the AppKit Retina cache rep).
    /// Differs from `metadata.pixelWidth/Height` whenever the decode
    /// path capped the image — RAW embedded previews on older bodies,
    /// `decodeMaxPixel`-capped HEIC, etc. The status bar shows this
    /// alongside the source dimensions so the user can tell when
    /// they're looking at a downsampled view.
    var renderedBitmapSize: CGSize? {
        guard let image, image.size.width > 0 else { return nil }
        let bitmapW = CGFloat(Self.bitmapPixelWidth(image))
        let bitmapH = (bitmapW * image.size.height / image.size.width).rounded()
        return CGSize(width: bitmapW, height: bitmapH)
    }

    /// Developer log of decode / prefetch / upgrade events. The dev
    /// overlay reads from this directly via `@ObservedObject`. We
    /// deliberately don't forward `log.objectWillChange` to this
    /// loader's `objectWillChange`, otherwise every log line would
    /// invalidate every view in the app and tank performance.
    let log = LoadLog()

    /// Toggles the dev log overlay. Lives on the loader (rather than on
    /// `LoadLog` itself) so views that observe the loader update
    /// without having to subscribe to the log directly.
    @Published var showsLog: Bool = false

    /// Wall-clock timestamp captured when the user issues a navigation
    /// (arrow key, thumbnail click, ⌘O, drag-and-drop). Read by
    /// `noteImageRendered()` to log the *end-to-end* press → first-frame
    /// latency, so we can see how much time is being spent in
    /// SwiftUI / AppKit / the render server *after* the bitmap is ready.
    private var navStart: (timestamp: Date, label: String)?

    /// Closure to run once the most recently shown image's paint commit
    /// has reached the render server. Used to defer prefetching until
    /// after the foreground GPU upload, so the prefetch decode (which
    /// hits the hardware JPEG unit on Apple silicon) doesn't contend
    /// with the IOSurface upload for the image the user is *currently
    /// looking at*. Cleared by `notePaintCommitted()`.
    private var afterPaint: (() -> Void)?

    @Published private(set) var currentURL: URL?
    @Published private(set) var siblings: [URL] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var errorMessage: String?
    @Published var thumbnailPosition: ThumbnailPosition = .hidden
    @Published var zoom: Zoom = .fit
    @Published var showsMetadata: Bool = true
    @Published private(set) var metadata: ImageMetadata?
    @Published var isFullscreen: Bool = false {
        didSet {
            chromeVisible = true
            if isFullscreen {
                scheduleChromeHide()
            } else {
                cancelChromeHide()
            }
        }
    }

    @Published var chromeVisible: Bool = true
    private var chromeHideTimer: Timer?
    private var chromeIdleDelay: TimeInterval = 2.0

    init() {
        print("ImageLoader.init", ObjectIdentifier(self))
    }

    func notePointerActivity() {
        guard isFullscreen else { return }
        if !chromeVisible {
            chromeVisible = true
        }
        scheduleChromeHide()
    }

    func scheduleChromeHide() {
        cancelChromeHide()
        chromeHideTimer = Timer.scheduledTimer(withTimeInterval: chromeIdleDelay, repeats: false) {
            _ in
            MainActor.assumeIsolated { self.chromeVisible = false }
        }
    }

    func cancelChromeHide() {
        chromeHideTimer?.invalidate()
        chromeHideTimer = nil
    }

    /// The effective on-screen scale (`1.0` = 1 image pixel : 1 backing
    /// pixel) that's *currently* being rendered. The view writes this on
    /// every layout pass so menu items / toolbar buttons that step the
    /// zoom can do so relative to whatever the user is looking at right
    /// now — including when they're in `.fit` mode.
    ///
    /// Setting this also drives the on-demand RAW upgrade path: when the
    /// user zooms in past what the embedded preview can resolve, a
    /// background full-resolution decode is fired (deduplicated per URL).
    var currentEffectiveScale: CGFloat = 1.0 {
        didSet {
            if oldValue != currentEffectiveScale { upgradeIfNeeded() }
        }
    }

    /// Every UTType that ImageIO can decode on this system. Computed once.
    static let supportedTypes: [UTType] = {
        let ids = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return ids.compactMap { UTType($0) }
    }()

    /// File extensions corresponding to `supportedTypes`, lower-cased.
    static let supportedExtensions: Set<String> = Set(supportedTypes.flatMap { $0.tags[.filenameExtension] ?? [] }
        .map { $0.lowercased() })

    /// Tracks security-scoped access so we can stop it when switching folders.
    private var scopedFolder: URL?

    /// LRU cache of decoded images keyed by URL. `NSCache` evicts under
    /// memory pressure automatically.
    private let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 7 // current ± 3 neighbours, comfortably
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

    /// In-flight RAW full-resolution upgrades, keyed by URL. We open RAWs
    /// using their embedded JPEG preview (fast) and only demosaic the full
    /// sensor data when the user zooms in past what the preview can resolve.
    private var upgradeTasks: [URL: Task<Void, Never>] = [:]

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
        print("ImageLoader.deinit", ObjectIdentifier(self))
    }

    func open(url: URL) {
        print("ImageLoader.open id=\(ObjectIdentifier(self)) url=\(url.lastPathComponent)")
        let resolved = url.resolvingSymlinksInPath()
        let folder = resolved.deletingLastPathComponent()
        log.info("open \(resolved.lastPathComponent)")
        markNavStart("open \(resolved.lastPathComponent)")

        // Acquire security-scoped access to the parent folder. This is a no-op
        // when the app is not sandboxed, but keeping the dance means the code
        // still works if sandboxing is re-enabled later AND the folder URL was
        // vended by Powerbox / a bookmark.
        if scopedFolder != folder {
            scopedFolder?.stopAccessingSecurityScopedResource()
            scopedFolder = folder.startAccessingSecurityScopedResource() ? folder : nil
        }

        // Best-effort: clear `com.apple.quarantine` from this file before we
        // read its bytes. macOS Sequoia prompts ("App can't verify the file
        // isn't malware…") whenever an ad-hoc-signed app reads a quarantined
        // file. Stripping the xattr is metadata-only and doesn't itself
        // trigger Gatekeeper, so doing it preemptively suppresses the prompt
        // for files the user owns. Silently no-ops if we can't write metadata.
        Self.dropQuarantine(resolved)

        do {
            let neighbours = try scanFolder(folder)
            siblings = neighbours
            currentIndex = neighbours.firstIndex(of: resolved) ?? 0
            // Also clear neighbours so arrow-key navigation doesn't hit the
            // dialog later. Done off-main since it's pure metadata I/O.
            Task.detached(priority: .utility) { [neighbours] in
                for n in neighbours {
                    Self.dropQuarantine(n)
                }
            }
        } catch {
            siblings = [resolved]
            currentIndex = 0
            errorMessage = "Couldn't read folder \(folder.lastPathComponent): \(error.localizedDescription)"
        }

        show(resolved)
    }

    /// Remove the `com.apple.quarantine` extended attribute from `url`.
    /// Best-effort: we ignore any failure (file we don't own, read-only
    /// filesystem, no xattr in the first place).
    ///
    /// We use the NSURL bridge rather than `URLResourceValues` because
    /// setting the Swift wrapper's `quarantineProperties = nil` historically
    /// *clears the dictionary contents* but doesn't always remove the xattr
    /// itself. The NSURL `setResourceValue(nil, forKey:)` form does.
    nonisolated static func dropQuarantine(_ url: URL) {
        try? (url as NSURL).setResourceValue(nil, forKey: .quarantinePropertiesKey)
    }

    func next() {
        guard !siblings.isEmpty else { return }
        currentIndex = (currentIndex + 1) % siblings.count
        let name = siblings[currentIndex].lastPathComponent
        log.info("nav next → \(name)")
        markNavStart("next → \(name)")
        show(siblings[currentIndex])
    }

    func previous() {
        guard !siblings.isEmpty else { return }
        currentIndex = (currentIndex - 1 + siblings.count) % siblings.count
        let name = siblings[currentIndex].lastPathComponent
        log.info("nav prev → \(name)")
        markNavStart("prev → \(name)")
        show(siblings[currentIndex])
    }

    // MARK: - Delete

    /// `true` when there's a current image that can be moved to the Trash.
    var canDeleteCurrent: Bool {
        currentURL != nil
    }

    /// Move the currently displayed image to the Trash and advance to the
    /// next sibling (or the previous one if we were on the last image).
    /// On failure, the image stays put and `errorMessage` is set.
    func deleteCurrent() {
        guard let url = currentURL else { return }

        log.info("delete \(url.lastPathComponent): moving to Trash")
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            log.error("delete \(url.lastPathComponent): \(error.localizedDescription)")
            errorMessage = "Couldn't move \(url.lastPathComponent) to Trash: \(error.localizedDescription)"
            return
        }

        // Drop any cached decode / in-flight prefetch for the deleted file.
        cache.removeObject(forKey: url as NSURL)
        thumbnailCache.removeObject(forKey: url as NSURL)
        prefetchTasks[url]?.cancel()
        prefetchTasks.removeValue(forKey: url)
        upgradeTasks[url]?.cancel()
        upgradeTasks.removeValue(forKey: url)

        guard let removedIdx = siblings.firstIndex(of: url) else {
            // Wasn't tracked as a sibling (shouldn't happen, but be safe).
            setImage(nil)
            currentURL = nil
            metadata = nil
            return
        }

        siblings.remove(at: removedIdx)

        if siblings.isEmpty {
            showTask?.cancel(); showTask = nil
            metadataTask?.cancel(); metadataTask = nil
            setImage(nil)
            currentURL = nil
            metadata = nil
            errorMessage = nil
            currentIndex = 0
            return
        }

        // Stay on the same slot when possible (so the user keeps moving
        // forward through the folder); clamp to the last image when we
        // just deleted the tail.
        currentIndex = min(removedIdx, siblings.count - 1)
        show(siblings[currentIndex])
    }

    // MARK: - Zoom

    /// Zoom in one √2 step from whatever the user is looking at right now,
    /// even if that's `.fit` mode (in which case the next state becomes an
    /// absolute scale slightly larger than the current fit scale).
    func zoomIn() {
        let next = min(currentEffectiveScale * Zoom.step, Zoom.max)
        zoom = .scale(next)
    }

    func zoomOut() {
        let next = max(currentEffectiveScale / Zoom.step, Zoom.min)
        zoom = .scale(next)
    }

    func zoomToFit() {
        zoom = .fit
    }

    func zoomToActualSize() {
        zoom = .scale(1.0)
    }

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

        let name = url.lastPathComponent

        if let cached = cache.object(forKey: url as NSURL) {
            let bw = Self.bitmapPixelWidth(cached)
            let lw = Int(cached.size.width.rounded())
            log.info("show \(name): cache HIT (bitmap \(bw)px, logical \(lw)px)")
            setImage(cached)
            errorMessage = nil
            scheduleAfterPaint { [weak self] in self?.schedulePrefetch() }
            return
        }

        log.info("show \(name): cache MISS — decoding")
        let showT0 = Date()
        let maxPixel = Self.decodeMaxPixel
        let logRef = log
        showTask = Task { [weak self] in
            let decoded = await Self.decode(url: url, maxPixel: maxPixel, log: logRef, priority: .userInitiated)
            guard let self else { return }
            if Task.isCancelled || self.currentURL != url {
                logRef.info("show \(name): superseded — discarding decode result")
                return
            }

            if let decoded {
                let totalMs = Int((Date().timeIntervalSince(showT0) * 1000).rounded())
                logRef.info("show \(name): committing image (total \(totalMs) ms)")
                self.cache.setObject(decoded, forKey: url as NSURL)
                self.setImage(decoded)
                self.errorMessage = nil
            } else {
                logRef.error("show \(name): decode failed")
                self.setImage(nil)
                self.errorMessage = "Could not decode \(name)"
            }
            self.scheduleAfterPaint { [weak self] in self?.schedulePrefetch() }
        }
    }

    /// Stash `work` to run after the next paint commit reaches the
    /// render server. The view layer calls `notePaintCommitted()` from
    /// its `CATransaction` completion block once the new bitmap is
    /// actually on screen.
    ///
    /// Includes a safety net: if no commit lands within 500 ms (e.g.
    /// the view isn't on screen, or the same `NSImage` instance was
    /// re-set so AppKit elides the swap), we run the work anyway so
    /// the deferred prefetch isn't lost forever.
    private func scheduleAfterPaint(_ work: @escaping () -> Void) {
        afterPaint = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // If `notePaintCommitted()` already consumed the closure,
            // `afterPaint` is nil and we no-op. Otherwise run whatever
            // is currently queued; running the latest queued closure
            // (rather than the captured `work`) is fine because
            // `schedulePrefetch()` is idempotent.
            guard let self, let pending = self.afterPaint else { return }
            self.afterPaint = nil
            pending()
        }
    }

    /// Called from `HDRImageView` once the layer transaction holding
    /// the new bitmap has been flushed to the render server. Runs any
    /// work deferred by `scheduleAfterPaint(_:)` — currently the
    /// neighbour prefetch — so the foreground GPU upload doesn't have
    /// to compete with the prefetch's hardware JPEG decode for shared
    /// silicon.
    func notePaintCommitted() {
        let pending = afterPaint
        afterPaint = nil
        pending?()
    }

    /// Records the start of a navigation event. Call from any entry
    /// point that ultimately leads to a different image being shown
    /// (arrow keys, ⌘O, thumbnail click). The companion
    /// `takeNavStart()` is consumed by the view layer once it sets up
    /// the layer commit, so end-to-end latency can be logged when the
    /// commit reaches the render server.
    private func markNavStart(_ label: String) {
        navStart = (Date(), label)
    }

    /// Atomically reads and clears the most recent navigation press
    /// info. Called by `HDRImageView` at the moment it sets up the
    /// CATransaction that will swap the bitmap, so the press time is
    /// pinned to *that* commit even if the user fires another arrow
    /// before the previous render lands.
    func takeNavStart() -> (timestamp: Date, label: String)? {
        defer { navStart = nil }
        return navStart
    }

    /// Single point of truth for `image` updates: also keeps
    /// `isShowingRawPreview` in sync so the status bar can disclose when
    /// the user is looking at an embedded preview rather than a
    /// full-resolution decode.
    private func setImage(_ img: NSImage?) {
        image = img
        if let img {
            let bw = Self.bitmapPixelWidth(img)
            let lw = Int(img.size.width.rounded())
            let lh = Int(img.size.height.rounded())
            let isFull = Self.isFullResolutionImage(img)
            // The "embedded preview" badge is specifically about
            // looking at a camera-embedded JPEG instead of the
            // demosaiced sensor data; it shouldn't fire for ordinary
            // screen-capped JPEG/HEIC where the upgrade path will
            // simply re-decode the same source at full resolution.
            let isRawSource = currentURL.map(Self.isRawImage) ?? false
            isShowingRawPreview = !isFull && isRawSource
            log.info("image set: bitmap \(bw)px, logical \(lw)×\(lh), \(isFull ? "full-res" : "downsampled")")
        } else {
            isShowingRawPreview = false
        }
    }

    /// Kick off background decodes for the immediate neighbours and cancel
    /// any prefetches that are no longer adjacent.
    private func schedulePrefetch() {
        guard siblings.count > 1 else { return }
        let nextIdx = (currentIndex + 1) % siblings.count
        let prevIdx = (currentIndex - 1 + siblings.count) % siblings.count
        let neighbours: [URL] = [siblings[nextIdx], siblings[prevIdx]]

        for url in neighbours {
            prefetch(url)
        }

        let keep = Set(neighbours)
        for (url, task) in prefetchTasks where !keep.contains(url) {
            task.cancel()
            prefetchTasks.removeValue(forKey: url)
        }
    }

    private func prefetch(_ url: URL) {
        if cache.object(forKey: url as NSURL) != nil { return }
        if prefetchTasks[url] != nil { return }

        let name = url.lastPathComponent
        log.info("prefetch \(name): start")
        let t0 = Date()
        let maxPixel = Self.decodeMaxPixel
        let logRef = log
        prefetchTasks[url] = Task(priority: .utility) { [weak self] in
            // Match the prefetch's `.utility` priority on the inner
            // detached decode too — otherwise the inner task pins
            // itself at `.userInitiated` and competes with the
            // foreground for the hardware JPEG decoder on Apple
            // silicon, which we just observed adding ~100 ms to the
            // visible swap-to-paint window.
            let decoded = await Self.decode(url: url, maxPixel: maxPixel, log: logRef, priority: .utility)
            guard let self else { return }
            let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
            if Task.isCancelled {
                logRef.info("prefetch \(name): cancelled after \(ms) ms")
            } else if let decoded {
                self.cache.setObject(decoded, forKey: url as NSURL)
                logRef.info("prefetch \(name): cached (total \(ms) ms)")
            } else {
                logRef.warn("prefetch \(name): decode returned nil after \(ms) ms")
            }
            self.prefetchTasks.removeValue(forKey: url)
        }
    }

    /// Off-main-actor decode via ImageIO. Produces an image no larger than
    /// `maxPixel` on either side, with EXIF orientation already baked in
    /// and the bitmap eagerly materialised (so first draw doesn't stutter).
    ///
    /// For RAW files this prefers the embedded-preview path
    /// (`…FromImageAlways=false`), which returns whatever camera-embedded
    /// JPEG the file contains. On modern formats (CR3, ARW, RAF, ORF
    /// since ~2015) that JPEG is the same resolution as the sensor, so
    /// the user effectively skips the demosaic step entirely. Older RAWs
    /// with a smaller embedded preview rely on the upgrade path below to
    /// swap in a full-resolution bitmap when the user zooms in.
    ///
    /// Reports timings into `log` so the developer overlay can show
    /// where the time is being spent.
    private static func decode(
        url: URL,
        maxPixel: CGFloat,
        log: LoadLog,
        priority: TaskPriority
    ) async -> NSImage? {
        await Task.detached(priority: priority) { () -> NSImage? in
            let name = url.lastPathComponent

            if Self.isRawImage(url) {
                let t0 = Date()
                if let preview = Self.decodeRawEmbeddedPreview(url: url, maxPixel: maxPixel) {
                    let cg = preview.cgImage
                    let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
                    log.info("decode \(name): RAW embedded preview \(cg.width)×\(cg.height) (logical \(Int(preview.fullPointSize.width))×\(Int(preview.fullPointSize.height))) in \(ms) ms")
                    return Self.makeNSImage(cgImage: cg, size: preview.fullPointSize)
                }
                log.warn("decode \(name): RAW has no embedded preview — falling through to capped demosaic")
            }

            let t0 = Date()
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                log.error("decode \(name): CGImageSourceCreateWithURL failed")
                return nil
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                // Preserve float-component pixel values (> 1.0) so that HDR
                // images retain their extended luminance rather than being
                // tone-mapped to SDR before we even see the CGImage.
                kCGImageSourceShouldAllowFloat: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                log.error("decode \(name): CreateThumbnailAtIndex returned nil")
                return nil
            }
            let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
            // Read the source's full visual dimensions (orientation
            // baked in) so the NSImage's logical size reflects the
            // *source* rather than the capped thumbnail. That way the
            // upgrade path can compare bitmap-vs-source and fire the
            // full-resolution decode the moment the user zooms past
            // what the capped thumbnail can resolve.
            let logicalSize = Self.sourceVisualSize(src)
                ?? CGSize(width: cg.width, height: cg.height)
            log.info("decode \(name): screen-capped thumbnail \(cg.width)×\(cg.height) (logical \(Int(logicalSize.width))×\(Int(logicalSize.height))) in \(ms) ms")
            return Self.makeNSImage(cgImage: cg, size: logicalSize)
        }.value
    }

    /// Orientation-corrected source pixel dimensions. Returns the
    /// dimensions a viewer would see (rotated when EXIF orientation
    /// is 5–8), so callers can use it as a logical-size reference
    /// when comparing against a downsampled bitmap.
    private nonisolated static func sourceVisualSize(_ src: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
        guard w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        let rotated = (5 ... 8).contains(orientation)
        return CGSize(width: rotated ? h : w, height: rotated ? w : h)
    }

    /// `true` if `url` looks like a camera RAW (by UTType when available,
    /// extension as a fallback for files without a recognised content type).
    private nonisolated static func isRawImage(_ url: URL) -> Bool {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType,
           type.conforms(to: .rawImage)
        {
            return true
        }
        return Self.rawExtensions.contains(url.pathExtension.lowercased())
    }

    /// Common RAW container extensions. Used only as a fallback when the
    /// system can't resolve a UTType for the file.
    private nonisolated static let rawExtensions: Set<String> = [
        "3fr", "ari", "arw", "bay", "cap", "cr2", "cr3", "crw", "dcr", "dcs",
        "dng", "drf", "eip", "erf", "fff", "iiq", "k25", "kdc", "mdc", "mef",
        "mos", "mrw", "nef", "nrw", "obm", "orf", "pef", "ptx", "pxn", "r3d",
        "raf", "raw", "rw2", "rwl", "rwz", "sr2", "srf", "srw", "x3f",
    ]

    /// Decode the camera-embedded preview JPEG from a RAW. ImageIO is told
    /// not to fall back to a full demosaic if no preview is present —
    /// that's the slow path the caller wants to avoid on the hot navigation
    /// loop.
    ///
    /// Returns the preview pixels alongside the full RAW's point dimensions
    /// (orientation-corrected) so the caller can present the small bitmap
    /// at the logical size of the full image.
    private nonisolated static func decodeRawEmbeddedPreview(url: URL, maxPixel: CGFloat)
        -> (cgImage: CGImage, fullPointSize: CGSize)?
    {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }

        let rawW = (props[kCGImagePropertyPixelWidth] as? CGFloat) ?? 0
        let rawH = (props[kCGImagePropertyPixelHeight] as? CGFloat) ?? 0
        guard rawW > 0, rawH > 0 else { return nil }

        // EXIF orientations 5-8 swap width and height when applied.
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        let rotated = (5 ... 8).contains(orientation)
        let fullPointSize = CGSize(
            width: rotated ? rawH : rawW,
            height: rotated ? rawW : rawH
        )

        let opts: [CFString: Any] = [
            // Embedded only — never demosaic the sensor data here.
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // Caller-controlled cap. The hot navigation path passes
            // `decodeMaxPixel` (sized to the largest connected screen),
            // matching the JPEG/HEIC strategy. The upgrade path passes
            // a near-uncapped value so the embedded preview comes back
            // at full file resolution when the user zooms in.
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return (cg, fullPointSize)
    }

    /// Decode `url` at full source resolution (no pixel cap). Used by
    /// the upgrade path the moment the user zooms past what the
    /// previously-decoded capped bitmap can resolve.
    ///
    /// For RAW sources we prefer the camera-embedded JPEG preview at
    /// its full-file resolution: it's already the size of the sensor
    /// on modern bodies (~24 MP) and decoding it is ~100–250 ms vs
    /// the multi-second cost of a true sensor demosaic. We only fall
    /// through to demosaic if the file genuinely has no embedded
    /// preview (rare; old DNGs).
    ///
    /// For JPEG / HEIC / TIFF / etc. we ask ImageIO for the full image
    /// data with no max-pixel cap; that's a few hundred ms for a
    /// typical 24 MP JPEG on Apple silicon.
    private nonisolated static func decodeFullResolution(url: URL, log: LoadLog) -> NSImage? {
        let name = url.lastPathComponent
        let t0 = Date()

        if Self.isRawImage(url) {
            // 16384 is effectively "uncapped" — every camera embeds
            // previews far smaller than that. Picks up the sensor-sized
            // JPEG that's already inside the RAW container.
            if let preview = Self.decodeRawEmbeddedPreview(url: url, maxPixel: 16384) {
                let cg = preview.cgImage
                let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
                log.info("upgrade \(name): RAW embedded preview \(cg.width)×\(cg.height) in \(ms) ms")
                return Self.makeNSImage(cgImage: cg, size: preview.fullPointSize)
            }
            log.warn("upgrade \(name): RAW has no embedded preview — demosaicing")
        }

        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            log.error("upgrade \(name): CGImageSourceCreateWithURL failed")
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: true,
            // Deliberately no kCGImageSourceThumbnailMaxPixelSize — we want
            // the full source resolution.
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            log.error("upgrade \(name): CreateThumbnailAtIndex returned nil")
            return nil
        }
        let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
        let logicalSize = Self.sourceVisualSize(src)
            ?? CGSize(width: cg.width, height: cg.height)
        log.info("upgrade \(name): full decode \(cg.width)×\(cg.height) in \(ms) ms")
        return Self.makeNSImage(cgImage: cg, size: logicalSize)
    }

    // MARK: Resolution upgrade

    /// Pixel width of the underlying bitmap (the CGImage we wrapped).
    ///
    /// We can't read this back from `image.representations.first?.pixelsWide`
    /// because AppKit silently appends a Retina-scale (`@2x`) cache rep
    /// to the `NSImage` once it touches a 2× backing store, and that
    /// cache rep moves to the front of the `representations` array.
    /// Reading it would always overstate the bitmap by 2× on Retina,
    /// which would prevent the RAW upgrade path from firing for files
    /// whose embedded preview is genuinely smaller than the sensor.
    ///
    /// Instead, we tag the `NSImage` with the source CGImage's width
    /// at construction time (see `Self.makeNSImage`) and read it back
    /// from there.
    fileprivate static func bitmapPixelWidth(_ image: NSImage) -> Int {
        image.sourceBitmapWidth ?? Int(image.size.width.rounded())
    }

    /// `true` when the displayed bitmap is sharp at the logical image size
    /// (or larger). `false` for a RAW preview presented at the full RAW's
    /// point size — those benefit from a background upgrade.
    private static func isFullResolutionImage(_ image: NSImage) -> Bool {
        bitmapPixelWidth(image) >= Int(image.size.width.rounded()) - 1
    }

    /// Constructs an `NSImage` from a CGImage, tagging it with the
    /// CGImage's pixel width so `bitmapPixelWidth(_:)` can read the
    /// original bitmap size back later (see that method's doc comment).
    /// `size` is the `NSImage`'s logical point size; pass `.zero` to
    /// adopt the CGImage's pixel dimensions verbatim.
    ///
    /// Also pre-renders the CGImage into an IOSurface and stashes it
    /// on the NSImage. The view layer prefers the surface when
    /// available because handing an IOSurface to `CALayer.contents`
    /// is effectively a Mach-port reference: the WindowServer already
    /// has the bytes via shared memory and skips the per-commit
    /// ~95 ms cross-process copy that a malloc-backed CGImage would
    /// trigger. See `renderToDisplaySurface(_:)` for the pixel-format
    /// constraints — HDR / float images skip the surface and fall
    /// back to the CGImage path so we don't crush their extended
    /// range to BGRA8.
    nonisolated static func makeNSImage(cgImage cg: CGImage, size: NSSize) -> NSImage {
        let img = NSImage(cgImage: cg, size: size)
        img.sourceBitmapWidth = cg.width
        img.displaySurface = renderToDisplaySurface(cg)
        return img
    }

    /// Render `cg` into a freshly-allocated `IOSurface` tagged with a
    /// matching color space, so the WindowServer picks it up without a
    /// per-commit copy *and* renders it through correct color
    /// management.
    ///
    /// Color-space strategy:
    /// - sRGB and Display P3 sources round-trip into a same-named
    ///   8-bit BGRA surface losslessly.
    /// - Anything else (Adobe RGB, ProPhoto, ICC-tagged custom
    ///   profiles, untagged) is rendered into Display P3, which is
    ///   the widest CALayer-supported gamut on Apple silicon and
    ///   covers virtually every display. Out-of-P3 colors clip to
    ///   gamut boundary, which is what the OS would do for compositing
    ///   anyway.
    /// - The destination space's well-known name is attached to the
    ///   IOSurface via `kIOSurfaceColorSpace` so CALayer does NOT fall
    ///   back to "interpret bytes in the display's color space".
    ///
    /// Returns `nil` for image formats we deliberately don't downgrade
    /// to 8-bit (HDR / float-component / wider bit depth) — the caller
    /// falls back to the slower CGImage path so HDR luminance survives.
    nonisolated static func renderToDisplaySurface(_ cg: CGImage) -> IOSurface? {
        // Only 8-bit-per-component images are safe to pack into BGRA8.
        // Anything wider (HDR HEIC gain map, OpenEXR, Radiance HDR)
        // would lose its extended dynamic range here.
        guard cg.bitsPerComponent <= 8 else { return nil }

        // Pick the destination color space:
        //  - If the source is sRGB/P3, match it exactly (no conversion,
        //    no precision loss).
        //  - Otherwise, render into P3 so wide-gamut originals
        //    (Adobe RGB greens, etc.) keep more saturation than they
        //    would in sRGB.
        let destSpace: CGColorSpace = {
            if let srcName = cg.colorSpace?.name {
                if srcName == CGColorSpace.sRGB,
                   let s = CGColorSpace(name: CGColorSpace.sRGB)
                {
                    return s
                }
                if srcName == CGColorSpace.displayP3,
                   let s = CGColorSpace(name: CGColorSpace.displayP3)
                {
                    return s
                }
            }
            // Wide-gamut catch-all. P3 is what AppKit / Apple silicon
            // displays are calibrated against by default.
            return CGColorSpace(name: CGColorSpace.displayP3)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!
        }()

        let w = cg.width
        let h = cg.height
        // 64-byte stride alignment is what the Apple-silicon display
        // pipeline wants for the zero-copy fast path.
        let bytesPerRow = ((w * 4) + 63) & ~63

        let props: [IOSurfacePropertyKey: any Sendable] = [
            .width: w,
            .height: h,
            .bytesPerElement: 4,
            .bytesPerRow: bytesPerRow,
            .pixelFormat: Int(kCVPixelFormatType_32BGRA),
        ]
        guard let surface = IOSurface(properties: props) else { return nil }

        // Tag the surface with the color space we wrote it in, so
        // CALayer color-manages it correctly when compositing onto
        // displays of any gamut. Without this, CALayer interprets
        // unattributed BGRA8 in the display's color space, which makes
        // sRGB photos look oversaturated on P3 displays and P3 photos
        // look desaturated on sRGB displays.
        //
        // We use the IOSurface C API (`IOSurfaceSetValue`) rather than
        // `setValue(_:forKey:)` because the latter goes through
        // NSObject KVC and raises `NSUnknownKeyException` for IOSurface
        // attachments. The Swift overlay doesn't expose a typed
        // `colorSpace` setter on this SDK. The key string itself is
        // stable since macOS 10.12 — the underlying C constant is
        // `kIOSurfaceColorSpace` from `<IOSurface/IOSurfaceRef.h>`.
        IOSurfaceSetValue(
            surface,
            "IOSurfaceColorSpace" as CFString,
            destSpace
        )

        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }

        guard let ctx = CGContext(
            data: surface.baseAddress,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: destSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        // CGContext does the source.colorSpace → destSpace conversion
        // implicitly using the source CGImage's color space tag.
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return surface
    }

    /// If the current image is a downsampled bitmap (RAW embedded
    /// preview, screen-capped JPEG/HEIC, etc.) and the requested zoom
    /// would upscale past the bitmap's native pixel count, fire (or
    /// join) a background full-resolution decode. The view-side
    /// bitmap is swapped in place when the decode lands; pan offset
    /// is preserved because the swap keeps `currentURL` constant.
    private func upgradeIfNeeded() {
        guard let url = currentURL,
              let img = image,
              upgradeTasks[url] == nil,
              !Self.isFullResolutionImage(img)
        else { return }

        let bitmapWidth = Self.bitmapPixelWidth(img)
        let requiredBitmapWidth = img.size.width * currentEffectiveScale
        // Add a small slack so we don't fire for trivial overshoots
        // (sub-pixel rounding during pinch, viewport one px wider than
        // the preview, etc.).
        guard requiredBitmapWidth > CGFloat(bitmapWidth) + 4 else { return }

        let name = url.lastPathComponent
        let needPx = Int(requiredBitmapWidth.rounded())
        log.info("upgrade \(name): needed (have \(bitmapWidth)px, need \(needPx)px @ \(String(format: "%.2f", currentEffectiveScale))×)")
        let t0 = Date()
        let logRef = log

        upgradeTasks[url] = Task(priority: .userInitiated) { [weak self] in
            let upgraded = await Task.detached(priority: .userInitiated) {
                Self.decodeFullResolution(url: url, log: logRef)
            }.value
            guard let self else { return }
            self.upgradeTasks.removeValue(forKey: url)
            let ms = Int((Date().timeIntervalSince(t0) * 1000).rounded())
            if Task.isCancelled {
                logRef.info("upgrade \(name): cancelled after \(ms) ms")
                return
            }
            guard let upgraded else {
                logRef.error("upgrade \(name): decode failed after \(ms) ms")
                return
            }
            self.cache.setObject(upgraded, forKey: url as NSURL)
            if self.currentURL == url {
                logRef.info("upgrade \(name): swapping in (total \(ms) ms)")
                self.setImage(upgraded)
            } else {
                logRef.info("upgrade \(name): cached for later (total \(ms) ms, user moved on)")
            }
        }
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
    private nonisolated static func decodeThumbnailCG(url: URL, maxPixel: CGFloat) -> SendableCGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let baseOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]

        // 1. Fast: use the embedded thumbnail if one exists and is large enough.
        var opts = baseOpts
        opts[kCGImageSourceCreateThumbnailFromImageIfAbsent] = false
        opts[kCGImageSourceCreateThumbnailFromImageAlways] = false
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
        log.info("nav select → \(url.lastPathComponent)")
        markNavStart("select → \(url.lastPathComponent)")
        show(url)
    }

    // MARK: - Metadata

    private func loadMetadata(for url: URL) {
        metadata = nil
        // Compute the RAW classification on the calling actor — it
        // reads `URL.resourceValues` which is cheap and we already
        // know the URL is the one the user opened.
        let isRaw = Self.isRawImage(url)
        metadataTask = Task { [weak self] in
            let meta = await Self.readMetadata(url: url, isRaw: isRaw)
            guard let self else { return }
            if Task.isCancelled || self.currentURL != url { return }
            self.metadata = meta
        }
    }

    private static func readMetadata(url: URL, isRaw: Bool) async -> ImageMetadata? {
        await Task.detached(priority: .utility) { () -> ImageMetadata? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            else { return nil }

            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

            let width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0

            let make = tiff[kCGImagePropertyTIFFMake] as? String
            let model = tiff[kCGImagePropertyTIFFModel] as? String
            let camera: String? = {
                switch (make, model) {
                case let (m?, mm?) where !mm.lowercased().contains(m.lowercased()):
                    return "\(m) \(mm)"
                case let (_, mm?): return mm
                case let (m?, _): return m
                default: return nil
                }
            }()

            let lens = (exif[kCGImagePropertyExifLensModel] as? String)
                ?? (exif[kCGImagePropertyExifLensMake] as? String)

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
            // ImageIO surfaces a friendly name for the embedded ICC
            // profile when one is present (sRGB, Display P3, Adobe RGB,
            // ProPhoto, etc.). Falls back to nil for files with only a
            // calibrated/device profile.
            let profileName = props[kCGImagePropertyProfileName] as? String

            // HDR detection. Two signals cover the practical universe:
            //  1. Bit depth > 8 — HDR HEIC, OpenEXR, Radiance HDR,
            //     16-bit TIFF, JPEG XL HDR, etc.
            //  2. Embedded HDR gain map — iPhone HDR HEIC files store
            //     SDR pixels at 8 bpc plus a gain map auxiliary that
            //     boosts to extended range on capable displays.
            let depth = (props[kCGImagePropertyDepth] as? Int) ?? 8
            let hasGainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                src, 0, kCGImageAuxiliaryDataTypeHDRGainMap
            ) != nil
            let isHDR = depth > 8 || hasGainMap

            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { Int64($0) }

            return ImageMetadata(
                pixelWidth: width,
                pixelHeight: height,
                fileSize: fileSize,
                camera: camera,
                lens: lens,
                iso: iso,
                aperture: aperture,
                shutter: shutter,
                focalLengthMM: focal,
                dateTaken: date,
                colorModel: colorModel,
                profileName: profileName,
                isRaw: isRaw,
                isHDR: isHDR
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
               let type = values.contentType
            {
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
    init(_ image: CGImage) {
        self.image = image
    }
}

// MARK: - NSImage source-bitmap-width tagging

/// Stable storage key for the associated `sourceBitmapWidth` value below.
private nonisolated(unsafe) var sourceBitmapWidthKey: UInt8 = 0

/// Stable storage key for the associated `displaySurface` value below.
private nonisolated(unsafe) var displaySurfaceKey: UInt8 = 0

extension NSImage {
    /// The pixel width of the original CGImage we wrapped, recorded at
    /// construction time. Survives even after AppKit appends Retina
    /// cache representations that would otherwise pollute reads of
    /// `representations.first?.pixelsWide`. See
    /// `ImageLoader.bitmapPixelWidth(_:)` for why this matters.
    var sourceBitmapWidth: Int? {
        get { objc_getAssociatedObject(self, &sourceBitmapWidthKey) as? Int }
        set {
            objc_setAssociatedObject(
                self, &sourceBitmapWidthKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Pre-rendered, IOSurface-backed copy of the CGImage we wrapped.
    /// Populated during decode (see `ImageLoader.makeNSImage(...)`)
    /// so the view layer can hand a Mach-port-backed surface to
    /// `CALayer.contents` instead of a malloc-backed CGImage. Skipping
    /// the per-commit cross-process bitmap copy is the difference
    /// between a ~95 ms swap-to-paint and a single-frame swap.
    var displaySurface: IOSurface? {
        get { objc_getAssociatedObject(self, &displaySurfaceKey) as? IOSurface }
        set {
            objc_setAssociatedObject(
                self, &displaySurfaceKey, newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

// MARK: - LoadLog

/// In-app developer log used by `ImageLoader` to record the timing of
/// decode / prefetch / upgrade events. Surfaced through a dev overlay
/// (toggle with ⌘L) so we can see where time is being spent without
/// shipping `print` calls or cracking open Console.app.
///
/// The class is `@unchecked Sendable` so any actor (including detached
/// background decode tasks) can append a line without a hop. The actual
/// `@Published` mutation happens on the main actor via `Task { @MainActor }`,
/// preserving SwiftUI's invariants.
final class LoadLog: ObservableObject, @unchecked Sendable {
    enum Level: String {
        case info, warn, error
    }

    struct Entry: Identifiable, Equatable {
        let id: UInt64
        let timestamp: Date
        let level: Level
        let message: String
    }

    @Published private(set) var entries: [Entry] = []

    /// Hard cap on retained entries — older ones are dropped on overflow
    /// to keep the overlay scrollable and memory bounded during long
    /// browsing sessions.
    private let cap = 500
    private let counter = AtomicCounter()

    func info(_ msg: String) {
        append(.info, msg)
    }

    func warn(_ msg: String) {
        append(.warn, msg)
    }

    func error(_ msg: String) {
        append(.error, msg)
    }

    private func append(_ level: Level, _ msg: String) {
        let entry = Entry(
            id: counter.next(),
            timestamp: Date(),
            level: level,
            message: msg
        )
        // SwiftUI's @Published needs to fire its objectWillChange on the
        // main actor. When we're already there, run synchronously via
        // `MainActor.assumeIsolated` so the timestamp the user sees in
        // the overlay matches the moment the event happened. From a
        // background queue, hop via GCD (cheaper than spawning a Task).
        if Thread.isMainThread {
            MainActor.assumeIsolated { commit(entry) }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.commit(entry)
            }
        }
    }

    @MainActor private func commit(_ entry: Entry) {
        entries.append(entry)
        if entries.count > cap {
            entries.removeFirst(entries.count - cap)
        }
    }

    @MainActor func clear() {
        entries.removeAll()
    }
}

/// Lock-free monotonically-increasing UInt64 counter. Used to give every
/// log entry a stable identity for SwiftUI's `ForEach`. Avoids `UUID()`
/// (which is fine but heavier than an int).
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}
