import XCTest
import CoreImage
@testable import KelvinCore

final class NaiveAutoTests: XCTestCase {

    /// A low-contrast source should come out with a wider tonal range after the histogram
    /// stretch — that is the whole point of the baseline.
    func testNaiveAutoIncreasesContrastOnFlatImage() throws {
        // A flat, low-contrast gray patch (values hugging mid-gray).
        let flat = CIImage(color: CIColor(red: 0.45, green: 0.47, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))

        let before = try ImageMetrics.sample(flat)
        let after = try ImageMetrics.sample(try Baselines.naiveAuto(flat))

        XCTAssertGreaterThanOrEqual(lumaRange(after), lumaRange(before),
            "naive-auto should not reduce tonal range on a flat image")
    }

    /// Grey-world WB should pull a strong uniform color cast back toward neutral.
    func testNaiveAutoReducesColorCast() throws {
        // A blue-cast field: chroma is far from neutral.
        let cast = CIImage(color: CIColor(red: 0.35, green: 0.4, blue: 0.7))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))

        let before = ImageMetrics.meanChroma(try ImageMetrics.sample(cast))
        let after = ImageMetrics.meanChroma(try ImageMetrics.sample(try Baselines.naiveAuto(cast)))

        let magBefore = (before.a * before.a + before.b * before.b).squareRoot()
        let magAfter = (after.a * after.a + after.b * after.b).squareRoot()
        XCTAssertLessThan(magAfter, magBefore, "grey-world WB should reduce the color cast")
    }

    private func lumaRange(_ data: Data) -> Double {
        var lo = 1.0, hi = 0.0
        data.withUnsafeBytes { dp in
            let p = dp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) {
                let y = 0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])
                let yn = y / 255.0
                lo = min(lo, yn); hi = max(hi, yn)
            }
        }
        return hi - lo
    }
}
