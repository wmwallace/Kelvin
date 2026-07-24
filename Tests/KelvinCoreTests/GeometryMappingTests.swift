import XCTest
import CoreImage
@testable import KelvinCore

/// Masks are applied BEFORE geometry, so a UI that positions a mask by clicking the *straightened*
/// preview must undo the rotate+crop. These tests pin that inverse against the real renderer.
final class GeometryMappingTests: XCTestCase {

    /// Black image with a white square centred at normalised (nx, ny), top-left origin.
    private func marker(at nx: Double, _ ny: Double, size: Int = 128, dot: Int = 7) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bpr = size * 4
        var px = [UInt8](repeating: 0, count: bpr * size)
        for i in stride(from: 0, to: px.count, by: 4) { px[i + 3] = 255 }
        let cx = Int(nx * Double(size - 1)), cy = Int(ny * Double(size - 1))
        for y in max(0, cy - dot / 2)...min(size - 1, cy + dot / 2) {
            for x in max(0, cx - dot / 2)...min(size - 1, cx + dot / 2) {
                let i = y * bpr + x * 4
                px[i] = 255; px[i + 1] = 255; px[i + 2] = 255
            }
        }
        let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Brightest pixel of `image`, as normalised top-left coords.
    private func brightest(_ image: CIImage, grid: Int = 128) throws -> CGPoint {
        let data = try ImageWriter.rgba8Sampled(image, width: grid, height: grid)
        var best = -1.0, bx = 0, by = 0
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for y in 0..<grid {
                for x in 0..<grid {
                    let i = (y * grid + x) * 4
                    let l = 0.299 * Double(px[i]) + 0.587 * Double(px[i+1]) + 0.114 * Double(px[i+2])
                    if l > best { best = l; bx = x; by = y }
                }
            }
        }
        return CGPoint(x: Double(bx) / Double(grid - 1), y: Double(by) / Double(grid - 1))
    }

    func testNilGeometryIsIdentity() {
        let p = CGPoint(x: 0.3, y: 0.7)
        let out = Renderer.sourceNormalized(fromFramed: p, geometry: nil,
                                            sourceExtent: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(out.x, 0.3, accuracy: 0.001)
        XCTAssertEqual(out.y, 0.7, accuracy: 0.001)
    }

    /// The real proof: put a marker at a known source spot, straighten, find where it landed in the
    /// framed image, and map that back — it must return the original spot.
    func testRoundTripThroughStraighten() throws {
        let source = marker(at: 0.30, 0.30)
        let geo = Geometry(rotateDeg: 8, crop: nil, lensCorrection: false)
        let framed = Renderer.applyGeometry(source, geo)

        let framedPoint = try brightest(framed)
        let back = Renderer.sourceNormalized(fromFramed: framedPoint, geometry: geo,
                                             sourceExtent: source.extent)
        XCTAssertEqual(back.x, 0.30, accuracy: 0.03, "x should map back to where the marker was")
        XCTAssertEqual(back.y, 0.30, accuracy: 0.03, "y should map back to where the marker was")
    }

    /// The two directions must be exact inverses of each other.
    func testForwardAndInverseAreInverses() {
        let ext = CGRect(x: 0, y: 0, width: 400, height: 300)
        let geo = Geometry(rotateDeg: 6.5, crop: nil, lensCorrection: false)
        for p in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.42, y: 0.61), CGPoint(x: 0.55, y: 0.38)] {
            let framed = Renderer.framedNormalized(fromSource: p, geometry: geo, sourceExtent: ext)
            let back = Renderer.sourceNormalized(fromFramed: framed, geometry: geo, sourceExtent: ext)
            XCTAssertEqual(back.x, p.x, accuracy: 0.0001)
            XCTAssertEqual(back.y, p.y, accuracy: 0.0001)
        }
    }

    func testRoundTripThroughExplicitCrop() throws {
        let source = marker(at: 0.60, 0.40)
        let geo = Geometry(rotateDeg: 0,
                           crop: CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                           lensCorrection: false)
        let framed = Renderer.applyGeometry(source, geo)
        let framedPoint = try brightest(framed)
        let back = Renderer.sourceNormalized(fromFramed: framedPoint, geometry: geo,
                                             sourceExtent: source.extent)
        XCTAssertEqual(back.x, 0.60, accuracy: 0.03)
        XCTAssertEqual(back.y, 0.40, accuracy: 0.03)
    }
}
