import XCTest
import KelvinCore
@testable import KelvinApp

/// Gathering up what the scan found, and getting rid of frames.
///
/// The second half is the only thing in this app that touches an original, so the rules worth
/// pinning are the ones that decide whether someone's photographs survive a mistake.
@MainActor
final class CullingTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/shoot/\(name)") }

    private func state(with photos: [URL]) -> AppState {
        let s = AppState()
        s.folderPhotos = photos
        return s
    }

    /// A verdict with the findings this test cares about. The statistics and signature are
    /// placeholders — nothing here reads them, and the filter under test is about the concerns.
    private func verdict(_ concerns: [PhotoTriage.Concern]) -> PhotoTriage.Verdict {
        PhotoTriage.Verdict(
            concerns: concerns,
            focus: FocusMeasure.Reading(acuity: 4, measurable: true),
            statistics: ImageStatistics(
                meanLuma: 0.4, medianLuma: 0.4, blackPoint: 0, shadowLevel: 0.1,
                highlightLevel: 0.9, whitePoint: 1, highlightClip: 0, shadowClip: 0,
                chromaA: 0, chromaB: 0),
            signature: PhotoTriage.Signature(bits: 0, contrast: 10))
    }

    // MARK: Gathering what the scan found

    /// The gap this closes: a frame flagged `veryDark` drew a badge and could not be filtered on, so
    /// the one action the flag exists for — see them together, decide, move on — meant scrolling a
    /// whole shoot hunting for triangles.
    func testFlaggedGathersExposureConcernsThatFocusMisses() {
        let dark = url("dark.ARW"), fine = url("fine.ARW")
        let s = state(with: [dark, fine])
        s.triage = [dark: verdict([.veryDark]), fine: verdict([])]

        s.stripFilter = .soft
        XCTAssertFalse(s.visiblePhotos.contains(dark), "Focus should not claim an exposure concern")
        s.stripFilter = .flagged
        XCTAssertEqual(s.visiblePhotos, [dark])
    }

    /// And it is a union, not a replacement: a soft frame is still something the scan flagged.
    func testFlaggedIncludesSoftFrames() {
        let soft = url("soft.ARW"), fine = url("fine.ARW")
        let s = state(with: [soft, fine])
        // Below `softThreshold` (2.0), not equal to it — `isSoft` is a strict comparison.
        s.focus = [soft: FocusMeasure.Reading(acuity: 1.4, measurable: true)]
        s.stripFilter = .flagged
        XCTAssertEqual(s.visiblePhotos, [soft])
        XCTAssertEqual(s.flaggedCount, 1)
    }

    /// An unscanned shoot flags nothing. "Not measured yet" and "measured, and fine" must never
    /// read alike — the first is a reason to wait, the second a reason to move on.
    func testAnUnscannedShootFlagsNothing() {
        let s = state(with: [url("a.ARW"), url("b.ARW")])
        XCTAssertEqual(s.flaggedCount, 0)
        s.stripFilter = .flagged
        XCTAssertTrue(s.visiblePhotos.isEmpty)
    }

    // MARK: Trashing — the destructive one

    /// **Nothing happens without a confirmation.** Asking is a separate step from doing, so a
    /// mis-hit menu item cannot cost someone a frame.
    func testRequestingATrashDeletesNothingYet() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-cull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("_DSC0001.jpg")
        try Data("photo".utf8).write(to: photo)

        let s = state(with: [photo])
        s.requestTrash([photo])
        XCTAssertEqual(s.pendingTrash, [photo])
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path),
                      "requesting a trash must not remove anything")
        XCTAssertEqual(s.folderPhotos, [photo], "and the strip must still show it")
    }

    /// Cancelling clears the request and leaves the files alone.
    func testCancellingLeavesEverythingWhereItWas() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-cull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("_DSC0001.jpg")
        try Data("photo".utf8).write(to: photo)

        let s = state(with: [photo])
        s.requestTrash([photo])
        s.pendingTrash = []                       // what Cancel does
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path))
    }

    /// **The file goes to the Trash and is recoverable — it is never unlinked.** This is the whole
    /// reason offering deletion at all is defensible against non-negotiable #3, so it is asserted
    /// on the real filesystem rather than on a mock: the file must be gone from where it was AND
    /// still exist somewhere.
    func testConfirmingMovesTheFileToTheTrashRatherThanDestroyingIt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-cull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("_DSC0001.jpg")
        try Data("photo".utf8).write(to: photo)

        var recovered: NSURL?
        try FileManager.default.trashItem(at: photo, resultingItemURL: &recovered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path),
                       "it should be gone from the shoot folder")
        let landed = try XCTUnwrap(recovered as URL?)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path),
                      "and still exist in the Trash — unlinking would make this fail")
        try? FileManager.default.removeItem(at: landed)
    }

    /// A trashed frame leaves the working set, so the strip stops drawing something that is gone.
    func testATrashedFrameLeavesTheStrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-cull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)

        let s = state(with: [a, b])
        s.selectedPhotos = [a]
        s.requestTrash([a])
        s.confirmTrash()

        XCTAssertEqual(s.folderPhotos, [b])
        XCTAssertTrue(s.pendingTrash.isEmpty)
        XCTAssertFalse(s.selectedPhotos.contains(a), "a gone frame must not stay selected")
        XCTAssertTrue(s.statusMessage.contains("Trash"), "got: \(s.statusMessage)")
    }

    /// **The edit survives.** A trashed photo can be put back, and someone who restores a frame
    /// should find their work on it intact — orphaned sidecars cost kilobytes, destroying an
    /// afternoon's editing costs the afternoon.
    func testTrashingAPhotoKeepsItsEdit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-cull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("_DSC0001.jpg")
        try Data("photo".utf8).write(to: photo)

        let edit = SavedEdit(styleId: "natural", global: .neutral, userMasks: [], maskEnabled: [:],
                             maskStrength: [:], straighten: 0, hsl: [:], blackAndWhite: nil,
                             removeDust: false, recipe: nil, savedAt: "2026-07-28T00:00:00Z",
                             contentHint: nil)
        EditStore.save(edit, for: photo)
        defer { EditStore.remove(for: photo) }

        let s = state(with: [photo])
        s.requestTrash([photo])
        s.confirmTrash()

        XCTAssertNotNil(EditStore.load(for: photo),
                        "the edit was destroyed along with the file")
    }

    /// Several at once, which is the point — the scan finds forty soft frames and they get decided
    /// about together.
    func testAWholeSelectionCanGoAtOnce() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-cull-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try (0..<5).map { i -> URL in
            let u = dir.appendingPathComponent("f\(i).jpg")
            try Data("f".utf8).write(to: u)
            return u
        }
        let s = state(with: urls)
        s.requestTrash(Array(urls.prefix(3)))
        XCTAssertTrue(s.trashPrompt.contains("3 photos"), "got: \(s.trashPrompt)")
        s.confirmTrash()
        XCTAssertEqual(s.folderPhotos, Array(urls.suffix(2)))
    }

    /// One frame is named, not counted. "Move 1 photos to the Trash" is how a dialog stops being
    /// read, and the filename is the thing that makes the decision checkable.
    func testASingleFrameIsNamedInThePrompt() {
        let s = state(with: [url("_DSC0001.ARW")])
        s.requestTrash([url("_DSC0001.ARW")])
        XCTAssertTrue(s.trashPrompt.contains("_DSC0001.ARW"), "got: \(s.trashPrompt)")
    }

    func testAnEmptyRequestAsksNothing() {
        let s = state(with: [url("a.ARW")])
        s.requestTrash([])
        XCTAssertTrue(s.pendingTrash.isEmpty)
    }
}
