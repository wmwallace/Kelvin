import Foundation
import CoreImage

/// Batch apply (build-order step 8): propagate one already-chosen recipe across a folder of
/// images. This is the cheap step the app runs *after* a pick — no perception, no model, no
/// candidate generation, just decode → render → write per file.
///
/// Like `Eval/`, this module is allowed I/O; the pure `Render`/`Engine` layers are not. It
/// renders full resolution (this is the export-time path, not the interactive one) and never
/// writes over the originals — non-destructive, always (CLAUDE.md non-negotiable #3). The rules
/// that make that true — where output goes, what happens to a name that already exists, and the
/// refusal to write into the source folder — live in `BatchApply.Destination`.
public enum BatchApply {

    /// A single file that could not be processed. Batch never aborts on one bad frame — a
    /// folder with one unreadable file should still get the other 99 rendered.
    public struct Failure: Sendable, Equatable {
        public var source: URL
        public var message: String
        public init(source: URL, message: String) { self.source = source; self.message = message }
    }

    /// What happened, file by file.
    ///
    /// This used to be two flat lists, which meant a partial run could only be reported as
    /// "37 succeeded, 3 failed" — the user could see that something went wrong but not *what*,
    /// and a file that was quietly skipped looked exactly like a file that was written. A batch
    /// that ran overnight has to be able to answer "which frames do I still need?", so the
    /// per-file record is the stored form and the counts are derived from it.
    public struct Outcome: Sendable {

        public enum Result: Sendable, Equatable {
            /// Rendered and written to this URL.
            case written(URL)
            /// Not rendered: a file of that name was already in the destination and the collision
            /// policy said to leave it alone. The existing file is named so a UI can point at it.
            case skipped(existing: URL)
            /// Rendered or decoded and threw. The rest of the batch continued.
            case failed(String)
        }

        public struct Item: Sendable, Equatable {
            public var source: URL
            public var result: Result
            public init(source: URL, result: Result) { self.source = source; self.result = result }

            public static func written(source: URL, to output: URL) -> Item {
                Item(source: source, result: .written(output))
            }
            public static func skipped(source: URL, existing: URL) -> Item {
                Item(source: source, result: .skipped(existing: existing))
            }
            public static func failed(source: URL, message: String) -> Item {
                Item(source: source, result: .failed(message))
            }
        }

        /// One entry per input, in the order the batch processed them.
        public var items: [Item]

        public init(items: [Item]) { self.items = items }

        /// Compatibility shim for callers that assemble an outcome from their own render loop
        /// (the app's adaptive batch re-perceives every frame, so it cannot use `run` directly).
        /// It cannot recover which source produced which output, so written items carry the
        /// output URL as their source; prefer building `items` directly.
        public init(written: [URL], failures: [Failure]) {
            self.items = written.map { Item(source: $0, result: .written($0)) }
                + failures.map { Item(source: $0.source, result: .failed($0.message)) }
        }

        public var written: [URL] {
            items.compactMap { if case .written(let url) = $0.result { return url } else { return nil } }
        }
        public var skipped: [URL] {
            items.compactMap { if case .skipped = $0.result { return $0.source } else { return nil } }
        }
        public var failures: [Failure] {
            items.compactMap {
                if case .failed(let message) = $0.result {
                    return Failure(source: $0.source, message: message)
                } else { return nil }
            }
        }

        public var succeeded: Int { written.count }
        public var failed: Int { failures.count }
        public var skippedCount: Int { skipped.count }
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

    /// Render `recipe` over every URL in `inputs`, writing edited copies into `destination`.
    /// Processes in stable order, continues past failures and collects them.
    ///
    /// `look` labels the output filenames; it defaults to the recipe's own label, which is what
    /// the user picked ("Natural", "Warm portrait") and therefore the one word that distinguishes
    /// two batches of the same shoot.
    @discardableResult
    public static func run(
        inputs: [URL],
        recipe: Recipe,
        destination: Destination,
        look: String? = nil
    ) throws -> Outcome {
        let ordered = inputs.sorted { $0.path < $1.path }
        // Throws before any pixel is written: a destination that could clobber originals is a
        // refusal, not a per-file failure.
        try destination.prepare(sources: ordered)

        // Belt and braces behind the destination guard. `prepare` compares folders, and a folder
        // comparison is only as good as what the filesystem will tell us about paths; this
        // compares the actual bytes-about-to-be-written path against the actual inputs. It should
        // be unreachable, and it is the last thing standing between a bug here and a lost original.
        let inputPaths = Set(ordered.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })

        var items: [Outcome.Item] = []
        for url in ordered {
            switch destination.plan(for: url, look: look ?? recipe.label) {
            case .skip(let existing):
                items.append(.skipped(source: url, existing: existing))
            case .write(let out):
                guard !inputPaths.contains(out.resolvingSymlinksInPath().standardizedFileURL.path) else {
                    items.append(.failed(source: url,
                                         message: "refusing to write over a source file at \(out.path)"))
                    continue
                }
                do {
                    let image = try ImageDecoder.decode(url: url)
                    // Re-segment subject + sky per photo so the recipe's local masks land on *this*
                    // frame's subject and sky, not the reference frame's — the masks adapt even when
                    // the recipe parameters are propagated verbatim.
                    let bitmaps = recipe.masks?.isEmpty == false
                        ? LocalMasks.measure(in: image).bitmaps : [:]
                    let rendered = Renderer.render(image, with: recipe, maskBitmaps: bitmaps)
                    try ImageWriter.write(rendered, to: out, format: destination.format,
                                          metadata: destination.metadata)
                    items.append(.written(source: url, to: out))
                } catch {
                    items.append(.failed(source: url, message: "\(error)"))
                }
            }
        }
        return Outcome(items: items)
    }

    /// Convenience: apply a recipe to every image directly inside `inputDir`.
    @discardableResult
    public static func run(
        inputDir: URL,
        recipe: Recipe,
        destination: Destination,
        look: String? = nil
    ) throws -> Outcome {
        try run(inputs: try imageFiles(in: inputDir), recipe: recipe,
                destination: destination, look: look)
    }

    /// Convenience for callers that only have a folder and a format. Output format defaults to
    /// PNG (lossless propagation regardless of source type) and collisions get a unique suffix.
    @discardableResult
    public static func run(
        inputs: [URL],
        recipe: Recipe,
        outputDir: URL,
        format: ImageWriter.Format = .png,
        onCollision: Destination.OnCollision = .uniqueSuffix
    ) throws -> Outcome {
        try run(inputs: inputs, recipe: recipe,
                destination: Destination(directory: outputDir, onCollision: onCollision, format: format))
    }

    @discardableResult
    public static func run(
        inputDir: URL,
        recipe: Recipe,
        outputDir: URL,
        format: ImageWriter.Format = .png,
        onCollision: Destination.OnCollision = .uniqueSuffix
    ) throws -> Outcome {
        try run(inputs: try imageFiles(in: inputDir), recipe: recipe,
                outputDir: outputDir, format: format, onCollision: onCollision)
    }
}
