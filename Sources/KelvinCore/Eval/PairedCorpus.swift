import Foundation

/// Builds an evaluation corpus from **real before/after pairs**: a RAW as the source, and the
/// photographer's own finished export of that same frame as the reference.
///
/// This is the instrument `DegradationCorpus` cannot be. That one synthesises a fault on a finished
/// photograph and asks the engine to undo it, which is licence-safe and reproducible and has one
/// structural blind spot: **its reference is the untouched original, so every stylistic choice costs
/// ΔE and doing nothing is the strongest possible baseline.** Everything the project has learned
/// about over-tuning traces back to that (docs/EVALUATION.md, "A caution on the target"), and two
/// separate findings have now died on it — the endpoint rule's 20.7 ΔE turned out to be the look
/// being priced by an instrument that penalises looks, and the white-balance estimator that *won*
/// the degradation corpus is the one that should not ship.
///
/// Here the reference is what the photographer actually wanted. A style that moves toward it scores
/// better, so restraint is no longer free and "do nothing" is no longer near-optimal. That inverts
/// the bias rather than removing it — see the caveats on `build`.
public enum PairedCorpus {

    public enum Error: Swift.Error, CustomStringConvertible {
        case noPairs
        case unreadable(URL)
        public var description: String {
            switch self {
            case .noPairs: return "No usable RAW/edited pairs"
            case .unreadable(let url): return "Could not decode \(url.path)"
            }
        }
    }

    /// One before/after pair.
    public struct Pair: Sendable {
        /// The capture — what Kelvin is handed.
        public let source: URL
        /// The photographer's finished export of that same frame.
        public let reference: URL
        /// Prefix for the entry id, so frames from different shoots cannot collide on `_DSC1234`.
        public let group: String
        public init(source: URL, reference: URL, group: String) {
            self.source = source; self.reference = reference; self.group = group
        }
    }

    /// The largest allowed disagreement between a pair's aspect ratios, as a fraction.
    ///
    /// A crop makes a pair worthless — the two images no longer frame the same thing, so a per-pixel
    /// ΔE is measuring the crop rather than the edit — and it is the one defect that would quietly
    /// produce plausible-looking numbers. Orientation is *not* a crop: a portrait export of a
    /// landscape-sensor frame is the same pixels rotated, so the comparison is made on the long/short
    /// ratio rather than width/height.
    public static let aspectTolerance = 0.02

    /// True when the two frames plausibly show the same thing at the same framing.
    public static func aspectsAgree(_ a: (Int, Int), _ b: (Int, Int)) -> Bool {
        func ratio(_ d: (Int, Int)) -> Double {
            let hi = Double(max(d.0, d.1)), lo = Double(min(d.0, d.1))
            return lo > 0 ? hi / lo : 0
        }
        let ra = ratio(a), rb = ratio(b)
        guard ra > 0, rb > 0 else { return false }
        return abs(ra - rb) / rb <= aspectTolerance
    }

    /// Build the corpus into `outputDir` as `source/`, `reference/` and `manifest.json`.
    ///
    /// - Parameter longEdge: cap on both sides. **Use it** for the same reason `DegradationCorpus`
    ///   says to: the evaluator renders every style on every entry.
    ///
    /// ⚠️ **What this corpus can and cannot settle.** It replaces one bias with its opposite rather
    /// than removing bias: the reference now carries the photographer's whole style, so an engine
    /// that under-edits is penalised where the degradation corpus rewarded it. Neither is neutral.
    /// Read them together — a change that improves both is real, and a change that improves one at
    /// the other's expense is a taste call, not a defect fix.
    ///
    /// It also cannot distinguish "the engine chose differently" from "the engine chose worse": the
    /// reference is one photographer's edit, on their own work, in their own style. And a pair whose
    /// export was cropped is dropped rather than scored, because there is no honest way to compare
    /// two different framings.
    @discardableResult
    public static func build(
        pairs: [Pair],
        outputDir: URL,
        longEdge: Int? = nil,
        onSkip: ((URL, String) -> Void)? = nil
    ) throws -> CorpusManifest {
        let fm = FileManager.default
        let refDir = outputDir.appendingPathComponent("reference")
        let srcDir = outputDir.appendingPathComponent("source")
        try fm.createDirectory(at: refDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)

        var entries: [CorpusManifest.Entry] = []
        for pair in pairs.sorted(by: { $0.source.path < $1.source.path }) {
            let stem = "\(pair.group)-\(pair.source.deletingPathExtension().lastPathComponent)"

            guard var source = try? ImageDecoder.decode(url: pair.source) else {
                onSkip?(pair.source, "could not decode the capture"); continue
            }
            guard var reference = try? ImageDecoder.decode(url: pair.reference) else {
                onSkip?(pair.reference, "could not decode the export"); continue
            }

            // Reject a crop before spending anything on it. `extent` is the decoded frame with EXIF
            // orientation already applied, which is what makes the long/short comparison the right
            // one — by this point a rotated export has become the same shape as its capture.
            let sourceDims = (Int(source.extent.width), Int(source.extent.height))
            let refDims = (Int(reference.extent.width), Int(reference.extent.height))
            guard aspectsAgree(sourceDims, refDims) else {
                onSkip?(pair.reference,
                        "the export is cropped (\(sourceDims.0)×\(sourceDims.1) vs "
                        + "\(refDims.0)×\(refDims.1)) — a per-pixel ΔE would measure the crop")
                continue
            }

            if let longEdge {
                source = PerceptionProxy.downsample(source, maxEdge: longEdge)
                reference = PerceptionProxy.downsample(reference, maxEdge: longEdge)
            }

            let sourceRel = "source/\(stem).png"
            let refRel = "reference/\(stem).png"
            try ImageWriter.write(source, to: outputDir.appendingPathComponent(sourceRel), format: .png)
            try ImageWriter.write(reference, to: outputDir.appendingPathComponent(refRel), format: .png)

            entries.append(CorpusManifest.Entry(
                id: stem,
                source: sourceRel,
                cameraJpeg: nil,
                references: [refRel],
                perception: "\(DegradationCorpus.perceptionDirName)/\(stem).json"
            ))
        }
        guard !entries.isEmpty else { throw Error.noPairs }

        let manifest = CorpusManifest(schemaVersion: 1, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: outputDir.appendingPathComponent("manifest.json"))
        return manifest
    }

    /// Find pairs under `root`: any image in a directory named `edited` (case-insensitive) whose
    /// filename stem matches a capture elsewhere in the same shoot.
    ///
    /// The convention is the photographer's, not ours — Lightroom exports land in an `edited/`
    /// subfolder beside the captures — so this discovers rather than imposes it, and a shoot that
    /// does not follow it simply yields nothing.
    /// A second camera's frames count: one real shoot pairs Sony ARWs and Canon CR2s from a second
    /// shooter, and both are captures the engine has to handle.
    public static func discover(root: URL, captureExtensions: Set<String> = ["arw", "raf", "nef",
                                                                            "cr2", "cr3", "dng"])
        -> [Pair] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        var editedDirs: [URL] = []
        for case let url as URL in walker {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir, url.lastPathComponent.lowercased().hasPrefix("edited") { editedDirs.append(url) }
        }

        var pairs: [Pair] = []
        for edited in editedDirs {
            let shoot = edited.deletingLastPathComponent()
            // Index the shoot's captures by stem once — a per-file search is quadratic and these
            // are folders of hundreds of frames on a possibly-remote volume (D15).
            var capturesByStem: [String: URL] = [:]
            if let inner = fm.enumerator(at: shoot, includingPropertiesForKeys: nil) {
                for case let url as URL in inner
                where captureExtensions.contains(url.pathExtension.lowercased()) {
                    capturesByStem[url.deletingPathExtension().lastPathComponent] = url
                }
            }
            let exports = (try? fm.contentsOfDirectory(at: edited, includingPropertiesForKeys: nil))
                ?? []
            for export in exports
            where ["jpg", "jpeg", "png", "tif", "tiff"].contains(export.pathExtension.lowercased()) {
                let stem = export.deletingPathExtension().lastPathComponent
                guard let capture = capturesByStem[stem] else { continue }
                // Shoot names are the photographer's and contain spaces and commas; entry ids become
                // filenames and get passed around shells and tools, so flatten them here rather than
                // leaving every consumer to quote correctly.
                let group = shoot.lastPathComponent
                    .replacingOccurrences(of: " ", with: "_")
                    .replacingOccurrences(of: ",", with: "")
                pairs.append(Pair(source: capture, reference: export, group: group))
            }
        }

        // ONE ENTRY PER CAPTURE. Exports nest — a real shoot had `Edited/` and, inside it,
        // `Edited Small/` holding a downscaled copy of the same frames, and both match the
        // `edited` prefix. Left alone that silently double-counts those frames in every mean the
        // corpus produces, which is the kind of error that makes a corpus look fine and read wrong.
        // The largest export wins, being the one closest to the photographer's full-size output.
        var best: [URL: (pair: Pair, size: Int)] = [:]
        for pair in pairs {
            let size = (try? pair.reference.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if let existing = best[pair.source], existing.size >= size { continue }
            best[pair.source] = (pair, size)
        }
        return best.values.map(\.pair).sorted { $0.source.path < $1.source.path }
    }
}
