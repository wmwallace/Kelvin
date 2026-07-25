import XCTest
import KelvinCore
@testable import KelvinApp

/// The contract between the mask panel and the renderer, asserted in the app where the panel lives.
///
/// `AppState.assertCoversTheContract()` already checks this at launch — but only in debug builds,
/// only when someone runs the app, and a crash on launch is a poor way to learn that a slider list
/// drifted. It exists because the app package had no test target. It has one now, so the check can
/// happen in a second rather than at the next launch, and it can say more than an assertion can.
final class MaskEditorContractTests: XCTestCase {

    @MainActor private var keys: [String] { AppState.maskAdjustmentSpecs.map(\.key) }

    /// The bug that motivated `Mask.adjustmentKeys`: two hand-written lists of mask adjustments,
    /// six in one editor and three in the other, so half the renderer's local capability was
    /// unreachable from a mask you drew by hand.
    @MainActor
    func testThePanelOffersExactlyTheAdjustmentsTheRendererHonours() {
        XCTAssertEqual(Set(keys), Set(Mask.adjustmentKeys),
                       "panel and renderer disagree about "
                       + "\(Set(keys).symmetricDifference(Set(Mask.adjustmentKeys))): a key the "
                       + "renderer has and the panel lacks is capability nobody can reach; a key "
                       + "the panel has and the renderer lacks is a slider that does nothing")
    }

    /// One row per adjustment. A duplicate key would draw two sliders bound to the same value,
    /// which reads as a control that moves on its own.
    @MainActor
    func testThePanelDrawsEachAdjustmentOnce() {
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate key in the panel's slider list")
    }

    /// Ranges have to be usable and have to include neutral, because zero is where every one of
    /// these adjustments does nothing — a slider you cannot return to its rest position is a
    /// change you cannot undo by hand.
    @MainActor
    func testEveryAdjustmentCanBeReturnedToNeutral() {
        for spec in AppState.maskAdjustmentSpecs {
            XCTAssertTrue(spec.range.contains(0), "`\(spec.key)` cannot be set back to neutral")
            XCTAssertLessThan(spec.range.lowerBound, spec.range.upperBound, "`\(spec.key)`")
        }
    }

    /// Highlight recovery is offered as a one-sided control on purpose, and the reason is a
    /// measurement rather than a preference: `CIHighlightShadowAdjust` treats 1.0 as "no change"
    /// and clamps above it, so the renderer's positive half is dead at ΔE 0.0 (measured in
    /// KelvinCore's `MaskAdjustmentTests`). A slider dead across half its travel is worse than a
    /// shorter one. If the renderer ever gains a live positive highlight path, this test is the
    /// reminder that the panel should grow to match.
    @MainActor
    func testHighlightRecoveryIsOfferedOnlyWhereItIsLive() throws {
        let spec = try XCTUnwrap(AppState.maskAdjustmentSpecs.first { $0.key == "highlights" })
        XCTAssertEqual(spec.range.upperBound, 0,
                       "the renderer's positive highlight range is a no-op; do not offer it")
        XCTAssertLessThan(spec.range.lowerBound, 0, "recovery has to go somewhere")
    }

    /// Every adjustment slider is drawn with a rail that describes the ACTION it performs. `.plain`
    /// is the "no honest reading in light" case, reserved for geometry and softness — an adjustment
    /// falling through to it means a key nobody taught the rail about, which shows up as a slider
    /// that is visually mute next to its neighbours.
    @MainActor
    func testEveryAdjustmentSliderHasARailThatDescribesIt() {
        for key in keys {
            if case .plain = ToneIdentity.adjustment(key) {
                XCTFail("`\(key)` has no tone rail — add it to ToneIdentity.adjustment")
            }
        }
    }

    /// A mask's local exposure is in EV and everything else is in percent-ish units. Mislabelling
    /// the unit is how a −3 EV mask gets dragged expecting −3%.
    @MainActor
    func testOnlyExposureIsLabelledInEV() {
        for spec in AppState.maskAdjustmentSpecs {
            XCTAssertEqual(spec.unit.contains("EV"), spec.key == "exposure_ev", "`\(spec.key)`")
        }
    }
}
