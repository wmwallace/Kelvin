import Foundation

/// Milestone 6: preference store conforming to docs/RECIPE-SCHEMA.md Stage 3.
///
/// Every time the user picks among candidates, that is a labelled comparison.
/// "Semantic understanding of a single photo produces several candidate parametric recipes;
/// the user's pick becomes training signal." (CLAUDE.md differentiator).
public struct PreferencePick: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var imageId: String
    public var perceptionHash: String?
    public var shown: [String]
    public var chosen: String
    public var subsequentManualEdits: [String: Double]?
    public var timestamp: Date

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = currentSchemaVersion,
        imageId: String,
        perceptionHash: String? = nil,
        shown: [String],
        chosen: String,
        subsequentManualEdits: [String: Double]? = nil,
        timestamp: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.imageId = imageId
        self.perceptionHash = perceptionHash
        self.shown = shown
        self.chosen = chosen
        self.subsequentManualEdits = subsequentManualEdits
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case imageId = "image_id"
        case perceptionHash = "perception_hash"
        case shown
        case chosen
        case subsequentManualEdits = "subsequent_manual_edits"
        case timestamp
    }
}

public actor PreferenceStore {
    private let logFileURL: URL
    private let encoder: JSONEncoder

    public init(logFileURL: URL) {
        self.logFileURL = logFileURL
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    /// Appends a user preference pick to the log file on disk.
    public func record(pick: PreferencePick) throws {
        let data = try encoder.encode(pick)
        guard var line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "PreferenceStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to stringify pick"])
        }
        line += "\n"

        let fm = FileManager.default
        let folder = logFileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: folder.path) {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        // Whether to create or to append is decided by whether the file exists, never by
        // whether the handle opened. `try?` on the open would erase the difference between
        // "no log yet" and "the log is there but unwritable" — a read-only mode left behind
        // by a restore, or descriptor exhaustion — and the create path *replaces* the file.
        // This log is append-forever training signal that cannot be recomputed from the
        // originals, so a failed open must cost one pick and throw, not the whole history.
        // The gap between the existence check and the open is harmless: `record` is actor
        // isolated and is the only writer.
        if !fm.fileExists(atPath: logFileURL.path) {
            try line.write(to: logFileURL, atomically: true, encoding: .utf8)
        } else {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let lineData = line.data(using: .utf8) {
                try handle.write(contentsOf: lineData)
            }
        }
    }

    /// Reads all recorded preference picks from the log file.
    ///
    /// A line that will not decode is skipped, not fatal. The append in `record` is not
    /// atomic, so a crash mid-write can leave one truncated line — and this log is
    /// append-forever training signal, so one bad line must never make years of picks
    /// unreadable. The skip count is returned to the caller's judgment via
    /// `loadAllReport` below; this convenience keeps the original signature.
    public func loadAll() throws -> [PreferencePick] {
        try loadAllReport().picks
    }

    public func loadAllReport() throws -> (picks: [PreferencePick], skippedLines: Int) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logFileURL.path) else { return ([], 0) }

        let content = try String(contentsOf: logFileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var picks: [PreferencePick] = []
        var skipped = 0
        let lines = content.components(separatedBy: .newlines)
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let data = line.data(using: .utf8),
                  let pick = try? decoder.decode(PreferencePick.self, from: data) else {
                skipped += 1
                continue
            }
            picks.append(pick)
        }
        return (picks, skipped)
    }
}
