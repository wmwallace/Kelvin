import XCTest
import CoreImage
import AppKit
import KelvinCore
@testable import KelvinApp

/// A look must survive quitting the app. It didn't: `SavedEdit` wrote `blackAndWhite` and never
/// read it back, and the look's id was not stored at all — so a mono-looked photo reopened in a
/// new session silently returned to colour, and the very next save then overwrote the sidecar's
/// mono with the loss. These tests drive the exact reopen path (`EditStore` → `apply(_:)`) on a
/// fresh `AppState`, which is what a new launch is.
@MainActor
final class LookPersistenceTests: XCTestCase {

    private func photo() -> URL {
        URL(fileURLWithPath: "/kelvin-tests/\(UUID().uuidString)/_DSC0001.ARW")
    }

    /// A launch: fresh state, a decoded proxy, and the engine's candidates — no look, no edit.
    private func freshSession() -> AppState {
        let s = AppState()
        s.proxyCI = CIImage(color: CIColor(red: 0.5, green: 0.45, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        s.candidates = [CandidateViewModel(id: "natural", label: "Natural",
                                           baseRecipe: .neutral, previewImage: NSImage())]
        s.selectCandidate(id: "natural")
        return s
    }

    /// The shipped bug, end to end: pick a mono look, quit, reopen, and the photo must still be
    /// black and white — including in the NEXT save, which is how the loss became permanent.
    func testAMonoLookSurvivesQuittingAndReopening() throws {
        let url = photo()
        addTeardownBlock { EditStore.remove(for: url) }

        let firstSession = freshSession()
        firstSession.applyLook("mono-red")
        XCTAssertNotNil(firstSession.activeRecipe?.blackAndWhite,
                        "the look did not convert at all — nothing to persist")
        EditStore.save(firstSession.currentSavedEdit(), for: url)

        let secondSession = freshSession()
        let saved = try XCTUnwrap(EditStore.load(for: url))
        secondSession.apply(saved)

        XCTAssertEqual(secondSession.activeLookId, "mono-red", "the look itself must come back")
        XCTAssertEqual(secondSession.activeRecipe?.blackAndWhite,
                       LookPreset.named("mono-red")?.mono,
                       "reopening returned the photo to colour — the shipped bug")
        // The second half of the bug: the next persist must keep the mono, not overwrite it.
        let resaved = secondSession.currentSavedEdit()
        XCTAssertEqual(resaved.lookId, "mono-red")
        XCTAssertNotNil(resaved.blackAndWhite, "the re-save lost the conversion")
    }

    /// A sidecar written by the shipped build has `blackAndWhite` but no `lookId` key. The mix
    /// itself names the look — a conversion only ever comes from one — so those edits recover
    /// rather than staying broken.
    func testAPreLookIdSidecarStillComesBackMono() throws {
        let url = photo()
        addTeardownBlock { EditStore.remove(for: url) }

        var legacy = freshSession().currentSavedEdit()
        legacy.lookId = nil                                       // the field did not exist
        legacy.blackAndWhite = LookPreset.named("mono-portrait")?.mono
        EditStore.save(legacy, for: url)

        let session = freshSession()
        session.apply(try XCTUnwrap(EditStore.load(for: url)))
        XCTAssertEqual(session.activeLookId, "mono-portrait",
                       "the mix identifies the look; a shipped-build sidecar must not stay broken")
        XCTAssertEqual(session.activeRecipe?.blackAndWhite,
                       LookPreset.named("mono-portrait")?.mono)
    }

    /// Clearing the look must also clear it from the next save — restoring is not sticking.
    func testClearingTheLookPersistsTheClearing() {
        let s = freshSession()
        s.applyLook("mono")
        s.applyLook(nil)
        XCTAssertNil(s.activeRecipe?.blackAndWhite)
        XCTAssertNil(s.currentSavedEdit().lookId)
        XCTAssertNil(s.currentSavedEdit().blackAndWhite)
    }

    /// The new structured limb: a look that carries a curve owns the tone character while it is
    /// active — and hands it back when cleared.
    func testALooksCurveReachesTheRecipeAndYieldsWhenCleared() {
        let s = freshSession()
        s.applyLook("matte")
        XCTAssertEqual(s.activeRecipe?.curve, LookPreset.named("matte")?.curve,
                       "the look's curve must land in the rendered recipe")
        s.applyLook(nil)
        XCTAssertNil(s.activeRecipe?.curve, "clearing the look must restore the candidate's curve")
    }
}
