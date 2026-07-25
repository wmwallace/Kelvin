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
        XCTAssertEqual(s.suggestedExportName(ext: "jpg"), "kelvin-edit.jpg")
        XCTAssertEqual(s.suggestedExportName(ext: "tiff"), "kelvin-edit.tiff")
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
