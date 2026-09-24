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
    ///
    /// Still 1 after D29 added the creative look, deliberately: the two new fields are ADDITIVE and
    /// optional on the wire. A record written before them decodes here with no look (which is what
    /// it always meant), and a record written after them decodes in an older build as the same
    /// style with the look ignored — degraded, not broken. Nothing reads `version` to branch, so
    /// bumping it would buy a number and no behaviour. `SavedEdit.lookId` was added on the same
    /// terms.
    var version: Int = 1
    /// The style the whole shoot is in, by `CandidateStyle` raw value. Nil means the shoot has never
    /// been given a look and each photograph falls back to whatever the engine ranks first.
    var style: String?
    /// Frames that were given a different look from the rest of the shoot, by path.
    var overrides: [String: String] = [:]
    var appliedAt: String?
    /// The creative look (`LookPreset.id` — Portrait film, Mono, Selenium…) that goes on top of
    /// `style` on every frame with no override. Nil means the style alone. D29.
    ///
    /// **This is not a slider carried across the shoot**, which is the thing D13 exists to forbid.
    /// A preset is a fixed creative choice with a name, the same kind of decision as the style: it
    /// is applied to each frame's OWN development exactly as it would be if the photographer had
    /// clicked it there (`LookPreset.applied(to:)`, the one composition rule). What never travels
    /// is what someone dialled on the hero frame — its exposure, its per-band colour, its masks.
    ///
    /// Before this field, "Apply to shoot" on a frame in Soft + Portrait film gave every other
    /// frame Soft and silently dropped the film look — the choice the photographer had just made,
    /// halved, with nothing on screen to say so.
    var lookId: String?
    /// The creative look for each OVERRIDDEN frame, by the same canonical path as `overrides`.
    ///
    /// **An override is a whole choice: a style plus an optional look.** So a path in `overrides`
    /// that is absent here is "that style, no look" — NOT "inherit the shoot's look". The
    /// alternative reads naturally until the day a selection is given Mono and the shoot is in
    /// Portrait film, and the frames that were singled out precisely to be different come back in
    /// the shoot's film look anyway. Keys here without a matching `overrides` entry mean nothing.
    ///
    /// A separate map rather than widening `overrides`' value type, so every record already on
    /// disk decodes untouched — its overrides simply carry no look, which is what they always had.
    var overrideLooks: [String: String] = [:]

    init(version: Int = 1, style: String? = nil, overrides: [String: String] = [:],
         appliedAt: String? = nil, lookId: String? = nil, overrideLooks: [String: String] = [:]) {
        self.version = version
        self.style = style
        self.overrides = overrides
        self.appliedAt = appliedAt
        self.lookId = lookId
        self.overrideLooks = overrideLooks
    }

    /// Every field but `version` read with `decodeIfPresent`, so a record written by ANY earlier
    /// build decodes — the synthesised decoder would have demanded `overrideLooks` of every record
    /// written before it existed, and a shoot's look that fails to decode is a shoot that quietly
    /// forgets it was ever given one.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        style = try c.decodeIfPresent(String.self, forKey: .style)
        overrides = try c.decodeIfPresent([String: String].self, forKey: .overrides) ?? [:]
        appliedAt = try c.decodeIfPresent(String.self, forKey: .appliedAt)
        lookId = try c.decodeIfPresent(String.self, forKey: .lookId)
        overrideLooks = try c.decodeIfPresent([String: String].self, forKey: .overrideLooks) ?? [:]
    }

    func style(for photo: URL) -> String? {
        overrides[photo.standardizedFileURL.path] ?? style
    }

    /// The creative look a photograph is carried into, by `LookPreset.id`, or nil for none.
    ///
    /// Follows the override rule above: a frame singled out gets exactly its override's look (which
    /// may be none); every other frame gets the shoot's. A frame the record does not claim at all
    /// has no style and therefore no look — a look is only ever carried together with a style.
    func lookId(for photo: URL) -> String? {
        let key = photo.standardizedFileURL.path
        if overrides[key] != nil { return overrideLooks[key] }
        return style == nil ? nil : lookId
    }

    /// The record to write when `styleId` — with the creative look `lookId`, if any — is applied to
    /// `scope` within a shoot of `allPhotos`.
    ///
    /// **Only an apply that covers every photograph in the folder may claim the folder itself.**
    /// `style` is the shoot-wide fallback and `style(for:)` hands it to every frame with no
    /// override — including the ones the scope deliberately left out. So writing it for a narrower
    /// scope silently gives the look to rejected and undecided frames while the status line reports
    /// only the count that was asked for, which is the worst combination available: wrong, and
    /// reported as right. Anything narrower writes per-frame overrides instead and leaves the rest
    /// of the shoot exactly as it was.
    ///
    /// The creative look travels with the style in both branches, never apart from it: the pair is
    /// one decision (D29), and an apply that moved one without the other would be the halved
    /// choice this field was added to stop.
    ///
    /// Pure, so the rule that decides what four hundred photographs get is testable without a
    /// window or a file.
    func applying(_ styleId: String, look lookId: String? = nil,
                  to scope: [URL], inShootOf allPhotos: [URL]) -> ShootLook {
        var next = self
        if ShootLook.covers(scope, allPhotos) {
            // "Apply this to everything" has to mean everything, or the frames singled out last
            // week silently outrank the decision just made.
            next.style = styleId
            next.lookId = lookId
            next.overrides = [:]
            next.overrideLooks = [:]
        } else {
            for url in scope {
                let key = url.standardizedFileURL.path
                next.overrides[key] = styleId
                // Written or REMOVED: an override re-applied without a look must not keep the look
                // an earlier apply gave that frame.
                next.overrideLooks[key] = lookId
            }
        }
        return next
    }

    /// The recipe a claimed frame exports: its style, resolved against its own photograph, with
    /// the carried creative look composed on top by the one rule there is for that —
    /// `LookPreset.applied(to:)`, the same composition the canvas applies piecewise.
    ///
    /// **The look goes on AFTER the style is resolved, never into the resolve.** `ResolvedRecipeStore`
    /// caches photograph + style → recipe, which is the expensive, deterministic half (a decode and
    /// a curation pass). A preset is a pure function on top of that answer, so putting it here
    /// keeps the cache key what it was: switching a shoot from Portrait film to Mono re-exports from
    /// cache instead of re-reading four hundred frames, and no record already in the cache changes
    /// meaning. An id the library no longer has composes nothing, rather than failing the export.
    static func finished(_ resolved: Recipe, look lookId: String?) -> Recipe {
        guard let look = lookId.flatMap(LookPreset.named) else { return resolved }
        return look.applied(to: resolved)
    }

    /// How the whole choice is said on screen: "Soft", or "Soft + Portrait film" when a creative
    /// look rides on the style. One spelling, so the button's tooltip, the apply's status line and
    /// the canvas's "adapted from the shoot's look" all name the same thing the same way.
    static func choiceLabel(style: String, look lookId: String?) -> String {
        guard let name = lookId.flatMap(LookPreset.named)?.name else { return style }
        return "\(style) + \(name)"
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
        // FAST PATHS FIRST. This is read by the footer's button label on every body evaluation —
        // which, during a slider drag, is every tick — and standardising 874 URLs to answer "is
        // the whole shoot in scope" was 22% of main-thread time in a profile of that drag. The
        // scope is almost always the folder listing itself, or a strict subset of it: both are
        // answered without touching a single path.
        if scope.count < allPhotos.count { return false }
        if scope == allPhotos { return true }
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

    // `in base:` exists for the tests, which read and write records under a temporary directory
    // so that running the suite never touches a real shoot's record in Application Support. The
    // app always takes the default; `AppState.shootLookDirectory` is the one seam it is set through.
    static func url(for folder: URL, in base: URL = ShootLookStore.directory) -> URL {
        base.appendingPathComponent(key(for: folder)).appendingPathExtension("json")
    }

    static func load(for folder: URL, in base: URL = ShootLookStore.directory) -> ShootLook? {
        guard let data = try? Data(contentsOf: url(for: folder, in: base)) else { return nil }
        return try? JSONDecoder().decode(ShootLook.self, from: data)
    }

    static func save(_ look: ShootLook, for folder: URL, in base: URL = ShootLookStore.directory) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(look).write(to: url(for: folder, in: base), options: .atomic)
        } catch {
            // Same reasoning as EditStore: a silent failure here loses a decision about a whole
            // shoot, and the filename stays redacted because the log must not leak what the app
            // promises not to.
            log.error("Failed to save shoot look: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func remove(for folder: URL, in base: URL = ShootLookStore.directory) {
        try? FileManager.default.removeItem(at: url(for: folder, in: base))
    }
}
