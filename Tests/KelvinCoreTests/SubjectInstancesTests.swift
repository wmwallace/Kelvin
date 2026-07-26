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

    /// An instance at a given position, for the re-identification tests. The mask is a distinct
    /// solid so a mis-match is visible as the wrong bitmap, not just a wrong count.
    private func placed(_ id: String, _ kind: SubjectInstances.Kind, _ box: CGRect,
                        shade: CGFloat = 1) -> SubjectInstances.Instance {
        SubjectInstances.Instance(
            id: id, label: id, kind: kind,
            mask: CIImage(color: CIColor(red: shade, green: shade, blue: shade))
                .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)),
            coverage: Double(box.width * box.height), boundingBox: box)
    }

    /// The grey level of a returned mask, identifying WHICH mask came back. -1 when there is no
    /// mask at all, so a missing bitmap fails against the expected shade rather than passing as a
    /// vacuous nil comparison.
    private func shade(of image: CIImage?) -> Double {
        guard let image, let data = try? ImageWriter.rgba8Sampled(image, width: 2, height: 2) else {
            return -1
        }
        return Double(data[0]) / 255
    }

    // MARK: - Re-identification
    //
    // Instance ids are Vision's per-pass indices, stable within a pass and meaningless between
    // two. Export runs the segmentation again at full resolution, so a recipe saying "brighten
    // person2" could brighten a different person in the exported file while looking right on
    // screen. These pin the matching that stops that.

    func testMasksAreRekeyedOntoTheOriginalIds() {
        let left = CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.6)
        let right = CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.6)
        let references = [SubjectInstances.Reference(id: "person0", kind: .person, boundingBox: left),
                          SubjectInstances.Reference(id: "person1", kind: .person, boundingBox: right)]
        // The full-res pass finds the same two people, indexed the other way round and shifted a
        // little, as a re-run at another resolution genuinely does.
        let fresh = [placed("person0", .person, right.offsetBy(dx: 0.01, dy: 0), shade: 0.25),
                     placed("person1", .person, left.offsetBy(dx: -0.01, dy: 0.01), shade: 0.75)]

        let out = SubjectInstances.reidentify(fresh, as: references)
        XCTAssertEqual(out.unmatched, [])
        // person0 is the one on the LEFT, whatever this pass chose to call it.
        XCTAssertEqual(shade(of: out.bitmaps["person0"]), 0.75, accuracy: 0.02)
        XCTAssertEqual(shade(of: out.bitmaps["person1"]), 0.25, accuracy: 0.02)
    }

    func testASubjectThatIsNoLongerFoundIsReportedNotDroppedSilently() {
        let left = CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.6)
        let right = CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.6)
        let references = [SubjectInstances.Reference(id: "person0", kind: .person, boundingBox: left),
                          SubjectInstances.Reference(id: "person1", kind: .person, boundingBox: right)]
        let out = SubjectInstances.reidentify([placed("a", .person, left)], as: references)

        XCTAssertEqual(Set(out.bitmaps.keys), ["person0"])
        // Rendering with a missing mask drops the local edit without a word, so the caller has to
        // be told rather than left to notice.
        XCTAssertEqual(out.unmatched, ["person1"])
    }

    func testAReclassifiedSubjectStillMatches() {
        // The person segmentation is a threshold decision and can flip between a 1200px proxy and
        // a 60 MP frame. Losing the edit because someone was re-classified is worse than matching
        // them across the flip — the geometry is the stronger evidence.
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.5)
        let references = [SubjectInstances.Reference(id: "person0", kind: .person, boundingBox: box)]
        let out = SubjectInstances.reidentify([placed("instance3", .object, box)], as: references)
        XCTAssertEqual(Set(out.bitmaps.keys), ["person0"])
        XCTAssertEqual(out.unmatched, [])
    }

    func testKindOnlyBreaksTiesItDoesNotBeatGeometry() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        let references = [SubjectInstances.Reference(id: "person0", kind: .person, boundingBox: box)]
        // A same-kind candidate that barely overlaps must not beat a different-kind one sitting
        // exactly where the subject was.
        let out = SubjectInstances.reidentify(
            [placed("far", .person, CGRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), shade: 0.25),
             placed("here", .object, box, shade: 0.75)],
            as: references)
        XCTAssertEqual(shade(of: out.bitmaps["person0"]), 0.75, accuracy: 0.02)
    }

    func testTwoReferencesCannotClaimTheSameMask() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        let references = [SubjectInstances.Reference(id: "a", kind: .person, boundingBox: box),
                          SubjectInstances.Reference(id: "b", kind: .person, boundingBox: box)]
        let out = SubjectInstances.reidentify([placed("only", .person, box)], as: references)
        XCTAssertEqual(out.bitmaps.count, 1, "one mask cannot serve two subjects")
        XCTAssertEqual(out.unmatched.count, 1)
    }

    func testDistantSubjectsDoNotMatchAtAll() {
        let references = [SubjectInstances.Reference(
            id: "person0", kind: .person,
            boundingBox: CGRect(x: 0.0, y: 0.0, width: 0.25, height: 0.25))]
        let out = SubjectInstances.reidentify(
            [placed("elsewhere", .person, CGRect(x: 0.7, y: 0.7, width: 0.25, height: 0.25))],
            as: references)
        XCTAssertTrue(out.bitmaps.isEmpty, "a subject across the frame is not the same subject")
        XCTAssertEqual(out.unmatched, ["person0"])
    }

    func testIntersectionOverUnionIsSymmetricAndBounded() {
        let a = CGRect(x: 0, y: 0, width: 0.4, height: 0.4)
        let b = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        XCTAssertEqual(SubjectInstances.intersectionOverUnion(a, b),
                       SubjectInstances.intersectionOverUnion(b, a), accuracy: 1e-12)
        XCTAssertEqual(SubjectInstances.intersectionOverUnion(a, a), 1.0, accuracy: 1e-12)
        XCTAssertEqual(SubjectInstances.intersectionOverUnion(a, CGRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)), 0)
        // Intersection 0.2×0.2 = 0.04; union 0.16 + 0.16 − 0.04 = 0.28.
        XCTAssertEqual(SubjectInstances.intersectionOverUnion(a, b), 0.04 / 0.28, accuracy: 1e-9)
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

    // MARK: - Which of the equally-confident labels gets shown

    /// Measured on a real frame: Vision returns a whole taxonomy for one squirrel, every level at
    /// the same confidence. Picking the first meant the row read "Animal" — true, and useless for
    /// telling one mask from another.
    func testPrefersTheMostSpecificOfEquallyConfidentLabels() {
        let observed: [(String, Double)] = [
            ("animal", 0.991), ("mammal", 0.991), ("rodent", 0.991), ("squirrel", 0.991)
        ]
        XCTAssertEqual(SubjectInstances.preferredLabel(from: observed), "Squirrel")
    }

    /// Specificity is a tie-break and nothing more. A less confident but more specific guess must
    /// never win, or one bad frame renames a subject to something it plainly is not.
    func testConfidenceStillBeatsSpecificity() {
        let candidates: [(String, Double)] = [("car", 0.62), ("sportscar", 0.31)]
        XCTAssertEqual(SubjectInstances.preferredLabel(from: candidates), "Car")
    }

    /// Float confidences that print the same can differ in the last bit; near-ties count as ties.
    func testNearIdenticalConfidencesCountAsTied() {
        let candidates: [(String, Double)] = [("bird", 0.8001), ("owl", 0.8)]
        XCTAssertEqual(SubjectInstances.preferredLabel(from: candidates), "Owl")
    }

    /// A guess too weak to show is no guess. The row falls back to "Subject" rather than inventing.
    func testNothingConfidentEnoughIsNotNamed() {
        XCTAssertNil(SubjectInstances.preferredLabel(from: [("flower", 0.20), ("lily", 0.19)]))
        XCTAssertNil(SubjectInstances.preferredLabel(from: []))
    }

    /// Identifiers are lowercase and sometimes compound.
    func testCompoundIdentifiersAreReadable() {
        XCTAssertEqual(SubjectInstances.preferredLabel(from: [("sea_turtle", 0.9)]), "Sea turtle")
    }
}
