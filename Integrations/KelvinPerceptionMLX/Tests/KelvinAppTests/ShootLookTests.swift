import XCTest
import KelvinCore
@testable import KelvinApp

/// Applying a look to a shoot, which is the one feature in this app that touches every photograph
/// at once — and therefore the one where being wrong is most expensive.
///
/// The rules worth pinning are the ones that decide *which frame gets which look*, because they are
/// invisible: nothing on screen distinguishes "this frame is Natural because the shoot is" from
/// "this frame is Natural because you made it so", and the second must always win. Everything here
/// is checked without rendering a pixel or writing a file — the resolution rules are pure by
/// design, and that is what makes them checkable at all.
@MainActor
final class ShootLookTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/shoot/\(name)") }

    private func state(with photos: [URL]) -> AppState {
        let s = AppState()
        s.folderPhotos = photos
        return s
    }

    // MARK: Which look a frame is in

    /// A shoot with no look decides nothing. This is the state every folder starts in, and the
    /// engine's own ranking has to keep winning in it — otherwise adding this feature silently
    /// changed what every existing shoot opens as.
    func testAShootWithNoLookClaimsNothing() {
        let a = url("a.ARW")
        let s = state(with: [a])
        XCTAssertNil(s.effectiveStyle(for: a))
    }

    func testTheShootsStyleCoversEveryFrameInIt() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.shootLook = ShootLook(style: "vivid")
        XCTAssertEqual(s.effectiveStyle(for: a), "vivid")
        XCTAssertEqual(s.effectiveStyle(for: b), "vivid")
    }

    /// The whole reason `overrides` exists: frame 12 was given something else and must keep it.
    func testAnOverriddenFrameKeepsItsOwnLook() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.shootLook = ShootLook(style: "natural", overrides: [b.path: "dramatic"])
        XCTAssertEqual(s.effectiveStyle(for: a), "natural")
        XCTAssertEqual(s.effectiveStyle(for: b), "dramatic")
    }

    /// Paths that mean the same file must resolve to the same look. A photo reached by a drop
    /// spells its path differently from one reached by the file picker, and an override that only
    /// worked for one of those spellings would look like the feature randomly forgetting.
    func testAnOverrideSurvivesADifferentSpellingOfTheSamePath() {
        let canonical = URL(fileURLWithPath: "/shoot/a.ARW")
        let awkward = URL(fileURLWithPath: "/shoot/./a.ARW")
        let s = state(with: [canonical])
        s.shootLook = ShootLook(style: "natural", overrides: [canonical.path: "soft"])
        XCTAssertEqual(s.effectiveStyle(for: awkward), "soft",
                       "the same photograph resolved to two different looks")
    }

    /// A look can be given to *only* some frames, with no shoot-wide style at all. Then the frames
    /// nobody named stay unclaimed rather than inheriting something they were never given.
    func testFramesOutsideAnOverrideOnlyLookAreStillUnclaimed() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.shootLook = ShootLook(style: nil, overrides: [a.path: "soft"])
        XCTAssertEqual(s.effectiveStyle(for: a), "soft")
        XCTAssertNil(s.effectiveStyle(for: b), "a frame nobody chose for should not inherit a look")
    }

    // MARK: Whether a scope covers the shoot

    /// `ShootLook.covers` is read by the footer's button label on every body evaluation, so its
    /// common answers must come without standardising every path (D23). The listing itself, and a
    /// strict subset of it, are answered by count and equality; a differently spelled path still
    /// gets the standardised comparison.
    func testCoversAnswersTheCommonCasesByShapeAndTheRestByPath() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        XCTAssertTrue(ShootLook.covers([a, b, c], [a, b, c]), "the listing covers itself")
        XCTAssertFalse(ShootLook.covers([a, b], [a, b, c]), "fewer frames cannot cover more")
        XCTAssertTrue(ShootLook.covers([c, b, a], [a, b, c]), "order does not matter")
        let spelled = URL(fileURLWithPath: "/shoot/./a.ARW")
        XCTAssertTrue(ShootLook.covers([spelled, b, c], [a, b, c]),
                      "a different spelling of the same path is still the same frame")
        XCTAssertFalse(ShootLook.covers([], []), "an empty shoot is covered by nothing")
    }

    // MARK: What an apply covers

    /// No selection means the whole shoot — the default, and the one people will use most.
    func testApplyingWithNothingSelectedCoversTheShoot() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let s = state(with: [a, b, c])
        XCTAssertEqual(s.applyScope(), [a, b, c])
    }

    /// A selection narrows it, and the Keep flag stops applying — a selection IS the scope, and
    /// intersecting the two would silently drop frames the user had explicitly clicked.
    func testASelectionIsTheScopeAndOutranksTheKeepFlag() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let s = state(with: [a, b, c])
        s.flags = [a: .keep]
        s.batchKeepersOnly = true
        s.selectedPhotos = [b, c]
        XCTAssertEqual(s.applyScope(), [b, c],
                       "frames the user clicked were dropped by a flag they did not press")
    }

    /// With nothing selected, "kept only" still narrows — the scope control that used to live in
    /// the batch panel has to keep working now it is in the toolbar.
    func testKeptOnlyNarrowsAnUnselectedApply() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.flags = [b: .keep]
        s.batchKeepersOnly = true
        XCTAssertEqual(s.applyScope(), [b])
    }

    /// The scope comes back in the strip's order, not the order frames happened to be clicked in.
    /// The progress messages count through it, and counting through a shuffled shoot reads as the
    /// app working on random photographs.
    func testTheScopeComesBackInStripOrder() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let s = state(with: [a, b, c])
        s.selectedPhotos = [c, a]
        XCTAssertEqual(s.applyScope(), [a, c])
    }

    // MARK: What an apply WRITES
    //
    // Distinct from what it covers, and the gap between the two was a real bug: `applyScope()`
    // honoured the Keep flag while the record it produced claimed the whole folder anyway. The
    // frames the scope left out got the look regardless — silently, because the status line
    // reported the scope's count and the record is not something anyone can see.

    /// An apply that covers the folder claims the folder. This is the common case and the only one
    /// allowed to write the shoot-wide style.
    func testAnApplyOverTheWholeShootBecomesTheShootsStyle() {
        let a = url("a.ARW"), b = url("b.ARW")
        let look = ShootLook().applying("vivid", to: [a, b], inShootOf: [a, b])
        XCTAssertEqual(look.style, "vivid")
        XCTAssertTrue(look.overrides.isEmpty)
    }

    /// "Apply this to everything" has to mean everything, or the frames singled out last week
    /// silently outrank the decision just made.
    func testAWholeShootApplyClearsOverridesItContradicts() {
        let a = url("a.ARW"), b = url("b.ARW")
        let existing = ShootLook(style: "natural", overrides: [a.path: "dramatic"])
        let look = existing.applying("vivid", to: [a, b], inShootOf: [a, b])
        XCTAssertEqual(look.style, "vivid")
        XCTAssertTrue(look.overrides.isEmpty, "an override survived an apply that covered it")
        XCTAssertEqual(look.style(for: a), "vivid")
    }

    /// THE BUG. Kept-only narrowed the scope and the record claimed the folder anyway, so every
    /// reject and every undecided frame quietly got the look while the app reported the keeper
    /// count. A narrower scope must write per-frame overrides instead.
    func testAKeptOnlyApplyNeverClaimsTheFramesItLeftOut() {
        let keeper = url("keeper.ARW"), reject = url("reject.ARW"), undecided = url("u.ARW")
        let all = [keeper, reject, undecided]
        let look = ShootLook().applying("vivid", to: [keeper], inShootOf: all)

        XCTAssertNil(look.style, "a kept-only apply must not claim the whole folder")
        XCTAssertEqual(look.style(for: keeper), "vivid")
        XCTAssertNil(look.style(for: reject), "a rejected frame was given a look nobody asked for")
        XCTAssertNil(look.style(for: undecided))
    }

    /// And a narrower apply leaves what the rest of the shoot already had exactly alone.
    func testANarrowApplyLeavesTheRestOfTheShootsLookStanding() {
        let a = url("a.ARW"), b = url("b.ARW")
        let existing = ShootLook(style: "natural")
        let look = existing.applying("soft", to: [a], inShootOf: [a, b])
        XCTAssertEqual(look.style, "natural", "the shoot's existing style was overwritten")
        XCTAssertEqual(look.style(for: a), "soft")
        XCTAssertEqual(look.style(for: b), "natural")
    }

    /// A selection is narrower by definition, and always was — pinned so the fix to the kept-only
    /// case cannot regress the case that already worked.
    func testASelectionApplyWritesOverrides() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let look = ShootLook().applying("dramatic", to: [b], inShootOf: [a, b, c])
        XCTAssertNil(look.style)
        XCTAssertEqual(look.overrides, [b.path: "dramatic"])
    }

    /// Paths that spell the same file differently must not write two entries — the same
    /// normalisation `style(for:)` reads through.
    func testAnApplyWritesTheCanonicalSpellingOfAPath() {
        let canonical = URL(fileURLWithPath: "/shoot/a.ARW")
        let awkward = URL(fileURLWithPath: "/shoot/./a.ARW")
        let other = url("b.ARW")
        let look = ShootLook().applying("soft", to: [awkward], inShootOf: [canonical, other])
        XCTAssertEqual(look.overrides, [canonical.path: "soft"])
    }

    /// A scope that covers the folder by a different spelling still counts as covering it.
    func testCoverageIsMeasuredOnCanonicalPathsToo() {
        let canonical = URL(fileURLWithPath: "/shoot/a.ARW")
        let awkward = URL(fileURLWithPath: "/shoot/./a.ARW")
        XCTAssertEqual(ShootLook().applying("soft", to: [awkward], inShootOf: [canonical]).style,
                       "soft")
    }

    /// An empty shoot claims nothing. Otherwise "every photo is covered" is vacuously true and an
    /// apply against a folder that has not been listed yet would set a shoot-wide style.
    func testAnApplyWithNoShootToApplyToClaimsNothing() {
        let look = ShootLook().applying("vivid", to: [], inShootOf: [])
        XCTAssertNil(look.style)
        XCTAssertTrue(look.overrides.isEmpty)
    }

    // MARK: What an apply invalidates
    //
    // `openPhoto` returns early on a cached session and never reaches `loadPhoto`, which is the
    // only place a shoot look picks a candidate. So a frame browsed before an apply came back
    // exactly as it was — canvas showing the old look while export wrote the new one.

    func testApplyingALookDropsTheCachedFramesItCovers() {
        let a = url("a.ARW"), b = url("b.ARW"), outside = url("c.ARW")
        let s = state(with: [a, b, outside])
        XCTAssertEqual(s.staleSessionURLs(coveredBy: [a, b], cached: [a, b, outside]), [a, b],
                       "a frame the apply covers must be re-read against the new look")
    }

    /// A hand edit outranks the shoot's look, so nothing about those frames changed — and dropping
    /// one would spend a decode to arrive at the same picture.
    func testAHandEditedFrameKeepsItsCachedSession() {
        let a = url("a.ARW"), edited = url("edited.ARW")
        let s = state(with: [a, edited])
        s.editedURLs = [edited]
        XCTAssertEqual(s.staleSessionURLs(coveredBy: [a, edited], cached: [a, edited]), [a])
    }

    /// Frames outside the scope were not touched by the apply and must not pay for a re-read.
    func testAFrameOutsideTheScopeKeepsItsCachedSession() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        XCTAssertTrue(s.staleSessionURLs(coveredBy: [a], cached: [b]).isEmpty)
    }

    // MARK: Selecting in the strip

    /// A plain click is still "show me this one". Anything else and the strip stops being a way to
    /// look through a shoot.
    func testAPlainClickClearsTheSelection() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.selectedPhotos = [a, b]
        s.stripClick(a, extend: false, toggle: false)
        XCTAssertTrue(s.selectedPhotos.isEmpty)
    }

    func testCommandClickAddsAndRemovesOneFrame() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.stripClick(a, extend: false, toggle: true)
        s.stripClick(b, extend: false, toggle: true)
        XCTAssertEqual(s.selectedPhotos, [a, b])
        s.stripClick(a, extend: false, toggle: true)
        XCTAssertEqual(s.selectedPhotos, [b], "command-clicking a selected frame should drop it")
    }

    /// Shift extends along the STRIP's order, which is the order on screen — not the order the
    /// filenames sort in. A shoot sorted by capture time extends the way the eye expects.
    func testShiftClickExtendsAlongTheOrderOnScreen() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW"), d = url("d.ARW")
        let s = state(with: [d, c, b, a])          // strip order, deliberately not alphabetical
        s.stripClick(d, extend: false, toggle: true)
        s.stripClick(b, extend: true, toggle: false)
        XCTAssertEqual(s.selectedPhotos, [d, c, b])
    }

    /// Extending backwards is the same range. Anchors are not directional.
    func testShiftClickExtendsBothWays() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let s = state(with: [a, b, c])
        s.stripClick(c, extend: false, toggle: true)
        s.stripClick(a, extend: true, toggle: false)
        XCTAssertEqual(s.selectedPhotos, [a, b, c])
    }

    /// Extending must not reach through the filter. A strip showing only keepers has rejected
    /// frames sitting between the ones on screen, and sweeping those up would apply a look to
    /// photographs the photographer had already thrown out — invisibly, because they are filtered
    /// out of the very strip that would have shown the selection.
    func testExtendingNeverSelectsAFrameTheFilterIsHiding() {
        let a = url("a.ARW"), bad = url("bad.ARW"), c = url("c.ARW")
        let s = state(with: [a, bad, c])
        s.flags = [bad: .reject]                   // hidden from the strip under the default filter
        s.stripClick(a, extend: false, toggle: true)
        s.stripClick(c, extend: true, toggle: false)
        XCTAssertEqual(s.selectedPhotos, [a, c],
                       "a rejected frame the strip is not showing was selected anyway")
    }

    /// Same rule for select-all: it covers the strip, not the folder behind it.
    func testSelectAllCoversWhatTheStripIsShowing() {
        let a = url("a.ARW"), bad = url("bad.ARW")
        let s = state(with: [a, bad])
        s.flags = [bad: .reject]
        s.selectAllPhotos()
        XCTAssertEqual(s.selectedPhotos, [a])
    }

    // MARK: What export writes

    /// The point of the whole redesign: applying a look and pressing export has to produce files.
    /// Before, export wrote only the frames carrying a hand edit, so a look applied to four hundred
    /// photographs exported nothing at all.
    func testExportCoversFramesTheShootsLookClaims() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        XCTAssertTrue(s.exportTargets(keepersOnly: false).isEmpty)
        s.shootLook = ShootLook(style: "vivid")
        XCTAssertEqual(s.exportTargets(keepersOnly: false), [a, b])
    }

    /// A hand-edited frame is exported whether or not a look claims it, and is not counted twice.
    func testAHandEditedFrameIsExportedOnceEvenUnderALook() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.editedURLs = [a]
        s.shootLook = ShootLook(style: "soft")
        XCTAssertEqual(s.exportTargets(keepersOnly: false), [a, b])
        XCTAssertEqual(s.exportableCount, 2)
    }

    /// Frames the look does not claim stay out of the export, even in a shoot that has one.
    func testAnUnclaimedFrameIsNotExported() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.shootLook = ShootLook(style: nil, overrides: [a.path: "vivid"])
        XCTAssertEqual(s.exportTargets(keepersOnly: false), [a])
    }

    /// The Keep flag still narrows an export that is carried by the shoot's look, the same way it
    /// narrows one carried by hand edits.
    func testKeptOnlyNarrowsALookCarriedExport() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.shootLook = ShootLook(style: "vivid")
        s.flags = [b: .keep]
        XCTAssertEqual(s.exportTargets(keepersOnly: true), [b])
    }

    // MARK: Export scope — a selection is the scope, exactly as it is for Apply

    /// **Export was the one action that ignored the selection.** Selecting four frames and pressing
    /// export wrote the whole shoot, and the button carried on saying 126 while you did it.
    func testASelectionIsTheExportScope() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let s = state(with: [a, b, c])
        s.shootLook = ShootLook(style: "vivid")           // the look claims all three
        XCTAssertEqual(s.exportScope(), [a, b, c])
        s.selectedPhotos = [c, a]
        XCTAssertEqual(s.exportScope(), [a, c], "the selection must be the scope, in strip order")
    }

    /// A selected frame exports whether or not it is edited. Pointing at a frame and asking for it
    /// IS the request — requiring an edit as well would silently drop frames just picked by hand,
    /// which is impossible to notice in a folder of results.
    func testASelectedFrameExportsEvenWithNoEditOnIt() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        XCTAssertTrue(s.exportScope().isEmpty, "nothing edited, nothing claimed, nothing to export")
        s.selectedPhotos = [b]
        XCTAssertEqual(s.exportScope(), [b])
    }

    /// The label names the scope AND counts it. It used to read "Export 40" from `exportableCount`,
    /// which ignores the Kept-only narrowing — so the button could promise 40 and write 12.
    func testTheExportButtonLabelMatchesWhatWillActuallyBeWritten() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.shootLook = ShootLook(style: "vivid")
        s.flags = [b: .keep]
        XCTAssertEqual(s.exportButtonLabel, "Export 2 edited")

        s.exportKeepersOnly = true
        XCTAssertEqual(s.exportScope(), [b])
        XCTAssertEqual(s.exportButtonLabel, "Export 1 edited",
                       "the button promised more than Kept-only would write")

        s.selectedPhotos = [a, b]
        XCTAssertEqual(s.exportButtonLabel, "Export 2 selected",
                       "a selection outranks the keep flag, as it does for Apply")
    }

    /// **The button's name must stop being a lie.** `exportLongEdge` is persisted, so someone who
    /// once picked 2048 px got 2048 px files from a button reading "Export full-res", every time
    /// after, with nothing on screen to say so.
    func testTheSinglePhotoButtonNamesTheSizeItWillActuallyWrite() {
        let s = state(with: [url("a.ARW")])
        let restore = s.exportLongEdge
        defer { s.exportLongEdge = restore }

        s.exportLongEdge = 0
        XCTAssertEqual(s.exportOneButtonLabel, "Export full-res")
        s.exportLongEdge = 2048
        XCTAssertEqual(s.exportOneButtonLabel, "Export 2048 px",
                       "the button still promised full resolution while set to downscale")
    }

    // MARK: The record itself

    /// A shoot look must survive quitting, which is the only reason it is a file. Written and read
    /// through a temporary folder so the test never touches a real shoot's record.
    func testALookSurvivesBeingWrittenAndReadBack() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-shoot-\(UUID().uuidString)")
        defer { ShootLookStore.remove(for: folder) }

        let look = ShootLook(style: "vivid", overrides: ["/shoot/a.ARW": "soft"],
                             appliedAt: "2026-07-28T10:00:00Z")
        ShootLookStore.save(look, for: folder)
        let read = try XCTUnwrap(ShootLookStore.load(for: folder))
        XCTAssertEqual(read, look)
    }

    /// Removing the record is what "clear the look" does, and it has to actually be gone — a look
    /// that comes back on relaunch is worse than one that never cleared.
    func testClearingRemovesTheRecord() {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-shoot-\(UUID().uuidString)")
        ShootLookStore.save(ShootLook(style: "natural"), for: folder)
        XCTAssertNotNil(ShootLookStore.load(for: folder))
        ShootLookStore.remove(for: folder)
        XCTAssertNil(ShootLookStore.load(for: folder))
    }

    /// Two shoots must never share a record — the same failure mode `EditStore` is keyed against,
    /// and here it would put one wedding's look on another's.
    func testDifferentShootsNeverShareARecord() {
        let a = URL(fileURLWithPath: "/shoots/wedding")
        let b = URL(fileURLWithPath: "/shoots/portraits")
        XCTAssertNotEqual(ShootLookStore.url(for: a), ShootLookStore.url(for: b))
        XCTAssertEqual(ShootLookStore.url(for: a),
                       ShootLookStore.url(for: URL(fileURLWithPath: "/shoots/./wedding")),
                       "one folder spelled two ways must find one record")
    }

    /// Versioned from the first write, like every other serialised thing in this project — a
    /// record with no version is one that can never be migrated.
    func testTheRecordCarriesItsVersion() throws {
        let data = try JSONEncoder().encode(ShootLook(style: "natural"))
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
    }
}
