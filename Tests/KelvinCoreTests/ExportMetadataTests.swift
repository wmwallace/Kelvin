import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import KelvinCore

/// What travels out of the app inside an exported file.
///
/// These tests exist because the answer was "more than anyone intended". `CIImage(contentsOf:)` fills
/// `properties` from the source file, the dictionary survives the whole filter chain, and
/// `writeJPEGRepresentation` encodes it again — so an export re-published the photograph's GPS fix
/// and the camera body's serial number, and a batch did it for every frame.
///
/// A privacy claim that is not measured is not a claim. Every assertion below reads the written file
/// back through ImageIO rather than trusting the policy that produced it.
final class ExportMetadataTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-export-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A photograph carrying the fields a real camera writes: where it was, which body took it, and
    /// the ordinary exposure facts that must survive an export.
    private func makeSourceFile() throws -> URL {
        let url = directory.appendingPathComponent("source.jpg")
        let image = TestSupport.makeGradientImage(width: 32, height: 32)
        let cg = try XCTUnwrap(ImageWriter.context.createCGImage(image, from: image.extent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [String: Any] = [
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 50.4123,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 4.1456,
                kCGImagePropertyGPSLongitudeRef as String: "W",
                kCGImagePropertyGPSAltitude as String: 123
            ],
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifBodySerialNumber as String: "SERIAL12345",
                kCGImagePropertyExifLensModel as String: "FE 55mm F1.8 ZA",
                kCGImagePropertyExifDateTimeOriginal as String: "2024:01:02 03:04:05",
                kCGImagePropertyExifISOSpeedRatings as String: [400]
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "SONY",
                kCGImagePropertyTIFFModel as String: "ILCE-7M4"
            ]
        ]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// A real edit, so the test proves the metadata survives (or does not) across the filter chain
    /// rather than across a copy.
    private var lifted: Recipe {
        var global = GlobalAdjustments.neutral
        global.exposureEV = 0.3
        return Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                      global: global, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    private func properties(of url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    /// The leak, pinned as a test. Not an aspiration — this documents that the default carries
    /// everything, so that changing the default is a deliberate act with a failing test attached
    /// rather than a silent behaviour change.
    func testTheDefaultCarriesTheSourcesMetadataThrough() throws {
        let source = try makeSourceFile()
        let edited = Renderer.render(try XCTUnwrap(CIImage(contentsOf: source)), with: lifted)
        let out = directory.appendingPathComponent("as-shot.jpg")
        try ImageWriter.write(edited, to: out)

        let written = try properties(of: out)
        XCTAssertNotNil(written[kCGImagePropertyGPSDictionary as String],
                        "the default is as-shot: the position travels")
    }

    /// The toggle, measured on the file that lands on disk.
    func testRemovingLocationTakesThePositionAndTheBodySerialOut() throws {
        let source = try makeSourceFile()
        let edited = Renderer.render(try XCTUnwrap(CIImage(contentsOf: source)), with: lifted)
        let out = directory.appendingPathComponent("scrubbed.jpg")
        try ImageWriter.write(edited, to: out, metadata: .withoutLocation)

        let written = try properties(of: out)
        XCTAssertNil(written[kCGImagePropertyGPSDictionary as String],
                     "no GPS dictionary at all — not an empty one")
        let exif = written[kCGImagePropertyExifDictionary as String] as? [String: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifBodySerialNumber as String],
                     "the body serial identifies every frame this camera ever exported")
    }

    /// Stripping the position must not strip the photography. A photographer exporting for a client
    /// wants the camera, the lens, the date and the exposure to survive — an export that arrives
    /// anonymous is less useful without being meaningfully more private.
    func testRemovingLocationKeepsTheCameraLensAndDate() throws {
        let source = try makeSourceFile()
        let edited = Renderer.render(try XCTUnwrap(CIImage(contentsOf: source)), with: lifted)
        let out = directory.appendingPathComponent("kept.jpg")
        try ImageWriter.write(edited, to: out, metadata: .withoutLocation)

        let written = try properties(of: out)
        let exif = written[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = written[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual(exif?[kCGImagePropertyExifLensModel as String] as? String, "FE 55mm F1.8 ZA")
        XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String,
                       "2024:01:02 03:04:05")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel as String] as? String, "ILCE-7M4")
    }

    /// PNG carries EXIF too — ImageIO writes an `eXIf` chunk — so the policy has to hold on both
    /// paths. A toggle that only worked for JPEG would be worse than none: it would be believed.
    func testThePolicyHoldsForPNGAsWellAsJPEG() throws {
        let source = try makeSourceFile()
        let edited = Renderer.render(try XCTUnwrap(CIImage(contentsOf: source)), with: lifted)
        let out = directory.appendingPathComponent("scrubbed.png")
        try ImageWriter.write(edited, to: out, format: .png, metadata: .withoutLocation)

        let written = try properties(of: out)
        XCTAssertNil(written[kCGImagePropertyGPSDictionary as String])
    }

    /// Scrubbing is metadata-only. It must not touch a single pixel — the whole point of doing it on
    /// `properties` instead of rewriting the file is that the encode happens exactly once.
    func testScrubbingChangesNoPixels() throws {
        let image = TestSupport.makeGradientImage(width: 24, height: 24)
        XCTAssertEqual(try ImageWriter.rgba8Bytes(ImageWriter.scrubbed(image)),
                       try ImageWriter.rgba8Bytes(image))
    }
}
