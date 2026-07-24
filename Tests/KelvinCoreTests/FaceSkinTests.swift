import XCTest
import CoreImage
@testable import KelvinCore

final class FaceSkinTests: XCTestCase {

    /// No face in a synthetic gradient → no faces, no skin metered. (Face *detection* on real
    /// portraits is exercised manually via `kelvin-cli mask`; Vision won't find a face in a
    /// procedural image, so the unit test pins the empty-result contract the engine relies on.)
    func testNoFaceInGradient() {
        let reading = FaceSkin.read(in: TestSupport.makeGradientImage())
        XCTAssertEqual(reading.faceCount, 0)
        XCTAssertNil(reading.skinLuma)
    }

    func testNoFaceInSolid() {
        let reading = FaceSkin.read(in: TestSupport.makeSolidImage(r: 120, g: 90, b: 70))
        XCTAssertEqual(reading.faceCount, 0)
        XCTAssertNil(reading.skinLuma)
    }
}
