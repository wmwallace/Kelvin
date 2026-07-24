import XCTest
@testable import KelvinCore

final class HorizonDetectorTests: XCTestCase {
    func testNoHorizonInSyntheticImage() {
        // Vision finds no horizon in a procedural gradient → nil, not a bogus angle.
        XCTAssertNil(HorizonDetector.levelingAngle(in: TestSupport.makeGradientImage()))
    }
}
