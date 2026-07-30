import XCTest
import CoreImage
@testable import KelvinCore

final class EvalHarnessTests: XCTestCase {

    /// Build a tiny on-disk corpus (source + camera JPEG + two "expert" references + a
    /// manifest) in a temp dir, then run the whole harness end to end.
    func testEndToEndEvalOnGeneratedCorpus() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("kelvin-eval-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let source = TestSupport.makeGradientImage(width: 48, height: 48)

        // source + camera jpeg
        let sourceURL = root.appendingPathComponent("src.png")
        try ImageWriter.write(source, to: sourceURL, format: .png)
        let cameraURL = root.appendingPathComponent("cam.jpg")
        try ImageWriter.write(source, to: cameraURL, format: .jpeg(quality: 0.9))

        // two distinct "expert" references, made by rendering real recipes
        func recipe(exposure: Double, contrast: Double) -> Recipe {
            var g = GlobalAdjustments.neutral
            g.exposureEV = exposure
            g.contrast = contrast
            return Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                          global: g, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
        }
        let refAURL = root.appendingPathComponent("refA.png")
        let refBURL = root.appendingPathComponent("refB.png")
        try ImageWriter.write(Renderer.render(source, with: recipe(exposure: 0.4, contrast: 20)),
                              to: refAURL, format: .png)
        try ImageWriter.write(Renderer.render(source, with: recipe(exposure: -0.3, contrast: 10)),
                              to: refBURL, format: .png)

        let manifest = """
        {
          "schema_version": 1,
          "entries": [
            {
              "id": "img01",
              "source": "src.png",
              "camera_jpeg": "cam.jpg",
              "references": ["refA.png", "refB.png"]
            }
          ]
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))

        // Run.
        let corpus = try Corpus.load(root: root)
        let report = try Evaluator.run(corpus: corpus, engineVersion: "test")

        XCTAssertEqual(report.imageCount, 1)
        XCTAssertEqual(report.scoredImageCount, 1)

        // No-op fidelity must hold for every image.
        XCTAssertEqual(report.noOpFidelityPassed, report.noOpFidelityTotal)
        XCTAssertTrue(report.noOpFidelityOK)

        // All three baselines present and each scored against the references.
        let names = Set(report.methods.map { $0.method })
        XCTAssertTrue(names.isSuperset(of: ["camera-jpeg", "neutral", "naive-auto"]))
        for m in report.methods {
            XCTAssertEqual(m.scoredImages, 1, "\(m.method) should have a score")
            if let de = m.meanMinDeltaE {
                XCTAssertGreaterThanOrEqual(de, 0)
                XCTAssertTrue(de.isFinite)
            }
        }

        // The neutral baseline is literally the source, and refA/refB are edits of it, so
        // neutral's distance to the nearest reference must be > 0.
        let neutral = report.methods.first { $0.method == "neutral" }
        XCTAssertNotNil(neutral?.meanMinDeltaE)
        XCTAssertGreaterThan(neutral!.meanMinDeltaE!, 0)

        // The table renders without throwing and mentions the fidelity line.
        XCTAssertTrue(report.renderTable().contains("no-op fidelity"))
    }

    /// When an entry carries a perception JSON, the harness runs the engine and scores it as
    /// the `engine` method alongside the baselines.
    func testEngineMethodScoredWhenPerceptionPresent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("kelvin-eval-eng-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // A dim source so the engine has something real to correct.
        let source = TestSupport.makeSolidImage(r: 70, g: 68, b: 60, width: 48, height: 48)
        try ImageWriter.write(source, to: root.appendingPathComponent("src.png"), format: .png)

        // A realistic "expert" correction of a dim, flat frame: lift exposure, add moderate
        // contrast and a little colour — the shape of edit the engine aims for. (A pure
        // exposure bump would be an unfair target, penalising any fuller edit.)
        var expert = GlobalAdjustments.neutral
        expert.exposureEV = 0.85
        expert.contrast = 22
        expert.vibrance = 12
        let ref = Renderer.render(source, with: Recipe(
            schemaVersion: 1, id: nil, label: nil, provenance: nil,
            global: expert, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil))
        try ImageWriter.write(ref, to: root.appendingPathComponent("refA.png"), format: .png)

        let perception = """
        {
          "schema_version": 1,
          "scene": "landscape",
          "subject": { "present": false, "type": "none", "count": "none", "placement": "center" },
          "lighting": { "condition": "overcast", "direction": "diffuse", "contrast_range": "low" },
          "problems": ["underexposed-subject", "flat"],
          "intent": "natural",
          "confidence": 0.9
        }
        """
        try Data(perception.utf8).write(to: root.appendingPathComponent("p.json"))

        let manifest = """
        {
          "schema_version": 1,
          "entries": [
            {
              "id": "img01",
              "source": "src.png",
              "references": ["refA.png"],
              "perception": "p.json"
            }
          ]
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))

        let report = try Evaluator.run(corpus: try Corpus.load(root: root), engineVersion: "test")

        let engine = report.methods.first { $0.method == Evaluator.engineMethodName }
        XCTAssertNotNil(engine, "engine method should be present when perception is supplied")
        XCTAssertEqual(engine?.scoredImages, 1)
        XCTAssertNotNil(engine?.meanMinDeltaE)

        // The engine lifted a dim frame toward a brighter expert, so it should land closer to
        // that expert than the untouched neutral baseline does.
        let neutral = report.methods.first { $0.method == "neutral" }
        XCTAssertNotNil(neutral?.meanMinDeltaE)
        XCTAssertLessThan(engine!.meanMinDeltaE!, neutral!.meanMinDeltaE!,
                          "engine should beat the do-nothing baseline on this constructed case")

        // Best-of-candidates is scored too, and by construction picks the closest candidate to
        // an expert, so it is never worse than doing nothing.
        let best = report.methods.first { $0.method == Evaluator.engineBestMethodName }
        XCTAssertNotNil(best, "engine-best should be present when perception is supplied")
        XCTAssertNotNil(best?.meanMinDeltaE)
        XCTAssertLessThanOrEqual(best!.meanMinDeltaE!, neutral!.meanMinDeltaE!)

        XCTAssertTrue(report.noOpFidelityOK)
    }

    /// Build the same one-entry corpus as `testEngineMethodScoredWhenPerceptionPresent`, so the
    /// tests below can each ask a different question of one report.
    private func runCorpusWithPerception(problems: String = #"["underexposed-subject", "flat"]"#)
        throws -> EvalReport {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("kelvin-eval-shipped-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }

        // Bright sky over dark ground, so the engine has a real local decision to make and the
        // report is measuring something more than a global grade.
        let width = 120, height = 120
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: width * 4 * height)
        for y in 0..<height {
            let c: (UInt8, UInt8, UInt8) = y < height / 2 ? (150, 180, 230) : (44, 60, 40)
            for x in 0..<width {
                let i = y * width * 4 + x * 4
                bytes[i] = c.0; bytes[i+1] = c.1; bytes[i+2] = c.2; bytes[i+3] = 255
            }
        }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let source = CIImage(cgImage: ctx.makeImage()!)
        try ImageWriter.write(source, to: root.appendingPathComponent("src.png"), format: .png)
        try ImageWriter.write(source, to: root.appendingPathComponent("cam.jpg"),
                              format: .jpeg(quality: 0.9))

        var expert = GlobalAdjustments.neutral
        expert.exposureEV = 0.5
        expert.contrast = 18
        expert.vibrance = 10
        try ImageWriter.write(
            Renderer.render(source, with: Recipe(
                schemaVersion: 1, id: nil, label: nil, provenance: nil, global: expert,
                curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)),
            to: root.appendingPathComponent("refA.png"), format: .png)

        try Data("""
        {
          "schema_version": 1,
          "scene": "landscape",
          "subject": { "present": false, "type": "none", "count": "none", "placement": "center" },
          "lighting": { "condition": "harsh-sun", "direction": "diffuse", "contrast_range": "normal" },
          "problems": \(problems),
          "intent": "natural",
          "confidence": 0.9
        }
        """.utf8).write(to: root.appendingPathComponent("p.json"))

        try Data("""
        {
          "schema_version": 1,
          "entries": [
            {
              "id": "img01",
              "source": "src.png",
              "camera_jpeg": "cam.jpg",
              "references": ["refA.png"],
              "perception": "p.json"
            }
          ]
        }
        """.utf8).write(to: root.appendingPathComponent("manifest.json"))

        return try Evaluator.run(corpus: try Corpus.load(root: root), engineVersion: "test")
    }

    /// **The gap this harness had.** The corpus scored `RecipeEngine.recipe()` — which nothing in
    /// the app calls — and an oracle over the candidate set, and never the candidate a photographer
    /// opens on. So a single style could grow a look with the suite green, because no number in the
    /// report was a function of what that style does. Both are now rows.
    func testReportScoresTheCandidateAPhotographerOpensOn() throws {
        let report = try runCorpusWithPerception()
        let names = Set(report.methods.map(\.method))

        XCTAssertTrue(names.contains(Evaluator.engineDefaultMethodName),
                      "the opening candidate must be scored — it is what a user actually sees")

        // One row per style, so a taste change to one look moves a number of its own.
        for style in CandidateStyle.all {
            XCTAssertTrue(names.contains(Evaluator.methodName(forStyle: style.id)),
                          "\(style.id) has no row, so a drift in it would be invisible")
        }

        let dflt = try XCTUnwrap(report.methods.first { $0.method == Evaluator.engineDefaultMethodName })
        XCTAssertEqual(dflt.scoredImages, 1)
        XCTAssertNotNil(dflt.meanMinDeltaE)
    }

    /// The headline number has to *be* one of the styles, not a fourth thing computed alongside
    /// them. If `engine-default` and the row for the style the frame opened in ever disagree, the
    /// report and the curator have drifted apart — which is the failure mode that put a different
    /// recipe on the canvas than in the exported file.
    func testDefaultMatchesTheStyleTheFrameOpenedIn() throws {
        let report = try runCorpusWithPerception()
        let image = try XCTUnwrap(report.images.first)
        let openedIn = try XCTUnwrap(image.defaultStyle,
                                     "a frame with a perception label must record what it opens in")

        let dflt = try XCTUnwrap(image.methods.first { $0.method == Evaluator.engineDefaultMethodName })
        let style = try XCTUnwrap(image.methods.first {
            $0.method == Evaluator.methodName(forStyle: openedIn)
        })
        XCTAssertEqual(dflt.minDeltaE, style.minDeltaE,
                       "engine-default must be the same pixels as the style it resolved to")
        XCTAssertEqual(dflt.highlightClip, style.highlightClip, accuracy: 1e-9)
    }

    /// The curator's verdict is recorded per image, so a frame the engine has no good answer for
    /// can be told apart from one it answers badly.
    func testReportRecordsWhatThePickerOfferedAndDropped() throws {
        let report = try runCorpusWithPerception()
        let image = try XCTUnwrap(report.images.first)

        let curated = try XCTUnwrap(image.curatedStyles)
        let dropped = try XCTUnwrap(image.droppedStyles)
        XCTAssertFalse(curated.isEmpty)
        XCTAssertLessThanOrEqual(curated.count, 4)
        XCTAssertEqual(Set(curated).union(dropped), Set(CandidateStyle.all.map(\.id)),
                       "curated and dropped must partition the styles")
        XCTAssertTrue(curated.contains(try XCTUnwrap(image.defaultStyle)))

        // And the table says so, rather than leaving it in the JSON only.
        XCTAssertTrue(report.renderTable().contains("opened in:"))
    }

    /// `engine-best` is now taken over the CURATED set. A style the curator drops is one no
    /// photographer can pick, so scoring the ceiling over all eight flattered the engine with looks
    /// it refuses to offer. It must land on one of the shown candidates.
    func testBestIsTakenOverTheCuratedSetOnly() throws {
        let report = try runCorpusWithPerception()
        let image = try XCTUnwrap(report.images.first)
        let curated = try XCTUnwrap(image.curatedStyles)

        let best = try XCTUnwrap(image.methods.first { $0.method == Evaluator.engineBestMethodName })
        let bestDE = try XCTUnwrap(best.minDeltaE)

        // Its ΔE must equal some curated style's, and be no worse than the default's.
        let curatedDEs = curated.compactMap { id in
            image.methods.first { $0.method == Evaluator.methodName(forStyle: id) }?.minDeltaE
        }
        XCTAssertEqual(curatedDEs.count, curated.count)
        XCTAssertTrue(curatedDEs.contains { abs($0 - bestDE) < 1e-9 },
                      "engine-best must be one of the candidates the picker shows")
        let dflt = try XCTUnwrap(
            image.methods.first { $0.method == Evaluator.engineDefaultMethodName }?.minDeltaE)
        XCTAssertLessThanOrEqual(bestDE, dflt + 1e-9,
                                 "the ceiling cannot be worse than the candidate it contains")
    }

    /// No style may be named such that its row collides with `engine`, `engine-default` or
    /// `engine-best`. A collision would silently overwrite the headline number with a style's.
    func testStyleRowNamesDoNotCollideWithTheAggregateRows() {
        let reserved = Set([Evaluator.engineMethodName,
                            Evaluator.engineDefaultMethodName,
                            Evaluator.engineBestMethodName])
        for style in CandidateStyle.all {
            XCTAssertFalse(reserved.contains(Evaluator.methodName(forStyle: style.id)),
                           "style '\(style.id)' collides with an aggregate row name")
        }
        XCTAssertEqual(Set(CandidateStyle.all.map(\.id)).count, CandidateStyle.all.count,
                       "two styles sharing an id would share a row")
    }

    func testMissingManifestThrows() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-nope-\(UUID().uuidString)")
        XCTAssertThrowsError(try Corpus.load(root: empty))
    }
}
