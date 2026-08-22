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
}
