import XCTest
@testable import KelvinCore

final class LookPresetTests: XCTestCase {

    func testLibraryIsWellFormed() {
        let library = LookPreset.library
        XCTAssertFalse(library.isEmpty)
        XCTAssertEqual(Set(library.map(\.id)).count, library.count, "preset ids must be unique")
        for look in library {
            XCTAssertFalse(look.name.isEmpty)
            XCTAssertFalse(look.blurb.isEmpty, "a preset you must apply to understand is a bad preset")
        }
    }

    /// Every black-and-white look must actually carry a mix — otherwise picking one would leave
    /// the photo in colour and only shift the tone, which is a confusing half-result.
    func testEveryMonoLookConverts() {
        for look in LookPreset.library where look.group == .blackAndWhite {
            XCTAssertNotNil(look.mono, "\(look.id) is filed under black & white but has no mix")
        }
        for look in LookPreset.library where look.group == .creative {
            XCTAssertNil(look.mono, "\(look.id) is a colour look but converts to grey")
        }
    }

    /// Looks are deltas on the candidate, so applying one must not wipe out the engine's work.
    func testLooksAreDeltasNotReplacements() {
        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.6          // the engine's corrective exposure
        g.contrast = 10
        let before = g.exposureEV
        LookPreset.named("faded")!.apply(to: &g)
        XCTAssertEqual(g.exposureEV, before, "a look must not overwrite corrective exposure")
        XCTAssertLessThan(g.contrast, 10, "faded film should soften the candidate's contrast")
        XCTAssertGreaterThan(g.blacks, 0, "faded film lifts the blacks")
    }

    /// Re-applying looks must not compound — the app applies each to the untouched baseline.
    func testApplyingIsIdempotentFromTheSameBaseline() {
        let baseline = GlobalAdjustments.neutral
        var once = baseline, twice = baseline
        LookPreset.named("golden")!.apply(to: &once)
        LookPreset.named("golden")!.apply(to: &twice)
        XCTAssertEqual(once, twice)
    }

    func testTemperatureShiftOnlyAppliesWhenThereIsATemperature() {
        var asShot = GlobalAdjustments.neutral            // temperatureK == nil
        LookPreset.named("golden")!.apply(to: &asShot)
        XCTAssertNil(asShot.temperatureK, "as-shot must stay as-shot")

        var warmed = GlobalAdjustments.neutral
        warmed.temperatureK = 5500
        LookPreset.named("golden")!.apply(to: &warmed)
        XCTAssertGreaterThan(warmed.temperatureK ?? 0, 5500, "golden hour warms")
    }
}
