import Foundation
import CryptoKit
import KelvinCore

/// What the photographer chose for one photograph: the look, and the adjustments on it.
///
/// The phone's counterpart of the Mac's `EditStore`, and deliberately smaller — a style id and three
/// offsets, because that is all the phone lets you change. Kept in the app's own Application Support
/// folder (CLAUDE.md, non-negotiable #3: nothing is written beside, or into, anyone's originals), and
/// keyed on the Photos library's identifier for the picture rather than a path, since a photo from
/// the library has no path the app can rely on (the iPhone feasibility audit, "File model").
struct PhoneEdit: Codable, Equatable {
    var styleId: String
    var light: Double
    var warmth: Double
    var contrast: Double

    init(styleId: String, adjustments: Adjustments) {
        self.styleId = styleId
        light = adjustments.light; warmth = adjustments.warmth; contrast = adjustments.contrast
    }

    var adjustments: Adjustments { Adjustments(light: light, warmth: warmth, contrast: contrast) }
}

enum PhoneEditStore {
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Edits", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func file(for key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(digest).appendingPathExtension("json")
    }

    static func load(for key: String) -> PhoneEdit? {
        guard let url = file(for: key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PhoneEdit.self, from: data)
    }

    /// Written whole or not at all, so a quit mid-write cannot leave half an edit.
    static func save(_ edit: PhoneEdit, for key: String) {
        guard let url = file(for: key), let data = try? JSONEncoder().encode(edit) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func remove(for key: String) {
        guard let url = file(for: key) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
