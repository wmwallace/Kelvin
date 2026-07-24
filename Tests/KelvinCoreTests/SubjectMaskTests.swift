import XCTest
import CoreImage
@testable import KelvinCore

/// Vision hands back a valid but ENTIRELY BLACK mask when it finds no person, rather than no
/// result. Treating that as a mask made every subject tool believe it had a subject: it then did
/// nothing (the mask is empty) and the UI couldn't warn that nobody was in the frame.
final class SubjectMaskTests: XCTestCase {

    func testEmptyMaskIsNotASubject() {
        let black = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertLessThan(SubjectMask.coverage(of: black), SubjectMask.minimumCoverage,
                          "an all-black mask selects nothing and must not count as a subject")
    }

    func testFullMaskIsASubject() {
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertGreaterThan(SubjectMask.coverage(of: white), 0.9)
    }

    /// A few stray bright pixels are noise, not a subject worth building an edit on.
    func testSpeckleIsNotASubject() {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let n = 64, bpr = n * 4
        var px = [UInt8](repeating: 0, count: bpr * n)
        for i in stride(from: 0, to: px.count, by: 4) { px[i + 3] = 255 }
        for k in 0..<6 {                      // 6 lit pixels out of 4096
            let i = (k * 137) * 4
            px[i] = 255; px[i + 1] = 255; px[i + 2] = 255
        }
        let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: bpr,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let speckle = CIImage(cgImage: ctx.makeImage()!)
        XCTAssertLessThan(SubjectMask.coverage(of: speckle), SubjectMask.minimumCoverage)
    }

    /// No person and no distinct foreground → nothing, rather than an empty mask pretending.
    func testSyntheticGradientHasNoSubject() {
        XCTAssertNil(SubjectMask.subject(in: TestSupport.makeGradientImage(width: 96, height: 96)))
    }
}
