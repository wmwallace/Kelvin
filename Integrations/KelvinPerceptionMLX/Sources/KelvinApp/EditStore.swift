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

/// Keep it or lose it. Deliberately binary.
///
/// The temptation is five stars plus colour labels plus flags, and that is the documented mistake:
/// dozens of possible states per image is the enemy of speed, and speed is the whole point when a
/// shoot is too big to hold in your head. A first pass wants one decision with no thinking in it.
enum PhotoFlag: String, Codable, Sendable {
    case keep, reject
}

/// Which frames a photographer has decided about, stored beside the edits.
///
/// Kept out of the photo folder for the same reason edits are — Kelvin never writes next to
/// someone's originals — and keyed by resolved path so moving the app or reopening a folder
/// finds the same decisions.
@MainActor
enum FlagStore {
    private static var url: URL { EditStore.directory.appendingPathComponent("flags.json") }

    private static var cache: [String: PhotoFlag] = load()

    private static func load() -> [String: PhotoFlag] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: PhotoFlag].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func persist() {
        try? FileManager.default.createDirectory(at: EditStore.directory,
                                                 withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: url, options: .atomic)
    }

    static func flag(for photo: URL) -> PhotoFlag? {
        cache[photo.standardizedFileURL.path]
    }

    /// Setting the flag it already has clears it — the same key both flags and unflags, so a
    /// mistaken keystroke is undone by repeating it rather than by finding a different one.
    static func toggle(_ flag: PhotoFlag, for photo: URL) {
        let key = photo.standardizedFileURL.path
        cache[key] = (cache[key] == flag) ? nil : flag
        persist()
    }

    static func clear(for photo: URL) {
        cache.removeValue(forKey: photo.standardizedFileURL.path)
        persist()
    }

    static func flags(among photos: [URL]) -> [URL: PhotoFlag] {
        var out: [URL: PhotoFlag] = [:]
        for photo in photos {
            if let f = cache[photo.standardizedFileURL.path] { out[photo] = f }
        }
        return out
    }
}
