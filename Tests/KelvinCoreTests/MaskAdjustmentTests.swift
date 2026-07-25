import XCTest
import CoreImage
@testable import KelvinCore

/// Every per-mask adjustment the UI offers must actually change the picture.
///
/// This codebase has form here: `texture` was a dead control, and negative clarity silently did
/// nothing because CIUnsharpMask clamps. Exposing six sliders per mask without checking each one
/// is live would be repeating that. The keys tested here are exactly the ones the mask panel
/// shows, so a slider can never appear for an adjustment the renderer ignores.
final class MaskAdjustmentTests: XCTestCase {

    /// A frame with a real tonal range and real colour. A flat mid-grey patch is the wrong
    /// subject for this test: a highlight slider has no highlights to act on, so it measures as a
    /// dead control when it is working perfectly well.
    private func base() -> CIImage { TestSupport.makeGradientImage(width: 96, height: 96) }

    private func fullMask() -> CIImage {
        CIImage(color: .white).cropped(to: base().extent)
    }

    private func render(_ adjustments: [String: Double], invert: Bool = false,
                        feather: Double = 0, opacity: Double = 1) -> CIImage {
        let mask = Mask(id: "subject", type: "subject", source: "segmentation", invert: invert,
                        feather: feather, opacity: opacity, adjustments: adjustments)
        let recipe = Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                            global: .neutral, curve: nil, hsl: nil, masks: [mask],
                            detail: nil, geometry: nil)
        return Renderer.render(base(), with: recipe, maskBitmaps: ["subject": fullMask()])
    }

    private func differs(_ a: CIImage, _ b: CIImage) throws -> Double {
        ImageMetrics.meanDeltaE2000(try ImageMetrics.sample(a), try ImageMetrics.sample(b))
    }

    /// The keys the mask panel exposes, with the sign the panel actually allows. Names must match
    /// `Renderer.applyMaskedAdjustments` exactly — a typo here is a slider that moves and does
    /// nothing.
    ///
    /// `highlights` is recovery-only, and that is a real limitation rather than a preference:
    /// `CIHighlightShadowAdjust` documents its highlight amount as 0…1 with 1.0 meaning no change,
    /// so the renderer's `1.0 + highlights/100` clamps for any positive value. Measured at exactly
    /// ΔE 0.0 — a dead control, found by this test. The panel therefore offers -100…0 only.
    /// Derived from `Mask.adjustmentKeys` rather than hand-listed, so adding a key to the
    /// renderer's contract without proving it is live fails here instead of shipping a dead
    /// slider. `positiveWorks` is the per-key exception, not the source of the key list.
    private static let positiveIsDead: Set<String> = ["highlights"]
    private static let exposed: [(key: String, positiveWorks: Bool)] =
        Mask.adjustmentKeys.map { ($0, !positiveIsDead.contains($0)) }

    /// The list the UI builds its sliders from is the list the renderer honours — asserted, not
    /// assumed, because the app package has no test target of its own to assert it there.
    func testTheContractCoversExactlyWhatTheRendererHonours() {
        XCTAssertEqual(Set(Mask.adjustmentKeys).count, Mask.adjustmentKeys.count,
                       "duplicate key in the contract")
        XCTAssertEqual(Set(Mask.adjustmentKeys),
                       ["exposure_ev", "highlights", "shadows", "contrast", "saturation", "vibrance"],
                       "the renderer's masked-adjustment contract changed — update every mask "
                       + "editor that builds sliders from it, and prove the new key is live below")
    }

    func testEveryExposedMaskAdjustmentChangesTheRender() throws {
        let neutral = render([:])
        for (key, positiveWorks) in Self.exposed where positiveWorks {
            // Exposure is in EV; the rest are ±100 scales.
            let amount: Double = key == "exposure_ev" ? 1.0 : 60
            let changed = render([key: amount])
            XCTAssertGreaterThan(try differs(neutral, changed), 0.5,
                                 "\(key) is a dead control — the slider would do nothing")
        }
    }

    /// Pins the limitation itself, so if a future Core Image release starts honouring values above
    /// 1.0 this fails and the panel can open the range back up.
    func testPositiveHighlightsIsStillInertAndSoIsNotOffered() throws {
        XCTAssertEqual(try differs(render([:]), render(["highlights": 60])), 0, accuracy: 0.01,
                       "positive highlights now does something — widen the slider range")
    }

    /// Negative values must work too. That is precisely how the clarity/texture bug hid: the
    /// positive direction worked, so it looked fine.
    func testNegativeMaskAdjustmentsAlsoChangeTheRender() throws {
        let neutral = render([:])
        for (key, _) in Self.exposed {
            let amount: Double = key == "exposure_ev" ? -1.0 : -60
            let changed = render([key: amount])
            XCTAssertGreaterThan(try differs(neutral, changed), 0.5,
                                 "\(key) does nothing when negative")
        }
    }

    /// Opacity scales the effect rather than switching it — half strength must land between.
    func testOpacityScalesTheEffect() throws {
        let neutral = render([:])
        let half = try differs(neutral, render(["exposure_ev": 1.0], opacity: 0.5))
        let full = try differs(neutral, render(["exposure_ev": 1.0], opacity: 1.0))
        XCTAssertGreaterThan(full, half)
        XCTAssertGreaterThan(half, 0.1, "half strength must still do something")
    }

    /// Invert on a full-frame mask means the adjustment applies nowhere, so the render is
    /// untouched. If this fails, invert is wired backwards.
    func testInvertFlipsWhereTheAdjustmentLands() throws {
        let neutral = render([:])
        let inverted = render(["exposure_ev": 1.0], invert: true)
        XCTAssertLessThan(try differs(neutral, inverted), 0.5,
                          "inverting a whole-frame mask should leave the frame alone")
    }

    /// Tightness sharpens mask edge transitions, changing the result when applied to soft edges.
    func testTightnessChangesMaskEdgeContrast() throws {
        let mask = Mask(id: "radial", type: "radial", source: "gradient", invert: false,
                        feather: 0, opacity: 1, adjustments: ["exposure_ev": 1.0],
                        shape: MaskShape(kind: .radial, cx: 0.5, cy: 0.5, radius: 0.3, softness: 0.4),
                        tightness: 0)
        let maskTight = Mask(id: "radial", type: "radial", source: "gradient", invert: false,
                             feather: 0, opacity: 1, adjustments: ["exposure_ev": 1.0],
                             shape: MaskShape(kind: .radial, cx: 0.5, cy: 0.5, radius: 0.3, softness: 0.4),
                             tightness: 60)
        let r1 = Renderer.render(base(), with: Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                                                       global: .neutral, curve: nil, hsl: nil, masks: [mask],
                                                       detail: nil, geometry: nil))
        let r2 = Renderer.render(base(), with: Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil,
                                                       global: .neutral, curve: nil, hsl: nil, masks: [maskTight],
                                                       detail: nil, geometry: nil))
        XCTAssertGreaterThan(try differs(r1, r2), 0.5, "Tightness should sharpen mask transition")
    }

    /// Mask overlay rendering composites a red visualization overlay over affected areas.
    func testRenderMaskOverlayProducesRedOverlay() throws {
        let baseImage = base()
        let maskImage = fullMask()
        let overlay = Renderer.renderMaskOverlay(baseImage, maskBitmap: maskImage, opacity: 0.6)
        XCTAssertGreaterThan(try differs(baseImage, overlay), 2.0, "Mask overlay should visually alter image with red tint")
    }
}
