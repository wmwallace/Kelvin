import Foundation
import CryptoKit
import KelvinCore

/// What the user did to a photo, in a form that survives quitting the app.
///
/// The values are absolute, not a diff against the candidate — a later engine version might
/// generate a different candidate, and the edit you made should not silently drift because of it.
struct SavedEdit: Codable {
    var styleId: String?
    var global: GlobalAdjustments
    var userMasks: [UserMaskVM]
    var maskEnabled: [String: Bool]
    var maskStrength: [String: Double]
    var straighten: Double
    var hsl: [String: HSLAdjustment]
    var blackAndWhite: BlackAndWhiteMix?
    var removeDust: Bool
    var savedAt: String
    /// Recorded for provenance and to spot a file that changed under us; not used for lookup.
    var contentHint: String?
}

/// Persists edits between launches.
///
/// **Deliberately not written next to your photos.** A sidecar beside the original is the usual
/// convention and the architecture is built for it, but silently creating files inside someone's
/// photography library is not a decision an app should make on its own. So edits live in the app's
/// own Application Support directory until the owner asks otherwise; the format is the same, so
/// pointing it at real sidecars later is a path change, not a rewrite.
///
/// Keyed by the photo's **path**, not its contents: hashing a folder of 60 MP RAWs just to draw the
/// filmstrip's "edited" dots would stall the UI, and path lookup is instant. The trade is that
/// moving or renaming a photo orphans its edit — recorded here so it's a known limit rather than a
/// surprise.
enum EditStore {

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Branding.displayName)
            .appendingPathComponent("edits")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func key(for photo: URL) -> String {
        let digest = SHA256.hash(data: Data(photo.standardizedFileURL.path.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    static func url(for photo: URL) -> URL {
        directory.appendingPathComponent(key(for: photo)).appendingPathExtension("json")
    }

    static func save(_ edit: SavedEdit, for photo: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(edit) else { return }
        try? data.write(to: url(for: photo), options: .atomic)
    }

    static func load(for photo: URL) -> SavedEdit? {
        guard let data = try? Data(contentsOf: url(for: photo)) else { return nil }
        return try? JSONDecoder().decode(SavedEdit.self, from: data)
    }

    static func remove(for photo: URL) {
        try? FileManager.default.removeItem(at: url(for: photo))
    }

    /// Which of these photos already have a saved edit — a cheap existence check per file, so the
    /// filmstrip can mark them without opening anything.
    static func edited(among photos: [URL]) -> Set<URL> {
        let fm = FileManager.default
        return Set(photos.filter { fm.fileExists(atPath: url(for: $0).path) })
    }
}
