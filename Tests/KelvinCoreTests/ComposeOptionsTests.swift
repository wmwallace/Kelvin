import XCTest
import CoreImage
@testable import KelvinCore

/// `compose`'s options change how the candidate stage runs, never what it decides — the promise that
/// lets the canvas call the harness's own composition instead of keeping a copy of it.
final class ComposeOptionsTests: XCTestCase {

    private let frame: CIImage = {
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 768, y: 512),
            "inputColor0": CIColor(red: 0.08, green: 0.10, blue: 0.16),
            "inputColor1": CIColor(red: 0.86, green: 0.78, blue: 0.62)])!.outputImage!
        return ramp.cropped(to: CGRect(x: 0, y: 0, width: 768, height: 512))
    }()

    private let perception = Perception(
        scene: .other, subject: .absent,
        lighting: .init(condition: .indoorDaylight, direction: .diffuse, contrastRange: .normal),
        problems: [], intent: .natural, confidence: 0.3)

    private func fingerprint(_ c: ShippedCandidates.Composition) -> [String] {
        c.all.map { "\($0.styleID) \($0.score.overall)" } + ["chosen \(c.chosen?.recipe.id ?? "-")"]
            + c.curatedStyleIDs
    }

    func testRenderingConcurrentlyDecidesExactlyWhatSeriallyDoes() throws {
        let serial = try ShippedCandidates.compose(for: frame, perception: perception)
        let concurrent = try ShippedCandidates.compose(for: frame, perception: perception,
                                                       options: .init(width: 4))
        XCTAssertEqual(fingerprint(serial), fingerprint(concurrent))
        XCTAssertEqual(serial.all.map(\.recipe), concurrent.all.map(\.recipe))
    }

    func testHandingInTheMeasurementsDecidesWhatMeasuringDoes() throws {
        let measured = try ShippedCandidates.compose(for: frame, perception: perception)
        let pre = ShippedCandidates.Premeasured(
            measuredOn: measured.measuredOn, statistics: measured.statistics,
            masks: measured.masks, focus: FocusMeasure.engineReading(for: measured.measuredOn))
        let handed = try ShippedCandidates.compose(for: frame, perception: perception, premeasured: pre)
        XCTAssertEqual(fingerprint(measured), fingerprint(handed))
    }

    func testAPhotographYouHaveLeftStopsTheStage() {
        XCTAssertThrowsError(try ShippedCandidates.compose(
            for: frame, perception: perception, options: .init(width: 2, isCurrent: { false }))) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
