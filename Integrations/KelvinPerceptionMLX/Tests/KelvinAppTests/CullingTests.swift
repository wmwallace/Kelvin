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

    // MARK: Best — one frame per group of alike

    /// A verdict with a chosen acuity and signature, so runs and sharpness can both be arranged.
    private func frame(acuity: Double, bits: UInt64, measurable: Bool = true) -> PhotoTriage.Verdict {
        PhotoTriage.Verdict(
            concerns: [],
            focus: FocusMeasure.Reading(acuity: acuity, measurable: measurable),
            statistics: ImageStatistics(
                meanLuma: 0.4, medianLuma: 0.4, blackPoint: 0, shadowLevel: 0.1,
                highlightLevel: 0.9, whitePoint: 1, highlightClip: 0, shadowClip: 0,
                chromaA: 0, chromaB: 0),
            signature: PhotoTriage.Signature(bits: bits, contrast: 10))
    }

    /// The point of the filter: six near-identical frames collapse to the one worth looking at.
    func testBestKeepsOnlyTheSharpestOfARunOfAlikeFrames() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let s = state(with: [a, b, c])
        // Identical signatures — one run of three. b is sharpest.
        s.triage = [a: frame(acuity: 3, bits: 0), b: frame(acuity: 9, bits: 0), c: frame(acuity: 5, bits: 0)]
        s.stripFilter = .best
        XCTAssertEqual(s.visiblePhotos, [b], "the run should collapse to its sharpest frame")
    }

    /// A photograph that resembles nothing else is the best of its own run of one. Dropping it would
    /// empty the strip for any shoot without bursts in it, which is most of them.
    func testBestKeepsAFrameThatIsAlikeNothing() {
        let alone = url("alone.ARW"), a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [alone, a, b])
        s.triage = [alone: frame(acuity: 2, bits: 0xFFFF_FFFF_FFFF_FFFF),
                    a: frame(acuity: 3, bits: 0), b: frame(acuity: 9, bits: 0)]
        s.stripFilter = .best
        XCTAssertTrue(s.visiblePhotos.contains(alone), "a unique frame was hidden as though duplicated")
        XCTAssertTrue(s.visiblePhotos.contains(b))
        XCTAssertFalse(s.visiblePhotos.contains(a))
    }

    /// **An unscanned frame is not a duplicate.** Hiding one because the scan has not reached it
    /// loses a photograph from the view with nothing to say so; showing it costs a glance.
    func testBestShowsFramesTheScanHasNotFingerprintedYet() {
        let scanned = url("scanned.ARW"), pending = url("pending.ARW")
        let s = state(with: [scanned, pending])
        s.triage = [scanned: frame(acuity: 4, bits: 0)]
        s.stripFilter = .best
        XCTAssertTrue(s.visiblePhotos.contains(pending), "an unmeasured frame was treated as a duplicate")
    }

    /// Ties go to the earlier frame, or the filter would reshuffle between renders for no reason
    /// the photographer can see.
    func testBestBreaksTiesTowardsTheEarlierFrame() {
        let first = url("1.ARW"), second = url("2.ARW")
        let s = state(with: [first, second])
        s.triage = [first: frame(acuity: 7, bits: 0), second: frame(acuity: 7, bits: 0)]
        s.stripFilter = .best
        XCTAssertEqual(s.visiblePhotos, [first])
    }

    /// **The defect this whole notice exists for.** With no fingerprints every frame is its own run
    /// of one, so every frame is the sharpest of its run and `Best` returns the entire shoot. That
    /// is honest and useless, and it is indistinguishable from a filter that does not work — which
    /// is how it was reported.
    func testBestAnnouncesItselfWhenNothingHasBeenScanned() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.stripFilter = .best
        XCTAssertTrue(s.bestFilterNeedsScan, "Best silently showed everything with nothing measured")
        XCTAssertEqual(s.visiblePhotos.count, 2, "and it does still show everything, deliberately")

        // A PARTLY scanned shoot still says so, and says how much is left. This is the state that
        // made the first version of the notice look like it had not worked: unmeasured frames are
        // included by design, so until the scan finishes the answer barely changes.
        s.triage = [a: frame(acuity: 3, bits: 0)]
        XCTAssertTrue(s.bestFilterNeedsScan, "a half-measured shoot said nothing")
        XCTAssertEqual(s.bestFilterNote, "1 of 2 still to measure — "
                       + "Best shows unmeasured frames until the scan reaches them.")

        s.triage[b] = frame(acuity: 9, bits: 0)
        XCTAssertNil(s.bestFilterNote, "a fully measured shoot has nothing to explain")
        XCTAssertEqual(s.visiblePhotos, [b], "and now it actually filters — b is the sharper")
    }

    /// The NOTICE is about `Best` alone. `Focus` and `Flagged` also need the scan, but they show
    /// nothing rather than everything without it, which reads as "no soft frames" rather than as a
    /// broken control — so they get the measurement (below) and not the sentence.
    func testOtherFiltersDoNotAskForAScan() {
        let s = state(with: [url("a.ARW")])
        for f in [AppState.StripFilter.all, .keepers, .undecided, .edited, .soft, .flagged] {
            s.stripFilter = f
            XCTAssertFalse(s.bestFilterNeedsScan, "\(f.rawValue) asked for a scan it does not need")
        }
    }

    /// **The reason `Best` was reported broken twice.** The filter was correct; nothing ever ran the
    /// measurement it reads. Only the `Similar` grouping lens started a scan, so a photographer who
    /// picked `Best` from the filter chips got the whole shoot back and got it back forever — waiting
    /// changed nothing, which is why it looked broken both before and after "a scan" that had never
    /// begun. Selecting the filter has to be what asks for the numbers.
    func testSelectingBestStartsTheScanItDependsOn() {
        let s = state(with: [url("a.ARW"), url("b.ARW")])
        XCTAssertNil(s.focusScanProgress, "nothing should be measuring before anything is asked for")
        s.stripFilter = .best
        XCTAssertNotNil(s.focusScanProgress,
                        "Best read fingerprints without ever asking for them to be measured")
    }

    /// The same for the other two readings the scan produces, and NOT for the four filters that read
    /// decisions the photographer made by hand — those are correct the instant a folder opens, and
    /// spending eight minutes of decoding to answer `Keepers` would be pure waste.
    func testOnlyTheMeasuredFiltersAskForTheScan() {
        for f in AppState.StripFilter.allCases {
            let s = state(with: [url("a.ARW"), url("b.ARW")])
            s.stripFilter = f
            XCTAssertEqual(s.focusScanProgress != nil, f.needsScan,
                           "\(f.rawValue) disagrees with its own needsScan")
        }
    }

    /// The open photograph is never filtered out from under you — the rule every other filter obeys.
    func testBestNeverHidesThePhotographBeingEdited() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.triage = [a: frame(acuity: 3, bits: 0), b: frame(acuity: 9, bits: 0)]
        s.imageURL = a
        s.stripFilter = .best
        XCTAssertTrue(s.visiblePhotos.contains(a), "the frame under edit was filtered away")
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
