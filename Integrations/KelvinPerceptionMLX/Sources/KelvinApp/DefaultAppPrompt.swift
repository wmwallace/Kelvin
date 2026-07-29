import Foundation
import AppKit
import CoreServices
import UniformTypeIdentifiers
import KelvinCore
import os

/// Whether Kelvin is the app that opens a photograph when you double-click one, and the offer to
/// become it.
///
/// **Kelvin ships as `LSHandlerRank = Alternate` and that is deliberate** — see the long note in
/// `scripts/package-app.sh`. `Default` would tell Launch Services to take over JPEG and RAW the
/// moment the app is installed, and silently reassigning a photographer's double-click is not a
/// decision an app gets to make on their behalf, least of all one that opens a 1.6 GB model to show a
/// picture. The plist's promise is that Kelvin appears in the "Open With" menu and *the user promotes
/// it if they want it*.
///
/// This is the other half of that promise, which was missing. "The user can promote it" was true only
/// in the sense that Finder's Get Info panel exists — there was nothing in the app that offered, so
/// the feature was reachable only by someone who already knew macOS well enough not to need it.
/// Asking once, plainly, with a decline that sticks, is the well-behaved version.
///
/// The prompt is **offered once and never nagged**: declining records the decision, and the offer
/// does not come back. It stays available in Settings ▸ General for anyone who changes their mind.
@MainActor
enum DefaultAppPrompt {

    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "DefaultApp")

    /// Set when the user has answered the prompt either way. A declined offer that came back would be
    /// nagging, and this app has exactly one thing to ask about.
    static let askedKey = "defaultApp.asked"

    // MARK: - What Kelvin can claim

    /// Photographs, as Launch Services names them.
    ///
    /// These are the types the Info.plist declares, and the two lists must agree: Launch Services will
    /// not make an app the default handler for something its bundle never said it could open.
    static let stillImageTypes = [
        "public.jpeg", "public.png", "public.tiff", "public.heic", "public.heif"
    ]

    /// RAW, one entry per vendor, and **not** just the `public.camera-raw-image` umbrella.
    ///
    /// This is the trap the whole file exists to record. Every vendor type conforms to
    /// `public.camera-raw-image`, so declaring the umbrella in the Info.plist is enough to make Kelvin
    /// *able* to open an ARW and enough to put it in the "Open With" menu. It is **not** enough to make
    /// it the default: Launch Services resolves a concrete file to its most specific type, and
    /// `_DSC6390.ARW` is a `com.sony.arw-raw-image`. Setting only the umbrella leaves every RAW opening
    /// in whatever already claimed the vendor type — measured on this machine, Adobe Lightroom, with
    /// JPEG and PNG correctly switching over at the same time. Silent, and exactly the sort of
    /// half-configured state that reads as "the app is broken".
    ///
    /// Derived from `ImageDecoder.rawExtensions` rather than hardcoded, so a body Kelvin learns to
    /// decode is a body it can also be the default for. Extensions with no system type — `.x3f`,
    /// and whatever else Apple has not declared — resolve to a dynamic UTI and are dropped: there is
    /// nothing to claim. Those files still open by drag and by ⌘O.
    static var rawTypes: [String] {
        var seen = Set<String>()
        return ImageDecoder.rawExtensions.sorted().compactMap { ext in
            guard let type = UTType(filenameExtension: ext) else { return nil }
            let id = type.identifier
            // A dynamic identifier means the system has no declaration for this extension, so there
            // is no content type to be the handler for.
            guard !id.hasPrefix("dyn."), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    static var allTypes: [String] { stillImageTypes + rawTypes + ["public.camera-raw-image"] }

    // MARK: - State

    /// Whether Kelvin already opens the everyday cases. Deliberately not "all of them": a user who
    /// wants RAW in Kelvin and screenshots in Preview has a perfectly coherent setup, and telling them
    /// they are not done would be wrong.
    static var isDefaultForAnything: Bool {
        allTypes.contains { currentHandler(for: $0) == Branding.bundleIdentifier }
    }

    static var isDefaultForEverything: Bool {
        allTypes.allSatisfy { currentHandler(for: $0) == Branding.bundleIdentifier }
    }

    static func currentHandler(for type: String) -> String? {
        LSCopyDefaultRoleHandlerForContentType(type as CFString, .all)?
            .takeRetainedValue() as String?
    }

    /// Whether to offer. Not from a bundled app, and not twice.
    ///
    /// A `swift run` dev build has no bundle and no identifier Launch Services can register, so
    /// offering there would be offering something that cannot work.
    static var shouldOffer: Bool {
        guard Bundle.main.bundleIdentifier == Branding.bundleIdentifier else { return false }
        guard !UserDefaults.standard.bool(forKey: askedKey) else { return false }
        return !isDefaultForAnything
    }

    // MARK: - Doing it

    /// Claim `types`, returning what could not be claimed.
    ///
    /// `LSSetDefaultRoleHandlerForContentType` rather than shelling out: it returns an `OSStatus`, so a
    /// refusal is visible. `duti`, which is the obvious command-line way to do this, reported success
    /// on this machine for every vendor RAW type and changed none of them — a silent no-op is the
    /// worst possible outcome for something whose whole job is to change a setting.
    @discardableResult
    static func claim(_ types: [String]) -> [String] {
        var failed: [String] = []
        for type in types {
            let status = LSSetDefaultRoleHandlerForContentType(
                type as CFString, .all, Branding.bundleIdentifier as CFString)
            if status != noErr || currentHandler(for: type) != Branding.bundleIdentifier {
                failed.append(type)
            }
        }
        if !failed.isEmpty {
            log.error("Could not become the default for \(failed.count, privacy: .public) type(s)")
        }
        return failed
    }

    /// Hand every type back to whatever the system would choose. There is no "previous handler" to
    /// restore — Launch Services does not keep one — so this clears Kelvin's claim and lets macOS fall
    /// back, which for photographs means Preview on a stock Mac.
    static func relinquish() {
        for type in allTypes where currentHandler(for: type) == Branding.bundleIdentifier {
            LSSetDefaultRoleHandlerForContentType(type as CFString, .all,
                                                  "com.apple.Preview" as CFString)
        }
    }

    // MARK: - The offer

    /// Ask, once, after the first photograph is on screen.
    ///
    /// **Timing is the whole courtesy here.** Asked at launch, this is a modal in front of an empty
    /// window from an app that has not yet shown it can do anything. Asked once a photograph has been
    /// read and its candidates are up, the question has a subject: the user has just seen what Kelvin
    /// does with a photograph and is in a position to answer whether they want that on a double-click.
    static func offerIfAppropriate() {
        guard shouldOffer else { return }
        // Recorded BEFORE the sheet, not after. A crash or a force-quit while the dialog is up must
        // not turn "asked once" into "asks every launch" — of the two ways to be wrong, never asking
        // again is the one that does not harass anybody.
        UserDefaults.standard.set(true, forKey: askedKey)

        let alert = NSAlert()
        alert.messageText = "Open photos with \(Branding.displayName)?"
        alert.informativeText =
            "Double-clicking a photo in Finder would open it here instead of Preview — RAW files, "
            + "JPEGs, PNGs, TIFFs and HEICs.\n\n"
            + "\(Branding.displayName) never changes your original, and you can change this back at "
            + "any time in Settings."
        alert.addButton(withTitle: "Open Photos with \(Branding.displayName)")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let failed = claim(allTypes)
        if !failed.isEmpty {
            let problem = NSAlert()
            problem.messageText = "Some photo types could not be changed"
            problem.informativeText =
                "\(Branding.displayName) is now the default for the rest. macOS refused "
                + "\(failed.count) of \(allTypes.count) — another app may have claimed them in a way "
                + "that needs changing from Finder's Get Info panel."
            problem.alertStyle = .warning
            problem.runModal()
        }
    }
}
