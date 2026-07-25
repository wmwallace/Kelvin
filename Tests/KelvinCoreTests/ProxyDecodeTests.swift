import XCTest
import CoreImage
@testable import KelvinCore

/// The proxy is the image everything downstream is measured against — statistics, segmentation,
/// masks, the histogram — and at export those measurements are applied to a separately decoded
/// full-resolution frame. So a faster proxy is only allowed if it is the SAME PICTURE.
///
/// Profiled on a 9504×6336 JPEG, building the 1200 px proxy by decoding the full frame and scaling
/// it cost 2017 ms; asking ImageIO to decode straight to that size cost 120 ms. These pin the
/// conditions under which taking the fast path is safe.
final class ProxyDecodeTests: XCTestCase {

    private func write(_ image: CIImage, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-\(name)-\(UUID().uuidString)")
        try ImageWriter.write(image, to: url.appendingPathExtension("png"))
        return url.appendingPathExtension("png")
    }

    /// A landscape frame, so a rotation would be unmistakable in the aspect ratio.
    private func landscape() -> CIImage {
        TestSupport.pixels(size: 256) { x, y in
            (UInt8(x), UInt8(y), UInt8((x + y) / 2))
        }
        .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 128))
    }

    func testFastProxyMatchesTheDecodedImage() throws {
        let url = try write(landscape(), "landscape")
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try ImageDecoder.decode(url: url)
        let fast = try XCTUnwrap(PerceptionProxy.fromFile(url, maxEdge: 64, matching: decoded.extent),
                                 "a PNG on disk must take the fast path")
        let slow = PerceptionProxy.downsample(decoded, maxEdge: 64)

        XCTAssertEqual(fast.extent.width / fast.extent.height,
                       slow.extent.width / slow.extent.height, accuracy: 0.02,
                       "the fast proxy must be the same shape as the one it replaces")
        XCTAssertLessThanOrEqual(max(fast.extent.width, fast.extent.height), 64,
                                 "the long edge must honour maxEdge")

        // Same picture, not merely the same shape: measured through the same statistics the engine
        // uses, the two proxies have to agree about the photograph.
        let a = try ImageStatistics.compute(fast)
        let b = try ImageStatistics.compute(slow)
        XCTAssertEqual(a.medianLuma, b.medianLuma, accuracy: 0.05, "brightness disagrees")
        XCTAssertEqual(a.chromaA, b.chromaA, accuracy: 3.0, "colour disagrees")
        XCTAssertEqual(a.chromaB, b.chromaB, accuracy: 3.0, "colour disagrees")
    }

    /// The guard that keeps a sideways proxy out. Masks are measured on the proxy and applied to a
    /// separately decoded full-resolution frame at export; if the two disagree about orientation
    /// every mask lands rotated, and it would look like a masking bug rather than a decode one.
    func testAProxyOfADifferentShapeIsRefused() throws {
        let url = try write(landscape(), "mismatch")
        defer { try? FileManager.default.removeItem(at: url) }

        // Claim the full-resolution frame is portrait when the file is landscape — exactly the
        // shape of an orientation disagreement.
        let portrait = CGRect(x: 0, y: 0, width: 128, height: 256)
        XCTAssertNil(PerceptionProxy.fromFile(url, maxEdge: 64, matching: portrait),
                     "a proxy whose aspect ratio disagrees with the decode must be refused")
    }

    /// RAW never takes this path, however fast it is. ImageIO would answer a RAW file with the
    /// camera's embedded preview — the manufacturer's rendering, not Apple's decode and per-camera
    /// colour profile, which is the entire reason RAW goes through `CIRAWFilter` (non-negotiable
    /// #2). It would look fine and be wrong, which is the worst way to be wrong.
    func testRawIsNeverTakenFromTheEmbeddedPreview() {
        for ext in ImageDecoder.rawExtensions {
            let url = URL(fileURLWithPath: "/tmp/nonexistent-fixture.\(ext)")
            XCTAssertNil(PerceptionProxy.fromFile(url), ".\(ext) must not use the ImageIO path")
        }
    }
}
