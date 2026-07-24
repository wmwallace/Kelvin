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
        XCTAssertTrue(report.noOpFidelityOK)
    }

    func testMissingManifestThrows() {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-nope-\(UUID().uuidString)")
        XCTAssertThrowsError(try Corpus.load(root: empty))
    }
}
