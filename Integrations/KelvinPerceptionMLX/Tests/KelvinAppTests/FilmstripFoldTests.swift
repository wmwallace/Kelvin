import XCTest
@testable import KelvinApp

/// Whether the filmstrip starts folded, and — the part that matters — who gets to decide.
///
/// Double-clicking one photograph used to pull 437 thumbnails into view. The fix was to let the
/// *intent* of the open set the default: a single file lists the shoot but folds it away, a folder
/// expands it. That is a good default and a terrible rule, because a photographer who has folded
/// the strip on purpose must not have it unfolded again by the next open. Having your choice
/// quietly undone is worse than either default.
///
/// So there are two facts here, not one: what the fold is, and whether anyone has ever said. The
/// second is why `expanded` alone is not enough to answer the question — `true` cannot tell you
/// whether it was a decision or the value it shipped with.
final class FilmstripFoldTests: XCTestCase {

    private let userChoiceKey = "filmstrip.expanded.chosen"
    private var saved: (expanded: Any?, chosen: Any?) = (nil, nil)

    override func setUp() {
        super.setUp()
        let d = UserDefaults.standard
        saved = (d.object(forKey: FilmstripFold.expandedKey), d.object(forKey: userChoiceKey))
        d.removeObject(forKey: FilmstripFold.expandedKey)
        d.removeObject(forKey: userChoiceKey)
    }

    override func tearDown() {
        let d = UserDefaults.standard
        d.removeObject(forKey: FilmstripFold.expandedKey)
        d.removeObject(forKey: userChoiceKey)
        if let v = saved.expanded { d.set(v, forKey: FilmstripFold.expandedKey) }
        if let v = saved.chosen { d.set(v, forKey: userChoiceKey) }
        super.tearDown()
    }

    private var isExpanded: Bool { UserDefaults.standard.bool(forKey: FilmstripFold.expandedKey) }

    // MARK: The default, before anyone has said

    func testOpeningAFolderExpandsTheStripBecauseThatIsPlainlyWhatWasAskedFor() {
        FilmstripFold.applyOpenIntent(openedFolder: true)
        XCTAssertTrue(isExpanded)
    }

    func testOpeningOneFileLeavesTheShootFoldedAway() {
        FilmstripFold.applyOpenIntent(openedFolder: false)
        XCTAssertFalse(isExpanded, "437 thumbnails from a double-click is the bug this fixed")
    }

    /// Applying a default is not deciding. If it counted as a choice, the very first open would
    /// lock the fold in and the intent would never apply again.
    func testApplyingTheDefaultIsNotRecordedAsTheUsersChoice() {
        FilmstripFold.applyOpenIntent(openedFolder: true)
        XCTAssertFalse(FilmstripFold.hasUserChoice)
        FilmstripFold.applyOpenIntent(openedFolder: false)
        XCTAssertFalse(isExpanded, "the intent should still be free to set the default")
    }

    // MARK: Once the user has said

    /// The rule this whole type exists for. A recorded choice is never overwritten by an open —
    /// not by a folder, not by a file, not by any number of them.
    func testAnOpenIntentNeverOverwritesARecordedChoice() {
        FilmstripFold.recordUserChoice(expanded: false)
        XCTAssertTrue(FilmstripFold.hasUserChoice)

        FilmstripFold.applyOpenIntent(openedFolder: true)
        XCTAssertFalse(isExpanded, "a folder open unfolded a strip the photographer had folded")

        FilmstripFold.applyOpenIntent(openedFolder: false)
        XCTAssertFalse(isExpanded)
    }

    /// And in the other direction: someone who unfolded the strip keeps it unfolded when they open
    /// a single file, which is the case the default would otherwise get wrong on every photo.
    func testAStripUnfoldedOnPurposeStaysUnfoldedWhenOpeningOneFile() {
        FilmstripFold.recordUserChoice(expanded: true)
        FilmstripFold.applyOpenIntent(openedFolder: false)
        XCTAssertTrue(isExpanded)
    }

    /// The choice is permanent, not one-shot: opening ten photographs in a row must not wear it
    /// down.
    func testTheChoiceHoldsAcrossManyOpens() {
        FilmstripFold.recordUserChoice(expanded: false)
        for i in 0..<10 { FilmstripFold.applyOpenIntent(openedFolder: i.isMultiple(of: 2)) }
        XCTAssertFalse(isExpanded)
    }

    /// Changing your mind is still a choice, and the newest one wins.
    func testRecordingAgainReplacesTheEarlierChoice() {
        FilmstripFold.recordUserChoice(expanded: false)
        FilmstripFold.recordUserChoice(expanded: true)
        XCTAssertTrue(isExpanded)
        XCTAssertTrue(FilmstripFold.hasUserChoice)
    }

    /// A fresh install has no opinion recorded, which is what makes the open-intent default apply
    /// at all. Asserted because "nobody has said yet" is the state every rule above branches on.
    func testAFreshInstallHasNoRecordedChoice() {
        XCTAssertFalse(FilmstripFold.hasUserChoice)
    }
}
