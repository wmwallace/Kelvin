import XCTest
import CoreImage
@testable import KelvinCore

/// An exported file is whole or it is not there. `ImageWriter` encodes into a hidden sibling and
/// renames into place, so a quit, a crash or a stopped export mid-encode can never leave a
/// truncated image under the real name — the thing every viewer opens as "a photo", half grey.
/// These pin the contract from the outside: what is on disk afterwards, and what is not.
final class ImageWriterAtomicTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-atomic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var image: CIImage {
        CIImage(color: CIColor(red: 0.5, green: 0.4, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48))
    }

    private func listing() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// A first write lands under the real name and leaves no sibling behind.
    func testAWriteLeavesExactlyTheNamedFile() throws {
        let out = directory.appendingPathComponent("frame.jpg")
        try ImageWriter.write(image, to: out, format: .jpeg(quality: 0.9))
        XCTAssertEqual(try listing(), ["frame.jpg"], "the partial must be renamed away, not left beside the file")
        XCTAssertNotNil(CIImage(contentsOf: out), "the file under the real name decodes")
    }

    /// A second write over the same name replaces it in one step — no window with no file, and
    /// still no sibling afterwards.
    func testAWriteOverAnExistingFileReplacesItWithoutLeavings() throws {
        let out = directory.appendingPathComponent("frame.jpg")
        try ImageWriter.write(image, to: out, format: .jpeg(quality: 0.9))
        let first = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
        try ImageWriter.write(image, to: out, format: .jpeg(quality: 0.3))
        let second = try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int
        XCTAssertEqual(try listing(), ["frame.jpg"])
        XCTAssertNotEqual(first, second, "the second write's bytes are the ones on disk")
    }

    /// Every format goes through the same door.
    func testPNGAndTIFFAndHEICAreAtomicToo() throws {
        for (name, format) in [("a.png", ImageWriter.Format.png), ("b.tif", .tiff16), ("c.heic", .heic(quality: 0.8))] {
            try ImageWriter.write(image, to: directory.appendingPathComponent(name), format: format)
        }
        XCTAssertEqual(try listing(), ["a.png", "b.tif", "c.heic"])
    }

    /// What a write cut off before its rename leaves behind is a hidden `.name.partial-UUID`, and
    /// the next export into the folder sweeps those up — but ONLY those: the pattern must be
    /// exact (a UUID, not any suffix), the file must be old enough that it cannot be a write in
    /// progress beside us, and nothing else in the folder is touched.
    func testStalePartialsAreSweptAndNothingElseIs() throws {
        let fm = FileManager.default
        func touch(_ name: String, age: TimeInterval) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data([1, 2, 3]).write(to: url)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
            return url
        }
        let stale = try touch(".photo.jpg.partial-\(UUID().uuidString)", age: 600)
        let fresh = try touch(".photo.jpg.partial-\(UUID().uuidString)", age: 5)
        let realName = try touch("photo.jpg", age: 600)
        let lookalike = try touch(".photo.jpg.partial-not-a-uuid", age: 600)
        let visible = try touch("photo.jpg.partial-\(UUID().uuidString)", age: 600)

        let removed = ImageWriter.removeStalePartials(in: directory, olderThan: 60)

        XCTAssertEqual(removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "the old partial is the one thing swept")
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "a partial young enough to be in progress stays")
        XCTAssertTrue(fm.fileExists(atPath: realName.path))
        XCTAssertTrue(fm.fileExists(atPath: lookalike.path), "a malformed suffix is not ours")
        XCTAssertTrue(fm.fileExists(atPath: visible.path), "a visible file is never ours")
    }

    /// The writer's own temp name round-trips through the recogniser, so the two cannot drift.
    func testTheWriterRecognisesItsOwnPartialName() {
        let partial = ImageWriter.partialURL(for: directory.appendingPathComponent("_DSC0458_soft.jpg"))
        XCTAssertTrue(ImageWriter.isPartial(partial))
        XCTAssertFalse(ImageWriter.isPartial(directory.appendingPathComponent("_DSC0458_soft.jpg")))
    }
}
