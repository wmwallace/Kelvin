import XCTest
@testable import KelvinApp

/// Which of Kelvin's answers the compare grid shows, and in what order.
///
/// The rule is small and the reasons are not. A comparison is only a comparison if the thing you
/// currently have is one of the things on screen, if the order does not shuffle under you between
/// glances, and if the same number key means the same candidate here as it does in the picker.
/// Each of those is a way the view could be technically correct and useless.
final class CandidateCompareTests: XCTestCase {

    private let four = ["natural", "soft", "vivid", "dramatic"]

    // MARK: Two up

    /// The chosen candidate is what you are comparing FROM. It cannot fall off the screen.
    func testTheChosenCandidateIsAlwaysFirstAndAlwaysPresent() {
        for id in four {
            let tiles = CandidateCompare.tiles(candidateIds: four, selectedId: id,
                                               partnerId: nil, mode: .two)
            XCTAssertEqual(tiles.first, id)
            XCTAssertEqual(tiles.count, 2)
        }
    }

    /// With nothing chosen — the moment before the first pick — the grid still has to draw
    /// something, and the first two is the honest default.
    func testNothingChosenYetStillGivesAComparison() {
        XCTAssertEqual(CandidateCompare.tiles(candidateIds: four, selectedId: nil,
                                              partnerId: nil, mode: .two),
                       ["natural", "soft"])
    }

    /// The partner defaults to the NEXT candidate rather than the best of the rest: "best" is a
    /// judgment the picker has already made and the user is entitled to disagree with.
    func testThePartnerDefaultsToTheNextCandidate() {
        XCTAssertEqual(CandidateCompare.tiles(candidateIds: four, selectedId: "soft",
                                              partnerId: nil, mode: .two),
                       ["soft", "vivid"])
    }

    /// And wraps, so the last candidate compares against the first rather than against nothing.
    func testThePartnerWrapsPastTheEnd() {
        XCTAssertEqual(CandidateCompare.tiles(candidateIds: four, selectedId: "dramatic",
                                              partnerId: nil, mode: .two),
                       ["dramatic", "natural"])
    }

    func testAnExplicitPartnerIsHonoured() {
        XCTAssertEqual(CandidateCompare.tiles(candidateIds: four, selectedId: "natural",
                                              partnerId: "dramatic", mode: .two),
                       ["natural", "dramatic"])
    }

    /// One photograph twice is not a comparison. A partner that has become the selection — which is
    /// exactly what happens when you choose the right-hand tile — falls back to the next one.
    func testAPartnerThatIsTheSelectionIsRefused() {
        let tiles = CandidateCompare.tiles(candidateIds: four, selectedId: "vivid",
                                           partnerId: "vivid", mode: .two)
        XCTAssertEqual(tiles, ["vivid", "dramatic"])
        XCTAssertEqual(Set(tiles).count, tiles.count)
    }

    /// A partner from a photograph ago — the ids are per-frame — must not survive into this one.
    func testAPartnerFromAnotherFrameIsIgnored() {
        XCTAssertEqual(CandidateCompare.tiles(candidateIds: four, selectedId: "natural",
                                              partnerId: "some-other-frames-id", mode: .two),
                       ["natural", "soft"])
    }

    // MARK: Four up

    /// Engine order, whatever is selected. Tiles that move between glances stop being a comparison.
    func testFourUpKeepsEngineOrderRegardlessOfSelection() {
        XCTAssertEqual(CandidateCompare.tiles(candidateIds: four, selectedId: "dramatic",
                                              partnerId: "soft", mode: .four),
                       four)
    }

    func testFourUpNeverShowsMoreThanFour() {
        let five = four + ["mono"]
        XCTAssertEqual(CandidateCompare.tiles(candidateIds: five, selectedId: nil,
                                              partnerId: nil, mode: .four).count, 4)
    }

    // MARK: Not enough to compare

    /// One candidate is not a comparison, and neither is none. The view is never offered in that
    /// state (`canCompare`), but the rule says so itself rather than trusting the caller.
    func testFewerThanTwoCandidatesIsNotAComparison() {
        XCTAssertTrue(CandidateCompare.tiles(candidateIds: ["natural"], selectedId: "natural",
                                             partnerId: nil, mode: .two).isEmpty)
        XCTAssertTrue(CandidateCompare.tiles(candidateIds: [], selectedId: nil,
                                             partnerId: nil, mode: .four).isEmpty)
    }

    // MARK: The numbering

    /// The tile badge and the keyboard are the same numbering as the picker's rows, because a "3"
    /// that chose a different candidate in each place would be worse than no number at all.
    func testTheNumberOnATileIsThePickersOwnNumbering() {
        XCTAssertEqual(CandidateCompare.shortcutNumber(for: "natural", in: four), 1)
        XCTAssertEqual(CandidateCompare.shortcutNumber(for: "dramatic", in: four), 4)
        XCTAssertNil(CandidateCompare.shortcutNumber(for: "mono", in: four))
    }

    /// Only four number keys are bound, so a fifth candidate gets no badge rather than a badge
    /// whose key does nothing.
    func testAFifthCandidateHasNoNumber() {
        XCTAssertNil(CandidateCompare.shortcutNumber(for: "mono", in: four + ["mono"]))
    }

    // MARK: The state it lives in

    @MainActor
    func testComparingNeedsTwoCandidatesAndAProxy() {
        let s = AppState()
        XCTAssertFalse(s.canCompare, "no photograph, nothing to compare")
        s.toggleCompare()
        XCTAssertFalse(s.comparing, "and asking must not open an empty grid")
    }
}
