import XCTest
@testable import KelvinCore

/// CIEDE2000 verified against the canonical Sharma, Wu & Dalal (2005) test vectors. If this
/// drifts, every color metric in the eval harness is silently wrong.
final class DeltaE2000Tests: XCTestCase {

    func testSharmaReferenceVectors() {
        // (L1,a1,b1), (L2,a2,b2), expected ΔE00
        let cases: [(Lab, Lab, Double)] = [
            (Lab(L: 50, a: 2.6772, b: -79.7751), Lab(L: 50, a: 0, b: -82.7485), 2.0425),
            (Lab(L: 50, a: 3.1571, b: -77.2803), Lab(L: 50, a: 0, b: -82.7485), 2.8615),
            (Lab(L: 50, a: 2.8361, b: -74.0200), Lab(L: 50, a: 0, b: -82.7485), 3.4412),
            (Lab(L: 50, a: -1.3802, b: -84.2814), Lab(L: 50, a: 0, b: -82.7485), 1.0000),
            (Lab(L: 50, a: 0, b: 0), Lab(L: 50, a: -1, b: 2), 2.3669),
            (Lab(L: 50, a: 2.4900, b: -0.0010), Lab(L: 50, a: -2.4900, b: 0.0009), 7.1792),
            (Lab(L: 60.2574, a: -34.0099, b: 36.2677), Lab(L: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
            (Lab(L: 63.0109, a: -31.0961, b: -5.8663), Lab(L: 62.8187, a: -29.7946, b: -4.0864), 1.2630),
            (Lab(L: 35.0831, a: -44.1164, b: 3.7933), Lab(L: 35.0232, a: -40.0716, b: 1.5901), 1.8645),
            (Lab(L: 22.7233, a: 20.0904, b: -46.6940), Lab(L: 23.0331, a: 14.9730, b: -42.5619), 2.0373),
            (Lab(L: 90.8027, a: -2.0831, b: 1.4410), Lab(L: 91.1528, a: -1.6435, b: 0.0447), 1.4441),
            (Lab(L: 2.0776, a: 0.0795, b: -1.1350), Lab(L: 0.9033, a: -0.0636, b: -0.5514), 0.9082)
        ]

        for (c1, c2, expected) in cases {
            let got = ColorDifference.deltaE2000(c1, c2)
            XCTAssertEqual(got, expected, accuracy: 1e-4,
                           "ΔE00(\(c1), \(c2)) = \(got), expected \(expected)")
        }
    }

    func testIdenticalColorsAreZero() {
        let c = Lab(L: 42, a: 7, b: -13)
        XCTAssertEqual(ColorDifference.deltaE2000(c, c), 0, accuracy: 1e-9)
    }

    func testSRGBWhiteAndBlackAreFarApart() {
        let white = Lab.fromSRGB8(r: 255, g: 255, b: 255)
        let black = Lab.fromSRGB8(r: 0, g: 0, b: 0)
        XCTAssertEqual(white.L, 100, accuracy: 0.2)
        XCTAssertEqual(black.L, 0, accuracy: 0.2)
        XCTAssertGreaterThan(ColorDifference.deltaE2000(white, black), 90)
    }
}
