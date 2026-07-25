import XCTest
import KelvinCore
@testable import KelvinApp

/// `AppState` is where the window's behaviour is decided, and most of it is not about pixels at
/// all: which frames the strip shows, what a new mask starts as, what order masks composite in,
/// how far the zoom goes. None of that needs a window to check, and none of it was checked.
///
/// The rules here are the ones a photographer would notice being broken within a minute of using
/// the app, which is exactly why they should not be found that way.
@MainActor
final class AppStateTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/shoot/\(name)") }

    private func state(with photos: [URL]) -> AppState {
        let s = AppState()
        s.folderPhotos = photos
        return s
    }

    // MARK: Culling — what the strip shows

    /// Rejecting a frame hides it, which is the entire point of a binary cull: decide first, then
    /// edit what is left.
    func testRejectedFramesLeaveTheStrip() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.flags = [b: .reject]
        XCTAssertEqual(s.visiblePhotos, [a])
    }

    /// Except the one you are editing. Filtering the open photograph out from under yourself
    /// leaves the strip showing a shoot the preview is not part of, which reads as a bug whichever
    /// way you look at it.
    func testTheFrameYouAreEditingIsNeverFilteredAway() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.flags = [b: .reject]
        s.imageURL = b
        XCTAssertEqual(s.visiblePhotos, [a, b])

        s.stripFilter = .keepers
        XCTAssertTrue(s.visiblePhotos.contains(b), "even under a filter that excludes it")
    }

    func testKeepersShowsOnlyWhatWasKept() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let s = state(with: [a, b, c])
        s.flags = [a: .keep, b: .reject]
        s.stripFilter = .keepers
        XCTAssertEqual(s.visiblePhotos, [a])
    }

    /// "Undecided" is the filter that makes a long shoot finishable: it shows what is left to do,
    /// so both keeps and rejects drop out of it.
    func testUndecidedShowsOnlyFramesWithNoDecisionYet() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let s = state(with: [a, b, c])
        s.flags = [a: .keep, b: .reject]
        s.stripFilter = .undecided
        XCTAssertEqual(s.visiblePhotos, [c])
    }

    /// Filtering never reorders. The strip's order is a separate decision (`PhotoOrder`), and a
    /// filter that shuffled would move frames under the pointer mid-cull.
    func testFilteringPreservesTheShootsOrder() {
        let urls = (1...6).map { url("_DSC000\($0).ARW") }
        let s = state(with: urls)
        s.flags = [urls[1]: .reject, urls[4]: .reject]
        XCTAssertEqual(s.visiblePhotos, [urls[0], urls[2], urls[3], urls[5]])
    }

    /// Opening one photograph lists its folder, and that is the right default — the strip is what
    /// culling, Batch apply and the arrow keys all operate on. But it was a surprise to the person
    /// it happened to, so it is now a stated choice, and the status line says what it did.
    func testTheFolderNoteReportsWhatWasActuallyLoaded() {
        let urls = (1...4).map { url("_DSC000\($0).ARW") }
        let s = state(with: urls)
        s.imageURL = urls[0]
        XCTAssertTrue(s.statusNote.contains("3 more photos"), "got: \(s.statusNote)")

        // One sibling reads as "photo", not "photos" — the kind of detail that makes copy look
        // written rather than generated.
        let two = state(with: [urls[0], urls[1]])
        XCTAssertTrue(two.statusNote.contains("1 more photo in"), "got: \(two.statusNote)")

        // Nothing to say when there is nothing else there, so it says nothing.
        XCTAssertEqual(state(with: [urls[0]]).statusNote, "")
    }

    /// With the setting off, the note must not claim a folder was listed — and nothing should be.
    func testOptingOutOfTheFolderSaysNothingAboutIt() {
        let urls = (1...3).map { url("_DSC000\($0).ARW") }
        let s = state(with: urls)
        s.includeFolderOnOpen = false
        XCTAssertEqual(s.statusNote, "")
        s.includeFolderOnOpen = true   // leave the shared default as it was found
    }

    // MARK: Grouping — one control, one axis (D-browse-1)

    /// Minutes apart, as a shoot's EXIF would read.
    private func at(_ minutes: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 500_000_000 + minutes * 60)
    }

    /// No grouping is a FLAT strip, not one group holding the shoot. The distinction is the whole
    /// reason this is optional: a single bucket would have the view draw a heading over everything.
    func testUngroupedIsAFlatStripRatherThanOneGroup() {
        let s = state(with: [url("a.ARW"), url("b.ARW")])
        XCTAssertNil(s.stripGroups)
    }

    /// Grouping partitions: every frame on screen appears in exactly one run, so the count in the
    /// header still describes what you are looking at.
    func testEveryVisibleFrameLandsInExactlyOneRun() {
        let urls = (1...5).map { url("_DSC000\($0).ARW") }
        let s = state(with: urls)
        s.captureIndex = .init(dates: [urls[0]: at(0), urls[1]: at(1), urls[2]: at(600),
                                       urls[3]: at(601)])   // urls[4] undated on purpose

        for lens in [AppState.StripGrouping.day, .burst] {
            s.stripGrouping = lens
            let grouped = (s.stripGroups ?? []).flatMap(\.urls)
            XCTAssertEqual(grouped.count, urls.count, "\(lens.label): every frame drawn once")
            XCTAssertEqual(Set(grouped), Set(urls), "\(lens.label): and it is the same frames")
        }
    }

    /// Frames the grouping cannot place go last, under their own heading. "No date" is a true
    /// statement about the files; mixing them into the first day would invent a time for them.
    func testFramesWithNoDateAreTheLastRunAndSayWhy() throws {
        let dated = url("dated.ARW"), undated = url("undated.ARW")
        let s = state(with: [dated, undated])
        s.captureIndex = .init(dates: [dated: at(0)])
        s.stripGrouping = .day

        let groups = try XCTUnwrap(s.stripGroups)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.last?.urls, [undated])
        XCTAssertEqual(groups.last?.heading, "No date")
    }

    /// A lone frame is not a burst. Heading every unrepeated frame would put several hundred labels
    /// on a shoot and bury the runs that are actually a burst.
    func testALoneFrameIsNotLabelledABurst() {
        let a = url("a.ARW"), b = url("b.ARW"), alone = url("c.ARW")
        let s = state(with: [a, b, alone])
        s.captureIndex = .init(dates: [a: at(0), b: at(0.02), alone: at(30)])
        s.stripGrouping = .burst

        let groups = s.stripGroups ?? []
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.urls.count, 2)
        XCTAssertNotNil(groups.first?.heading, "two frames two seconds apart are a burst")
        XCTAssertNil(groups.last?.heading, "one frame half an hour later is not")
    }

    /// Place needs positions, and most folders have none — a camera without GPS records nothing at
    /// all. The control has to be able to say so rather than offer a lens that cannot answer.
    func testPlaceIsUnavailableWithoutPositions() {
        let a = url("a.ARW")
        let s = state(with: [a])
        s.captureIndex = .init(dates: [a: at(0)])
        XCTAssertFalse(s.canGroupByPlace)

        s.captureIndex = .init(dates: [a: at(0)],
                               locations: [a: GeoPoint(latitude: 50.4, longitude: -4.1)])
        XCTAssertTrue(s.canGroupByPlace)
    }

    /// Grouping by place reads the anchor out as coordinates, because naming a place would mean a
    /// network call and this app does not make any.
    func testPlaceRunsAreHeadedWithCoordinates() {
        let a = url("a.ARW")
        let s = state(with: [a])
        s.captureIndex = .init(dates: [a: at(0)],
                               locations: [a: GeoPoint(latitude: 50.37, longitude: -4.14)])
        s.stripGrouping = .place
        XCTAssertEqual(s.stripGroups?.first?.heading, "50.4°N, 4.1°W")
    }

    /// "Not measured yet" is not "unique". Until the scan has fingerprinted a frame, the near
    /// duplicate lens knows nothing about it, and a singleton run would claim the opposite.
    func testUnmeasuredFramesAreHeldBackRatherThanCalledUnique() {
        let urls = (1...3).map { url("_DSC000\($0).ARW") }
        let s = state(with: urls)
        s.stripGrouping = .similar

        let groups = s.stripGroups ?? []
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.heading, "Not measured yet")
        XCTAssertEqual(groups.first?.urls.count, 3)
    }

    /// The point of paying for the scan: in a run of near-identical frames, say which one measured
    /// sharpest. One mark per run, and only where there is a choice to make.
    func testTheSharpestFrameOfEachBurstIsMarked() {
        let urls = (1...4).map { url("_DSC000\($0).ARW") }
        let s = state(with: urls)
        // Three frames in one burst, a fourth half an hour later on its own.
        s.captureIndex = .init(dates: [urls[0]: at(0), urls[1]: at(0.03), urls[2]: at(0.06),
                                       urls[3]: at(30)])
        s.focus = [urls[0]: .init(acuity: 4.1, measurable: true),
                   urls[1]: .init(acuity: 6.8, measurable: true),
                   urls[2]: .init(acuity: 3.2, measurable: true),
                   urls[3]: .init(acuity: 9.9, measurable: true)]
        s.stripGrouping = .burst

        XCTAssertEqual(s.sharpestInRun, [urls[1]],
                       "the sharpest of the three, and nothing for the frame that is alone")
    }

    /// A frame with no edges to judge — a plain sky, a studio backdrop — has no acuity to compare, and
    /// a run of those has no sharpest frame. Silence rather than an arbitrary pick.
    func testAnUnmeasurableRunIsNotMarkedAtAll() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.captureIndex = .init(dates: [a: at(0), b: at(0.03)])
        s.focus = [a: .init(acuity: 0, measurable: false), b: .init(acuity: 0, measurable: false)]
        s.stripGrouping = .burst

        XCTAssertTrue(s.sharpestInRun.isEmpty)
    }

    /// Only where the question makes sense. The sharpest frame of a whole afternoon answers nothing —
    /// the mark exists to help choose between frames of the same picture.
    func testSharpestIsNotOfferedForDayOrPlaceGroupings() {
        let urls = (1...3).map { url("_DSC000\($0).ARW") }
        let s = state(with: urls)
        s.captureIndex = .init(dates: [urls[0]: at(0), urls[1]: at(0.03), urls[2]: at(0.06)])
        s.focus = Dictionary(uniqueKeysWithValues: urls.enumerated().map {
            ($0.element, FocusMeasure.Reading(acuity: Double($0.offset) + 1, measurable: true))
        })

        s.stripGrouping = .day
        XCTAssertTrue(s.sharpestInRun.isEmpty)
        s.stripGrouping = .none
        XCTAssertTrue(s.sharpestInRun.isEmpty)
    }

    // MARK: New masks

    /// A new mask arrives with a visible adjustment already dialled in. A mask that changes nothing
    /// looks broken the moment it appears — you have added a thing and the photograph is identical.
    func testANewMaskArrivesDoingSomethingVisible() {
        for kind in [UserMaskVM.Kind.radial, .linear, .brush, .colorRange, .luminance,
                     .skin, .background, .subject] {
            let s = AppState()
            s.addUserMask(kind)
            let mask = s.userMasks.last?.toMask()
            XCTAssertEqual(mask?.adjustments.isEmpty, false,
                           "a new \(kind) mask does nothing to the picture")
        }
    }

    /// Subject and skin masks open the subject UP; a background mask pushes the background DOWN.
    /// Both directions are "make the subject the brightest thing in the frame", and getting the
    /// sign wrong on either is an edit that fights itself.
    func testTheDefaultsPushTheSubjectForwardAndTheBackgroundBack() {
        let subject = AppState(); subject.addUserMask(.subject)
        XCTAssertGreaterThan(subject.userMasks.last?.exposure ?? 0, 0)

        let skin = AppState(); skin.addUserMask(.skin)
        XCTAssertGreaterThan(skin.userMasks.last?.exposure ?? 0, 0)

        let background = AppState(); background.addUserMask(.background)
        XCTAssertLessThan(background.userMasks.last?.exposure ?? 0, 0)
    }

    /// A new mask is selected, so its canvas handles are there to drag without hunting for it in a
    /// list. A brush additionally starts in painting mode, because a brush mask with no strokes is
    /// a mask over nothing.
    func testANewMaskIsSelectedAndABrushIsReadyToPaint() throws {
        let s = AppState()
        s.addUserMask(.radial)
        XCTAssertEqual(s.selectedUserMaskId, s.userMasks.last?.id)

        s.addUserMask(.brush)
        let brush = try XCTUnwrap(s.userMasks.last)
        XCTAssertEqual(s.paintingMaskId, brush.id)
    }

    /// Deleting the mask you are painting has to stop the painting too, or the next drag lays
    /// stamps onto a mask that no longer exists.
    func testDeletingTheBrushYouArePaintingStopsThePainting() {
        let s = AppState()
        s.addUserMask(.brush)
        let id = s.userMasks[0].id
        s.removeUserMask(id)
        XCTAssertTrue(s.userMasks.isEmpty)
        XCTAssertNil(s.paintingMaskId)
    }

    /// The reported bug, as a rule: putting a mask's selection down must not cost you the mask.
    ///
    /// Everything the canvas draws for the selected mask — a subject's outline, a gradient's dashed
    /// guide — is drawn for as long as it is selected, and selecting used to be one-way. So the only
    /// control that cleared the annotation was the trash, and the edits went with it.
    func testAMaskCanBePutDownWithoutLosingItsEdits() throws {
        let s = AppState()
        s.addUserMask(.radial)
        let mask = try XCTUnwrap(s.userMasks.last)
        s.userMasks[0].exposure = 0.8

        s.toggleMaskSelection(mask.id)
        XCTAssertNil(s.selectedMask, "clicking the eye of the selected mask puts it down")
        XCTAssertEqual(s.userMasks.count, 1, "and the mask is still there")
        XCTAssertEqual(s.userMasks[0].exposure, 0.8, "with the edits made to it")

        s.toggleMaskSelection(mask.id)
        XCTAssertEqual(s.selectedUserMaskId, mask.id, "and it comes back")
    }

    /// Selecting a different mask is a move, not a toggle — the second click on a mask that was
    /// never selected must select it rather than clearing the panel.
    func testPuttingOneMaskDownIsNotConfusedWithPickingAnother() {
        let s = AppState()
        s.addUserMask(.radial); s.addUserMask(.linear)
        let ids = s.userMasks.map(\.id)

        s.toggleMaskSelection(ids[0])
        XCTAssertEqual(s.selectedUserMaskId, ids[0])
        s.toggleMaskSelection(ids[0])
        XCTAssertNil(s.selectedMask)
    }

    /// With nothing selected the overlay draws nothing, so an armed brush would be laying stamps
    /// into a mask the canvas has stopped showing. Putting the mask down puts the brush down.
    func testPuttingABrushDownStopsPainting() {
        let s = AppState()
        s.addUserMask(.brush)
        let id = s.userMasks[0].id
        XCTAssertEqual(s.paintingMaskId, id)

        s.toggleMaskSelection(id)
        XCTAssertNil(s.paintingMaskId)
        XCTAssertEqual(s.userMasks.count, 1, "the strokes are not the casualty of hiding them")
    }

    // MARK: Mask order

    /// Stack order is not cosmetic: each mask composites over the result of the ones before it, so
    /// two overlapping masks give a different photograph depending which is on top.
    func testMovingAMaskChangesTheOrderItCompositesIn() {
        let s = AppState()
        s.addUserMask(.radial); s.addUserMask(.linear); s.addUserMask(.subject)
        let ids = s.userMasks.map(\.id)

        s.moveUserMask(ids[2], by: -1)
        XCTAssertEqual(s.userMasks.map(\.id), [ids[0], ids[2], ids[1]])
    }

    /// Moving off the end of the stack does nothing rather than wrapping around. A mask that
    /// teleports from the bottom to the top on one extra keypress is worse than one that stops.
    func testAMaskCannotBeMovedOffTheEndsOfTheStack() {
        let s = AppState()
        s.addUserMask(.radial); s.addUserMask(.linear)
        let ids = s.userMasks.map(\.id)

        s.moveUserMask(ids[0], by: -1)
        XCTAssertEqual(s.userMasks.map(\.id), ids, "already at the bottom")
        s.moveUserMask(ids[1], by: 1)
        XCTAssertEqual(s.userMasks.map(\.id), ids, "already at the top")
    }

    /// The count next to the mask section counts masks the render is actually using — an auto mask
    /// switched off is not one of them.
    func testTheMaskCountReflectsWhatIsActuallyApplied() {
        let s = AppState()
        XCTAssertNil(s.maskCountLabel, "no masks: say nothing rather than '0'")

        s.addUserMask(.radial)
        XCTAssertEqual(s.maskCountLabel, "1")
    }

    // MARK: Zoom

    /// Zoom is bounded at both ends: below 1 the photo would be smaller than the fit it was framed
    /// to, and there is no detail past 8× on a proxy — a zoom that keeps going is a blur that keeps
    /// growing.
    func testZoomStaysBetweenFitAndTheLimitOfTheProxy() {
        let s = AppState()
        s.setZoom(0.2)
        XCTAssertEqual(s.zoom, 1, accuracy: 1e-9)
        s.setZoom(99)
        XCTAssertEqual(s.zoom, 8, accuracy: 1e-9)
    }

    /// Returning to fit recentres. A pan left over from a zoomed-in inspection would otherwise
    /// leave the fitted photograph sitting off to one side of an empty canvas.
    func testReturningToFitClearsThePan() {
        let s = AppState()
        s.setZoom(4)
        s.pan = CGSize(width: 120, height: -40)
        s.setZoom(1)
        XCTAssertEqual(s.pan, .zero)

        s.setZoom(4); s.pan = CGSize(width: 10, height: 10)
        s.resetZoom()
        XCTAssertEqual(s.zoom, 1, accuracy: 1e-9)
        XCTAssertEqual(s.pan, .zero)
    }

    // MARK: Small readouts

    /// A restored edit should say *when*, in words a person reads, and should still say something
    /// when the timestamp is unreadable rather than showing a machine string or nothing at all.
    func testARestoredEditSaysWhenInWordsAndDegradesGracefully() {
        XCTAssertEqual(AppState.friendlyDate("not-a-date"), "an earlier session")
        let formatted = AppState.friendlyDate("2026-03-12T14:03:00Z")
        XCTAssertFalse(formatted.contains("T"), "'\(formatted)' still reads as a machine timestamp")
        XCTAssertNotEqual(formatted, "an earlier session", "a valid ISO date should format")
    }

    /// With no photo open there is still a filename to offer, because the export sheet can be
    /// reached before one is loaded.
    func testTheSuggestedExportNameAlwaysHasAnExtension() {
        let s = AppState()
        // Asserted against `Branding`, not against the literal. A test that hardcodes the product
        // name is a test that fails the day the product is renamed — which turns the rename from a
        // constant change into an archaeology exercise.
        XCTAssertEqual(s.suggestedExportName(ext: "jpg"), "\(Branding.exportStem).jpg")
        XCTAssertEqual(s.suggestedExportName(ext: "tiff"), "\(Branding.exportStem).tiff")
    }
}

/// The colour of a temperature, used for the white-balance rail and the per-candidate dot. It is a
/// scale a photographer reads at a glance, so the only properties worth pinning are the ones that
/// make it readable: it stays inside its ends, and it moves the same way the number does.
final class KelvinScaleTests: XCTestCase {

    func testThePositionOnTheRailStaysInsideIt() {
        XCTAssertEqual(KelvinScale.position(KelvinScale.minK), 0, accuracy: 1e-9)
        XCTAssertEqual(KelvinScale.position(KelvinScale.maxK), 1, accuracy: 1e-9)
        XCTAssertEqual(KelvinScale.position(-500), 0, accuracy: 1e-9, "a knob cannot leave its track")
        XCTAssertEqual(KelvinScale.position(50_000), 1, accuracy: 1e-9)
    }

    func testWarmerTemperaturesSitLeftOfCoolerOnes() {
        var previous = -1.0
        for k in stride(from: 2000.0, through: 10_000.0, by: 250) {
            let p = KelvinScale.position(k)
            XCTAssertGreaterThan(p, previous, "the rail doubled back at \(k)K")
            previous = p
        }
    }
}
