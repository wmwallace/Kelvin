import XCTest
import CoreImage
import AppKit
import KelvinCore
@testable import KelvinApp

/// A pick is the photographer's, and it must never cost them their work.
///
/// `selectCandidate` puts a candidate up fresh and resets the undo history, which is right when the
/// app chooses and was wrong when a person did: a click on the tile already selected, or a stray
/// number key during a cull, threw every slider move away with no undo. `pickCandidate` is the
/// user-facing route, and these pin its two promises.
@MainActor
final class CandidatePickTests: XCTestCase {

    private func session() -> AppState {
        let s = AppState()
        s.proxyCI = CIImage(color: CIColor(red: 0.5, green: 0.45, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var soft = Recipe.neutral
        soft.global.contrast = -12
        soft.id = "soft"
        s.candidates = [
            CandidateViewModel(id: "natural", label: "Natural", baseRecipe: .neutral,
                               previewImage: NSImage()),
            CandidateViewModel(id: "soft", label: "Soft", baseRecipe: soft, previewImage: NSImage()),
        ]
        s.selectCandidate(id: "natural")
        return s
    }

    func testPickingTheTileYouAreOnKeepsYourEdits() {
        let s = session()
        s.edit.exposureEV = 0.7
        s.hsl["red"] = HSLAdjustment(h: 0, s: 10, l: 0)
        s.pickCandidate(id: "natural")
        XCTAssertEqual(s.edit.exposureEV, 0.7, "re-picking the current look reset the sliders")
        XCTAssertEqual(s.hsl["red"]?.s, 10)
    }

    func testTheNumberKeyForTheCurrentLookIsHarmlessToo() {
        let s = session()
        s.edit.shadows = 25
        s.selectCandidateIndex(0)
        XCTAssertEqual(s.edit.shadows, 25)
    }

    func testTryingAnotherLookAndComingBackBringsTheWorkBack() {
        let s = session()
        s.edit.exposureEV = 0.4
        s.straighten = 2
        s.pickCandidate(id: "soft")
        XCTAssertEqual(s.edit.contrast, -12, "the other look must come up as generated")
        XCTAssertEqual(s.edit.exposureEV, 0, "and without the first look's hand edits on it")
        XCTAssertEqual(s.straighten, 0)

        s.pickCandidate(id: "natural")
        XCTAssertEqual(s.edit.exposureEV, 0.4, "coming back to a look must restore its work")
        XCTAssertEqual(s.straighten, 2)
    }

    /// Parked work is still the photograph's work: an untouched look on screen must not read as
    /// "no edit" and delete the sidecar that holds it.
    func testParkedWorkKeepsTheSavedEditOnDisk() throws {
        let url = URL(fileURLWithPath: "/kelvin-tests/\(UUID().uuidString)/_DSC0001.ARW")
        addTeardownBlock { EditStore.remove(for: url) }
        let s = session()
        s.edit.exposureEV = 0.4
        EditStore.save(s.currentSavedEdit(), for: url)
        s.pickCandidate(id: "soft")
        XCTAssertFalse(s.candidateWork.isEmpty)
        XCTAssertNotNil(EditStore.load(for: url))
    }

    /// Switching photographs forgets the parked work with everything else per-photo — it belongs
    /// to one frame's candidates, and the next frame's are different recipes.
    func testClearingThePhotoForgetsParkedWorkAndTheSliders() {
        let s = session()
        s.edit.exposureEV = 0.4
        s.pickCandidate(id: "soft")
        s.clearPerPhotoState()
        XCTAssertTrue(s.candidateWork.isEmpty)
        XCTAssertEqual(s.edit, .neutral, "the outgoing photo's sliders stood through the next decode")
    }
}
