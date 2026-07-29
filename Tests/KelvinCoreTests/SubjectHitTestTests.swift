import XCTest
import CoreImage
@testable import KelvinCore

/// Clicking a thing on the photograph to mask it.
///
/// The rules that matter are the coordinate conventions — the click arrives top-left origin and
/// Vision's boxes are bottom-left, so a flip in the wrong place selects the object mirrored above
/// or below the one you pointed at — and that a miss is nil rather than a guess.
final class SubjectHitTestTests: XCTestCase {

    private let extent = CGRect(x: 0, y: 0, width: 200, height: 100)

    /// A mask that is white inside `rect` (in CI coordinates, bottom-left origin) and black outside.
    private func mask(_ rect: CGRect) -> CIImage {
        CIImage(color: .white).cropped(to: rect)
            .composited(over: CIImage(color: .black).cropped(to: extent))
    }

    /// `box` is Vision-normalised (bottom-left). `ciRect` is the matching pixel rect.
    private func instance(_ id: String, ciRect: CGRect, coverage: Double) -> SubjectInstances.Instance {
        let box = CGRect(x: ciRect.minX / extent.width, y: ciRect.minY / extent.height,
                         width: ciRect.width / extent.width, height: ciRect.height / extent.height)
        return SubjectInstances.Instance(id: id, label: id, kind: .object, mask: mask(ciRect),
                                         coverage: coverage, boundingBox: box)
    }

    /// White over the LEFT half, TOP half of the picture. In CI coordinates the top half is the
    /// upper y range; in click coordinates it is y < 0.5. Getting this backwards is the bug this
    /// test exists to catch.
    private var topLeft: SubjectInstances.Instance {
        instance("topLeft", ciRect: CGRect(x: 0, y: 50, width: 100, height: 50), coverage: 0.25)
    }

    func testAClickInsideTheSubjectSelectsIt() {
        let hit = SubjectInstances.instance(at: CGPoint(x: 0.25, y: 0.25), in: [topLeft])
        XCTAssertEqual(hit?.id, "topLeft")
    }

    /// The flip, stated as a test: the same x, mirrored y, is the bottom half and must miss.
    func testTheClickIsTopLeftOriginNotVisionsBottomLeft() {
        XCTAssertNil(SubjectInstances.instance(at: CGPoint(x: 0.25, y: 0.75), in: [topLeft]),
                     "the y flip is wrong — clicking below the subject selected it")
    }

    func testAClickOnNothingIsAMissNotAGuess() {
        XCTAssertNil(SubjectInstances.instance(at: CGPoint(x: 0.9, y: 0.9), in: [topLeft]),
                     "a click on empty background must return nil so the UI can say so")
    }

    func testNoInstancesIsAMiss() {
        XCTAssertNil(SubjectInstances.instance(at: CGPoint(x: 0.5, y: 0.5), in: []))
    }

    func testAClickOutsideTheFrameIsAMiss() {
        XCTAssertNil(SubjectInstances.instance(at: CGPoint(x: 1.4, y: 0.2), in: [topLeft]))
        XCTAssertNil(SubjectInstances.instance(at: CGPoint(x: 0.2, y: -0.3), in: [topLeft]))
    }

    /// **The tightest thing wins.** A person standing against a hillside sits inside both masks, and
    /// clicking the person must not hand back the hillside.
    func testTheTightestOverlappingSubjectWins() {
        let big = instance("hillside", ciRect: CGRect(x: 0, y: 0, width: 200, height: 100), coverage: 0.9)
        let small = instance("person", ciRect: CGRect(x: 80, y: 20, width: 30, height: 60), coverage: 0.09)
        let hit = SubjectInstances.instance(at: CGPoint(x: 0.475, y: 0.5), in: [big, small])
        XCTAssertEqual(hit?.id, "person", "clicking the smaller subject selected the one behind it")
        // And a click that only the big one covers still finds the big one.
        XCTAssertEqual(SubjectInstances.instance(at: CGPoint(x: 0.05, y: 0.5), in: [big, small])?.id,
                       "hillside")
    }

    /// A mask's feathered edge should still select — clicking one pixel inside a silhouette is a
    /// hit, not a near miss.
    func testAlphaIsReadFromTheMaskNotTheBoundingBox() {
        // Box covers the whole frame; the mask covers only the left quarter. A click on the right
        // is inside the box and outside the mask, and must miss.
        let m = mask(CGRect(x: 0, y: 0, width: 50, height: 100))
        let wideBox = SubjectInstances.Instance(
            id: "sliver", label: "sliver", kind: .object, mask: m, coverage: 0.25,
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(SubjectInstances.instance(at: CGPoint(x: 0.1, y: 0.5), in: [wideBox])?.id, "sliver")
        XCTAssertNil(SubjectInstances.instance(at: CGPoint(x: 0.8, y: 0.5), in: [wideBox]),
                     "the bounding box was trusted instead of the mask")
    }
}
