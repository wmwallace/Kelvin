import XCTest
import CoreImage
@testable import KelvinCore

/// D28's pieces that can be tested without an HDR screen or a RAW in the repository.
final class HDRDeliveryTests: XCTestCase {

    /// Headroom comes from a RAW decode; anything else has none to give and must say so rather
    /// than invent a gain map.
    func testANonRAWFileHasNoHeadroom() {
        XCTAssertNil(HDRDelivery.headroom(for: URL(fileURLWithPath: "/tmp/photo.jpg")))
    }

    /// The companion multiplies the edit by the gain and changes nothing where the gain is 1.
    func testTheCompanionLiftsOnlyWhereThereIsGain() {
        let extent = CGRect(x: 0, y: 0, width: 4, height: 4)
        let edit = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let unity = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        // A gain above 1 built with a matrix: `CIColor` clamps its components to 1.
        let double = unity.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 2, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 2, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 2, w: 0)])
        func value(_ i: CIImage) -> Float {
            var px = [Float](repeating: 0, count: 4)
            CIContext(options: [.workingColorSpace: NSNull()]).render(
                i, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBAf, colorSpace: nil)
            return px[0]
        }
        XCTAssertEqual(value(HDRDelivery.hdrCompanion(ofEdit: edit, headroom: unity)), 0.5, accuracy: 0.01)
        XCTAssertEqual(value(HDRDelivery.hdrCompanion(ofEdit: edit, headroom: double)), 1.0, accuracy: 0.01)
    }

    /// The writer carries a companion as a gain map in a HEIC, and nowhere else.
    func testAHEICWrittenWithACompanionCarriesAGainMap() throws {
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let sdr = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8)).cropped(to: extent)
        let hdr = sdr.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 3, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 3, w: 0)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let heic = dir.appendingPathComponent("a.heic"), jpeg = dir.appendingPathComponent("a.jpg")
        try ImageWriter.write(sdr, to: heic, format: .heic(quality: 0.9), colorSpace: .displayP3, hdr: hdr)
        try ImageWriter.write(sdr, to: jpeg, format: .jpeg(quality: 0.9), hdr: hdr)
        XCTAssertTrue(HDRDelivery.hasGainMap(heic))
        XCTAssertFalse(HDRDelivery.hasGainMap(jpeg), "a JPEG export stays SDR")
    }
}
