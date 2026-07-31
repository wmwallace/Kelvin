import XCTest
import CoreImage
@testable import KelvinCore

/// `SpotHeal` turns a click into a `HealSpot`. The properties that matter are the ones a manual
/// tool depends on: a click always produces a spot, the source patch is somewhere else, and the
/// result actually removes the blemish when rendered.
final class SpotHealTests: XCTestCase {

    // MARK: - Fixtures

    /// A flat mid-grey field with one dark blob on it — the case healing exists for.
    private func fieldWithBlob(
        width: Int = 400, height: Int = 300,
        blobAt: CGPoint = CGPoint(x: 0.5, y: 0.5), blobRadius: Int = 5
    ) -> CIImage {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let cx = Int(blobAt.x * Double(width)), cy = Int(blobAt.y * Double(height))
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let dx = x - cx, dy = y - cy
                let inBlob = dx * dx + dy * dy <= blobRadius * blobRadius
                let v: UInt8 = inBlob ? 40 : 160
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
            }
        }
        return CIImage(bitmapData: Data(px), bytesPerRow: width * 4,
                       size: CGSize(width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    /// Mean luma over a small disc, read back from a rendered image. Top-left origin.
    private func meanLuma(_ image: CIImage, at point: CGPoint, radius: Int) -> Double {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard let data = try? ImageWriter.rgba8Sampled(image, width: w, height: h) else { return .nan }
        let cx = Int(point.x * Double(w)), cy = Int(point.y * Double(h))
        var sum = 0.0, count = 0.0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in max(0, cy - radius)...min(h - 1, cy + radius) {
                for x in max(0, cx - radius)...min(w - 1, cx + radius) {
                    let dx = x - cx, dy = y - cy
                    if dx * dx + dy * dy > radius * radius { continue }
                    let i = (y * w + x) * 4
                    sum += 0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])
                    count += 1
                }
            }
        }
        return count > 0 ? sum / count / 255.0 : .nan
    }

    // MARK: - A click always produces a spot

    /// The whole reason the smoothness gate became a cost rather than a gate: a click the user
    /// makes deliberately must never silently do nothing.
    func testClickOnBusyTextureStillReturnsASpot() {
        // Pure noise — no patch anywhere is smooth, so the old detector's gate would refuse.
        let w = 200, h = 200
        var px = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt64 = 12345
        for i in stride(from: 0, to: px.count, by: 4) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt8((seed >> 33) & 0xFF)
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 255
        }
        let noise = CIImage(bitmapData: Data(px), bytesPerRow: w * 4,
                            size: CGSize(width: w, height: h),
                            format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        let spot = SpotHeal.spot(in: noise, at: CGPoint(x: 0.5, y: 0.5), radius: 0.01)
        XCTAssertNotNil(spot, "a deliberate click must produce a spot even where nothing is smooth")
    }

    func testSpotIsCentredOnTheClick() {
        let img = fieldWithBlob()
        let click = CGPoint(x: 0.5, y: 0.5)
        let spot = SpotHeal.spot(in: img, at: click, radius: 0.02)
        XCTAssertEqual(spot?.x ?? -1, click.x, accuracy: 1e-9)
        XCTAssertEqual(spot?.y ?? -1, click.y, accuracy: 1e-9)
        XCTAssertEqual(spot?.radius ?? -1, 0.02, accuracy: 1e-9)
    }

    func testSourceOffsetIsNonZero() {
        let img = fieldWithBlob()
        let spot = SpotHeal.spot(in: img, at: CGPoint(x: 0.5, y: 0.5), radius: 0.02)
        let offset = ((spot?.dx ?? 0) * (spot?.dx ?? 0) + (spot?.dy ?? 0) * (spot?.dy ?? 0)).squareRoot()
        XCTAssertGreaterThan(offset, 0, "cloning a spot onto itself would be a no-op")
    }

    // MARK: - Rejection

    func testClickOutsideTheFrameIsRejected() {
        let img = fieldWithBlob()
        XCTAssertNil(SpotHeal.spot(in: img, at: CGPoint(x: 1.4, y: 0.5), radius: 0.01))
        XCTAssertNil(SpotHeal.spot(in: img, at: CGPoint(x: 0.5, y: -0.2), radius: 0.01))
    }

    func testNonPositiveRadiusIsRejected() {
        let img = fieldWithBlob()
        XCTAssertNil(SpotHeal.spot(in: img, at: CGPoint(x: 0.5, y: 0.5), radius: 0))
        XCTAssertNil(SpotHeal.spot(in: img, at: CGPoint(x: 0.5, y: 0.5), radius: -0.01))
    }

    // MARK: - The spot near a frame edge still finds somewhere to sample

    /// Every candidate on one side is off-frame here, so this exercises the direction search
    /// falling back to the sides that fit.
    func testSpotNearCornerStillHeals() {
        let img = fieldWithBlob(blobAt: CGPoint(x: 0.02, y: 0.02), blobRadius: 3)
        let spot = SpotHeal.spot(in: img, at: CGPoint(x: 0.02, y: 0.02), radius: 0.01)
        XCTAssertNotNil(spot)
        // The source must sit inside the frame, not off the top-left edge.
        if let s = spot {
            XCTAssertGreaterThanOrEqual(s.x + s.dx, 0)
            XCTAssertGreaterThanOrEqual(s.y + s.dy, 0)
        }
    }

    // MARK: - End to end: the blemish is actually gone

    /// The property that matters to the user. Render the healed recipe and confirm the dark blob
    /// has been replaced by something close to the surrounding field.
    func testRenderingTheSpotRemovesTheBlemish() throws {
        let img = fieldWithBlob(blobRadius: 5)
        let click = CGPoint(x: 0.5, y: 0.5)

        let before = meanLuma(img, at: click, radius: 3)
        XCTAssertLessThan(before, 0.3, "fixture should start with a dark blob")

        let spot = try XCTUnwrap(SpotHeal.spot(in: img, at: click, radius: 0.025))
        var recipe = Recipe.neutral
        recipe.heal = [spot]
        let healed = Renderer.render(img, with: recipe)

        let after = meanLuma(healed, at: click, radius: 3)
        // The surrounding field is 160/255 ≈ 0.627.
        XCTAssertEqual(after, 160.0 / 255.0, accuracy: 0.08,
                       "healed centre should match the field it was cloned from")
        XCTAssertGreaterThan(after, before + 0.25, "the blemish should be substantially lighter")
    }

    /// A recipe with no heal spots must still be the byte-identical no-op the schema promises.
    func testNoHealSpotsIsANoOp() {
        let img = fieldWithBlob()
        let out = Renderer.render(img, with: Recipe.neutral)
        XCTAssertEqual(meanLuma(out, at: CGPoint(x: 0.5, y: 0.5), radius: 3),
                       meanLuma(img, at: CGPoint(x: 0.5, y: 0.5), radius: 3),
                       accuracy: 1e-6)
    }

    // MARK: - Normalisation is what makes a spot portable

    /// The same click on the same scene at two resolutions must give the same normalised spot,
    /// because that is what lets a proxy click survive to a full-res export and across a shoot.
    func testSpotIsResolutionIndependent() throws {
        let small = fieldWithBlob(width: 400, height: 300)
        let large = fieldWithBlob(width: 1200, height: 900)
        let click = CGPoint(x: 0.5, y: 0.5)

        let a = try XCTUnwrap(SpotHeal.spot(in: small, at: click, radius: 0.02))
        let b = try XCTUnwrap(SpotHeal.spot(in: large, at: click, radius: 0.02))

        XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
        XCTAssertEqual(a.radius, b.radius, accuracy: 1e-9)
        // Both run on the same working grid, so the offsets should agree closely too.
        XCTAssertEqual(a.dx, b.dx, accuracy: 0.02)
        XCTAssertEqual(a.dy, b.dy, accuracy: 0.02)
    }
}
