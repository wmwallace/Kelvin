import XCTest
@testable import KelvinCore

/// Which frames the shoot check previews (`ShootCheck.pick`).
final class ShootCheckTests: XCTestCase {

    private func sig(_ b: Double, shadows: Double = 0, highlights: Double = 0, warmth: Double = 0) -> ShootCheck.Signature {
        ShootCheck.Signature(brightness: b, shadows: shadows, highlights: highlights, warmth: warmth, tint: 0)
    }

    func testTheHeroIsNeverPreviewed() {
        let frames = [("a", sig(0)), ("b", sig(-2)), ("c", sig(1))].map { (id: $0.0, signature: $0.1) }
        XCTAssertFalse(ShootCheck.pick(frames, hero: "a").contains("a"))
    }

    func testTheMostDifferentFrameComesFirstAndPicksSpreadOut() {
        // Six near-copies of the hero, a night frame and a blown-window frame.
        var frames = (0..<6).map { (id: "day\($0)", signature: sig(Double($0) * 0.02)) }
        frames.append((id: "night", signature: sig(-3, shadows: 2)))
        frames.append((id: "window", signature: sig(0.3, highlights: 1.2)))
        let picks = ShootCheck.pick(frames, hero: "day0", count: 3)
        XCTAssertEqual(picks.first, "night")
        XCTAssertTrue(picks.contains("window"), "the second pick is far from BOTH the hero and the first")
        XCTAssertEqual(picks.count, 2, "near-duplicates of the hero are not padded in: \(picks)")
    }

    func testAUniformShootYieldsNothingToCheck() {
        let frames = (0..<10).map { (id: $0, signature: sig(Double($0) * 0.01)) }
        XCTAssertTrue(ShootCheck.pick(frames, hero: 0).isEmpty)
    }

    func testDeterministic() {
        let frames = (0..<20).map { (id: $0, signature: sig(sin(Double($0)) * 2, shadows: cos(Double($0)))) }
        XCTAssertEqual(ShootCheck.pick(frames, hero: 3), ShootCheck.pick(frames, hero: 3))
    }

    func testReasonsNameTheBiggestDifference() {
        XCTAssertEqual(ShootCheck.reason(for: sig(-2), hero: sig(0)), "Much darker")
        XCTAssertEqual(ShootCheck.reason(for: sig(0, warmth: 2), hero: sig(0)), "Warmer light")
        XCTAssertEqual(ShootCheck.reason(for: sig(0.1), hero: sig(0)), "Like the one you chose")
    }

    func testSignatureFromStatistics() {
        let dark = ImageStatistics(meanLuma: 0.05, medianLuma: 0.05, blackPoint: 0.005, shadowLevel: 0.01,
                                   highlightLevel: 0.4, whitePoint: 0.6, highlightClip: 0, shadowClip: 0,
                                   chromaA: 0, chromaB: 0, shadowMass: 0.6, shadowRegion: 0.7)
        let s = ShootCheck.Signature(dark)
        XCTAssertLessThan(s.brightness, -3, "0.05 median is over three stops under mid grey")
        XCTAssertEqual(s.shadows, 2, accuracy: 0.001)
    }
}
