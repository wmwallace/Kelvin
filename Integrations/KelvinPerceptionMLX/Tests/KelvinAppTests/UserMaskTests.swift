import XCTest
import KelvinCore
@testable import KelvinApp

/// `UserMaskVM` is the app's hand-drawn mask, and `toMask()` is the only door between it and the
/// renderer. Everything a photographer dials into a mask has to fit through that door; anything
/// that does not is a control that moves and changes nothing.
///
/// This is not a hypothetical failure mode. The two mask editors drifted apart — the auto masks
/// (subject, sky) offered six local adjustments while every hand-drawn mask offered three — so
/// `shadows`, `highlights` and `vibrance` were unreachable on the masks people actually draw, on
/// all nine kinds. `Mask.adjustmentKeys` now exists in Core as the single contract, and these tests
/// hold the app side of it against that list rather than against a hand-written copy of it, which
/// is the only arrangement in which the two cannot disagree again.
final class UserMaskTests: XCTestCase {

    /// Distinct, non-zero, and different per key on purpose: equal values would let a `toMask()`
    /// that wrote the same number under two keys pass.
    private func distinctValues() -> [String: Double] {
        var out: [String: Double] = [:]
        for (i, key) in Mask.adjustmentKeys.enumerated() { out[key] = Double(i + 1) * -3 }
        return out
    }

    private func loaded(kind: UserMaskVM.Kind) -> (vm: UserMaskVM, values: [String: Double]) {
        var vm = UserMaskVM(kind: kind)
        let values = distinctValues()
        for (key, value) in values { vm[adjustment: key] = value }
        return (vm, values)
    }

    // MARK: The adjustment contract

    /// The subscript the editor's sliders bind through must address every adjustment the renderer
    /// honours. A key it silently ignores is a slider that returns to zero the instant you let go.
    func testEveryContractAdjustmentSurvivesTheSubscript() {
        for key in Mask.adjustmentKeys {
            var vm = UserMaskVM(kind: .radial)
            vm[adjustment: key] = -42
            XCTAssertEqual(vm[adjustment: key], -42, accuracy: 1e-9,
                           "`\(key)` is in the renderer's contract but UserMaskVM cannot hold it")
        }
    }

    /// The drift that shipped, stated as a property: what the VM carries is exactly what reaches
    /// the `Mask`. Not "at least" — extra keys would mean the app inventing adjustments the
    /// renderer has never been asked to honour.
    func testEveryAdjustmentTheVMHoldsReachesTheMask() {
        for kind in allKinds {
            let (vm, values) = loaded(kind: kind)
            let mask = vm.toMask()
            XCTAssertEqual(Set(mask.adjustments.keys), Set(Mask.adjustmentKeys),
                           "\(kind) mask carries \(Set(mask.adjustments.keys).symmetricDifference(Set(Mask.adjustmentKeys))) "
                           + "more or fewer adjustments than the renderer's contract")
            for (key, expected) in values {
                XCTAssertEqual(mask.adjustments[key] ?? .nan, expected, accuracy: 1e-9,
                               "\(kind) mask dropped or altered `\(key)` on the way to the renderer")
            }
        }
    }

    /// A mask nobody has adjusted must not send neutral values to the renderer. Neutral entries
    /// would put every mask through the full adjustment path for no visible reason, and the
    /// all-neutral-renders-a-no-op invariant depends on absence rather than on zeros.
    func testUntouchedAdjustmentsAreOmittedRatherThanSentAsZero() {
        for kind in allKinds {
            XCTAssertTrue(UserMaskVM(kind: kind).toMask().adjustments.isEmpty,
                          "\(kind): an untouched mask should carry no adjustments at all")
        }
    }

    private let allKinds: [UserMaskVM.Kind] = [
        .radial, .linear, .brush, .colorRange, .luminance, .skin, .background, .subject, .instance,
        .sky
    ]

    /// `.sky` hands the photographer the same region the engine's own sky treatment uses — the
    /// segmentation bitmap under the type key the renderer already speaks.
    func testSkyIsTheSkyRegionFromSegmentation() {
        let mask = UserMaskVM(kind: .sky).toMask()
        XCTAssertEqual(mask.type, "sky")
        XCTAssertEqual(mask.source, "segmentation")
        XCTAssertNil(mask.selection, "no selection: the region comes from segmentation")
        XCTAssertGreaterThan(mask.feather, 0, "a hard-edged sky line is the giveaway of a bad mask")
    }

    // MARK: One primitive, several presets

    /// `.background` is not a kind of region — it is the subject region with `invert` set for you.
    /// Asserting the *shape* of what it produces (a segmentation subject mask, inverted) rather
    /// than a type string is what keeps the preset honest if the vocabulary moves again.
    func testBackgroundIsTheSubjectRegionInverted() {
        let mask = UserMaskVM(kind: .background).toMask()
        XCTAssertEqual(mask.type, "subject")
        XCTAssertEqual(mask.source, "segmentation")
        XCTAssertTrue(mask.invert, "the background is everything the subject is not")
        XCTAssertNil(mask.selection, "no selection: the region comes from segmentation")
    }

    /// Inverting the background asks for the subject back. `invert` is a modifier over one region,
    /// so two inversions cancel rather than compounding into something meaningless.
    func testInvertingABackgroundMaskGivesTheSubjectBack() {
        var vm = UserMaskVM(kind: .background)
        vm.invert = true
        let mask = vm.toMask()
        XCTAssertEqual(mask.type, "subject")
        XCTAssertFalse(mask.invert, "invert on a background mask is the subject, not the frame")
    }

    /// `.skin` is the subject region narrowed to skin hues — the same pixels the old bespoke
    /// `type: "skin"` renderer branch computed, said in the general vocabulary.
    func testSkinIsTheSubjectRegionNarrowedToColour() {
        var vm = UserMaskVM(kind: .skin)
        vm.selCenter = 0.06; vm.selRange = 0.06; vm.selSoftness = 0.05
        let mask = vm.toMask()
        XCTAssertEqual(mask.type, "subject")
        XCTAssertEqual(mask.source, "segmentation")
        XCTAssertFalse(mask.invert)
        XCTAssertEqual(mask.refine?.kind, .color,
                       "skin is a COLOUR narrowing — a luminance one would select by brightness, "
                       + "which is the unfair-across-complexions version of this mask")
        XCTAssertEqual(mask.refine, Mask.skinRefinement,
                       "the app's skin defaults must be the range Core documents as fair across "
                       + "complexions, not a second opinion about it")
    }

    /// A skin mask scoped to one person is THAT subject's region narrowed to skin hues — same id
    /// contract as a per-subject mask, so the renderer finds the person's bitmap and export
    /// re-identifies them at full resolution. Brightening the bride's skin must not brighten the
    /// groom's.
    func testSkinScopedToOnePersonBecomesThatInstanceStillNarrowedToColour() {
        var vm = UserMaskVM(kind: .skin)
        vm.selCenter = 0.06; vm.selRange = 0.06; vm.selSoftness = 0.05
        vm.instanceId = "person0"
        let mask = vm.toMask()
        XCTAssertEqual(mask.type, "instance")
        XCTAssertEqual(mask.id, "person0",
                       "the mask's id must BE the instance id — that is how the renderer looks up "
                       + "the person's bitmap")
        XCTAssertEqual(mask.refine, Mask.skinRefinement,
                       "scoping to one person must not lose the skin narrowing — that would be a "
                       + "person mask wearing a skin mask's name")
        XCTAssertEqual(vm.boundInstanceId, "person0",
                       "export re-identification walks boundInstanceId; a scoped skin mask must "
                       + "be visible to it or the edit silently vanishes from full-size output")
    }

    /// The skin range the app hands a new mask is Core's, not a private copy that can drift from it.
    @MainActor
    func testANewSkinMaskUsesCoresDocumentedSkinRange() throws {
        let state = AppState()
        state.addUserMask(.skin)
        let vm = try XCTUnwrap(state.userMasks.last)
        XCTAssertEqual(vm.toMask().refine, Mask.skinRefinement)
    }

    /// Region-defining kinds must actually carry their region. A gradient with no `shape`, or a
    /// colour range with no `selection`, reaches the renderer as a mask over nothing.
    func testEachKindCarriesTheRegionItIsMadeOf() {
        var radial = UserMaskVM(kind: .radial)
        radial.cx = 0.2; radial.cy = 0.8; radial.radius = 0.4; radial.softness = 0.1
        let radialMask = radial.toMask()
        XCTAssertEqual(radialMask.shape?.kind, .radial)
        XCTAssertEqual(radialMask.shape?.cx ?? .nan, 0.2, accuracy: 1e-9)
        XCTAssertEqual(radialMask.shape?.cy ?? .nan, 0.8, accuracy: 1e-9)

        var linear = UserMaskVM(kind: .linear)
        linear.angle = 33
        XCTAssertEqual(linear.toMask().shape?.kind, .linear)
        XCTAssertEqual(linear.toMask().shape?.angle ?? .nan, 33, accuracy: 1e-9)

        var brush = UserMaskVM(kind: .brush)
        brush.stamps = [BrushStamp(x: 0.5, y: 0.5, radius: 0.1)]
        XCTAssertEqual(brush.toMask().stamps?.count, 1)

        var colour = UserMaskVM(kind: .colorRange)
        colour.selCenter = 0.3; colour.selRange = 0.2
        XCTAssertEqual(colour.toMask().selection?.kind, .color)
        XCTAssertEqual(colour.toMask().selection?.center ?? .nan, 0.3, accuracy: 1e-9)

        var luma = UserMaskVM(kind: .luminance)
        luma.selCenter = 0.78
        XCTAssertEqual(luma.toMask().selection?.kind, .luminance)
        XCTAssertEqual(luma.toMask().selection?.center ?? .nan, 0.78, accuracy: 1e-9)
    }

    /// A per-subject mask is looked up by the instance id, not by the view-model's UUID — the
    /// renderer and the export path both find its bitmap under that key, so getting this wrong is
    /// an edit that lands on nobody.
    func testInstanceMasksAreKeyedByTheSubjectTheyBelongTo() {
        var vm = UserMaskVM(kind: .instance)
        vm.instanceId = "person-2"
        XCTAssertEqual(vm.toMask().id, "person-2")
        XCTAssertEqual(vm.toMask().type, "instance")
    }

    // MARK: The universal modifier

    /// REFINE is offered on every mask in the editor, unconditionally. It therefore has to *work*
    /// on every mask: narrowing a graduated filter to its highlights, or a person to the reds, is
    /// the whole reason the mask kinds were collapsed into one primitive.
    ///
    /// A kind that quietly substitutes its own refinement is a control that moves and lies about
    /// what it did — worse than a dead one, because the mask still changes.
    func testRefinementIsHonouredOnEveryKindTheEditorOffersItOn() {
        for kind in allKinds {
            var vm = UserMaskVM(kind: kind)
            vm.refinement = .luminance
            vm.refineCenter = 0.9; vm.refineRange = 0.2; vm.refineSoftness = 0.05
            let mask = vm.toMask()
            XCTAssertEqual(mask.refine?.kind, .luminance,
                           "\(kind): the editor shows a REFINE picker for this mask, so choosing "
                           + "'Light' must produce a luminance narrowing")
            XCTAssertEqual(mask.refine?.center ?? .nan, 0.9, accuracy: 1e-9, "\(kind)")
        }
    }

    /// Refinement off means no narrowing at all, not a narrowing with neutral numbers — an
    /// unrefined mask must reach the renderer as the plain region it looks like on screen.
    func testRefinementOffLeavesTheRegionAlone() {
        for kind in allKinds where kind != .skin {   // .skin is a refinement by definition
            XCTAssertNil(UserMaskVM(kind: kind).toMask().refine,
                         "\(kind): REFINE is off, so the mask must be the bare region")
        }
    }

    // MARK: Naming

    /// Three radial masks in a list all called "Radial" is the state this replaced. A renamed mask
    /// shows its name; an unnamed one falls back to what it is rather than to nothing.
    func testDisplayNameFallsBackToTheKindRatherThanShowingBlank() {
        var vm = UserMaskVM(kind: .radial)
        XCTAssertEqual(vm.displayName, "Radial")
        vm.name = "Sky corner"
        XCTAssertEqual(vm.displayName, "Sky corner")
        vm.name = "   "
        XCTAssertEqual(vm.displayName, "Radial", "whitespace is not a name")
    }

    /// An instance mask is called after the subject it was made from, because "Subject" tells you
    /// nothing when there are three people in the frame.
    func testInstanceMasksAreNamedAfterTheirSubject() {
        var vm = UserMaskVM(kind: .instance)
        XCTAssertEqual(vm.displayName, "Subject", "no label yet — say something rather than blank")
        vm.instanceLabel = "Person 2"
        XCTAssertEqual(vm.displayName, "Person 2")
    }
}
