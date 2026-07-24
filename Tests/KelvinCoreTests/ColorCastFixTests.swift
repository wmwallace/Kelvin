import XCTest
import CoreImage
@testable import KelvinCore

/// The "Fix" offered for a colour cast must REMOVE colour. Reported from the app as: click Fix and
/// the photo goes "more and more and then more orange".
///
/// The cause was a hand-written `temperatureK = 5500` commented "neutralise white balance". The
/// renderer's neutral is 6500 and lower Kelvin is warmer, so the fix applied a 1000 K warm shift,
/// then re-detected the cast it had just created. These tests measure the result through the real
/// renderer rather than trusting either number.
final class ColorCastFixTests: XCTestCase {

    private func patch(r: Double, g: Double, b: Double) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    private func recipe(_ temperatureK: Double?, _ tint: Double) -> Recipe {
        var adj = GlobalAdjustments.neutral
        adj.temperatureK = temperatureK
        adj.tint = tint
        return Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                      global: adj, curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
    }

    private func cast(of image: CIImage) throws -> Double {
        let s = try ImageStatistics.compute(image)
        return (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
    }

    /// The regression itself: 5500 K makes a warm frame WARMER, which is what the user saw.
    func test5500MakesAWarmFrameWarmerNotNeutral() throws {
        let warm = patch(r: 0.62, g: 0.50, b: 0.34)
        let before = try cast(of: warm)
        let after = try cast(of: Renderer.render(warm, with: recipe(5500, 0)))
        XCTAssertGreaterThan(after, before,
                             "5500 K is a warm shift, not a neutraliser — this is the bug")
    }

    /// And the replacement genuinely reduces the cast, measured through the renderer.
    func testNeutralisingWhiteBalanceReducesAWarmCast() throws {
        let warm = patch(r: 0.62, g: 0.50, b: 0.34)
        let before = try cast(of: warm)
        let wb = RecipeEngine.neutralisingWhiteBalance(for: try ImageStatistics.compute(warm))
        let after = try cast(of: Renderer.render(warm, with: recipe(wb.temperatureK, wb.tint)))
        XCTAssertLessThan(after, before, "the fix must take colour out, not put it in")
    }

    /// A cool cast has to move the other way — a fix that only ever warms would be the same bug
    /// wearing a different sign.
    func testNeutralisingWhiteBalanceReducesACoolCast() throws {
        let cool = patch(r: 0.36, g: 0.48, b: 0.66)
        let before = try cast(of: cool)
        let wb = RecipeEngine.neutralisingWhiteBalance(for: try ImageStatistics.compute(cool))
        let after = try cast(of: Renderer.render(cool, with: recipe(wb.temperatureK, wb.tint)))
        XCTAssertLessThan(after, before)
        XCTAssertLessThan(wb.temperatureK, 6500, "a blue frame needs warming — a LOWER Kelvin")
    }

    /// Applying it twice must not keep pushing. The reported symptom was compounding, so
    /// converging matters as much as the direction being right.
    func testRepeatedApplicationConverges() throws {
        let warm = patch(r: 0.62, g: 0.50, b: 0.34)
        var image = warm
        var casts: [Double] = [try cast(of: warm)]
        for _ in 0..<3 {
            let wb = RecipeEngine.neutralisingWhiteBalance(for: try ImageStatistics.compute(image))
            image = Renderer.render(image, with: recipe(wb.temperatureK, wb.tint))
            casts.append(try cast(of: image))
        }
        XCTAssertLessThan(casts.last!, casts.first!, "never worse than where it started: \(casts)")
        XCTAssertLessThan(casts.last!, 12, "must settle near neutral, got \(casts)")
    }
}
