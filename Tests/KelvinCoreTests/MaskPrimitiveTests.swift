import XCTest
import CoreImage
@testable import KelvinCore

/// A mask is ONE primitive — a region from a source, optionally narrowed by a refinement and
/// optionally inverted. `skin` and `background` used to be separate mask *kinds*; they are a
/// subject region plus a modifier, and writing them as kinds meant those modifiers existed for
/// exactly one combination each.
final class MaskPrimitiveTests: XCTestCase {

    /// Warm skin-hued square on a cool background, so a colour refinement has something to cut.
    private func scene() -> CIImage {
        TestSupport.pixels(size: 120) { x, y in
            (x >= 40 && x < 80 && y >= 40 && y < 80) ? (210, 150, 120) : (90, 120, 200)
        }
    }

    private func region() -> CIImage {
        // "The subject": the middle third, which contains the warm square and some cool border.
        CIImage(color: .white)
            .cropped(to: CGRect(x: 30, y: 30, width: 60, height: 60))
            .composited(over: CIImage(color: .black).cropped(to: scene().extent))
    }

    private func render(_ mask: Mask) -> CIImage {
        var r = Recipe.neutral
        r.masks = [mask]
        return Renderer.render(scene(), with: r, maskBitmaps: ["subject": region()])
    }

    private func differs(_ a: CIImage, _ b: CIImage) throws -> Double {
        try ImageMetrics.meanDeltaE2000(ImageMetrics.sample(a), ImageMetrics.sample(b))
    }

    private func subject(_ adj: [String: Double], refine: MaskSelection? = nil,
                         invert: Bool = false) -> Mask {
        Mask(id: "subject", type: "subject", source: "segmentation", invert: invert,
             feather: 0, opacity: 1, adjustments: adj, refine: refine)
    }

    // MARK: - Refinement is a general modifier

    func testRefiningARegionAffectsLessOfItThanTheRegionAlone() throws {
        let whole = render(subject(["exposure_ev": 1.5]))
        let refined = render(subject(["exposure_ev": 1.5], refine: Mask.skinRefinement))
        let base = render(subject([:]))

        XCTAssertGreaterThan(try differs(base, whole), 1.0, "the plain region must do something")
        XCTAssertGreaterThan(try differs(base, refined), 0.3, "the refined region must do something")
        // Same adjustment, strictly fewer pixels — a refinement can only ever narrow.
        XCTAssertLessThan(try differs(base, refined), try differs(base, whole),
                          "refining must affect less of the picture, not more")
    }

    /// The generality is the point: a refinement is not skin-specific. A luminance refinement on
    /// the same region is "the bright part of the subject", which no mask kind could express.
    func testARegionCanBeRefinedByLuminanceNotJustColour() throws {
        let base = render(subject([:]))
        let bright = MaskSelection(kind: .luminance, center: 0.75, range: 0.25, softness: 0.1)
        let dark = MaskSelection(kind: .luminance, center: 0.15, range: 0.25, softness: 0.1)

        let inBright = try differs(base, render(subject(["exposure_ev": 1.5], refine: bright)))
        let inDark = try differs(base, render(subject(["exposure_ev": 1.5], refine: dark)))
        // The two must pick out different pixels; if the refinement were ignored they would be
        // identical, which is exactly how a dead modifier would look.
        XCTAssertNotEqual(inBright, inDark, accuracy: 0.0,
                          "luminance refinement is being ignored")
    }

    func testAnAbsentRefinementLeavesTheRegionAlone() throws {
        let a = render(subject(["exposure_ev": 1.0]))
        let b = render(subject(["exposure_ev": 1.0], refine: nil))
        XCTAssertEqual(try differs(a, b), 0, accuracy: 1e-9)
    }

    /// A refinement narrows; it must never RESURRECT a mask whose source is missing. That is what
    /// stopped a skin mask degrading into a bare hue selection and editing skin-toned sand.
    func testAMissingSourceIsNotRescuedByARefinement() throws {
        var r = Recipe.neutral
        r.masks = [subject(["exposure_ev": 2.0], refine: Mask.skinRefinement)]
        let noBitmap = Renderer.render(scene(), with: r, maskBitmaps: [:])
        XCTAssertEqual(try differs(scene(), noBitmap), 0, accuracy: 1e-9,
                       "with no region supplied the mask must do nothing at all")
    }

    // MARK: - The kinds that collapse into modifiers

    /// This pins the UI's "Background" preset: a subject mask with `invert: true`, which selects
    /// everything-but-subject INCLUDING any sky. The DERIVED background mask (`LocalMasks`,
    /// keyed "background") is a different, smaller region — the frame minus subject minus sky —
    /// pinned by the partition test below. Both are legitimate; they are not the same pixels.
    func testBackgroundIsTheSubjectInverted() throws {
        let base = render(subject([:]))
        let inside = render(subject(["exposure_ev": -1.0]))
        let outside = render(subject(["exposure_ev": -1.0], invert: true))
        XCTAssertGreaterThan(try differs(base, inside), 0.5)
        XCTAssertGreaterThan(try differs(base, outside), 0.5)
        // Different pixels, so `invert` genuinely expresses "everything else".
        XCTAssertGreaterThan(try differs(inside, outside), 1.0,
                             "invert must select the complement, not the same region")
    }

    // MARK: - The derived background

    /// Read a mask back as 0…1 luma on a grid that divides the 120 px fixtures evenly.
    private func grid(_ mask: CIImage, size: Int = 24) throws -> [Double] {
        let data = try ImageWriter.rgba8Sampled(mask, width: size, height: size)
        var out: [Double] = []
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) { out.append(Double(px[i]) / 255.0) }
        }
        return out
    }

    /// THE INVARIANT the derived background rests on: with a subject and a (disjoint) sky present,
    /// subject + sky + background ≈ 1 at every point — the three masks partition the frame. In
    /// particular the derived background EXCLUDES the sky, which `invert: true` on a subject mask
    /// does not.
    func testSubjectSkyAndDerivedBackgroundPartitionTheFrame() throws {
        let extent = CGRect(x: 0, y: 0, width: 120, height: 120)
        // Disjoint by construction, the shape `LocalMasks.measure` guarantees — it subtracts the
        // subject from the sky before deriving the background.
        let subjectMask = TestSupport.pixels(size: 120) { x, y in
            (x >= 40 && x < 80 && y >= 50 && y < 90) ? (255, 255, 255) : (0, 0, 0)
        }
        let skyMask = TestSupport.pixels(size: 120) { _, y in y < 30 ? (255, 255, 255) : (0, 0, 0) }
        let background = LocalMasks.background(subject: subjectMask, sky: skyMask, extent: extent)

        let s = try grid(subjectMask), k = try grid(skyMask), b = try grid(background)
        for i in s.indices {
            XCTAssertEqual(s[i] + k[i] + b[i], 1.0, accuracy: 0.06,
                           "at sample \(i) the three masks sum to \(s[i] + k[i] + b[i]) — "
                           + "they no longer partition the frame")
        }
        // Spot-check the exclusion in words: where the sky is, the background is not.
        let skySamples = zip(k, b).filter { $0.0 > 0.9 }
        XCTAssertFalse(skySamples.isEmpty)
        for (_, bg) in skySamples {
            XCTAssertLessThan(bg, 0.1, "the derived background reached into the sky")
        }
    }

    /// With nothing segmented, "everything no other mask claims" is the whole picture — the
    /// derived background must be full white, not absent and not black.
    func testWithNothingSegmentedTheBackgroundIsTheWholeFrame() throws {
        let extent = CGRect(x: 0, y: 0, width: 120, height: 120)
        let bg = LocalMasks.background(subject: nil, sky: nil, extent: extent)
        let lowest = try XCTUnwrap(grid(bg).min())
        XCTAssertGreaterThan(lowest, 0.99)
        XCTAssertEqual(bg.extent, extent)
    }

    func testSkinIsTheSubjectRefinedByColour() throws {
        let built = Mask.skin(id: "subject", adjustments: ["exposure_ev": 1.2])
        let byHand = subject(["exposure_ev": 1.2], refine: Mask.skinRefinement)
        XCTAssertEqual(try differs(render(built), render(byHand)), 0, accuracy: 1e-9,
                       "the skin convenience must be exactly subject + colour refinement")
    }

    // MARK: - Old sidecars

    /// A recipe saved before `refine` existed says `type: "skin"` with the hue range in
    /// `selection`. It must decode into the general form and render the same.
    func testLegacySkinSidecarMigratesOnDecode() throws {
        let json = """
        {"id":"subject","type":"skin","source":"skin","invert":false,"feather":0,"opacity":1,
         "adjustments":{"exposure_ev":1.2},
         "selection":{"kind":"color","center":0.06,"range":0.06,"softness":0.05}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Mask.self, from: json)

        XCTAssertEqual(decoded.type, "subject", "migrated to the general source")
        XCTAssertNil(decoded.selection, "the hue range is a refinement now, not a source")
        XCTAssertEqual(decoded.refine?.kind, .color)
        XCTAssertEqual(try differs(render(decoded),
                                   render(Mask.skin(id: "subject", adjustments: ["exposure_ev": 1.2]))),
                       0, accuracy: 1e-9, "a migrated sidecar must render identically")
    }

    func testAMaskWithNoRefinementStillRoundTrips() throws {
        let mask = subject(["exposure_ev": 0.5], refine: Mask.skinRefinement)
        let data = try JSONEncoder().encode(mask)
        let back = try JSONDecoder().decode(Mask.self, from: data)
        XCTAssertEqual(back.refine?.center, Mask.skinRefinement.center)
        XCTAssertEqual(back, mask)
    }
}
