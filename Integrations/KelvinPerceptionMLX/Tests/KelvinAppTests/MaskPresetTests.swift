import XCTest
import KelvinCore
@testable import KelvinApp

/// A preset is a mask's settings with a name — these tests hold that equivalence to account.
/// If capture → instantiate is lossy, a photographer saves "Stormy sky", applies it next week,
/// and gets a quietly different mask than the one they tuned; nothing on screen would say so.
final class MaskPresetTests: XCTestCase {

    /// Round trip: every setting a preset claims to carry survives capture and instantiation.
    func testCaptureThenInstantiateIsLossless() {
        var m = UserMaskVM(kind: .sky)
        m.exposure = -0.7; m.contrast = 25; m.saturation = -12
        m.shadows = 5; m.highlights = -35; m.vibrance = 3
        m.feather = 20; m.tightness = 10; m.invert = true
        m.refinement = .luminance; m.refineCenter = 0.8; m.refineRange = 0.15; m.refineSoftness = 0.05

        let preset = MaskPreset.capturing(m, name: "My stormy sky")
        let back = preset.instantiate()

        XCTAssertEqual(back.kind, .sky)
        XCTAssertEqual(back.name, "My stormy sky", "the mask arrives wearing the preset's name")
        XCTAssertEqual(back.exposure, m.exposure); XCTAssertEqual(back.contrast, m.contrast)
        XCTAssertEqual(back.saturation, m.saturation); XCTAssertEqual(back.shadows, m.shadows)
        XCTAssertEqual(back.highlights, m.highlights); XCTAssertEqual(back.vibrance, m.vibrance)
        XCTAssertEqual(back.feather, m.feather); XCTAssertEqual(back.tightness, m.tightness)
        XCTAssertEqual(back.invert, m.invert)
        XCTAssertEqual(back.refinement, m.refinement)
        XCTAssertEqual(back.refineCenter, m.refineCenter)
        XCTAssertEqual(back.refineRange, m.refineRange)
        XCTAssertEqual(back.refineSoftness, m.refineSoftness)
        XCTAssertNotEqual(back.id, m.id, "a preset stamps out NEW masks, never aliases the original")
    }

    /// Strokes belong to one photograph's geometry and a person to one photograph's people —
    /// a preset that silently dropped either would apply as something other than what was saved.
    func testBrushAndPerPersonMasksAreNotCapturable() {
        // The three photo-bound kinds: a brush needs its strokes, a per-person mask needs its
        // person, and a wand needs the point it was seeded from. A wand preset is the tempting one
        // — a tolerance looks portable — but the seed is a coordinate on one frame, so it would
        // land on whatever happens to sit there in the next photograph and report success.
        let photoBound: Set<UserMaskVM.Kind> = [.brush, .instance, .wand]
        for kind in photoBound { XCTAssertFalse(MaskPreset.isCapturable(kind)) }
        for kind in UserMaskVM.Kind.allCases where !photoBound.contains(kind) {
            XCTAssertTrue(MaskPreset.isCapturable(kind), "\(kind) has nothing photo-bound in it")
        }
    }

    /// The built-ins are the shipped opinions — they must be well-formed and land in the region
    /// groups the menu shows, or a preset exists that no menu can reach.
    func testBuiltInsAreWellFormedAndAllReachableFromTheMenus() {
        let builtIns = MaskPreset.builtIns
        XCTAssertEqual(Set(builtIns.map(\.name)).count, builtIns.count, "preset names must be unique")
        for preset in builtIns {
            XCTAssertTrue(MaskPreset.isCapturable(preset.kind),
                          "\(preset.name): built-ins must be the same shape users can save")
            XCTAssertTrue(preset.builtIn)
        }
        let grouped = MaskPreset.grouped(withCustom: [])
        let reachable = Set(grouped.flatMap { $0.presets.map(\.name) })
        XCTAssertEqual(reachable, Set(builtIns.map(\.name)),
                       "every built-in must appear in exactly the menus")
    }

    /// A custom preset of a kind with no named group still gets a menu — the user's own work
    /// must never be saved into a place nothing displays.
    func testCustomPresetsOfUngroupedKindsLandInYours() {
        var radial = UserMaskVM(kind: .radial)
        radial.exposure = -0.4
        let custom = MaskPreset.capturing(radial, name: "Corner burn")
        let grouped = MaskPreset.grouped(withCustom: [custom])
        let yours = grouped.first { $0.label == "Yours" }
        XCTAssertEqual(yours?.presets.map(\.name), ["Corner burn"])
    }

    /// Saved presets survive the trip to disk and back byte-for-byte in meaning.
    func testStoreRoundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-preset-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mask-presets.json")

        var m = UserMaskVM(kind: .skin)
        m.exposure = 0.2; m.selRange = 0.09
        let saved = [MaskPreset.capturing(m, name: "Gentle skin")]
        MaskPresetStore.save(saved, to: url)
        let loaded = MaskPresetStore.load(from: url)
        XCTAssertEqual(loaded, saved)
    }

    /// An unreadable or absent file means an empty library, never a crash and never invented data.
    func testLoadingNothingYieldsNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-no-such-presets-\(UUID().uuidString).json")
        XCTAssertEqual(MaskPresetStore.load(from: missing), [])
    }
}
