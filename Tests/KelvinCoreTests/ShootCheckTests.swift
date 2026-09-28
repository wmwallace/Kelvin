import XCTest
import CoreImage
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

    /// Reported: a black-and-white dog under "Like the one you chose", beside a Natural chosen on a
    /// colour car. Picked for a combined distance no single axis crossed, then labelled as alike.
    func testAPickedFrameIsNeverCalledAlike() {
        // Somewhat different on three axes, past none: 0.4 stops, 0.5 shadow, 0.35 warmth.
        let frame = sig(-0.4, shadows: 0.5, warmth: 0.35)
        XCTAssertGreaterThanOrEqual(frame.distance(to: sig(0)), ShootCheck.minimumDistance,
                                    "the picker would take this frame")
        XCTAssertEqual(ShootCheck.reason(for: frame, hero: sig(0)), "A little darker")
        let spread = sig(0.2, shadows: 0.3, highlights: 0.2, warmth: 0.2)
        XCTAssertGreaterThanOrEqual(spread.distance(to: sig(0)), ShootCheck.minimumDistance)
        XCTAssertEqual(ShootCheck.reason(for: spread, hero: sig(0)), "Slightly different light")
    }

    func testBlackAndWhiteIsNamedFirst() {
        var mono = sig(-2)                       // much darker, too — but grey is what the eye sees
        mono.colourfulness = 0.02
        var hero = sig(0)
        hero.colourfulness = 0.24
        XCTAssertEqual(ShootCheck.reason(for: mono, hero: hero), "Black and white")
        XCTAssertEqual(ShootCheck.reason(for: hero, hero: mono), "In colour")
        // Unmeasured, or in the gap between the two thresholds, claims neither.
        XCTAssertEqual(ShootCheck.reason(for: sig(-2), hero: hero), "Much darker")
        var pastel = sig(-2)
        pastel.colourfulness = 0.06
        XCTAssertEqual(ShootCheck.reason(for: pastel, hero: hero), "Much darker")
    }

    func testColourfulnessSeparatesGreyFromColour() throws {
        let grey = ShootCheck.colourfulness(CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)))
        let red = ShootCheck.colourfulness(CIImage(color: CIColor(red: 0.8, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 48)))
        XCTAssertLessThan(try XCTUnwrap(grey), ShootCheck.monochromeBelow)
        XCTAssertGreaterThan(try XCTUnwrap(red), ShootCheck.colourAbove)
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
