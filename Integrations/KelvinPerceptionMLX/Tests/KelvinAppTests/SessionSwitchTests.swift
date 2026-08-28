import XCTest
import CoreImage
import KelvinCore
@testable import KelvinApp

/// Switching photographs, which is the most common thing anybody does in this app and the place
/// where its state is most likely to be filed under the wrong name.
///
/// Two facts make this hard, and both are deliberate. `imageURL` moves the moment you click, while
/// `loadedURL` moves only when a decode lands — so for seconds at a time the app is *showing* one
/// photograph and *holding* another. And `clearPerPhotoState` empties the panel in between, on
/// purpose, without moving `loadedURL`, so a failed load can still be retried.
///
/// Everything below is a rule about that window. Each one is a bug that shipped: state filed under
/// the previous photograph, an edit deleted because the cleared panel read as untouched, a shoot
/// left listing the folder someone had walked away from, a location tick carried onto a stranger's
/// frame. None of them needs a decode to check.
@MainActor
final class SessionSwitchTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/shoot/\(name)") }

    private var image: CIImage {
        CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
    }

    /// A photograph that is loaded, in memory, and hand-edited — the state the app is in whenever
    /// somebody clicks the next thumbnail.
    private func loaded(_ photo: URL) -> AppState {
        let s = AppState()
        s.imageURL = photo
        s.loadedURL = photo
        s.fullResCI = image
        s.proxyCI = image
        s.editedURLs = [photo]
        return s
    }

    private func session(for photo: URL) -> PhotoSession {
        PhotoSession(
            url: photo, imageId: "id", fullResCI: image, proxyCI: image,
            originalPreviewImage: nil, perception: nil, candidates: [],
            openedInByRule: nil,
            proxyMaskBitmaps: [:], subjectInstances: [], subjectLuma: nil,
            subjectOrigin: nil, skyLuma: nil, healSpots: [],
            capture: CaptureInfo(), activeLookId: nil,
            maskAdjustments: [:], maskFeather: [:], maskTightness: [:], maskInvert: [:],
            selectedCandidateId: nil, edit: .neutral, editBaseline: .neutral,
            baseMasks: [], maskEnabled: [:], maskStrength: [:], userMasks: [],
            straighten: 0, hsl: [:])
    }

    // MARK: Filing state under the photograph it belongs to

    /// THE ONE THAT DELETES WORK. Between `clearPerPhotoState` and the new decode landing, the
    /// panel is empty but `loadedURL` still names the photograph you just left. A stash in that
    /// window filed the empty panel under that photograph — and because an empty panel reads as
    /// untouched, `persistEdit` took it as "this frame has no edit" and removed the saved one.
    ///
    /// Clicking a third thumbnail while the second was still decoding was enough to trigger it.
    func testAStashDuringTheClearedWindowDoesNotFileTheEmptyPanelUnderThePreviousPhoto() {
        let p = url("p.ARW")
        let s = loaded(p)
        s.userMasks = [UserMaskVM(kind: .brush)]

        // Leaving p: it is stashed intact, and only then torn down.
        s.stashCurrentSession()
        XCTAssertNotNil(s.sessions[p], "the outgoing photograph is stashed on the way out")
        XCTAssertTrue(s.editedURLs.contains(p))
        s.clearPerPhotoState()

        // A third click arrives before the new decode lands.
        s.stashCurrentSession()

        XCTAssertFalse(s.sessions[p]?.userMasks.isEmpty ?? true,
                       "the stashed session must still hold p's mask, not the cleared panel")
        XCTAssertTrue(s.editedURLs.contains(p),
                      "p is still edited — the cleared panel is not evidence that it is not")
    }

    /// The flag is a statement about the window, not about the photograph: once a decode lands or a
    /// cached session is restored, the state in memory describes `loadedURL` again and filing it is
    /// correct. Without this, one clear would suppress every stash for the rest of the run.
    func testRestoringAPhotographReopensTheWindowForStashing() {
        let p = url("p.ARW"), q = url("q.ARW")
        let s = loaded(p)
        s.clearPerPhotoState()
        XCTAssertTrue(s.perPhotoStateIsCleared)

        s.restore(session(for: q))
        XCTAssertFalse(s.perPhotoStateIsCleared)

        s.userMasks = [UserMaskVM(kind: .brush)]
        s.stashCurrentSession()
        XCTAssertFalse(s.sessions[q]?.userMasks.isEmpty ?? true,
                       "q is loaded and edited, so q must file normally")
    }

    // MARK: What belongs to one photograph and must not follow you to the next

    /// Including a location is a decision about ONE photograph. The reset for it lived in
    /// `clearPerPhotoState`, which a cached-session hop never reaches — so a tick made for a frame
    /// with GPS was still ticked on the next frame, whose checkbox may not even be on screen.
    func testARestoredPhotographForgetsThePreviousOnesLocationTick() {
        let p = url("p.ARW"), q = url("q.ARW")
        let s = loaded(p)
        s.shareIncludeLocation = true

        s.restore(session(for: q))

        XCTAssertFalse(s.shareIncludeLocation)
    }

    // MARK: Arriving in a shoot

    /// `enterShoot` is the housekeeping both arrival paths share. It used to live inside
    /// `loadPhoto` only, so restoring a cached frame from another folder left the strip listing the
    /// old shoot and the export label still naming it — and Apply then covered a folder the user
    /// had left.
    func testEnteringAShootRelistsTheStripAndDropsWhatNamedTheLastOne() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-session-switch-\(UUID().uuidString)")
        let one = root.appendingPathComponent("shoot-one")
        let two = root.appendingPathComponent("shoot-two")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = one.appendingPathComponent("a.jpg")
        let b = two.appendingPathComponent("b.jpg")
        let c = two.appendingPathComponent("c.jpg")
        for f in [a, b, c] { try Data([0]).write(to: f) }

        let s = AppState()
        s.folderPhotos = [a]
        s.exportLabel = "Lake Como"
        s.selectedPhotos = [a]
        s.imageURL = b

        let entered = await s.enterShoot(around: b)

        XCTAssertTrue(entered)
        // By name: the lister resolves symlinks, and on macOS the temporary directory is one.
        XCTAssertEqual(Set(s.folderPhotos.map(\.lastPathComponent)), ["b.jpg", "c.jpg"],
                       "the strip lists the shoot you are in")
        XCTAssertEqual(s.exportLabel, "", "a label names one shoot and does not follow you")
        XCTAssertTrue(s.selectedPhotos.isEmpty, "a selection names one shoot too")
    }

    /// The contract that makes the above safe to call from an async path: the listing takes a trip
    /// to the filesystem, and on a share that is long enough to arrow away twice. A listing that
    /// lands for a photograph the user has already left must be dropped, not applied.
    func testAShootThatLandsForAPhotographYouHaveLeftIsDropped() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-session-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.jpg")
        try Data([0]).write(to: a)

        let s = AppState()
        s.folderPhotos = []
        s.imageURL = URL(fileURLWithPath: "/elsewhere/z.ARW")

        let entered = await s.enterShoot(around: a)

        XCTAssertFalse(entered, "the caller must abandon a load that has been superseded")
        XCTAssertTrue(s.folderPhotos.isEmpty, "and nothing about the old shoot may be overwritten")
    }
}
