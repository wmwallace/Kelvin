import Foundation
import CryptoKit
import os
import KelvinCore

/// The look a shoot is in, and the frames that disagree with it.
///
/// **This is what "apply a look to the shoot" means, and it is deliberately not a copy of anybody's
/// sliders.** A look here is a *style* — Natural, Soft, Vivid, Dramatic — and every photograph in
/// the shoot resolves that style against its own histogram, its own scene reading and its own mask
/// stack. Frame 12 was shot into the sun and frame 13 was not; both are "Natural", and Natural means
/// something different to each of them. Copying the numbers from one frame to four hundred others is
/// the thing this app exists not to do.
///
/// **One record for the shoot, not four hundred records.** Applying a look to a folder writes a
/// single small file: the style, and a map of the frames that were given something else. The
/// alternative — materialising a full edit for every photograph the moment a button is clicked —
/// makes one click into hundreds of files, makes undo into a deletion sweep, and makes changing your
/// mind about the look an operation on the whole folder rather than a one-line change.
///
/// A per-photo edit is still written the moment a photograph is actually *edited*: the shoot look is
/// the starting point, and `EditStore` remains the record of what someone did by hand. When both
/// exist, the hand-made edit wins — see `AppState.effectiveStyle(for:)`.
///
/// Keyed by the folder's path, on the same terms and with the same known limit as `EditStore`:
/// moving the folder orphans the record.
struct ShootLook: Codable, Equatable {
    /// Versioned from the first write, like every other serialised thing in this project.
    var version: Int = 1
    /// The style the whole shoot is in, by `CandidateStyle` raw value. Nil means the shoot has never
    /// been given a look and each photograph falls back to whatever the engine ranks first.
    var style: String?
    /// Frames that were given a different look from the rest of the shoot, by path.
    var overrides: [String: String] = [:]
    var appliedAt: String?

    func style(for photo: URL) -> String? {
        overrides[photo.standardizedFileURL.path] ?? style
    }

    /// The record to write when `styleId` is applied to `scope` within a shoot of `allPhotos`.
    ///
    /// **Only an apply that covers every photograph in the folder may claim the folder itself.**
    /// `style` is the shoot-wide fallback and `style(for:)` hands it to every frame with no
    /// override — including the ones the scope deliberately left out. So writing it for a narrower
    /// scope silently gives the look to rejected and undecided frames while the status line reports
    /// only the count that was asked for, which is the worst combination available: wrong, and
    /// reported as right. Anything narrower writes per-frame overrides instead and leaves the rest
    /// of the shoot exactly as it was.
    ///
    /// Pure, so the rule that decides what four hundred photographs get is testable without a
    /// window or a file.
    func applying(_ styleId: String, to scope: [URL], inShootOf allPhotos: [URL]) -> ShootLook {
        var next = self
        if ShootLook.covers(scope, allPhotos) {
            // "Apply this to everything" has to mean everything, or the frames singled out last
            // week silently outrank the decision just made.
            next.style = styleId
            next.overrides = [:]
        } else {
            for url in scope { next.overrides[url.standardizedFileURL.path] = styleId }
        }
        return next
    }

    /// Whether `scope` reaches every photograph in `allPhotos` — the one condition under which an
    /// apply may claim the shoot itself rather than writing per-frame overrides.
    ///
    /// One copy, because the record and the sentence the app says about it have to agree. They are
    /// written in different places and the version of this bug that shipped was exactly a scope
    /// rule and a status line disagreeing about what had just happened.
    ///
    /// An empty shoot covers nothing: otherwise "every photograph is in scope" is vacuously true
    /// and applying to a folder that has not been listed yet would set a shoot-wide style.
    static func covers(_ scope: [URL], _ allPhotos: [URL]) -> Bool {
        guard !allPhotos.isEmpty else { return false }
        let covered = Set(scope.map(\.standardizedFileURL))
        return allPhotos.allSatisfy { covered.contains($0.standardizedFileURL) }
    }
}

enum ShootLookStore {

    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "ShootLook")

    static let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let base = appSupport
            .appendingPathComponent(Branding.displayName)
            .appendingPathComponent("shoots")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func key(for folder: URL) -> String {
        let digest = SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func url(for folder: URL) -> URL {
        directory.appendingPathComponent(key(for: folder)).appendingPathExtension("json")
    }

    static func load(for folder: URL) -> ShootLook? {
        guard let data = try? Data(contentsOf: url(for: folder)) else { return nil }
        return try? JSONDecoder().decode(ShootLook.self, from: data)
    }

    static func save(_ look: ShootLook, for folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(look).write(to: url(for: folder), options: .atomic)
        } catch {
            // Same reasoning as EditStore: a silent failure here loses a decision about a whole
            // shoot, and the filename stays redacted because the log must not leak what the app
            // promises not to.
            log.error("Failed to save shoot look: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func remove(for folder: URL) {
        try? FileManager.default.removeItem(at: url(for: folder))
    }
}
