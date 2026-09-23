import XCTest
import CoreImage
@testable import KelvinCore

/// The export's measurement shortcuts must answer what the slow paths answered.
final class DeliveryMeasurementTests: XCTestCase {

    /// A large frame with structure in it: a diagonal ramp with a bright disc, so both a mean and
    /// its spatial layout have something to get wrong.
    private func largeFrame(width: CGFloat = 4000, height: CGFloat = 3000) -> CIImage {
        let ramp = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: width, y: height),
            "inputColor0": CIColor(red: 0.05, green: 0.1, blue: 0.2),
            "inputColor1": CIColor(red: 0.9, green: 0.8, blue: 0.6)])!.outputImage!
        let disc = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: width * 0.3, y: height * 0.6),
            "inputRadius0": 200, "inputRadius1": 260,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])!.outputImage!
        return disc.composited(over: ramp).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Above the threshold the frame is shrunk on the GPU before it is read back. The grid that
    /// comes out must be the one the whole-frame raster produced, to well under a visible difference.
    func testTheGPUPrefilterSamplesWhatTheFullRasterSampled() throws {
        let frame = largeFrame()
        let fast = try ImageWriter.rgba8Sampled(frame, width: 96, height: 96, fullRaster: false)
        let slow = try ImageWriter.rgba8Sampled(frame, width: 96, height: 96, fullRaster: true)
        XCTAssertLessThan(ImageMetrics.meanDeltaE2000(fast, slow), 0.5)
    }

    /// Below the threshold nothing changes, byte for byte — the guarantee that every proxy
    /// measurement, and so every recipe and the corpus, is untouched.
    func testSmallFramesAreSampledExactlyAsBefore() throws {
        let frame = largeFrame(width: 1200, height: 800)
        XCTAssertEqual(try ImageWriter.rgba8Sampled(frame, width: 96, height: 96, fullRaster: false),
                       try ImageWriter.rgba8Sampled(frame, width: 96, height: 96, fullRaster: true))
    }

    /// Masks measured at delivery size are placed over the whole frame, not its 2048 px copy.
    func testDeliveryMasksCoverTheFullFrame() {
        let frame = largeFrame()
        for (id, mask) in LocalMasks.measureForDelivery(in: frame) {
            XCTAssertEqual(mask.extent.integral, frame.extent, id)
        }
    }
}
