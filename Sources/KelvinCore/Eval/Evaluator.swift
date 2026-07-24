import Foundation
import CoreImage

/// Runs the corpus, scores every method per image, and aggregates into an `EvalReport`.
/// Deterministic and headless (software rendering) so it can run on every commit.
public enum Evaluator {

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

            // No-op fidelity is a full-resolution byte comparison, not a sampled one.
            noOpTotal += 1
            let noOp = try ImageWriter.rgba8Bytes(source) == ImageWriter.rgba8Bytes(neutralImage)
            if noOp { noOpPass += 1 }

            imageResults.append(ImageResult(
                id: entry.id, hasReferences: hasRefs, noOpFidelity: noOp, methods: scores
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
        guard !chromas.isEmpty else { return nil }
        let a = median(chromas.map { $0.a })!
        let b = median(chromas.map { $0.b })!
        return (a, b)
    }

    private static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: date)
    }
}
