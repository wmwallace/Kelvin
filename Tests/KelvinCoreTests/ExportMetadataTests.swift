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
            ],
            // The AUX spellings differ from the EXIF ones — that difference is the leak an audit
            // caught, so the fixture carries both, the way a Canon body does.
            kCGImagePropertyExifAuxDictionary as String: [
                kCGImagePropertyExifAuxSerialNumber as String: "AUXSERIAL999",
                kCGImagePropertyExifAuxOwnerName as String: "W. Wallace",
                kCGImagePropertyExifAuxLensModel as String: "RF 24-70mm"
            ],
            // Place names with no GPS at all is exactly how a Lightroom export can arrive.
            kCGImagePropertyIPTCDictionary as String: [
                kCGImagePropertyIPTCCity as String: "Olympia",
                kCGImagePropertyIPTCProvinceState as String: "WA",
                kCGImagePropertyIPTCCountryPrimaryLocationName as String: "United States",
                kCGImagePropertyIPTCObjectName as String: "Lakeside"
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

    /// The audit findings, pinned. {ExifAux} names the same facts differently — `SerialNumber`,
    /// `OwnerName` — and the first scrub list removed only the EXIF spellings, so a Canon body's
    /// serial travelled through "location off". And place NAMES are location: IPTC City/State/
    /// Country must go with the coordinates, while the caption-side IPTC fields travel.
    func testRemovingLocationScrubsTheAuxSerialAndThePlaceNames() throws {
        let source = try makeSourceFile()
        let edited = Renderer.render(try XCTUnwrap(CIImage(contentsOf: source)), with: lifted)
        let out = directory.appendingPathComponent("scrubbed-aux.jpg")
        try ImageWriter.write(edited, to: out, metadata: .withoutLocation)

        let written = try properties(of: out)
        let aux = written[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        XCTAssertNil(aux?[kCGImagePropertyExifAuxSerialNumber as String],
                     "the AUX spelling of the body serial must go too")
        XCTAssertNil(aux?[kCGImagePropertyExifAuxOwnerName as String])
        XCTAssertEqual(aux?[kCGImagePropertyExifAuxLensModel as String] as? String, "RF 24-70mm",
                       "the lens is photography, not identity")
        let iptc = written[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        XCTAssertNil(iptc?[kCGImagePropertyIPTCCity as String],
                     "a place name is location as surely as a coordinate")
        XCTAssertNil(iptc?[kCGImagePropertyIPTCProvinceState as String])
        XCTAssertNil(iptc?[kCGImagePropertyIPTCCountryPrimaryLocationName as String])
        XCTAssertEqual(iptc?[kCGImagePropertyIPTCObjectName as String] as? String, "Lakeside",
                       "the caption side of IPTC travels")
    }

    /// Scrubbing is metadata-only. It must not touch a single pixel — the whole point of doing it on
    /// `properties` instead of rewriting the file is that the encode happens exactly once.
    func testScrubbingChangesNoPixels() throws {
        let image = TestSupport.makeGradientImage(width: 24, height: 24)
        XCTAssertEqual(try ImageWriter.rgba8Bytes(ImageWriter.scrubbed(image)),
                       try ImageWriter.rgba8Bytes(image))
    }
}

/// Formats, sizes and colour spaces — the export options a photographer actually asks for.
///
/// Every assertion reads the written file back through ImageIO. "16-bit" and "never upscales" are
/// exactly the sort of claim that is easy to make in a menu and quietly wrong on disk.
final class ExportFormatTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-export-format-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func properties(of url: URL) throws -> [String: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    private let image = TestSupport.makeGradientImage(width: 400, height: 300)

    func testEveryFormatWritesAFileThatReadsBack() throws {
        for format in [ImageWriter.Format.jpeg(quality: 0.9), .png, .tiff16, .heic(quality: 0.9)] {
            let out = directory.appendingPathComponent("out.\(format.fileExtension)")
            try ImageWriter.write(image, to: out, format: format)
            let written = try properties(of: out)
            XCTAssertEqual(written[kCGImagePropertyPixelWidth as String] as? Int, 400,
                           "\(format.label) lost its dimensions")
        }
    }

    /// The whole reason to choose TIFF: eight bits is enough to look at and not enough to edit
    /// again. A 16-bit container holding 8 bits of data would be a bigger file and no more useful.
    func testTIFFIsActuallySixteenBitsPerChannel() throws {
        let out = directory.appendingPathComponent("deep.tif")
        try ImageWriter.write(image, to: out, format: .tiff16)
        XCTAssertEqual(try properties(of: out)[kCGImagePropertyDepth as String] as? Int, 16)
    }

    /// Long edge, because that is the number every submission guideline is written in, and the only
    /// one that means the same thing for a portrait frame and a landscape one.
    func testLongEdgeResizesTheLongestSideWhicheverItIs() throws {
        let landscape = directory.appendingPathComponent("wide.png")
        try ImageWriter.write(image, to: landscape, format: .png, size: .longEdge(200))
        var written = try properties(of: landscape)
        XCTAssertEqual(written[kCGImagePropertyPixelWidth as String] as? Int, 200)
        XCTAssertEqual(written[kCGImagePropertyPixelHeight as String] as? Int, 150, "aspect kept")

        let portrait = directory.appendingPathComponent("tall.png")
        try ImageWriter.write(TestSupport.makeGradientImage(width: 300, height: 400),
                              to: portrait, format: .png, size: .longEdge(200))
        written = try properties(of: portrait)
        XCTAssertEqual(written[kCGImagePropertyPixelHeight as String] as? Int, 200)
    }

    /// Asking for more pixels than exist must not invent them. Upscaling makes a larger file and a
    /// softer photograph, and no export dialog should do that quietly.
    func testAskingForMoreThanTheOriginalNeverUpscales() throws {
        let out = directory.appendingPathComponent("big.png")
        try ImageWriter.write(image, to: out, format: .png, size: .longEdge(4000))
        XCTAssertEqual(try properties(of: out)[kCGImagePropertyPixelWidth as String] as? Int, 400)
    }

    /// The profile has to be IN the file. A wide-gamut export that does not say it is wide-gamut is
    /// worse than an sRGB one, because everything downstream then guesses — and guesses sRGB.
    ///
    /// Asserted on the embedded ICC PROFILE rather than on `CGColorSpace.name`, because the name is
    /// not a reliable round-trip: measured, sRGB and Display P3 both read back as
    /// `kCGColorSpaceSRGB`/`kCGColorSpaceDisplayP3`, while Adobe RGB reads back with a nil name and a
    /// perfectly good 544-byte profile. A test written against the name would have called a correct
    /// Adobe RGB export a failure, which is how a real behaviour gets "fixed" into a wrong one.
    func testTheColourSpaceIsWrittenIntoTheFile() throws {
        func profile(of url: URL) throws -> Data {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let space = try XCTUnwrap(cg.colorSpace, "no colour space at all")
            return try XCTUnwrap(space.copyICCData() as Data?, "no ICC profile embedded")
        }

        var profiles: [ImageWriter.ColorSpace: Data] = [:]
        for space in ImageWriter.ColorSpace.allCases {
            let out = directory.appendingPathComponent("\(space.rawValue).png")
            try ImageWriter.write(image, to: out, format: .png, colorSpace: space)
            profiles[space] = try profile(of: out)
        }

        // Each is genuinely a different profile — nothing silently fell back to sRGB.
        XCTAssertNotEqual(profiles[.displayP3], profiles[.sRGB], "Display P3 fell back to sRGB")
        XCTAssertNotEqual(profiles[.adobeRGB], profiles[.sRGB], "Adobe RGB fell back to sRGB")
        XCTAssertNotEqual(profiles[.adobeRGB], profiles[.displayP3])
    }

    /// Resizing must not undo the metadata decision — the two settings are independent, and a
    /// photographer stripping location for a web-sized export is the most likely combination there is.
    func testResizingStillHonoursTheMetadataPolicy() throws {
        let source = directory.appendingPathComponent("src.jpg")
        let cg = try XCTUnwrap(ImageWriter.context.createCGImage(image, from: image.extent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            source as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 50.4]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let out = directory.appendingPathComponent("small.jpg")
        try ImageWriter.write(try XCTUnwrap(CIImage(contentsOf: source)), to: out,
                              format: .jpeg(quality: 0.9), metadata: .withoutLocation,
                              size: .longEdge(100))
        let written = try properties(of: out)
        XCTAssertNil(written[kCGImagePropertyGPSDictionary as String], "location survived a resize")
        XCTAssertEqual(written[kCGImagePropertyPixelWidth as String] as? Int, 100)
    }
}
