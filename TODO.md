# TODO

Short list of things that aren't here yet, grouped by area. Roughly
ordered within each section by perceived value.

## Navigation & viewing
- [ ] Fullscreen mode with auto-hiding UI
- [ ] Rotate ±90° (view-only, no file mutation)
- [ ] Folder watching — auto-refresh siblings when files change on disk
- [ ] Slideshow / auto-advance with configurable interval
- [ ] Sort options (date taken / filename / file mtime)
- [ ] "Reveal in Finder" / "Open With…" context menu

## Image inspection
- [ ] Full EXIF panel (side panel, beyond the bottom bar's summary)
- [ ] Histogram overlay (luminance / RGB)
- [ ] Pixel-color picker
- [ ] Side-by-side compare (handy for burst picks)

## File management
- [ ] Star / flag / pick (xattr-backed tag, like the quarantine touch)
- [ ] Filter visible siblings by flag
- [ ] Move-to-folder and rename

## Format coverage
- [ ] Live Photo playback (HEIC + paired MOV, hold-to-play)
- [ ] Animated GIF / WebP / APNG
- [ ] Multi-page TIFF / HEIC bursts

## Performance polish
- [ ] Wide-gamut IOSurface path for HDR (currently HDR uses the slow
      CGImage swap)
- [ ] Disk-backed thumbnail cache (strip re-decodes on every launch)
- [ ] Adjacency-aware decode-max-pixel (smaller cap for small windows,
      larger for fullscreen)

## Persistence
- [ ] Remember window size / thumbnail-strip position / zoom mode
- [ ] Recent files menu
