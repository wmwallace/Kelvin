import Foundation
import CoreImage

/// Batch apply (build-order step 8): propagate one already-chosen recipe across a folder of
/// images. This is the cheap step the app runs *after* a pick — no perception, no model, no
/// candidate generation, just decode → render → write per file.
///
/// Like `Eval/`, this module is allowed I/O; the pure `Render`/`Engine` layers are not. It
/// renders full resolution (this is the export-time path, not the interactive one) and never
/// writes over the originals — non-destructive, always (CLAUDE.md non-negotiable #3).
public enum BatchApply {

    /// A single file that could not be processed. Batch never aborts on one bad frame — a
    /// folder with one unreadable file should still get the other 99 rendered.
    public struct Failure: Sendable, Equatable {
        public var source: URL
        public var message: String
        public init(source: URL, message: String) { self.source = source; self.message = message }
    }

    public struct Outcome: Sendable {
        public var written: [URL]
        public var failures: [Failure]
        public var succeeded: Int { written.count }
        public var failed: Int { failures.count }
        public init(written: [URL], failures: [Failure]) { self.written = written; self.failures = failures }
    }

    /// Extensions we attempt to decode. Core Image handles the RAW and HEIF cases; anything
    /// else is skipped by `imageFiles(in:)` so a folder's sidecars and notes are ignored.
    ///
    /// Derived from `ImageDecoder.rawExtensions` rather than repeating it: the two lists had
    /// drifted, so a folder of Leica/Pentax/Hasselblad frames browsed as EMPTY even though the
    /// decoder opens them all. This list governs what the filmstrip and batch can see, so a
    /// format the decoder gained but this list missed was effectively unopenable.
    public static let imageExtensions: Set<String> =
        ImageDecoder.rawExtensions.union(["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"])

    /// Decodable image files directly inside `directory` (non-recursive), in stable path order.
    public static func imageFiles(in directory: URL) throws -> [URL] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        return entries
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }

    /// Render `recipe` over every URL in `inputs`, writing results into `outputDir` under the
    /// same basename. Processes in stable order, continues past failures and collects them.
    /// Output format defaults to PNG (lossless propagation regardless of source type).
    @discardableResult
    public static func run(
        inputs: [URL],
        recipe: Recipe,
        outputDir: URL,
        format: ImageWriter.Format = .png
    ) throws -> Outcome {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let ext: String
        switch format {
        case .png: ext = "png"
        case .jpeg: ext = "jpg"
        }

        var written: [URL] = []
        var failures: [Failure] = []
        for url in inputs.sorted(by: { $0.path < $1.path }) {
            do {
                let image = try ImageDecoder.decode(url: url)
                // Re-segment subject + sky per photo so the recipe's local masks land on *this*
                // frame's subject and sky, not the reference frame's — the masks adapt even when
                // the recipe parameters are propagated verbatim.
                let bitmaps = recipe.masks?.isEmpty == false
                    ? LocalMasks.measure(in: image).bitmaps : [:]
                let rendered = Renderer.render(image, with: recipe, maskBitmaps: bitmaps)
                let out = outputDir
                    .appendingPathComponent(url.deletingPathExtension().lastPathComponent)
                    .appendingPathExtension(ext)
                try ImageWriter.write(rendered, to: out, format: format)
                written.append(out)
            } catch {
                failures.append(Failure(source: url, message: "\(error)"))
            }
        }
        return Outcome(written: written, failures: failures)
    }

    /// Convenience: apply a recipe to every image directly inside `inputDir`.
    @discardableResult
    public static func run(
        inputDir: URL,
        recipe: Recipe,
        outputDir: URL,
        format: ImageWriter.Format = .png
    ) throws -> Outcome {
        try run(inputs: try imageFiles(in: inputDir), recipe: recipe,
                outputDir: outputDir, format: format)
    }
}
