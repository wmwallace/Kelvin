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

    /// Traceability back to the file on the card matters more than any description — and it is
    /// traceability to `_DSC6595`, not to some lowercased approximation of it.
    func testOriginalStemAlwaysComesFirst() {
        let name = ExportNaming.stem(for: raw, perception: perception(), look: "Soft")
        XCTAssertTrue(name.hasPrefix("_DSC6595"), "got \(name)")
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
        XCTAssertEqual(name, "_DSC6595_natural")
    }

    /// THE ORIGINAL STEM SURVIVES BYTE FOR BYTE. This file's documentation has always claimed it
    /// and the code has never done it: `sanitize` was applied to the stem too, so `_DSC6595` shipped
    /// as `dsc6595` and `IMG_1234` as `img-1234`. The case was gone and the underscore had become a
    /// hyphen, which breaks `ls _DSC6595*`, breaks matching an export back to its RAW by name, and —
    /// on Nikon bodies — discards the leading underscore that marks Adobe RGB.
    func testTheOriginalStemIsPreservedExactly() {
        for stem in ["_DSC6595", "IMG_1234", "DSC_0001", "P1000123", "Shoot 2 Final"] {
            let url = URL(fileURLWithPath: "/photos/\(stem).ARW")
            let name = ExportNaming.stem(for: url, perception: nil, look: nil, scheme: .original)
            XCTAssertEqual(name, stem, "the stem must arrive intact")
        }
    }

    /// Each scheme is a different promise about how much judgement ends up on disk.
    func testEverySchemeKeepsTheStemAndAddsOnlyWhatItPromises() {
        let p = perception()
        XCTAssertEqual(ExportNaming.stem(for: raw, perception: p, look: "Natural", scheme: .original),
                       "_DSC6595")
        XCTAssertEqual(ExportNaming.stem(for: raw, perception: p, look: "Natural", scheme: .edited),
                       "_DSC6595-Edit")
        XCTAssertEqual(ExportNaming.stem(for: raw, perception: p, look: "Natural", scheme: .look),
                       "_DSC6595_natural")
        // The descriptive scheme is the only one that writes a model judgement into a filename.
        let described = ExportNaming.stem(for: raw, perception: p, look: "Natural", scheme: .descriptive)
        XCTAssertTrue(described.hasPrefix("_DSC6595_"), described)
        XCTAssertGreaterThan(described.count, "_DSC6595_natural".count, described)
    }

    /// A stem cannot contain a path separator, and a leading dot would hide the export. Everything
    /// else a filesystem already accepted stays exactly as it was.
    func testOnlyTheTwoImpossibleCharactersAreTouched() {
        XCTAssertEqual(ExportNaming.preserved("a/b"), "a-b")
        XCTAssertEqual(ExportNaming.preserved(".hidden"), "hidden")
        XCTAssertEqual(ExportNaming.preserved("Perfectly Fine (2)"), "Perfectly Fine (2)")
    }

    /// WE sanitise what WE add. We do not sanitise what the photographer named.
    ///
    /// This test used to assert the opposite, and the opposite is presumptuous: `My Photo (final)
    /// #2.jpg` already exists on their disk with spaces and parentheses, macOS accepted it, and
    /// every other copy of that frame is called the same thing. Rewriting it to `my-photo-final-2`
    /// breaks the one property the whole scheme is built on — that an export can be matched back to
    /// its original. Tokens Kelvin appends are a different matter: those are ours to format, and
    /// they stay lowercase and hyphenated.
    func testSanitisesTokensButNeverTheUsersOwnName() {
        let url = URL(fileURLWithPath: "/photos/My Photo (final) #2.jpg")
        let name = ExportNaming.stem(for: url, perception: nil, look: "Red filter")
        XCTAssertTrue(name.hasPrefix("My Photo (final) #2"), "the photographer's name survives: \(name)")
        XCTAssertTrue(name.contains("red-filter"), "our token is formatted: \(name)")
        // The two a path component genuinely cannot carry are still handled.
        XCTAssertFalse(ExportNaming.preserved("a/b").contains("/"))
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


    // MARK: The photographer's own label

    /// The one token here that is not a model judgement. Every other token is hedged — dropped when
    /// the read is unsure, omitted when uninformative — because a wrong filename goes to a client.
    /// This one was typed by a person, so it is never dropped and never second-guessed.
    func testTheLabelAppearsInEveryScheme() {
        for scheme in ExportNaming.Scheme.allCases {
            let name = ExportNaming.stem(for: raw, perception: perception(), look: "Soft",
                                         scheme: scheme, label: "Lake Como")
            XCTAssertTrue(name.contains("lake-como"),
                          "\(scheme.rawValue) dropped the label: \(name)")
        }
    }

    /// AFTER the stem, never before it. A prefix would sort nicely in a folder and break `ls
    /// _DSC6595*`, which is how an export maps back to the RAW on the card — rule 1, and the reason
    /// this codebase already had to undo a sanitised stem once.
    func testTheLabelNeverDisplacesTheStem() {
        for scheme in ExportNaming.Scheme.allCases {
            let name = ExportNaming.stem(for: raw, perception: perception(), look: nil,
                                         scheme: scheme, label: "Tuscany")
            XCTAssertTrue(name.hasPrefix("_DSC6595"),
                          "\(scheme.rawValue) put the label in front of the stem: \(name)")
        }
    }

    /// Typed text is not a filename. Spaces, commas and case all have to go somewhere predictable,
    /// and the panel shows this back before anything is written.
    func testATypedLabelBecomesAFilenameToken() {
        XCTAssertEqual(ExportNaming.labelToken("Lake Como, Day 2"), "lake-como-day-2")
        XCTAssertEqual(ExportNaming.labelToken("  Smith / Jones  "), "smith-jones")
        XCTAssertEqual(ExportNaming.labelToken(""), "")
        XCTAssertEqual(ExportNaming.labelToken("   "), "")
    }

    /// A pasted paragraph must not crowd out the stem, and truncation lands on a word boundary so
    /// the remainder still reads.
    func testAnOverlongLabelIsCutOnAWordBoundary() {
        let token = ExportNaming.labelToken(
            "the annual midsummer wedding of alexandra and christopher at the old barn")
        XCTAssertLessThanOrEqual(token.count, 40)
        XCTAssertFalse(token.hasSuffix("-"), "truncation left a dangling separator: \(token)")
        XCTAssertTrue(token.hasPrefix("the-annual-midsummer"), "got \(token)")
    }

    /// Rule 3 still holds for the label: a shoot folder whose files are already named for the place
    /// should not say it twice.
    func testALabelTheStemAlreadyCarriesIsNotRepeated() {
        let already = URL(fileURLWithPath: "/photos/tuscany_0042.ARW")
        let name = ExportNaming.stem(for: already, perception: nil, look: nil,
                                     scheme: .original, label: "Tuscany")
        XCTAssertEqual(name, "tuscany_0042")
    }

    /// No label is exactly the old behaviour — this feature must be invisible until used.
    func testNoLabelChangesNothing() {
        for scheme in ExportNaming.Scheme.allCases {
            let without = ExportNaming.stem(for: raw, perception: perception(), look: "Soft",
                                            scheme: scheme)
            for empty in [nil, "", "   "] as [String?] {
                XCTAssertEqual(
                    ExportNaming.stem(for: raw, perception: perception(), look: "Soft",
                                      scheme: scheme, label: empty),
                    without, "\(scheme.rawValue) changed when given an empty label")
            }
        }
    }
}
