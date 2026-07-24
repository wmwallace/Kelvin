import XCTest
@testable import KelvinCore

final class ExportNamingTests: XCTestCase {

    private func perception(scene: Scene = .landscape,
                            condition: Condition = .goldenHour,
                            subject: SubjectType = .none) -> Perception {
        Perception(
            scene: scene,
            subject: Perception.Subject(present: subject != .none, type: subject,
                                        count: subject == .none ? .none : .single, placement: .center),
            lighting: Perception.Lighting(condition: condition, direction: .back, contrastRange: .high),
            problems: [], intent: .natural, confidence: 0.9)
    }

    private let raw = URL(fileURLWithPath: "/photos/_DSC6595.ARW")

    /// Traceability back to the file on the card matters more than any description.
    func testOriginalStemAlwaysComesFirst() {
        let name = ExportNaming.stem(for: raw, perception: perception(), look: "Soft")
        XCTAssertTrue(name.hasPrefix("dsc6595"), "got \(name)")
    }

    func testDescribesSceneLightAndLook() {
        let name = ExportNaming.stem(for: raw, perception: perception(subject: .person), look: "Soft")
        XCTAssertTrue(name.contains("landscape"), name)
        XCTAssertTrue(name.contains("golden-hour"), name)
        XCTAssertTrue(name.contains("person"), name)
        XCTAssertTrue(name.contains("soft"), name)
    }

    /// A token that appears on every file is noise, so the model's fallback lighting is omitted.
    func testOmitsUninformativeFallbackLighting() {
        let name = ExportNaming.stem(for: raw, perception: perception(condition: .indoorDaylight), look: nil)
        XCTAssertFalse(name.contains("indoor"), name)
    }

    func testDoesNotRepeatWhatTheStemAlreadySays() {
        let url = URL(fileURLWithPath: "/photos/sunset-landscape.jpg")
        let name = ExportNaming.stem(for: url, perception: perception(), look: nil)
        XCTAssertEqual(name.components(separatedBy: "landscape").count - 1, 1,
                       "'landscape' should appear once, not twice: \(name)")
    }

    func testWorksWithNoPerception() {
        let name = ExportNaming.stem(for: raw, perception: nil, look: "Natural")
        XCTAssertEqual(name, "dsc6595_natural")
    }

    /// Filenames have to survive every filesystem and sync client.
    func testSanitisesAwkwardCharacters() {
        let url = URL(fileURLWithPath: "/photos/My Photo (final) #2.jpg")
        let name = ExportNaming.stem(for: url, perception: nil, look: "Red filter")
        XCTAssertFalse(name.contains(" "), name)
        XCTAssertFalse(name.contains("/"), name)
        XCTAssertFalse(name.contains("#"), name)
        XCTAssertFalse(name.contains("("), name)
        XCTAssertTrue(name.contains("red-filter"), name)
    }

    func testStaysAReasonableLength() {
        let long = URL(fileURLWithPath: "/photos/" + String(repeating: "a", count: 120) + ".jpg")
        let name = ExportNaming.stem(for: long, perception: perception(subject: .person), look: "Dramatic")
        XCTAssertLessThanOrEqual(name.count, 130, "should trim descriptors, not run away: \(name.count)")
    }

    func testIsDeterministic() {
        let a = ExportNaming.stem(for: raw, perception: perception(subject: .person), look: "Vivid")
        let b = ExportNaming.stem(for: raw, perception: perception(subject: .person), look: "Vivid")
        XCTAssertEqual(a, b)
    }

    /// A batch drops many files in one folder; silently overwriting one is unforgivable.
    func testUniqueURLAvoidsOverwriting() {
        let dir = URL(fileURLWithPath: "/out")
        var taken: Set<String> = ["/out/photo.jpg", "/out/photo-2.jpg"]
        let url = ExportNaming.uniqueURL(in: dir, stem: "photo", ext: "jpg") { taken.contains($0.path) }
        XCTAssertEqual(url.lastPathComponent, "photo-3.jpg")
        taken.insert(url.path)
        XCTAssertEqual(
            ExportNaming.uniqueURL(in: dir, stem: "other", ext: "jpg") { taken.contains($0.path) }
                .lastPathComponent, "other.jpg")
    }
}
