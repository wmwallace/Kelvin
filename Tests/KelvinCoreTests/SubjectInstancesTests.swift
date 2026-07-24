import XCTest
import CoreImage
@testable import KelvinCore

/// Per-subject masks. End-to-end detection needs real photographs, which aren't in the repo, so
/// it is verified by hand against the owner's library (two people on a porch swing separate into
/// Person 1 / Person 2; a cat and its owner into Person + Cat; a car into "Suv"). What is pinned
/// here is the logic around it, which is where the bugs were.
final class SubjectInstancesTests: XCTestCase {

    private func instance(_ label: String, _ kind: SubjectInstances.Kind,
                          coverage: Double = 0.1) -> SubjectInstances.Instance {
        SubjectInstances.Instance(
            id: label, label: label, kind: kind,
            mask: CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)),
            coverage: coverage, boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// A lone subject keeps its bare noun. "Person 1" when there is exactly one person in the
    /// frame reads as a bug, not as information.
    func testASingleSubjectIsNotNumbered() {
        let out = SubjectInstances.numbered([instance("Person", .person)])
        XCTAssertEqual(out.map(\.label), ["Person"])
    }

    /// Two of a kind DO get numbers, or the list has two identical rows and picking one is guesswork.
    func testRepeatedLabelsAreNumberedInOrder() {
        let out = SubjectInstances.numbered([
            instance("Person", .person), instance("Person", .person), instance("Cat", .animal)
        ])
        XCTAssertEqual(out.map(\.label), ["Person 1", "Person 2", "Cat"])
    }

    /// Numbering is per-label: two people and two cats number independently.
    func testEachLabelNumbersIndependently() {
        let out = SubjectInstances.numbered([
            instance("Person", .person), instance("Person", .person),
            instance("Cat", .animal), instance("Cat", .animal)
        ])
        XCTAssertEqual(out.map(\.label), ["Person 1", "Person 2", "Cat 1", "Cat 2"])
    }

    /// An image with nothing in it must return no instances rather than a full-frame "subject" —
    /// the empty answer is a real answer, and the UI shows an empty mask list for it.
    func testBlankImageYieldsNoInstances() {
        let blank = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        XCTAssertTrue(SubjectInstances.detect(in: blank).isEmpty)
    }

    /// Guards against a crash on a degenerate extent rather than any particular result.
    func testInfiniteExtentIsHandled() {
        XCTAssertTrue(SubjectInstances.detect(in: CIImage(color: .white)).isEmpty)
    }
}
