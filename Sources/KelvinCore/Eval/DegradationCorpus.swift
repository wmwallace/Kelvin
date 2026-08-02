import Foundation

/// Builds a **commercial-clean** evaluation corpus from good photographs, with no dependence on
/// licence-encumbered expert edits (FiveK/PPR10K are non-commercial-research only).
///
/// The trick: a finished photograph *is* the reference. For each good photo we synthesise
/// degraded versions — a known underexposure, colour cast, flatness, etc. — as the *sources*,
/// and keep the original as the single reference. The engine then perceives a degraded source
/// and must recover it toward the original; the eval harness scores ΔE to that known-good truth.
///
/// This measures the thing the perception→engine path actually does (diagnose and fix capture
/// problems), and it is licence-safe on any photos the user owns — their own library being the
/// cleanest possible source.
public enum DegradationCorpus {

    /// A named capture fault, expressed as a recipe applied to a good photo to simulate it.
    public struct Degradation: Sendable {
        public let id: String
        public let recipe: Recipe
        public init(id: String, recipe: Recipe) { self.id = id; self.recipe = recipe }
    }

    private static func make(_ mutate: (inout GlobalAdjustments) -> Void) -> Recipe {
        var g = GlobalAdjustments.neutral
        mutate(&g)
        return Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                      global: g, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    /// A spread across the defect space the engine is built to correct. Temperatures exploit the
    /// renderer's pinned WB sign: a *lower* target Kelvin warms the image (adds a warm cast), a
    /// higher one cools it.
    public static let standard: [Degradation] = [
        Degradation(id: "underexposed", recipe: make { $0.exposureEV = -1.3 }),
        Degradation(id: "overexposed",  recipe: make { $0.exposureEV = 1.0 }),
        Degradation(id: "warm-cast",    recipe: make { $0.temperatureK = 4000 }),
        Degradation(id: "cool-cast",    recipe: make { $0.temperatureK = 8800 }),
        Degradation(id: "flat",         recipe: make { $0.contrast = -70; $0.saturation = -20 }),
        Degradation(id: "dull",         recipe: make { $0.saturation = -45 })
    ]

    public enum Error: Swift.Error, CustomStringConvertible {
        case noPhotos(URL)
        case collidingNames(stem: String, files: [URL])
        public var description: String {
            switch self {
            case .noPhotos(let url): return "No decodable photos in \(url.path)"
            case .collidingNames(let stem, let files):
                let names = files.map { $0.lastPathComponent }.joined(separator: " and ")
                return "Two photographs share the name \"\(stem)\" (\(names)). Every reference, "
                    + "source and entry id is keyed on that name, so one would overwrite the other "
                    + "while the manifest counted both. Build from one format, or rename."
            }
        }
    }

    /// Directory of perception labels the manifest points at (created later by
    /// `kelvin-perceive label`). Pre-filling the path lets the eval score the engine as soon as
    /// labels exist, and skip it (scoring only baselines) until then.
    public static let perceptionDirName = "perception"

    /// Build the corpus into `outputDir`: `reference/` (the originals), `source/` (degraded
    /// variants), and `manifest.json`. Returns the manifest.
    ///
    /// - Parameter longEdge: cap the long edge of every reference and source. **Use it.** A corpus
    ///   built from 60 MP frames cannot run on every commit, which is the whole point of the
    ///   harness (docs/EVALUATION.md) — the evaluator renders every style on every entry, and it
    ///   does that at whatever size the corpus was written at. Reference and sources are capped
    ///   together, so the ΔE target is unaffected: both sides of the comparison move identically.
    ///   Nil keeps full resolution.
    @discardableResult
    public static func build(
        goodPhotos: [URL],
        degradations: [Degradation] = standard,
        outputDir: URL,
        longEdge: Int? = nil
    ) throws -> CorpusManifest {
        let photos = goodPhotos.sorted(by: { $0.path < $1.path })

        // A folder straight off a camera holds `_DSC0100.ARW` beside `_DSC0100.JPG`, and both
        // would key the same `reference/_DSC0100.png` and the same entry id: the second write wins
        // while the manifest emits a full set of entries for each, so the corpus claims twice the
        // frames it holds and every number computed on it is quietly wrong. Refuse before writing
        // anything rather than disambiguate, because the stem is also how a corpus finds its
        // perception labels (`perception/<id>.json`) — renaming entries would silently unmatch the
        // labels of every corpus already built. Compared case-insensitively: it is the written path
        // that collides, and macOS volumes are case-insensitive by default.
        var seenStems: [String: URL] = [:]
        for photo in photos {
            let stem = photo.deletingPathExtension().lastPathComponent
            if let first = seenStems.updateValue(photo, forKey: stem.lowercased()) {
                throw Error.collidingNames(stem: stem, files: [first, photo])
            }
        }

        let fm = FileManager.default
        let refDir = outputDir.appendingPathComponent("reference")
        let srcDir = outputDir.appendingPathComponent("source")
        try fm.createDirectory(at: refDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)

        var entries: [CorpusManifest.Entry] = []
        for photo in photos {
            let stem = photo.deletingPathExtension().lastPathComponent
            // Resized BEFORE degrading, not after: a degradation is a recipe, and applying it to
            // the frame the corpus will actually be scored on keeps the source an exact render of
            // the reference. Resizing afterwards would resample the two independently and put a
            // small, unowned difference between them on every entry.
            var good = try ImageDecoder.decode(url: photo)
            if let longEdge { good = PerceptionProxy.downsample(good, maxEdge: longEdge) }

            // Reference = the original, normalised to PNG so metric sampling is format-stable.
            let refRel = "reference/\(stem).png"
            try ImageWriter.write(good, to: outputDir.appendingPathComponent(refRel), format: .png)

            for degradation in degradations {
                let degraded = Renderer.render(good, with: degradation.recipe)
                let sourceStem = "\(stem)__\(degradation.id)"
                let sourceRel = "source/\(sourceStem).png"
                try ImageWriter.write(degraded, to: outputDir.appendingPathComponent(sourceRel), format: .png)

                entries.append(CorpusManifest.Entry(
                    id: sourceStem,
                    source: sourceRel,
                    cameraJpeg: nil,
                    references: [refRel],
                    perception: "\(perceptionDirName)/\(sourceStem).json"
                ))
            }
        }
        guard !entries.isEmpty else { throw Error.noPhotos(outputDir) }

        let manifest = CorpusManifest(schemaVersion: 1, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: outputDir.appendingPathComponent("manifest.json"))
        return manifest
    }
}
