import XCTest
import CoreImage
@testable import KelvinCore

/// Milestone 8: batch apply. Propagating one recipe across a folder must be robust (one bad
/// file cannot sink the run), non-destructive (originals untouched), and faithful to the
/// no-op invariant per file.
final class BatchApplyTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func vividRecipe() -> Recipe {
        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.3
        g.contrast = 20
        g.vibrance = 15
        return Recipe(schemaVersion: 1, id: nil, label: "test", provenance: nil,
                      global: g, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    func testAppliesRecipeToEveryImageInFolder() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        for i in 0..<3 {
            try ImageWriter.write(TestSupport.makeGradientImage(width: 32, height: 32),
                                  to: inDir.appendingPathComponent("img\(i).png"), format: .png)
        }

        let outcome = try BatchApply.run(inputDir: inDir, recipe: vividRecipe(), outputDir: outDir)

        XCTAssertEqual(outcome.succeeded, 3)
        XCTAssertEqual(outcome.failed, 0)
        for url in outcome.written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNoThrow(try ImageDecoder.decode(url: url), "output must be a valid image")
        }
    }

    func testOriginalsAreUntouched() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        let src = inDir.appendingPathComponent("orig.png")
        try ImageWriter.write(TestSupport.makeGradientImage(width: 32, height: 32), to: src, format: .png)
        let before = try Data(contentsOf: src)

        _ = try BatchApply.run(inputDir: inDir, recipe: vividRecipe(), outputDir: outDir)

        XCTAssertEqual(try Data(contentsOf: src), before, "batch must never write over the original")
    }

    func testNeutralRecipeIsNoOpPerFile() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        let source = TestSupport.makeGradientImage(width: 48, height: 48)
        try ImageWriter.write(source, to: inDir.appendingPathComponent("a.png"), format: .png)

        let outcome = try BatchApply.run(inputDir: inDir, recipe: .neutral, outputDir: outDir)
        XCTAssertEqual(outcome.succeeded, 1)

        // A neutral recipe must render byte-identical output (the no-op invariant), file by file.
        let inBytes = try ImageWriter.rgba8Bytes(try ImageDecoder.decode(url: inDir.appendingPathComponent("a.png")))
        let outBytes = try ImageWriter.rgba8Bytes(try ImageDecoder.decode(url: outcome.written[0]))
        XCTAssertEqual(inBytes, outBytes)
    }

    func testNonImageFilesAreIgnored() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16),
                              to: inDir.appendingPathComponent("photo.png"), format: .png)
        try Data("not an image".utf8).write(to: inDir.appendingPathComponent("notes.txt"))
        try Data("{}".utf8).write(to: inDir.appendingPathComponent("recipe.json"))

        let images = try BatchApply.imageFiles(in: inDir)
        XCTAssertEqual(images.map { $0.lastPathComponent }, ["photo.png"])
    }

    func testBadFileIsCollectedNotThrown() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        let outDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: outDir) }

        try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16),
                              to: inDir.appendingPathComponent("good.png"), format: .png)
        // A file with an image extension but garbage contents.
        try Data("nope".utf8).write(to: inDir.appendingPathComponent("broken.png"))

        let outcome = try BatchApply.run(inputDir: inDir, recipe: vividRecipe(), outputDir: outDir)
        XCTAssertEqual(outcome.succeeded, 1, "the good file still renders")
        XCTAssertEqual(outcome.failed, 1, "the broken file is collected, not thrown")
        XCTAssertEqual(outcome.failures.first?.source.lastPathComponent, "broken.png")
    }

    func testDeterministicOrder() throws {
        let inDir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: inDir) }
        for name in ["c.png", "a.png", "b.png"] {
            try ImageWriter.write(TestSupport.makeGradientImage(width: 16, height: 16),
                                  to: inDir.appendingPathComponent(name), format: .png)
        }
        XCTAssertEqual(try BatchApply.imageFiles(in: inDir).map { $0.lastPathComponent },
                       ["a.png", "b.png", "c.png"])
    }
}
