import XCTest
import CoreImage
@testable import KelvinCore

/// The detections-to-categories mapping, without Vision in the loop, plus one live pass to prove
/// the requests run at all. The corpus decides whether this read is good enough to replace the
/// model; these only pin that it says what its documentation says it says.
final class VisionPerceptionTests: XCTestCase {

    private func findings(faces: [CGRect] = [], people: [CGRect] = [],
                          animals: [(String, CGRect)] = [],
                          labels: [(String, Double)] = []) -> VisionPerceptionProvider.Findings {
        var f = VisionPerceptionProvider.Findings()
        f.faces = faces; f.people = people
        f.animals = animals.map { (label: $0.0, box: $0.1) }
        f.labels = labels.map { (id: $0.0, confidence: $0.1) }
        return f
    }

    func testAProminentFaceIsAPersonSubject() {
        let p = VisionPerceptionProvider.perception(from: findings(
            faces: [CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.2)]))
        XCTAssertTrue(p.subject.present)
        XCTAssertEqual(p.subject.type, .person)
        XCTAssertEqual(p.subject.count, .single)
        XCTAssertEqual(p.subject.placement, .center)
    }

    /// Walkers on a beach are part of the landscape. Calling them the subject would hand the engine
    /// a person lift for a frame whose subject is the sea stack behind them.
    func testSmallDistantPeopleAreNotTheSubject() {
        let p = VisionPerceptionProvider.perception(from: findings(
            people: [CGRect(x: 0.1, y: 0.1, width: 0.03, height: 0.08)],
            labels: [("beach", 0.9), ("rocks", 0.6)]))
        XCTAssertEqual(p.subject.type, .naturalFeature, "the landform is the subject")
    }

    func testAnAnimalWithoutPeopleIsAnAnimalSubject() {
        let p = VisionPerceptionProvider.perception(from: findings(
            animals: [("cat", CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.3))]))
        XCTAssertEqual(p.subject.type, .animal)
        XCTAssertEqual(p.subject.label, "cat")
        XCTAssertEqual(p.subject.placement, .lowerRight, "Vision's origin is lower-left")
    }

    func testABroadLandscapeHasNoSubject() {
        let p = VisionPerceptionProvider.perception(from: findings(
            labels: [("mountain", 0.9), ("forest", 0.8), ("sky", 0.7)]))
        XCTAssertFalse(p.subject.present, "a mountain range is a scene, not a subject")
    }

    /// Everything but the subject is the measured constant arm, unless the scene switch is on.
    func testEverythingButTheSubjectIsTheConstantRead() {
        let p = VisionPerceptionProvider.perception(from: findings(
            faces: [CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.2)],
            labels: [("interior_room", 0.9)]))
        XCTAssertEqual(p.scene, .other)
        XCTAssertEqual(p.lighting.condition, .indoorDaylight)
        XCTAssertEqual(p.problems, [], "D19: nothing reads problems, and Vision claims none")
        XCTAssertEqual(p.intent, .natural)

        let scened = VisionPerceptionProvider.perception(
            from: findings(labels: [("interior_room", 0.9)]),
            options: .init(sceneFromClassifier: true))
        XCTAssertEqual(scened.scene, .interior)
    }

    func testTheSummaryIsWordsTheAppCanShow() {
        let p = VisionPerceptionProvider.perception(from: findings(
            labels: [("outdoor", 0.95), ("sunset_sunrise", 0.8), ("beach", 0.7)]))
        XCTAssertEqual(p.notes, "Sunset sunrise · beach")
    }

    /// One real pass, to prove the four requests perform on a plain image without throwing and
    /// that a featureless frame reads as having no subject.
    func testALivePassOnAFlatFrameFindsNoSubject() {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 256, height: 256))
        let p = VisionPerceptionProvider.read(flat)
        XCTAssertFalse(p.subject.present)
    }
}
