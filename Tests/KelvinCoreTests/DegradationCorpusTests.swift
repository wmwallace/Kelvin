import XCTest
import CoreImage
@testable import KelvinCore

/// The commercial-clean corpus: good photos become references, degraded variants become
/// sources. Verifies the structure, that degradations actually alter the image, that the eval
/// harness accepts the result, and that a manifest pointing at not-yet-created perception labels
/// doesn't break eval (the engine is simply skipped until labels exist).
final class DegradationCorpusTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-degrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBuildsReferenceSourceAndManifest() throws {
        let good = try makeTempDir(); defer { try? FileManager.default.removeItem(at: good) }
        let out = try makeTempDir(); defer { try? FileManager.default.removeItem(at: out) }

        for n in ["a", "b"] {
            try ImageWriter.write(TestSupport.makeGradientImage(width: 48, height: 48),
                                  to: good.appendingPathComponent("\(n).png"), format: .png)
        }

        let manifest = try DegradationCorpus.build(
            goodPhotos: try BatchApply.imageFiles(in: good), outputDir: out)

        let degs = DegradationCorpus.standard.count
        XCTAssertEqual(manifest.entries.count, 2 * degs)
        // Every entry has exactly one reference and a pre-filled perception path.
        for entry in manifest.entries {
            XCTAssertEqual(entry.references.count, 1)
            XCTAssertTrue(entry.source.hasPrefix("source/"))
            XCTAssertTrue(entry.references[0].hasPrefix("reference/"))
            XCTAssertEqual(entry.perception, "perception/\(entry.id).json")
        }
        // Files exist on disk.
        XCTAssertEqual(try BatchApply.imageFiles(in: out.appendingPathComponent("reference")).count, 2)
        XCTAssertEqual(try BatchApply.imageFiles(in: out.appendingPathComponent("source")).count, 2 * degs)
    }

    func testDegradedSourceDiffersFromReference() throws {
        let good = try makeTempDir(); defer { try? FileManager.default.removeItem(at: good) }
        let out = try makeTempDir(); defer { try? FileManager.default.removeItem(at: out) }
        try ImageWriter.write(TestSupport.makeGradientImage(width: 48, height: 48),
                              to: good.appendingPathComponent("p.png"), format: .png)

        try DegradationCorpus.build(goodPhotos: try BatchApply.imageFiles(in: good), outputDir: out)

        let ref = try ImageMetrics.sample(try ImageDecoder.decode(
            url: out.appendingPathComponent("reference/p.png")))
        let under = try ImageMetrics.sample(try ImageDecoder.decode(
            url: out.appendingPathComponent("source/p__underexposed.png")))
        XCTAssertGreaterThan(ImageMetrics.meanDeltaE2000(ref, under), 5,
                             "an underexposed source must differ from its good reference")
    }

    /// The whole point: eval runs on the generated corpus, and a manifest that references
    /// perception labels which do not exist yet does NOT crash — the engine is skipped, the
    /// baselines are still scored.
    func testEvalRunsBeforeLabelsExist() throws {
        let good = try makeTempDir(); defer { try? FileManager.default.removeItem(at: good) }
        let out = try makeTempDir(); defer { try? FileManager.default.removeItem(at: out) }
        try ImageWriter.write(TestSupport.makeGradientImage(width: 40, height: 40),
                              to: good.appendingPathComponent("p.png"), format: .png)
        try DegradationCorpus.build(goodPhotos: try BatchApply.imageFiles(in: good), outputDir: out)

        let report = try Evaluator.run(corpus: try Corpus.load(root: out), engineVersion: "test")
        XCTAssertEqual(report.imageCount, DegradationCorpus.standard.count)
        XCTAssertTrue(report.noOpFidelityOK)
        // Baselines scored; engine absent because no labels yet.
        let names = Set(report.methods.map { $0.method })
        XCTAssertTrue(names.contains("neutral"))
        XCTAssertFalse(names.contains(Evaluator.engineMethodName), "engine needs labels, skipped here")
    }
}
