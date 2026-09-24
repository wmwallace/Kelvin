import XCTest
@testable import KelvinCore

final class CandidateDescriptionTests: XCTestCase {

    private func recipe(_ id: String, _ edit: (inout GlobalAdjustments) -> Void) -> Recipe {
        var r = Recipe.neutral
        r.id = id
        edit(&r.global)
        return r
    }

    func testTheFaithfulOneDescribesItselfAsSuch() {
        let natural = recipe("natural") { _ in }
        XCTAssertEqual(CandidateDescription.sentence(for: natural, relativeTo: natural),
                       "True to the scene")
    }

    func testTheStrongestChangeIsSaidFirst() {
        let natural = recipe("natural") { _ in }
        let soft = recipe("soft") { g in g.contrast = -30; g.vibrance = -9 }
        XCTAssertEqual(CandidateDescription.phrases(for: soft, relativeTo: natural),
                       ["softer contrast", "quieter colour"])
        XCTAssertEqual(CandidateDescription.sentence(for: soft, relativeTo: natural),
                       "Softer contrast, quieter colour")
    }

    /// Warm is a NEGATIVE Kelvin shift on this engine's axis. Getting the direction backwards would
    /// tell a VoiceOver user the opposite of what the picture does.
    func testALowerTemperatureReadsAsWarmer() {
        let natural = recipe("natural") { g in g.temperatureK = 5600 }
        let warm = recipe("warm") { g in g.temperatureK = 5180 }
        XCTAssertEqual(CandidateDescription.phrases(for: warm, relativeTo: natural), ["warmer"])
    }

    func testSmallDifferencesAreNotClaimed() {
        let natural = recipe("natural") { _ in }
        let nearly = recipe("vivid") { g in g.contrast = 3; g.exposureEV = 0.05 }
        XCTAssertEqual(CandidateDescription.sentence(for: nearly, relativeTo: natural),
                       "Close to Natural")
    }

    func testMonoIsSaidPlainly() {
        let natural = recipe("natural") { _ in }
        var mono = recipe("mono") { g in g.contrast = 20 }
        mono.blackAndWhite = BlackAndWhiteMix(bands: [:])
        XCTAssertEqual(CandidateDescription.phrases(for: mono, relativeTo: natural), ["Black and white"])
    }

    // MARK: - Where a look acts

    private func sky(_ adjustments: [String: Double], opacity: Double = 1) -> Mask {
        Mask(id: "sky", type: "sky", source: "segmentation", invert: false, feather: 16,
             opacity: opacity, adjustments: adjustments)
    }

    private func subjectLift(_ ev: Double) -> Mask {
        // The engine's own proportions: exposure 0.7× and shadows 45× the lift.
        Mask(id: "subject", type: "subject", source: "segmentation", invert: false, feather: 6,
             opacity: 1, adjustments: ["exposure_ev": ev * 0.7, "shadows": (ev * 45).rounded()])
    }

    private func person(_ count: SubjectCount, label: String? = nil) -> Perception.Subject {
        .init(present: true, type: .person, count: count, placement: .center, label: label)
    }

    /// Dramatic's grad-ND on a landscape: the globals barely differ, the sky is the whole look,
    /// and before regions were described the caption said "Close to Natural".
    func testALocalOnlyDifferenceIsNamedByRegion() {
        var natural = recipe("natural") { _ in }
        natural.masks = [sky(["saturation": 12])]
        var dramatic = recipe("dramatic") { _ in }
        dramatic.masks = [sky(["saturation": 14, "exposure_ev": -1.4, "contrast": 16])]
        XCTAssertEqual(CandidateDescription.phrases(for: dramatic, relativeTo: natural), [])
        XCTAssertEqual(CandidateDescription.sentence(for: dramatic, relativeTo: natural),
                       "A deeper sky")
    }

    /// A 0.28 EV pull written into the sky mask is 0.08 of a stop in the sky (the measured 0.29
    /// reach), and the caption must not claim what nobody can see.
    func testASubThresholdLocalMoveIsNotClaimed() {
        let natural = recipe("natural") { _ in }
        var vivid = recipe("vivid") { _ in }
        vivid.masks = [sky(["exposure_ev": -0.28, "saturation": 10])]
        XCTAssertEqual(CandidateDescription.regionPhrases(for: vivid, relativeTo: natural), [])
        XCTAssertEqual(CandidateDescription.sentence(for: vivid, relativeTo: natural),
                       "Close to Natural")
        // Opacity counts too: a strong-looking parameter at low opacity is a weak move.
        var faint = recipe("faint") { _ in }
        faint.masks = [sky(["contrast": 20], opacity: 0.5)]
        XCTAssertEqual(CandidateDescription.regionPhrases(for: faint, relativeTo: natural), [])
    }

    func testGlobalAndLocalPhrasesShareOneSentenceGlobalFirst() {
        let natural = recipe("natural") { _ in }
        var look = recipe("rich") { g in g.contrast = 20 }
        look.masks = [sky(["exposure_ev": -0.84])]
        XCTAssertEqual(CandidateDescription.sentence(for: look, relativeTo: natural),
                       "More contrast, with a deeper sky")
    }

    /// At most three phrases, chosen by strength across global and local together — a strong sky
    /// outranks a weak global move and pushes it out.
    func testRankingPicksTheStrongestThreeAcrossBoth() {
        let natural = recipe("natural") { _ in }
        var look = recipe("dramatic") { g in
            g.contrast = 30           // 3.75
            g.blacks = -20            // 2.0
            g.exposureEV = 0.16       // 1.07 — the weakest, dropped
        }
        look.masks = [sky(["exposure_ev": -1.4])]   // 0.41 of a stop → 2.7
        XCTAssertEqual(CandidateDescription.sentence(for: look, relativeTo: natural),
                       "More contrast, deeper blacks, with a deeper sky")
    }

    /// One phrase per region, and the exposure-plus-shadows lift is one move, not two.
    func testASubjectLiftIsOnePhraseInPlainWords() {
        let natural = recipe("natural") { _ in }
        var look = recipe("look") { _ in }
        look.masks = [subjectLift(0.4)]
        XCTAssertEqual(CandidateDescription.regionPhrases(for: look, relativeTo: natural,
                                                          subject: "the people"),
                       ["the people lifted out of the shadows"])
        XCTAssertEqual(CandidateDescription.sentence(for: look, relativeTo: natural,
                                                     subject: "the people"),
                       "The people lifted out of the shadows")
    }

    /// Local phrases keep their rank among themselves (the sky's 2.7 before the lift's 2.3) and
    /// join with "and", no Oxford comma.
    func testRegionPhrasesJoinWithAndWithoutAnOxfordComma() {
        let natural = recipe("natural") { g in g.temperatureK = 6500 }
        var look = recipe("warm") { g in g.temperatureK = 5000 }
        look.masks = [subjectLift(0.5), sky(["exposure_ev": -1.4])]
        XCTAssertEqual(CandidateDescription.sentence(for: look, relativeTo: natural,
                                                     subject: "the animal"),
                       "Warmer, with a deeper sky and the animal lifted out of the shadows")
    }

    /// The noun comes from `type` and `count` — the closed vocabulary — and never from `label`,
    /// which is free text and display-only by rule (D19, D27).
    func testTheSubjectIsNamedFromItsTypeNeverItsLabel() {
        XCTAssertEqual(CandidateDescription.subjectNoun(for: person(.single, label: "bride")),
                       "the person")
        XCTAssertEqual(CandidateDescription.subjectNoun(for: person(.few, label: "person")),
                       "the people")
        XCTAssertEqual(CandidateDescription.subjectNoun(for: person(.crowd)), "the people")
        XCTAssertEqual(CandidateDescription.subjectNoun(
            for: .init(present: true, type: .animal, count: .single, placement: .center, label: "Dog")),
            "the animal")
        XCTAssertEqual(CandidateDescription.subjectNoun(
            for: .init(present: true, type: .naturalFeature, count: .single, placement: .center,
                       label: "sea stack")),
            "the subject")
        XCTAssertEqual(CandidateDescription.subjectNoun(for: .absent), "the subject")
    }

    /// Natural keeps its promise and says the one local move a viewer will notice against their
    /// original; it says nothing when the only local move is the quiet memory-colour sky.
    func testNaturalNamesItsStrongestLocalMoveOnly() {
        var natural = recipe("natural") { g in g.exposureEV = 0.4; g.contrast = 10 }
        XCTAssertEqual(CandidateDescription.sentence(for: natural, relativeTo: natural),
                       "True to the scene")
        natural.masks = [sky(["saturation": 12])]
        XCTAssertEqual(CandidateDescription.sentence(for: natural, relativeTo: natural),
                       "True to the scene")
        natural.masks = [subjectLift(0.25), sky(["saturation": 12, "highlights": -60])]
        XCTAssertEqual(CandidateDescription.sentence(for: natural, relativeTo: natural,
                                                     subject: "the person"),
                       "True to the scene, with more detail in the sky")
        natural.masks = [subjectLift(0.5)]
        XCTAssertEqual(CandidateDescription.sentence(for: natural, relativeTo: natural,
                                                     subject: "the person"),
                       "True to the scene, with the person lifted out of the shadows")
    }

    /// A mask both recipes carry identically is not a difference, and a region neither carries is
    /// not mentioned — the shared subject lift never appears in another look's caption.
    func testIdenticalOrAbsentMasksSayNothing() {
        var natural = recipe("natural") { _ in }
        natural.masks = [subjectLift(0.5)]
        var soft = recipe("soft") { g in g.contrast = -20 }
        soft.masks = [subjectLift(0.5)]
        XCTAssertEqual(CandidateDescription.sentence(for: soft, relativeTo: natural,
                                                     subject: "the people"),
                       "Softer contrast")
        let plain = recipe("plain") { g in g.contrast = -20 }
        XCTAssertEqual(CandidateDescription.regionPhrases(for: plain, relativeTo: recipe("n") { _ in }),
                       [])
    }

    /// A mask present on one side only compares against no edit — Airy opening a sky Natural
    /// never touched is still Airy opening a sky.
    func testAMaskOnOneSideComparesAgainstNoEdit() {
        let natural = recipe("natural") { _ in }
        var airy = recipe("airy") { _ in }
        airy.masks = [sky(["exposure_ev": 0.7])]
        XCTAssertEqual(CandidateDescription.regionPhrases(for: airy, relativeTo: natural),
                       ["a lighter sky"])
        XCTAssertEqual(CandidateDescription.regionPhrases(for: natural, relativeTo: airy),
                       ["a deeper sky"])
    }

    /// Only regions with a true name are described: a hand-drawn radial, or a subject mask refined
    /// to skin, is not "the sky" or "the people".
    func testUnnameableMasksAreNotDescribed() {
        let natural = recipe("natural") { _ in }
        var look = recipe("look") { _ in }
        look.masks = [
            Mask(id: "radial-1", type: "radial", source: nil, invert: false, feather: 50,
                 opacity: 1, adjustments: ["exposure_ev": 1.0]),
            Mask.skin(id: "skin", adjustments: ["exposure_ev": 1.0]),
        ]
        XCTAssertEqual(CandidateDescription.regionPhrases(for: look, relativeTo: natural), [])
    }

    /// Colour inside part of a mono picture is invisible, so it is not claimed; the sky's tone is.
    func testMonoKeepsToneRegionsAndDropsColourOnes() {
        let natural = recipe("natural") { _ in }
        var mono = recipe("mono") { _ in }
        mono.blackAndWhite = BlackAndWhiteMix(bands: [:])
        mono.masks = [sky(["saturation": 40])]
        XCTAssertEqual(CandidateDescription.sentence(for: mono, relativeTo: natural), "Black and white")
        mono.masks = [sky(["saturation": 40, "exposure_ev": -1.4])]
        XCTAssertEqual(CandidateDescription.sentence(for: mono, relativeTo: natural),
                       "Black and white, with a deeper sky")
    }
}
