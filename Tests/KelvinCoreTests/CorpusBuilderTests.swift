import XCTest
@testable import KelvinCore

/// CorpusBuilder maps a dataset's parallel folders into the eval harness manifest. It matches
/// by basename, requires every expert to have an image, and threads optional perception labels
/// through. It works on filenames alone, so these tests use empty placeholder files.
final class CorpusBuilderTests: XCTestCase {

    private func makeTree(_ layout: [String: [String]]) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kelvin-corpus-\(UUID().uuidString)")
        for (dir, files) in layout {
            let d = root.appendingPathComponent(dir)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
            for f in files { try Data().write(to: d.appendingPathComponent(f)) }
        }
        return root
    }

    func testBuildsPPR10KStyleManifest() throws {
        let root = try makeTree([
            "source":   ["1.tif", "2.tif", "3.tif"],
            "target_a": ["1.tif", "2.tif", "3.tif"],
            "target_b": ["1.tif", "2.tif", "3.tif"],
            "target_c": ["1.tif", "2.tif", "3.tif"]
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try CorpusBuilder.build(root: root, options: .ppr10k)
        XCTAssertEqual(manifest.entries.count, 3)
        let first = manifest.entries[0]
        XCTAssertEqual(first.id, "1")
        XCTAssertEqual(first.source, "source/1.tif")
        XCTAssertEqual(first.references, ["target_a/1.tif", "target_b/1.tif", "target_c/1.tif"])
        XCTAssertNil(first.perception)
    }

    func testImagesMissingFromAnyExpertAreDropped() throws {
        let root = try makeTree([
            "source":   ["1.tif", "2.tif", "3.tif"],
            "target_a": ["1.tif", "2.tif", "3.tif"],
            "target_b": ["1.tif", "3.tif"],           // 2 missing here
            "target_c": ["1.tif", "2.tif", "3.tif"]
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try CorpusBuilder.build(root: root, options: .ppr10k)
        XCTAssertEqual(manifest.entries.map { $0.id }, ["1", "3"], "id 2 lacks an expert, must drop")
    }

    func testPerceptionAndCameraFoldersThreadThrough() throws {
        let root = try makeTree([
            "source":   ["a.png", "b.png"],
            "exp1":     ["a.png", "b.png"],
            "perc":     ["a.json"],          // only a is labelled
            "cam":      ["a.jpg", "b.jpg"]
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = try CorpusBuilder.build(root: root, options: CorpusBuilder.Options(
            sourceDir: "source", referenceDirs: ["exp1"],
            perceptionDir: "perc", cameraJpegDir: "cam"
        ))
        let a = manifest.entries.first { $0.id == "a" }!
        let b = manifest.entries.first { $0.id == "b" }!
        XCTAssertEqual(a.perception, "perc/a.json")
        XCTAssertEqual(a.cameraJpeg, "cam/a.jpg")
        XCTAssertNil(b.perception, "b has no label")
        XCTAssertEqual(b.cameraJpeg, "cam/b.jpg")
    }

    func testWriteProducesLoadableManifest() throws {
        let root = try makeTree([
            "source": ["1.png"], "target_a": ["1.png"], "target_b": ["1.png"], "target_c": ["1.png"]
        ])
        defer { try? FileManager.default.removeItem(at: root) }

        try CorpusBuilder.write(root: root, options: .ppr10k)
        // The eval harness's own loader must accept what we wrote.
        let corpus = try Corpus.load(root: root)
        XCTAssertEqual(corpus.manifest.entries.count, 1)
        XCTAssertEqual(corpus.manifest.entries[0].references.count, 3)
    }

    func testThrowsWhenSourceFolderMissing() throws {
        let root = try makeTree(["target_a": ["1.png"]])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try CorpusBuilder.build(root: root, options: .ppr10k))
    }

    func testThrowsWhenNothingMatches() throws {
        let root = try makeTree(["source": ["1.png"], "target_a": ["2.png"], "target_b": ["3.png"], "target_c": ["4.png"]])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try CorpusBuilder.build(root: root, options: .ppr10k)) { error in
            guard case CorpusBuilder.Error.noCompleteEntries = error else {
                return XCTFail("expected noCompleteEntries, got \(error)")
            }
        }
    }
}
