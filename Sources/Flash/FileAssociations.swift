import AppKit
import UniformTypeIdentifiers

/// Offers to make Flash the default viewer for common image types.
///
/// Launch Services only records a default after the user agrees (or after they
/// pick Flash in Finder’s Get Info). We never change `LSHandlerRank` in the
/// Info.plist — that would steal associations just by being installed.
enum FileAssociations {
    private static let promptedKey = "fileAssociationPromptCompleted"

    /// Concrete types we claim. Parent `public.image` is not enough: jpeg/png
    /// already have a more specific default (Preview) that would win.
    static let claimTypes: [UTType] = {
        var types: [UTType] = [
            .jpeg, .png, .tiff, .gif, .bmp, .webP, .heic, .heif, .rawImage,
        ]
        if let heics = UTType("public.heics") { types.append(heics) }
        if let ico = UTType("com.microsoft.ico") { types.append(ico) }
        return types
    }()

    /// First-run prompt. Skipped for the raw SwiftPM binary, if the user
    /// already answered, or if Flash is already the default for JPEG/PNG/HEIC.
    static func promptOnLaunchIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        guard !UserDefaults.standard.bool(forKey: promptedKey) else { return }
        guard !isDefaultForCommonTypes else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            present(includeDontAsk: true)
        }
    }

    @MainActor
    static func confirmAndClaim() {
        present(includeDontAsk: false)
    }

    @MainActor
    private static func present(includeDontAsk: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Use Flash to open images?"
        alert.informativeText =
            "Flash can become the default app for JPEG, PNG, HEIC, TIFF, WebP, GIF, and camera RAW files. You can change this later in Finder with Get Info."
        alert.addButton(withTitle: "Use Flash")
        alert.addButton(withTitle: "Not Now")
        if includeDontAsk {
            alert.addButton(withTitle: "Don’t Ask Again")
        }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            claim()
            UserDefaults.standard.set(true, forKey: promptedKey)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: promptedKey)
        default:
            break
        }
    }

    static var isDefaultForCommonTypes: Bool {
        let app = Bundle.main.bundleURL.standardizedFileURL
        return [.jpeg, .png, .heic].allSatisfy { type in
            NSWorkspace.shared.urlForApplication(toOpen: type)?
                .standardizedFileURL == app
        }
    }

    static func claim() {
        let app = Bundle.main.bundleURL
        for type in claimTypes {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if let error {
                    NSLog(
                        "Flash: could not become default for %@: %@",
                        type.identifier,
                        error.localizedDescription
                    )
                }
            }
        }
    }
}
