import Foundation

/// Turns a downloaded retouching dataset into the eval harness's `manifest.json`. Datasets ship
/// as parallel folders — one of source images and one per expert retouch, files matched by
/// basename — which maps directly onto a `CorpusManifest` (source + `references[]`).
///
/// Generic over the two datasets that matter: **PPR10K** (3 experts: `source` +
/// `target_a/b/c`) and **MIT-Adobe FiveK** (5 experts). It matches by basename *stem*, so a
/// `.tif` source pairs with `.tif` (or any supported) references, and only emits an entry when
/// every expert has that image — a scored image needs all its references.
///
/// Perception labels are optional and, when absent, the engine simply isn't scored for that
/// image (it still scores the baselines). Generate them separately by running the perception
/// backend over the source folder.
public enum CorpusBuilder {

    public struct Options: Sendable {
        /// Subdirectory (relative to root) holding the source images.
        public var sourceDir: String
        /// Subdirectories, one per expert, holding retouched references.
        public var referenceDirs: [String]
        /// Optional subdirectory of per-image perception JSON (`<stem>.json`).
        public var perceptionDir: String?
        /// Optional subdirectory of manufacturer JPEGs (`<stem>.jpg`) — the clipping floor.
        public var cameraJpegDir: String?
        /// File extensions treated as images.
        public var imageExtensions: Set<String>

        public init(
            sourceDir: String = "source",
            referenceDirs: [String],
            perceptionDir: String? = nil,
            cameraJpegDir: String? = nil,
            imageExtensions: Set<String> = ["tif", "tiff", "png", "jpg", "jpeg", "dng"]
        ) {
            self.sourceDir = sourceDir
            self.referenceDirs = referenceDirs
            self.perceptionDir = perceptionDir
            self.cameraJpegDir = cameraJpegDir
            self.imageExtensions = imageExtensions
        }

        /// PPR10K's 360p layout: `source` + three expert folders.
        public static let ppr10k = Options(
            sourceDir: "source", referenceDirs: ["target_a", "target_b", "target_c"]
        )
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case missingDirectory(URL)
        case noSources(URL)
        case noCompleteEntries

        public var description: String {
            switch self {
            case .missingDirectory(let url): return "No directory at \(url.path)"
            case .noSources(let url): return "No source images in \(url.path)"
            case .noCompleteEntries:
                return "No image had a match in every reference folder — check --references"
            }
        }
    }

    /// Build a manifest from a dataset rooted at `root`. Paths in the manifest are relative to
    /// `root`, so writing `manifest.json` at the root makes them resolve correctly.
    public static func build(root: URL, options: Options) throws -> CorpusManifest {
        let fm = FileManager.default
        func images(in relative: String) throws -> [URL] {
            let dir = root.appendingPathComponent(relative)
            guard fm.fileExists(atPath: dir.path) else { throw Error.missingDirectory(dir) }
            return try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { options.imageExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        let sources = try images(in: options.sourceDir)
        guard !sources.isEmpty else {
            throw Error.noSources(root.appendingPathComponent(options.sourceDir))
        }

        // Index each reference dir by basename stem for O(1) matching.
        let refIndexes: [[String: String]] = try options.referenceDirs.map { dir in
            var index: [String: String] = [:]
            for url in try images(in: dir) {
                index[url.deletingPathExtension().lastPathComponent] = "\(dir)/\(url.lastPathComponent)"
            }
            return index
        }
        let perceptionIndex = try options.perceptionDir.map { dir -> [String: String] in
            let d = root.appendingPathComponent(dir)
            guard fm.fileExists(atPath: d.path) else { throw Error.missingDirectory(d) }
            var index: [String: String] = [:]
            for url in try fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
            where url.pathExtension.lowercased() == "json" {
                index[url.deletingPathExtension().lastPathComponent] = "\(dir)/\(url.lastPathComponent)"
            }
            return index
        }
        let cameraIndex = try options.cameraJpegDir.map { dir -> [String: String] in
            var index: [String: String] = [:]
            for url in try images(in: dir) {
                index[url.deletingPathExtension().lastPathComponent] = "\(dir)/\(url.lastPathComponent)"
            }
            return index
        }

        var entries: [CorpusManifest.Entry] = []
        for source in sources {
            let stem = source.deletingPathExtension().lastPathComponent

            // Every expert must have this image, or it can't be scored fairly.
            let refs = refIndexes.compactMap { $0[stem] }
            guard refs.count == options.referenceDirs.count else { continue }

            entries.append(CorpusManifest.Entry(
                id: stem,
                source: "\(options.sourceDir)/\(source.lastPathComponent)",
                cameraJpeg: cameraIndex?[stem],
                references: refs,
                perception: perceptionIndex?[stem]
            ))
        }

        guard !entries.isEmpty else { throw Error.noCompleteEntries }
        return CorpusManifest(schemaVersion: 1, entries: entries)
    }

    /// Build and write `manifest.json` into `root`. Returns the manifest.
    @discardableResult
    public static func write(root: URL, options: Options, to url: URL? = nil) throws -> CorpusManifest {
        let manifest = try build(root: root, options: options)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let out = url ?? root.appendingPathComponent("manifest.json")
        try encoder.encode(manifest).write(to: out)
        return manifest
    }
}
