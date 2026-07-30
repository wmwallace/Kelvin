import XCTest
import CoreImage
@testable import KelvinCore

/// `PairedCorpus` — the corpus whose reference is the photographer's own edit of the same RAW.
///
/// Two things in here can silently produce a corpus that looks fine and reads wrong, and both are
/// tested because neither would show up as a failure anywhere downstream: a **cropped** export
/// scored as though it framed the same scene, and the **same frame counted twice** because exports
/// nest.
final class PairedCorpusTests: XCTestCase {

    // MARK: - A crop is not a pair

    func testOrientationIsNotACrop() {
        // A portrait export of a landscape-sensor frame: the same pixels, rotated. Comparing
        // width-to-height would call this a crop and throw away most of a real shoot — 31 of 67
        // pairs on the first run, which is how this was found.
        XCTAssertTrue(PairedCorpus.aspectsAgree((9504, 6336), (6336, 9504)),
                      "a rotated export frames the same scene and must be kept")
        XCTAssertTrue(PairedCorpus.aspectsAgree((9504, 6336), (9504, 6336)))
    }

    func testARealCropIsRejected() {
        // Measured from the shoot this was built on: these are the exports Lightroom actually
        // cropped, and each has to be dropped rather than scored.
        for cropped in [(6434, 4747), (8165, 5085), (5671, 3573), (5330, 6336), (5851, 6336)] {
            XCTAssertFalse(PairedCorpus.aspectsAgree((9504, 6336), cropped),
                           "\(cropped) is a crop of a 3:2 frame — a per-pixel ΔE would measure the "
                           + "crop rather than the edit")
        }
    }

    func testASlightResampleIsStillTheSameFraming() {
        // An export is not always an exact integer multiple of the sensor; a fraction of a percent
        // is rounding, not a crop.
        XCTAssertTrue(PairedCorpus.aspectsAgree((9504, 6336), (3000, 2000)))
        XCTAssertTrue(PairedCorpus.aspectsAgree((9504, 6336), (2999, 2000)))
    }

    func testDegenerateDimensionsAreRejectedRatherThanCrashing() {
        XCTAssertFalse(PairedCorpus.aspectsAgree((9504, 6336), (0, 0)))
        XCTAssertFalse(PairedCorpus.aspectsAgree((0, 0), (9504, 6336)))
    }

    // MARK: - One entry per capture

    /// **Exports nest.** The shoot this was built from has `Edited/` and, inside it,
    /// `Edited Small/` holding downscaled copies of the same frames — and both match the `edited`
    /// prefix. Counted twice, those frames get double the weight in every mean the corpus produces.
    func testNestedExportFoldersDoNotDoubleCountAFrame() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-paired-\(UUID().uuidString)")
        let shoot = root.appendingPathComponent("2026-01-01 Shoot")
        let edited = shoot.appendingPathComponent("Edited")
        let small = edited.appendingPathComponent("Edited Small")
        try FileManager.default.createDirectory(at: small, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The capture, plus a full-size export and a smaller copy of the same frame.
        try Data("raw".utf8).write(to: shoot.appendingPathComponent("_DSC0001.ARW"))
        try Data(repeating: 0, count: 5000)
            .write(to: edited.appendingPathComponent("_DSC0001.jpg"))
        try Data(repeating: 0, count: 500)
            .write(to: small.appendingPathComponent("_DSC0001.jpg"))

        let pairs = PairedCorpus.discover(root: root)
        XCTAssertEqual(pairs.count, 1, "one capture must yield exactly one pair, not one per export")
        XCTAssertEqual(pairs.first?.reference.deletingLastPathComponent().lastPathComponent,
                       "Edited",
                       "the largest export wins — it is closest to the photographer's full-size output")
    }

    func testAnExportWithNoCaptureIsNotAPair() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-paired-\(UUID().uuidString)")
        let edited = root.appendingPathComponent("Shoot/Edited")
        try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0, count: 10).write(to: edited.appendingPathComponent("_DSC9999.jpg"))
        XCTAssertTrue(PairedCorpus.discover(root: root).isEmpty,
                      "an export whose capture is gone cannot be scored against anything")
    }

    /// A second camera's frames count. One real shoot pairs Sony ARWs with Canon CR2s from a second
    /// shooter, and dropping those would have lost 13 of 53 wedding entries.
    func testASecondCamerasRawIsAlsoACapture() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-paired-\(UUID().uuidString)")
        let shoot = root.appendingPathComponent("Wedding")
        let second = shoot.appendingPathComponent("RJ Cam")
        let edited = shoot.appendingPathComponent("Edited")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("raw".utf8).write(to: second.appendingPathComponent("IMG_2271.CR2"))
        try Data(repeating: 0, count: 10).write(to: edited.appendingPathComponent("IMG_2271.jpg"))

        let pairs = PairedCorpus.discover(root: root)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.source.pathExtension, "CR2")
    }

    /// Entry ids become filenames and get passed through shells and tools. The photographer's own
    /// folder names carry spaces and commas.
    func testShootNamesAreFlattenedForUseAsIdentifiers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-paired-\(UUID().uuidString)")
        let shoot = root.appendingPathComponent("2026-04-27 Cannon Beach, OR")
        let edited = shoot.appendingPathComponent("Edited")
        try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("raw".utf8).write(to: shoot.appendingPathComponent("_DSC0001.ARW"))
        try Data(repeating: 0, count: 10).write(to: edited.appendingPathComponent("_DSC0001.jpg"))

        let group = PairedCorpus.discover(root: root).first?.group
        XCTAssertEqual(group, "2026-04-27_Cannon_Beach_OR")
        XCTAssertFalse(group?.contains(" ") ?? true)
        XCTAssertFalse(group?.contains(",") ?? true)
    }
}
