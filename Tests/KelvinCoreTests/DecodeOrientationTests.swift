import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import KelvinCore

/// A phone held upright writes landscape sensor pixels and an EXIF orientation tag saying "rotate
/// me". Every reader of the file has to honour that tag the same way, because masks are measured on
/// one decode and applied to another: the filmstrip thumbnail and the fast proxy (ImageIO, with
/// `kCGImageSourceCreateThumbnailWithTransform`) always did, while the full decode
/// (`CIImage(contentsOf:)` without `.applyOrientationProperty`) did not. The photo appeared upright
/// in the strip and on its side in the editor, and the fast proxy was refused as "misaligned".
final class DecodeOrientationTests: XCTestCase {

    /// A 64 × 32 landscape JPEG tagged orientation 6 ("rotate 90° clockwise to display"), so the
    /// upright picture is 32 × 64 portrait. Encoded with ImageIO so the decoder is tested against a
    /// real file rather than a property dictionary the test invented.
    private func writeTaggedJPEG() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("orientation-\(UUID().uuidString).jpg")
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        let image = try XCTUnwrap(context?.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testATaggedJPEGDecodesUpright() throws {
        let url = try writeTaggedJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try ImageDecoder.decode(url: url)
        XCTAssertEqual(decoded.extent.width, 32, "the orientation tag must be applied at decode")
        XCTAssertEqual(decoded.extent.height, 64, "the orientation tag must be applied at decode")
    }

    /// The fast proxy was always upright; with the decode upright too, the aspect guard that
    /// protects mask alignment must now ACCEPT it rather than fall back to the slow path.
    func testTheFastProxyAgreesWithTheDecode() throws {
        let url = try writeTaggedJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try ImageDecoder.decode(url: url)
        XCTAssertNotNil(PerceptionProxy.fromFile(url, maxEdge: 32, matching: decoded.extent),
                        "proxy and decode must agree about which way up the photo is")
    }

    /// The pixels are rotated at decode, so the tag that described the rotation must not travel
    /// on into the export — otherwise every viewer would rotate the already-upright picture a
    /// second time and the export would land on its side.
    func testAnExportOfAnOrientedDecodeIsNotRotatedTwice() throws {
        let url = try writeTaggedJPEG()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("orientation-out-\(UUID().uuidString).jpg")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: out)
        }

        try ImageWriter.write(try ImageDecoder.decode(url: url), to: out)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tag = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
        XCTAssertEqual(tag, 1, "an upright export must not carry a rotate-me tag")
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 32)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 64)
    }
}

/// A failed open is explained to a person, not dumped as an error type.
final class DecodeErrorWordingTests: XCTestCase {
    func testAMissingFileSaysSoInWords() {
        let url = URL(fileURLWithPath: "/nowhere/_DSC0001.ARW")
        XCTAssertThrowsError(try ImageDecoder.decode(url: URL(fileURLWithPath: "/nowhere/missing.jpg"))) {
            XCTAssertTrue($0.localizedDescription.contains("missing.jpg"), $0.localizedDescription)
            XCTAssertFalse($0.localizedDescription.contains("KelvinCore"))
        }
        XCTAssertTrue(ImageDecoder.Error.rawDecodeFailed(url).localizedDescription.contains("_DSC0001.ARW"))
    }
}
