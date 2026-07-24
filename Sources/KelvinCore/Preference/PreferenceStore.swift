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

        if let handle = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? handle.closeFile() }
            try handle.seekToEnd()
            if let lineData = line.data(using: .utf8) {
                try handle.write(contentsOf: lineData)
            }
        } else {
            try line.write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Reads all recorded preference picks from the log file.
    public func loadAll() throws -> [PreferencePick] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: logFileURL.path) else { return [] }

        let content = try String(contentsOf: logFileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var picks: [PreferencePick] = []
        let lines = content.components(separatedBy: .newlines)
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if let data = line.data(using: .utf8) {
                let pick = try decoder.decode(PreferencePick.self, from: data)
                picks.append(pick)
            }
        }
        return picks
    }
}
