import XCTest
import KelvinCore
@testable import KelvinApp

/// Masks go to disk. `SavedEdit` writes the array of `UserMaskVM` into the edit store and reads it
/// back on the next launch, so this type has two obligations that pull in opposite directions:
///
/// 1. **Nothing may be lost on the way out.** An edit that comes back different from the one you
///    made is worse than an edit that fails to load — you cannot see what went missing, only that
///    the photograph is wrong somehow.
/// 2. **Nothing may break on the way in.** Sidecars already exist on disk, written before newer
///    fields did. They must keep opening, with sensible values for what they never carried.
///
/// The second is the one the type's own comments are careful about ("optional-with-default so a
/// sidecar written before these existed still decodes"). The first is the one nothing was checking.
final class UserMaskCodableTests: XCTestCase {

    private func roundTrip(_ vm: UserMaskVM) throws -> UserMaskVM {
        let data = try JSONEncoder().encode(vm)
        return try JSONDecoder().decode(UserMaskVM.self, from: data)
    }

    /// A mask with every field set to something distinctly non-default, saved and reopened. This
    /// is the whole promise of a non-destructive editor: the recipe is the work, and it survives.
    func testAFullyConfiguredMaskSurvivesASaveAndReopen() throws {
        var vm = UserMaskVM(kind: .radial)
        vm.cx = 0.21; vm.cy = 0.79; vm.radius = 0.44; vm.angle = 17; vm.softness = 0.22
        vm.selCenter = 0.33; vm.selRange = 0.12; vm.selSoftness = 0.04
        vm.tightness = 61; vm.feather = 12; vm.invert = true
        for (i, key) in Mask.adjustmentKeys.enumerated() { vm[adjustment: key] = Double(i + 1) * -2 }
        vm.refinement = .luminance
        vm.refineCenter = 0.88; vm.refineRange = 0.19; vm.refineSoftness = 0.03
        vm.name = "Her face"

        XCTAssertEqual(try roundTrip(vm), vm,
                       "a mask came back from disk different from the one that was saved")
    }

    /// The wand's own two fields, stated separately for the same reason the three below are: they
    /// are new, `CodingKeys` and `init(from:)` are both hand-written, and getting one of the two
    /// halves right loses the value silently — the file grows the field and nothing reads it back,
    /// or nothing writes it and the defaults come back looking untouched. A wand that reopened at
    /// tolerance 0.10 having been saved at 0.04 would select something else entirely.
    func testAWandsSeedAndToleranceSurviveASaveAndReopen() throws {
        var vm = UserMaskVM(kind: .wand)
        vm.cx = 0.766; vm.cy = 0.635          // the right-hand sea stack on _DSC6390
        vm.wandTolerance = 0.04; vm.wandSoftness = 0.6
        let back = try roundTrip(vm)
        XCTAssertEqual(back.wandTolerance, 0.04, accuracy: 1e-9)
        XCTAssertEqual(back.wandSoftness, 0.6, accuracy: 1e-9)
        XCTAssertEqual(back.cx, 0.766, accuracy: 1e-9, "the seed moved")
        XCTAssertEqual(back, vm)

        // And it must reach the renderer's own vocabulary, not just survive on the way to disk.
        XCTAssertEqual(back.toMask().region,
                       RegionSeed(x: 0.766, y: 0.635, tolerance: 0.04, softness: 0.6))
    }

    /// A mask saved before the wand existed still opens, and does not come back claiming to be one.
    func testAMaskSavedBeforeTheWandExistedStillOpens() throws {
        let json = #"{"kind":"radial","cx":0.3,"cy":0.4}"#
        let vm = try JSONDecoder().decode(UserMaskVM.self, from: Data(json.utf8))
        XCTAssertEqual(vm.kind, .radial)
        XCTAssertNil(vm.toMask().region, "a radial mask must not carry a region seed")
        XCTAssertEqual(vm.wandTolerance, 0.10, accuracy: 1e-9, "defaults changed under old files")
    }

    /// Stated separately from the round trip above, because this is the specific loss that matters:
    /// `shadows`, `highlights` and `vibrance` are the three adjustments that were unreachable on
    /// hand-drawn masks until recently. Making them reachable and then not persisting them would
    /// be the same bug wearing a different coat — the sliders would work until you reopened the
    /// photograph.
    func testTheAdjustmentsThatWereJustMadeReachableAlsoSurviveDisk() throws {
        var vm = UserMaskVM(kind: .brush)
        for (i, key) in Mask.adjustmentKeys.enumerated() { vm[adjustment: key] = Double(i + 1) * 4 }
        let restored = try roundTrip(vm)
        for key in Mask.adjustmentKeys {
            XCTAssertEqual(restored[adjustment: key], vm[adjustment: key], accuracy: 1e-9,
                           "`\(key)` did not survive being written to a sidecar and read back")
        }
    }

    /// The refinement is the universal modifier — "the skin within this person", "the highlights
    /// inside this graduated filter". Losing it on reopen turns a narrowed mask back into the whole
    /// region, which changes the picture silently.
    func testTheRefinementSurvivesDisk() throws {
        var vm = UserMaskVM(kind: .linear)
        vm.refinement = .colour
        vm.refineCenter = 0.07; vm.refineRange = 0.11; vm.refineSoftness = 0.02
        let restored = try roundTrip(vm)
        XCTAssertEqual(restored.refinement, .colour)
        XCTAssertEqual(restored.refineCenter, 0.07, accuracy: 1e-9)
        XCTAssertEqual(restored.refineRange, 0.11, accuracy: 1e-9)
        XCTAssertEqual(restored.refineSoftness, 0.02, accuracy: 1e-9)
        // What the renderer is eventually handed is the thing that has to be right.
        XCTAssertEqual(restored.toMask().refine, vm.toMask().refine)
    }

    /// Renaming a mask is how a panel with four masks in it stays legible. A name that vanishes on
    /// reopen leaves the list of "Radial, Radial, Radial" it was introduced to fix.
    func testAMaskNameSurvivesDisk() throws {
        var vm = UserMaskVM(kind: .radial)
        vm.name = "Sky corner"
        XCTAssertEqual(try roundTrip(vm).displayName, "Sky corner")
    }

    /// A per-subject mask's identity has to survive, because the id alone does not: detection runs
    /// again on reopen with fresh per-pass indices, and the box is what matches the mask back to
    /// the same person.
    func testInstanceIdentitySurvivesDisk() throws {
        var vm = UserMaskVM(kind: .instance)
        vm.instanceId = "person-1"
        vm.instanceLabel = "Person 2"
        vm.instanceBox = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        vm.instanceKind = .person
        let restored = try roundTrip(vm)
        XCTAssertEqual(restored.instanceId, "person-1")
        XCTAssertEqual(restored.instanceLabel, "Person 2")
        XCTAssertEqual(restored.instanceBox, CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        XCTAssertEqual(restored.instanceKind, .person)
    }

    // MARK: Old sidecars

    /// The oldest shape of saved mask: a kind, a geometry, and the three adjustments that were all
    /// there used to be. No shadows, no highlights, no vibrance, no refinement, no name, no id.
    ///
    /// Written out as literal JSON rather than produced by an old encoder, because that is what is
    /// actually sitting in someone's Application Support directory. It has to open, and it has to
    /// open as the mask it was — not as a mask with surprise values in the fields it never had.
    func testASidecarWrittenBeforeTheNewerFieldsExistedStillOpens() throws {
        let json = """
        {
          "kind": "radial",
          "cx": 0.3, "cy": 0.7, "radius": 0.4, "angle": 0, "softness": 0.35,
          "stamps": [],
          "selCenter": 0, "selRange": 0.1, "selSoftness": 0.1,
          "exposure": -0.6, "contrast": 12, "saturation": -8,
          "tightness": 0, "feather": 0, "invert": false
        }
        """
        let vm = try JSONDecoder().decode(UserMaskVM.self, from: Data(json.utf8))

        // What it did carry, unchanged.
        XCTAssertEqual(vm.kind, .radial)
        XCTAssertEqual(vm.cx, 0.3, accuracy: 1e-9)
        XCTAssertEqual(vm[adjustment: "exposure_ev"], -0.6, accuracy: 1e-9)
        XCTAssertEqual(vm[adjustment: "contrast"], 12, accuracy: 1e-9)
        XCTAssertEqual(vm[adjustment: "saturation"], -8, accuracy: 1e-9)

        // What it did not: neutral, so reopening an old edit does not change the photograph.
        XCTAssertEqual(vm[adjustment: "shadows"], 0, accuracy: 1e-9)
        XCTAssertEqual(vm[adjustment: "highlights"], 0, accuracy: 1e-9)
        XCTAssertEqual(vm[adjustment: "vibrance"], 0, accuracy: 1e-9)
        XCTAssertEqual(vm.refinement, .none, "an old mask narrowed nothing")
        XCTAssertNil(vm.name)
        XCTAssertNil(vm.toMask().refine)

        // The renderer must see the same three adjustments it saw before, and no others.
        XCTAssertEqual(Set(vm.toMask().adjustments.keys), ["exposure_ev", "contrast", "saturation"])
    }

    /// The minimum a sidecar can say. Everything but the kind is optional, and a mask that decodes
    /// with a missing field must land on the same value a freshly created one has — otherwise
    /// "opened an old edit" and "made a new mask" are two different masks that look identical.
    func testAMaskWithOnlyAKindDecodesToTheSameDefaultsANewOneHas() throws {
        let vm = try JSONDecoder().decode(UserMaskVM.self, from: Data(#"{"kind":"brush"}"#.utf8))
        var fresh = UserMaskVM(kind: .brush)
        fresh.id = vm.id            // a sidecar without an id gets a new one; that is intended
        XCTAssertEqual(vm, fresh)
    }

    /// Each mask keeps its own identity across a save. Two masks that come back sharing an id would
    /// collide in the renderer's bitmap lookup and in the mask list's selection.
    func testIdentityIsStableAcrossASaveSoMasksDoNotCollide() throws {
        let a = UserMaskVM(kind: .radial), b = UserMaskVM(kind: .radial)
        let data = try JSONEncoder().encode([a, b])
        let restored = try JSONDecoder().decode([UserMaskVM].self, from: data)
        XCTAssertEqual(restored.map(\.id), [a.id, b.id])
    }

    /// An unrecognised kind is the one thing that legitimately fails: there is no sensible mask to
    /// fall back to, and guessing would apply an adjustment somewhere the photographer never put
    /// one. Failing means the edit does not load, which is visible; guessing is not.
    func testAnUnknownKindFailsRatherThanGuessing() {
        let json = Data(#"{"kind":"holographic"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(UserMaskVM.self, from: json))
    }
}
