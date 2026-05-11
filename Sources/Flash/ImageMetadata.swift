import AppKit
import Foundation

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
    /// Friendly name of the embedded ICC profile, when one is present.
    /// Examples: "sRGB IEC61966-2.1", "Display P3", "Adobe RGB (1998)".
    /// Falls back to `nil` for files with no recognized profile.
    var profileName: String?
    /// `true` when the file is a camera RAW container (CR3, ARW, NEF,
    /// DNG, etc.). Drives the RAW badge in the status bar.
    var isRaw: Bool
    /// `true` when the file carries HDR information — either >8 bits
    /// per component (HDR HEIC, EXR, Radiance HDR) or an embedded
    /// HDR gain-map auxiliary (iPhone HDR HEIC). Drives the HDR badge.
    var isHDR: Bool

    /// Compact one-line summary for the status bar. Includes the
    /// original-on-disk pixel dimensions, file size, color profile,
    /// camera body, and an EXIF tail (focal/aperture/shutter/ISO).
    var summary: String {
        var parts: [String] = ["\(pixelWidth) × \(pixelHeight) px"]
        if let fileSize    { parts.append(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)) }
        if let profileName { parts.append(profileName) }
        if let camera      { parts.append(camera) }
        if let focalLengthMM { parts.append(String(format: "%.0f mm", focalLengthMM)) }
        if let aperture    { parts.append(String(format: "f/%.1f", aperture)) }
        if let shutter     { parts.append("\(shutter) s") }
        if let iso         { parts.append("ISO \(iso)") }
        return parts.joined(separator: "  ·  ")
    }
}