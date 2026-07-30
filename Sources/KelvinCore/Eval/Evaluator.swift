import Foundation
import CoreImage

/// Runs the corpus, scores every method per image, and aggregates into an `EvalReport`.
/// Deterministic and headless (software rendering) so it can run on every commit.
public enum Evaluator {

    /// The single-recipe path: `RecipeEngine.recipe()`.
    ///
    /// ⚠️ **Nothing in the app calls this.** It is kept scored because the `kelvin-cli engine`
    /// command produces it and because the flat-degradation over-correction is diagnosed on it —
    /// but it is not what a photographer sees, and for a long time it was the only engine number
    /// the corpus had. Read `engine-default` for that.
    public static let engineMethodName = "engine"

    /// **What a photographer actually opens on** — the candidate `CandidateCurator` resolves to,
    /// rendered the way export renders it. The headline number: it is the only method here whose
    /// quality is unconditionally somebody's experience of the app, and the only one that falls
    /// when a single style drifts.
    public static let engineDefaultMethodName = "engine-default"

    /// The best of the **curated** set (min ΔE to any expert). The product's other real question:
    /// not "is our first guess good," but "did the picker contain a good option?" — the same
    /// min-across-experts logic applied across candidates.
    ///
    /// ⚠️ This is an **oracle**: it chooses with the reference in hand, so it can never regress
    /// when one style goes wrong — another style covers for it. That is what let Natural grow a
    /// look against a green suite. Never read it as a quality gate on its own; it is a ceiling,
    /// and `engine-default` is the floor. It is now taken over the curated set rather than all
    /// eight styles, because a style the curator drops is one no photographer can pick.
    public static let engineBestMethodName = "engine-best"

    /// Per-style row name, e.g. `engine-natural`. One row per `CandidateStyle`, so a taste change
    /// to one look moves a number instead of hiding inside an aggregate.
    public static func methodName(forStyle id: String) -> String { "engine-" + id }

    public static func run(corpus: Corpus, engineVersion: String) throws -> EvalReport {
        let start = Date()

        var imageResults: [ImageResult] = []
        var noOpPass = 0
        var noOpTotal = 0
        var scoredCount = 0

        for entry in corpus.manifest.entries {
            let source = try ImageDecoder.decode(url: corpus.sourceURL(for: entry))

            // Reference expert edits, sampled to the metric grid.
            let refSamples = try corpus.referenceURLs(for: entry).map {
                try ImageMetrics.sample(try ImageDecoder.decode(url: $0))
            }
            let hasRefs = !refSamples.isEmpty
            if hasRefs { scoredCount += 1 }

            let refMedianChroma = medianChroma(refSamples.map { ImageMetrics.meanChroma($0) })

            var scores: [MethodImageScore] = []
            func score(_ name: String, _ image: CIImage) throws {
                let s = try ImageMetrics.sample(image)
                let clip = ImageMetrics.clipping(s)
                let minDE = hasRefs ? refSamples.map { ImageMetrics.meanDeltaE2000(s, $0) }.min() : nil
                var wb: Double? = nil
                if let med = refMedianChroma {
                    let c = ImageMetrics.meanChroma(s)
                    wb = ((c.a - med.a) * (c.a - med.a) + (c.b - med.b) * (c.b - med.b)).squareRoot()
                }
                scores.append(MethodImageScore(
                    method: name, minDeltaE: minDE,
                    highlightClip: clip.highlights, shadowClip: clip.shadows, wbError: wb
                ))
            }

            if let camURL = corpus.cameraJpegURL(for: entry) {
                try score(Baselines.Kind.cameraJPEG.rawValue, try ImageDecoder.decode(url: camURL))
            }
            let neutralImage = Baselines.neutral(source)
            try score(Baselines.Kind.neutral.rawValue, neutralImage)
            try score(Baselines.Kind.naiveAuto.rawValue, try Baselines.naiveAuto(source))

            // The engine — the thing under test — is scored only when the entry carries a
            // hand-labelled perception JSON, so it sees exactly what it will see in production:
            // judgments plus a histogram. A manifest may reference labels that haven't been
            // generated yet (e.g. a degradation corpus written before `kelvin-perceive label`
            // runs), so a missing file skips the engine rather than failing the whole eval.
            var defaultStyle: String?
            var curatedStyles: [String]?
            var droppedStyles: [String]?
            var culledStyles: [String]?
            if let perceptionURL = corpus.perceptionURL(for: entry),
               FileManager.default.fileExists(atPath: perceptionURL.path) {
                let perception = try PerceptionIO.load(from: perceptionURL)
                let sourceURL = corpus.sourceURL(for: entry)
                let iso = ExifReader.iso(url: sourceURL)

                // Generate and curate exactly as the app does — on the perception proxy, with the
                // mask measurements the engine's local decisions need. See `ShippedCandidates`
                // for what scoring this path without them used to hide.
                let composed = try ShippedCandidates.compose(
                    for: source, perception: perception, iso: iso
                )

                // Score the DELIVERED pixels: masks measured at the frame's own resolution and the
                // recipe rendered there, which is what export writes to disk. Masks are measured
                // once and reused — measuring does not depend on the recipe and it is the expensive
                // half (2.7 s on a 60 MP frame).
                let fullMasks = LocalMasks.measure(in: source).bitmaps
                func delivered(_ recipe: Recipe) -> CIImage {
                    ShippedCandidates.deliver(recipe, on: source, masks: fullMasks)
                }

                // Rendered ONCE per style and reused by the three engine rows below, which all
                // describe the same eight images. Rendering per row instead cost fourteen renders
                // an entry against nine, on the harness that is supposed to run per commit.
                var deliveredByStyle: [String: CIImage] = [:]
                for candidate in composed.all {
                    deliveredByStyle[candidate.styleID] = delivered(candidate.recipe)
                }

                // The single-recipe path, given the same local inputs the candidates get, so its
                // number describes the engine rather than a fiction. Nothing in the app calls it —
                // see `engineMethodName`.
                let single = RecipeEngine.recipe(
                    perception: perception,
                    statistics: composed.statistics,
                    subjectLuma: composed.masks.subjectLuma,
                    skyLuma: composed.masks.skyLuma,
                    subjectOrigin: composed.masks.subjectOrigin,
                    iso: iso
                )
                try score(Evaluator.engineMethodName, delivered(single))

                // What a photographer opens on. This is the number that moves when a style drifts.
                if let chosen = composed.chosen, let id = chosen.recipe.id,
                   let image = deliveredByStyle[id] {
                    defaultStyle = id
                    try score(Evaluator.engineDefaultMethodName, image)
                }

                // Best of the curated set — the ceiling, and an oracle. With references, the
                // candidate closest to any expert; without, the default, since there is no basis
                // to choose. See `engineBestMethodName` for why this is never a gate on its own.
                var best = defaultStyle
                if hasRefs {
                    var bestDE = Double.greatestFiniteMagnitude
                    for id in composed.curatedStyleIDs {
                        guard let image = deliveredByStyle[id] else { continue }
                        let s = try ImageMetrics.sample(image)
                        let de = refSamples.map { ImageMetrics.meanDeltaE2000(s, $0) }.min()
                            ?? .greatestFiniteMagnitude
                        if de < bestDE { bestDE = de; best = id }
                    }
                }
                if let best, let image = deliveredByStyle[best] {
                    try score(Evaluator.engineBestMethodName, image)
                }

                // One row per style, so a taste change to one look is visible on its own. An
                // aggregate cannot show this: Natural drifted while `engine-best` stayed flat,
                // because another style covered for it.
                for candidate in composed.all {
                    guard let image = deliveredByStyle[candidate.styleID] else { continue }
                    try score(Evaluator.methodName(forStyle: candidate.styleID), image)
                }

                // What the picker offered, what it left out, and — the one that is a verdict — what
                // it culled for a real craft defect. A ΔE alone cannot tell "the engine has no good
                // answer for this frame" apart from "the engine's answer is bad".
                curatedStyles = composed.curatedStyleIDs
                droppedStyles = composed.droppedStyleIDs
                culledStyles = composed.culledStyleIDs
            }

            // No-op fidelity is a full-resolution byte comparison, not a sampled one.
            noOpTotal += 1
            let noOp = try ImageWriter.rgba8Bytes(source) == ImageWriter.rgba8Bytes(neutralImage)
            if noOp { noOpPass += 1 }

            imageResults.append(ImageResult(
                id: entry.id, hasReferences: hasRefs, noOpFidelity: noOp, methods: scores,
                defaultStyle: defaultStyle, curatedStyles: curatedStyles,
                droppedStyles: droppedStyles, culledStyles: culledStyles
            ))
        }

        let methodNames = orderedMethodNames(imageResults)
        let summaries = methodNames.map { summarize($0, across: imageResults) }

        return EvalReport(
            engineVersion: engineVersion,
            generatedAt: iso8601(start),
            sampleEdge: ImageMetrics.sampleEdge,
            imageCount: corpus.manifest.entries.count,
            scoredImageCount: scoredCount,
            noOpFidelityPassed: noOpPass,
            noOpFidelityTotal: noOpTotal,
            wallClockSeconds: Date().timeIntervalSince(start),
            methods: summaries,
            images: imageResults
        )
    }

    // MARK: - Aggregation

    private static func summarize(_ name: String, across images: [ImageResult]) -> MethodSummary {
        var minDEs: [Double] = []
        var winCamNum = 0, winCamDen = 0
        var winNaiveNum = 0, winNaiveDen = 0
        var hiReg = 0

        let cameraName = Baselines.Kind.cameraJPEG.rawValue
        let naiveName = Baselines.Kind.naiveAuto.rawValue

        for img in images {
            guard let ms = img.methods.first(where: { $0.method == name }) else { continue }
            if let de = ms.minDeltaE { minDEs.append(de) }

            if let cam = img.methods.first(where: { $0.method == cameraName }) {
                if name != cameraName, let de = ms.minDeltaE, let camDE = cam.minDeltaE {
                    winCamDen += 1
                    if de < camDE { winCamNum += 1 }
                }
                if ms.highlightClip > cam.highlightClip + 1e-4 { hiReg += 1 }
            }
            if let naive = img.methods.first(where: { $0.method == naiveName }) {
                if name != naiveName, let de = ms.minDeltaE, let nDE = naive.minDeltaE {
                    winNaiveDen += 1
                    if de < nDE { winNaiveNum += 1 }
                }
            }
        }

        return MethodSummary(
            method: name,
            scoredImages: minDEs.count,
            meanMinDeltaE: minDEs.isEmpty ? nil : minDEs.reduce(0, +) / Double(minDEs.count),
            medianMinDeltaE: median(minDEs),
            winVsCameraFraction: winCamDen == 0 ? nil : Double(winCamNum) / Double(winCamDen),
            winVsNaiveFraction: winNaiveDen == 0 ? nil : Double(winNaiveNum) / Double(winNaiveDen),
            highlightRegressions: hiReg
        )
    }

    /// Preserve a stable, meaningful method order: camera-jpeg, neutral, naive-auto, then
    /// anything added later (e.g. the engine and its candidates).
    private static func orderedMethodNames(_ images: [ImageResult]) -> [String] {
        let preferred = Baselines.Kind.allCases.map { $0.rawValue }
        var seen = Set<String>()
        var ordered: [String] = []
        for name in preferred where images.contains(where: { $0.methods.contains { $0.method == name } }) {
            if seen.insert(name).inserted { ordered.append(name) }
        }
        for img in images {
            for ms in img.methods where seen.insert(ms.method).inserted {
                ordered.append(ms.method)
            }
        }
        return ordered
    }

    // MARK: - Small helpers

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    private static func medianChroma(_ chromas: [(a: Double, b: Double)]) -> (a: Double, b: Double)? {
        guard let a = median(chromas.map { $0.a }),
              let b = median(chromas.map { $0.b }) else { return nil }
        return (a, b)
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }
}
