import XCTest
import KelvinCore
@testable import KelvinApp

/// Where an edit goes when you quit, and how it finds its way back to the right photograph.
///
/// Kelvin never writes next to someone's originals, so edits live in the app's own directory keyed
/// by the photo's path. That trade is recorded in `EditStore` itself; what is not recorded anywhere
/// is that the keying has to be *stable* (the same photo must find its edit tomorrow) and
/// *injective* (two photos must never land on one file, which would silently give one of them the
/// other's edit).
final class EditStoreTests: XCTestCase {

    private func photo(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: Keying

    func testTheSamePhotoAlwaysResolvesToTheSameEditFile() {
        XCTAssertEqual(EditStore.url(for: photo("/shoot/_DSC0001.ARW")),
                       EditStore.url(for: photo("/shoot/_DSC0001.ARW")))
    }

    /// Paths that mean the same file must mean the same edit. `/shoot/./a.ARW` and `/shoot/a.ARW`
    /// are one photograph, and arriving by a drop rather than a file picker should not lose the
    /// work you did on it.
    func testEquivalentPathsForOnePhotoShareOneEdit() {
        XCTAssertEqual(EditStore.url(for: photo("/shoot/./_DSC0001.ARW")),
                       EditStore.url(for: photo("/shoot/_DSC0001.ARW")))
    }

    /// Different photographs must never collide — including two files of the same name in
    /// different folders, which is the ordinary shape of a shoot split across cards.
    func testDifferentPhotosNeverShareAnEditFile() {
        let urls = ["/shoot/a/_DSC0001.ARW", "/shoot/b/_DSC0001.ARW", "/shoot/a/_DSC0002.ARW"]
            .map(photo)
        XCTAssertEqual(Set(urls.map { EditStore.url(for: $0) }).count, urls.count)
    }

    /// The filename Kelvin writes carries no part of the original's path. The store is deliberately
    /// outside the photo library, and a directory listing of it should not read as an inventory of
    /// someone's folders.
    func testTheEditFileNameDoesNotLeakThePhotosPath() {
        let name = EditStore.url(for: photo("/Users/someone/Pictures/Wedding/_DSC0001.ARW"))
            .deletingPathExtension().lastPathComponent
        XCTAssertFalse(name.localizedCaseInsensitiveContains("wedding"))
        XCTAssertFalse(name.localizedCaseInsensitiveContains("_DSC0001"))
        XCTAssertEqual(name.count, 64, "a SHA-256 hex digest")
    }

    // MARK: The edit itself

    /// A full edit, written and read back. Values are absolute rather than a diff against the
    /// candidate on purpose — a later engine version might generate a different candidate, and the
    /// edit you made must not drift because of it — so what goes to disk is the whole of it.
    func testAnEditSurvivesQuittingTheApp() throws {
        let url = photo("/kelvin-tests/\(UUID().uuidString)/_DSC0001.ARW")
        addTeardownBlock { EditStore.remove(for: url) }

        var mask = UserMaskVM(kind: .radial)
        mask.exposure = -0.8
        mask.name = "Corner"

        let edit = SavedEdit(styleId: "warm", global: .neutral, userMasks: [mask],
                             maskEnabled: ["subject": false], maskStrength: ["subject": 60],
                             straighten: -1.4, hsl: ["blue": HSLAdjustment(h: 3, s: -12, l: 5)],
                             blackAndWhite: nil,
                             healSpots: [HealSpot(x: 0.31, y: 0.22, radius: 0.012,
                                                  dx: 0.03, dy: -0.02)],
                             savedAt: "2026-07-24T10:00:00Z", contentHint: "abc123")
        EditStore.save(edit, for: url)

        let restored = try XCTUnwrap(EditStore.load(for: url), "the edit did not come back at all")
        XCTAssertEqual(restored.styleId, "warm")
        XCTAssertEqual(restored.maskEnabled, ["subject": false])
        XCTAssertEqual(restored.maskStrength, ["subject": 60])
        XCTAssertEqual(restored.straighten, -1.4, accuracy: 1e-9)
        XCTAssertEqual(restored.hsl, ["blue": HSLAdjustment(h: 3, s: -12, l: 5)])
        XCTAssertEqual(restored.healSpots?.count, 1, "the heal did not come back")
        XCTAssertEqual(restored.healSpots?.first?.x ?? -1, 0.31, accuracy: 1e-9)
        XCTAssertEqual(restored.userMasks, [mask], "the mask came back changed")
    }

    /// A photo nobody has edited has no edit — distinct from an empty one, because the filmstrip's
    /// "already worked on" dot is drawn from exactly this question.
    func testAPhotoWithNoSavedEditReportsNothingRatherThanAnEmptyEdit() {
        XCTAssertNil(EditStore.load(for: photo("/kelvin-tests/\(UUID().uuidString)/never.ARW")))
    }

    func testEditedTellsTheStripWhichFramesHaveBeenWorkedOn() {
        let worked = photo("/kelvin-tests/\(UUID().uuidString)/worked.ARW")
        let untouched = photo("/kelvin-tests/\(UUID().uuidString)/untouched.ARW")
        addTeardownBlock { EditStore.remove(for: worked) }

        EditStore.save(SavedEdit(styleId: nil, global: .neutral, userMasks: [], maskEnabled: [:],
                                 maskStrength: [:], straighten: 0, hsl: [:], blackAndWhite: nil,
                                 healSpots: nil, savedAt: "2026-07-24T10:00:00Z",
                                 contentHint: nil),
                       for: worked)

        XCTAssertEqual(EditStore.edited(among: [worked, untouched]), [worked])
    }

    /// Discarding an edit has to actually discard it. A "reset" that leaves the file behind means
    /// the work reappears on the next launch.
    func testRemovingAnEditLeavesNoTrace() {
        let url = photo("/kelvin-tests/\(UUID().uuidString)/_DSC0002.ARW")
        EditStore.save(SavedEdit(styleId: nil, global: .neutral, userMasks: [], maskEnabled: [:],
                                 maskStrength: [:], straighten: 0, hsl: [:], blackAndWhite: nil,
                                 healSpots: nil, savedAt: "2026-07-24T10:00:00Z",
                                 contentHint: nil),
                       for: url)
        XCTAssertNotNil(EditStore.load(for: url))
        EditStore.remove(for: url)
        XCTAssertNil(EditStore.load(for: url))
        XCTAssertTrue(EditStore.edited(among: [url]).isEmpty)
    }
}
