import XCTest
@testable import KelvinCore

/// A word in front and a word at the end — the two positions a delivery folder actually needs.
///
/// The prefix breaks the "original stem always comes first" default on purpose, and only when
/// someone types one: sort-by-client needs the client in front, and a typed instruction outranks a
/// default. Everything else in a generated name is a model judgement; these two are not.
final class ExportAffixTests: XCTestCase {

    private let photo = URL(fileURLWithPath: "/shoot/_DSC6595.ARW")

    private func stem(scheme: ExportNaming.Scheme = .original,
                      prefix: String? = nil, suffix: String? = nil,
                      look: String? = nil) -> String {
        ExportNaming.stem(for: photo, perception: nil, look: look,
                          scheme: scheme, label: nil, prefix: prefix, suffix: suffix)
    }

    // MARK: Nothing typed changes nothing

    /// The default must be exactly what it was, or every existing workflow's filenames move.
    func testNoAffixesLeavesTheNameUntouched() {
        XCTAssertEqual(stem(), "_DSC6595")
        XCTAssertEqual(stem(scheme: .edited), "_DSC6595-Edit")
        XCTAssertEqual(stem(scheme: .look, look: "Natural"), "_DSC6595_natural")
    }

    func testEmptyStringsAreTreatedAsNotTyped() {
        XCTAssertEqual(stem(prefix: "", suffix: ""), "_DSC6595")
    }

    // MARK: Position

    func testThePrefixComesBeforeTheOriginalStem() {
        XCTAssertEqual(stem(prefix: "Acme"), "acme__DSC6595")
    }

    func testTheSuffixComesLast() {
        XCTAssertEqual(stem(suffix: "v2"), "_DSC6595_v2")
    }

    func testBothTogetherBracketTheName() {
        XCTAssertEqual(stem(prefix: "Acme", suffix: "v2"), "acme__DSC6595_v2")
    }

    /// Rule 1 still holds where it matters: the stem survives VERBATIM, so it is still greppable —
    /// `ls *_DSC6595*` rather than `ls _DSC6595*`.
    func testThePrefixDoesNotDamageTheOriginalStem() {
        XCTAssertTrue(stem(prefix: "Acme Photography").contains("_DSC6595"))
    }

    /// The suffix goes after every generated token, not into the middle of them.
    func testTheSuffixFollowsTheDescriptiveTokens() {
        let p = Perception(
            scene: .landscape,
            subject: Perception.Subject(present: false, type: .none, count: .none,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .goldenHour, direction: .back,
                                          contrastRange: .normal),
            problems: [], intent: .natural, confidence: 0.9)
        let name = ExportNaming.stem(for: photo, perception: p, look: "Natural",
                                     scheme: .descriptive, label: nil,
                                     prefix: nil, suffix: "v2")
        XCTAssertTrue(name.hasSuffix("_v2"), "suffix landed mid-name: \(name)")
        XCTAssertTrue(name.contains("landscape"), "the descriptors were lost: \(name)")
    }

    // MARK: Sanitising

    /// Same treatment as the label: someone typing "Acme Photography, Ltd." should find out what it
    /// becomes while they type, not after four hundred files exist.
    func testAffixesAreSanitisedIntoFilenameTokens() {
        XCTAssertEqual(stem(prefix: "Acme Photography"), "acme-photography__DSC6595")
        XCTAssertEqual(stem(suffix: "Round 2"), "_DSC6595_round-2")
    }

    func testAnAffixOfPurePunctuationIsDroppedRatherThanLeavingASeparator() {
        XCTAssertEqual(stem(prefix: "!!!"), "_DSC6595")
        XCTAssertEqual(stem(suffix: "???"), "_DSC6595")
    }

    // MARK: The suffix is never the token that gets dropped

    /// Long names are trimmed from the end, dropping the most incidental token first. A typed word
    /// is not incidental — it must survive a trim that discards the model's guesses.
    func testAVeryLongNameStillKeepsTheTypedSuffix() {
        let p = Perception(
            scene: .landscape,
            subject: Perception.Subject(present: true, type: .person, count: .single,
                                        placement: .center),
            lighting: Perception.Lighting(condition: .goldenHour, direction: .back,
                                          contrastRange: .high),
            problems: [], intent: .natural, confidence: 0.9)
        let long = URL(fileURLWithPath: "/shoot/" + String(repeating: "a", count: 90) + ".ARW")
        let name = ExportNaming.stem(for: long, perception: p, look: "Dramatic",
                                     scheme: .descriptive, label: "Lake Como",
                                     prefix: nil, suffix: "final")
        XCTAssertTrue(name.hasSuffix("_final"),
                      "the trimmer dropped a word somebody typed: \(name)")
    }

    // MARK: No duplication

    /// Rule 3 — no duplication — applies to GENERATED tokens, and the prefix now seeds it: a look
    /// or descriptor that merely repeats the typed prefix is dropped.
    func testAGeneratedTokenIsNotRepeatedWhenThePrefixAlreadySaysIt() {
        let name = ExportNaming.stem(for: photo, perception: nil, look: "beach",
                                     scheme: .look, label: nil, prefix: "beach", suffix: nil)
        XCTAssertEqual(name, "beach__DSC6595", "the look token repeated the prefix: \(name)")
    }

    /// But a TYPED word is never dropped or second-guessed, even when it duplicates the stem —
    /// the same rule that protects the label. `beach.ARW` with a "beach" prefix really does become
    /// `beach_beach`, because the alternative is the app silently ignoring an instruction, and a
    /// slightly redundant name is a much smaller surprise than a prefix that does nothing.
    func testATypedPrefixSurvivesEvenWhenTheStemAlreadySaysIt() {
        let name = ExportNaming.stem(for: URL(fileURLWithPath: "/s/beach.ARW"),
                                     perception: nil, look: nil,
                                     scheme: .original, label: nil, prefix: "beach", suffix: nil)
        XCTAssertEqual(name, "beach_beach")
    }

    // MARK: The scheme list the panel indexes into

    /// The export panel builds its pop-up by iterating `allCases` and selects by `firstIndex`, so
    /// the order and the labels are load-bearing UI, not just data. Pinned because a reordering
    /// would silently select the wrong scheme rather than fail to compile.
    func testTheSchemeOrderAndLabelsAreStable() {
        XCTAssertEqual(ExportNaming.Scheme.allCases.map(\.rawValue),
                       ["original", "edited", "look", "descriptive"])
        XCTAssertEqual(ExportNaming.Scheme.allCases.map(\.label),
                       ["Original name", "Original + “-Edit”", "Original + look",
                        "Describe the photo"])
    }

    /// With no perception, `descriptive` has nothing to describe and collapses onto `look` — worth
    /// pinning because it makes the two schemes indistinguishable in a preview, which is confusing
    /// rather than wrong, and someone will otherwise read it as a bug.
    func testDescriptiveFallsBackToLookWhenNothingWasPerceived() {
        XCTAssertEqual(stem(scheme: .descriptive, look: "Natural"),
                       stem(scheme: .look, look: "Natural"))
    }
}
