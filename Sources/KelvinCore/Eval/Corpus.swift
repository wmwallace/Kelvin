import Foundation

/// A corpus is described by a `manifest.json` at its root. This keeps the harness
/// corpus-agnostic: MIT-Adobe FiveK, an in-house regression set, or anything else maps in
/// by writing a manifest, with no code change and no assumption baked into the evaluator
/// about a particular directory layout (docs/EVALUATION.md).
///
/// All paths in the manifest are resolved relative to the manifest's directory.
public struct CorpusManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var entries: [Entry]

    public struct Entry: Codable, Equatable, Sendable {
        /// Stable identifier, used in the report.
        public var id: String
        /// Source image to edit (RAW / JPEG / PNG), relative to the corpus root.
        public var source: String
        /// The manufacturer's own rendering, if available. Baseline 1 and the clipping
        /// floor (a result that clips worse than this is always a bug).
        public var cameraJpeg: String?
        /// Expert reference edits of the same photo. Scoring reports the *minimum* ΔE
        /// across these — matching any one expert is success, not the centroid.
        public var references: [String]

        public init(id: String, source: String, cameraJpeg: String?, references: [String]) {
            self.id = id
            self.source = source
            self.cameraJpeg = cameraJpeg
            self.references = references
        }

        enum CodingKeys: String, CodingKey {
            case id, source
            case cameraJpeg = "camera_jpeg"
            case references
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case entries
    }
}

/// Loads a manifest and exposes absolute URLs for an entry's files.
public struct Corpus {
    public let root: URL
    public let manifest: CorpusManifest

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingManifest(URL)
        case emptyCorpus(URL)

        public var description: String {
            switch self {
            case .missingManifest(let url): return "No manifest.json at \(url.path)"
            case .emptyCorpus(let url): return "Corpus at \(url.path) has no entries"
            }
        }
    }

    /// Load `manifest.json` from `root` (a directory).
    public static func load(root: URL) throws -> Corpus {
        let manifestURL = root.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw Error.missingManifest(manifestURL)
        }
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(CorpusManifest.self, from: data)
        guard !manifest.entries.isEmpty else { throw Error.emptyCorpus(root) }
        return Corpus(root: root, manifest: manifest)
    }

    public func sourceURL(for entry: CorpusManifest.Entry) -> URL {
        root.appendingPathComponent(entry.source)
    }

    public func cameraJpegURL(for entry: CorpusManifest.Entry) -> URL? {
        entry.cameraJpeg.map { root.appendingPathComponent($0) }
    }

    public func referenceURLs(for entry: CorpusManifest.Entry) -> [URL] {
        entry.references.map { root.appendingPathComponent($0) }
    }
}
