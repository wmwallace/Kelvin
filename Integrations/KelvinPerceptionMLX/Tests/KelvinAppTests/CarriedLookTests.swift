import XCTest
import CoreImage
import AppKit
import KelvinCore
@testable import KelvinApp

/// A shoot's look is the WHOLE choice — a style and, when one is on, a creative look on top (D29).
///
/// "Apply to shoot" used to carry only the style: pick Soft + Portrait film on the hero frame and
/// every other frame came back Soft, with the film look silently gone. These pin the record that
/// fixes it (and that every record already on disk still reads), what an override means, the one
/// composition rule the canvas and the export share, and the thing that is easiest to break without
/// noticing — that a carried look is not a hand edit, so opening a frame of a Portrait-film shoot
/// does not quietly turn it into one.
///
/// No test here writes into Application Support: records go to a temporary store, and every
/// `applyLook` that schedules a commit does so while no photograph owns the panel.
@MainActor
final class CarriedLookTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/shoot/\(name)") }

    private func temporaryStore() throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kelvin-shoots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    /// A candidate with a colour grade in its curve, so a test can see whose curve survived.
    private func graded(_ id: String) throws -> Recipe {
        var r = Recipe.neutral
        r.id = id
        r.label = CandidateStyle.all.first { $0.id == id }?.label
        r.global.contrast = id == "soft" ? -16 : 0
        let json = #"{"luma": [[0, 0], [0.5, 0.45], [1, 1]], "red": [[0, 0], [0.5, 0.55], [1, 1]]}"#
        r.curve = try JSONDecoder().decode(Curve.self, from: Data(json.utf8))
        return r
    }

    /// A photograph in memory with its candidates up — what `loadPhoto` leaves behind — and no
    /// photograph owning the panel yet, so nothing the setup does can file an edit anywhere.
    private func session(photos: [URL], candidates ids: [String]) throws -> AppState {
        let s = AppState()
        s.shootLookDirectory = try temporaryStore()
        s.folderPhotos = photos
        s.proxyCI = CIImage(color: CIColor(red: 0.5, green: 0.45, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        s.candidates = try ids.map { id in
            CandidateViewModel(id: id, label: CandidateStyle.all.first { $0.id == id }?.label ?? id,
                               baseRecipe: try graded(id), previewImage: NSImage())
        }
        addTeardownBlock { s.resetReadAhead() }
        return s
    }

    // MARK: The record

    /// Every record written before D29 has no look and must read exactly as it always did — same
    /// style, same overrides, and no creative look anywhere. JSON as a shipped build wrote it.
    func testARecordFromBeforeLooksDecodesWithNoLook() throws {
        let legacy = #"""
        {
          "appliedAt" : "2026-08-02T09:00:00Z",
          "overrides" : { "/shoot/b.ARW" : "dramatic" },
          "style" : "soft",
          "version" : 1
        }
        """#
        let look = try JSONDecoder().decode(ShootLook.self, from: Data(legacy.utf8))
        XCTAssertEqual(look.style(for: url("a.ARW")), "soft")
        XCTAssertEqual(look.style(for: url("b.ARW")), "dramatic")
        XCTAssertNil(look.lookId)
        XCTAssertTrue(look.overrideLooks.isEmpty)
        XCTAssertNil(look.lookId(for: url("a.ARW")), "a legacy record grew a look it never had")
        XCTAssertNil(look.lookId(for: url("b.ARW")))
    }

    /// Only `version` is assumed; a record missing any other key still decodes rather than making
    /// the shoot forget it was ever given a look.
    func testASparseRecordStillDecodes() throws {
        let look = try JSONDecoder().decode(ShootLook.self, from: Data(#"{"version": 1}"#.utf8))
        XCTAssertNil(look.style)
        XCTAssertTrue(look.overrides.isEmpty)
    }

    /// The new shape survives a write and a read — through a temporary store, never the real one.
    func testALookAndItsOverrideLooksSurviveTheRoundTrip() throws {
        let store = try temporaryStore()
        let folder = URL(fileURLWithPath: "/shoots/wedding")
        let look = ShootLook(style: "soft", overrides: [url("b.ARW").path: "natural"],
                             appliedAt: "2026-09-24T10:00:00Z", lookId: "portra",
                             overrideLooks: [url("b.ARW").path: "mono"])
        ShootLookStore.save(look, for: folder, in: store)
        XCTAssertEqual(try XCTUnwrap(ShootLookStore.load(for: folder, in: store)), look)
    }

    /// Additive, not a new format: still version 1, so an older build reads the style and ignores
    /// the look rather than failing on the record.
    func testTheRecordStaysVersionOne() throws {
        let data = try JSONEncoder().encode(ShootLook(style: "soft", lookId: "portra"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["lookId"] as? String, "portra")
    }

    // MARK: What an apply writes, look included

    func testAWholeShootApplyRecordsTheLookWithTheStyle() {
        let a = url("a.ARW"), b = url("b.ARW")
        let look = ShootLook().applying("soft", look: "portra", to: [a, b], inShootOf: [a, b])
        XCTAssertEqual(look.style, "soft")
        XCTAssertEqual(look.lookId, "portra")
        XCTAssertEqual(look.lookId(for: a), "portra")
        XCTAssertEqual(look.lookId(for: b), "portra")
    }

    /// Applying a style with no look over a shoot in Portrait film takes the film look off: the
    /// apply is the whole choice, and the choice now has no look in it.
    func testAWholeShootApplyWithoutALookClearsTheOldOne() {
        let a = url("a.ARW"), b = url("b.ARW")
        let look = ShootLook(style: "soft", overrides: [a.path: "vivid"],
                             lookId: "portra", overrideLooks: [a.path: "mono"])
            .applying("natural", to: [a, b], inShootOf: [a, b])
        XCTAssertNil(look.lookId)
        XCTAssertTrue(look.overrideLooks.isEmpty, "an override's look survived an apply that covered it")
        XCTAssertNil(look.lookId(for: a))
    }

    /// An override is a whole choice. Frames singled out for Mono stay Mono under a Portrait-film
    /// shoot, and frames singled out with NO look do not inherit the shoot's.
    func testAnOverrideCarriesItsOwnLookAndNeverInheritsTheShoots() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let shoot = ShootLook().applying("soft", look: "portra", to: [a, b, c], inShootOf: [a, b, c])
        let monoOnA = shoot.applying("natural", look: "mono", to: [a], inShootOf: [a, b, c])
        let bareOnB = monoOnA.applying("vivid", to: [b], inShootOf: [a, b, c])

        XCTAssertEqual(bareOnB.style(for: a), "natural")
        XCTAssertEqual(bareOnB.lookId(for: a), "mono")
        XCTAssertEqual(bareOnB.style(for: b), "vivid")
        XCTAssertNil(bareOnB.lookId(for: b), "a frame singled out with no look inherited the shoot's")
        XCTAssertEqual(bareOnB.lookId(for: c), "portra", "the rest of the shoot lost its look")
    }

    /// Re-applying to a frame without a look removes the look an earlier apply gave it.
    func testReapplyingAnOverrideWithoutALookRemovesItsLook() {
        let a = url("a.ARW"), b = url("b.ARW")
        let first = ShootLook().applying("soft", look: "mono", to: [a], inShootOf: [a, b])
        let second = first.applying("soft", to: [a], inShootOf: [a, b])
        XCTAssertNil(second.lookId(for: a))
        XCTAssertNil(second.overrideLooks[a.path])
    }

    /// A frame the record does not claim has no style, and so no look: the look only ever rides on
    /// a style.
    func testAnUnclaimedFrameCarriesNoLook() {
        let a = url("a.ARW"), b = url("b.ARW")
        let look = ShootLook().applying("soft", look: "portra", to: [a], inShootOf: [a, b])
        XCTAssertNil(look.style(for: b))
        XCTAssertNil(look.lookId(for: b))
    }

    // MARK: Applying and clearing, through the app

    /// THE BUG. Soft + Portrait film on the hero frame, applied to the shoot, must record both —
    /// in memory and on disk — and say both on screen.
    func testApplyingToTheShootRecordsTheActiveLook() throws {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = try session(photos: [a, b], candidates: ["natural", "soft"])
        s.selectCandidate(id: "soft")
        s.applyLook("portra")              // while no photograph owns the panel: nothing is filed
        s.loadedURL = a
        XCTAssertTrue(s.applyButtonHelp.hasPrefix("Put Soft + Portrait film on all 2 photos"),
                      s.applyButtonHelp)

        s.applyLookToShoot()
        s.resetReadAhead()

        XCTAssertEqual(s.shootLook?.style, "soft")
        XCTAssertEqual(s.shootLook?.lookId, "portra", "the creative look was dropped on the way to the shoot")
        let onDisk = try XCTUnwrap(ShootLookStore.load(for: URL(fileURLWithPath: "/shoot"),
                                                       in: s.shootLookDirectory))
        XCTAssertEqual(onDisk.lookId, "portra")
        XCTAssertTrue(s.statusMessage.hasPrefix("This shoot is in Soft + Portrait film"), s.statusMessage)
        XCTAssertEqual(s.effectiveLook(for: b)?.id, "portra")
        // The hero now shows exactly what the shoot gives it, so it is no longer a hand edit.
        XCTAssertFalse(s.isTouched, "the hero frame still reads as edited after its look became the shoot's")
    }

    /// Clearing takes the look off with the style — on disk, in memory and on the frame on screen,
    /// which was only in Portrait film because the shoot put it there.
    func testClearingTheShootTakesTheLookOffToo() throws {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = try session(photos: [a, b], candidates: ["natural", "soft"])
        s.selectCandidate(id: "soft")
        s.applyLook("portra")
        s.loadedURL = a
        s.applyLookToShoot()
        s.resetReadAhead()

        s.clearShootLook()
        XCTAssertNil(s.shootLook)
        XCTAssertNil(ShootLookStore.load(for: URL(fileURLWithPath: "/shoot"), in: s.shootLookDirectory))
        XCTAssertNil(s.activeLookId, "the cleared shoot's look was left on the frame on screen")
        XCTAssertNil(s.activeRecipe?.blackAndWhite)
        XCTAssertFalse(s.isTouched, "clearing turned the shoot's look into a hand edit")
    }

    // MARK: The canvas

    /// A claimed frame opens in the style WITH the look, composed exactly as the export composes it
    /// — and that is what "untouched" means on it, so it is not saved as a hand edit.
    func testAClaimedFrameOpensInTheStyleAndTheLookAndIsNotAnEdit() throws {
        let a = url("a.ARW")
        let s = try session(photos: [a], candidates: ["natural", "soft"])
        s.shootLook = ShootLook(style: "soft", lookId: "portra")
        s.loadedURL = a
        s.selectCandidate(id: "soft")

        XCTAssertEqual(s.activeLookId, "portra")
        XCTAssertFalse(s.isTouched, "opening a frame of a Portrait-film shoot counted as editing it")
        let canvas = try XCTUnwrap(s.activeRecipe)
        let export = ShootLook.finished(try graded("soft"), look: "portra")
        XCTAssertEqual(canvas.global, export.global, "canvas and export disagree about the look's sliders")
        XCTAssertEqual(canvas.hsl, export.hsl)
        XCTAssertEqual(canvas.curve, export.curve)
        XCTAssertEqual(canvas.blackAndWhite, export.blackAndWhite)
    }

    /// The same for a mono look, where the composition rule is at its least obvious: the grade
    /// comes off and the conversion goes on, on both paths.
    func testAMonoLookComposesTheSameOnTheCanvasAsInTheExport() throws {
        let a = url("a.ARW")
        let s = try session(photos: [a], candidates: ["soft"])
        s.shootLook = ShootLook(style: "soft", lookId: "mono-red")
        s.loadedURL = a
        s.selectCandidate(id: "soft")
        let canvas = try XCTUnwrap(s.activeRecipe)
        let export = ShootLook.finished(try graded("soft"), look: "mono-red")
        XCTAssertEqual(canvas.blackAndWhite, LookPreset.named("mono-red")?.mono)
        XCTAssertEqual(canvas.blackAndWhite, export.blackAndWhite)
        XCTAssertEqual(canvas.curve, export.curve)
        XCTAssertNil(canvas.curve?.red, "the colour grade reached the grey print")
        XCTAssertEqual(canvas.global, export.global)
    }

    /// When the curator drops the shoot's style for a frame it falls back — and the creative look
    /// still goes on. A preset is chosen on its own terms; a frame that could not be Soft is still
    /// in Portrait film.
    func testTheLookSurvivesTheCuratorsFallback() throws {
        let a = url("a.ARW")
        let s = try session(photos: [a], candidates: ["natural"])      // Soft was culled here
        s.shootLook = ShootLook(style: "soft", lookId: "portra")
        s.loadedURL = a
        s.selectCandidate(id: "natural")
        XCTAssertEqual(s.activeLookId, "portra")
        XCTAssertFalse(s.isTouched)
    }

    /// Taking the carried look off, or moving a slider on top of it, IS an edit — that is what
    /// makes it outrank the shoot from then on. Reset puts the shoot's look back, and is not one.
    func testChangingTheCarriedLookIsAnEditAndResetIsNot() throws {
        let a = url("a.ARW")
        let s = try session(photos: [a], candidates: ["soft"])
        s.shootLook = ShootLook(style: "soft", lookId: "portra")
        s.selectCandidate(id: "soft")      // before ownership, so no commit can be filed
        s.loadedURL = a
        s.resetToCandidate()
        XCTAssertEqual(s.activeLookId, "portra")
        XCTAssertFalse(s.isTouched)

        s.loadedURL = nil
        s.applyLook(nil)
        s.loadedURL = a
        XCTAssertTrue(s.isTouched, "taking the shoot's look off this frame was not counted as an edit")

        s.resetToCandidate()
        XCTAssertEqual(s.activeLookId, "portra", "Reset stripped the look the shoot carries")
        XCTAssertFalse(s.isTouched, "pressing Reset created an edit")

        var nudged = s.edit
        nudged.exposureEV += 0.3
        s.edit = nudged
        XCTAssertTrue(s.isTouched)
    }

    /// Precedence #1 is unchanged: a hand-made edit restored over the frame replaces the carried
    /// look entirely, including a deliberate "no look".
    func testAHandEditOutranksTheCarriedLook() throws {
        let a = url("a.ARW")
        let s = try session(photos: [a], candidates: ["soft"])
        s.selectCandidate(id: "soft")
        var saved = s.currentSavedEdit()                 // Soft, no look, as saved by hand
        saved.lookId = nil
        s.shootLook = ShootLook(style: "soft", lookId: "portra")
        s.loadedURL = a
        s.selectCandidate(id: "soft")
        XCTAssertEqual(s.activeLookId, "portra")
        s.apply(saved)
        XCTAssertNil(s.activeLookId, "the shoot's look beat a hand-made edit")
        XCTAssertTrue(s.isTouched, "a hand edit that removed the shoot's look must stay an edit")
    }

    // MARK: The export

    /// The export's composition is `LookPreset.applied(to:)` on top of the resolved style — the one
    /// rule — and nothing at all when there is no look, or the id is one the library lost.
    func testTheExportComposesTheStyleAndTheLookByTheOneRule() throws {
        let resolved = try graded("soft")
        let portra = try XCTUnwrap(LookPreset.named("portra"))
        let finished = ShootLook.finished(resolved, look: "portra")
        XCTAssertEqual(finished.global, portra.applied(to: resolved).global)
        XCTAssertEqual(finished.hsl, portra.applied(to: resolved).hsl)
        XCTAssertEqual(finished.label, "Soft", "the recipe's own label names the style that was resolved")
        XCTAssertNotEqual(finished.global, resolved.global, "the look did nothing")

        XCTAssertEqual(ShootLook.finished(resolved, look: nil).global, resolved.global)
        XCTAssertEqual(ShootLook.finished(resolved, look: "no-such-look").global, resolved.global)
    }

    /// Files are named the way the canvas's own export names them: the creative look when one is
    /// on, the style otherwise.
    func testAnExportIsNamedForTheLookWhenOneIsCarried() {
        XCTAssertEqual(AppState.exportLookName(lookId: "portra", style: "Soft"), "Portrait film")
        XCTAssertEqual(AppState.exportLookName(lookId: nil, style: "Soft"), "Soft")
        XCTAssertEqual(AppState.exportLookName(lookId: "no-such-look", style: "Soft"), "Soft")
    }

    func testTheChoiceIsSaidAsStylePlusLook() {
        XCTAssertEqual(ShootLook.choiceLabel(style: "Soft", look: "portra"), "Soft + Portrait film")
        XCTAssertEqual(ShootLook.choiceLabel(style: "Soft", look: nil), "Soft")
    }
}
