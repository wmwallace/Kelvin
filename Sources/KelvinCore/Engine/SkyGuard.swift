import Foundation
import CoreImage

/// Keep a sky out of clipping that the rest of the recipe pushed it into — locally, through the sky
/// mask, so the ground keeps the lift it was given.
///
/// A bright sky over a dark foreground is the most common landscape there is, and the engine's
/// answer to the dark foreground is a global lift. `skyMask` decides whether a sky is "blown" from the
/// ORIGINAL's statistics, before any of that — so a sky that was fine as shot was lifted with
/// everything else and went over. Reported on `_DSC5069` (Skagit tulips): Natural at +0.59 EV,
/// highlights −70, and 12% of the frame clipped, nearly all of it cloud; Fix then did nothing
/// (`CraftFix`, fixed separately). What a photographer does there is not to give the foreground's
/// lift back — it is to hold the sky down with a graduated filter and keep it.
///
/// **Closed loop, measured on the render**, for the reason `highlightHeadroom` gives for wanting one
/// and could not have: an EV written into a soft mask is not an EV that reaches the picture (the sky
/// mask's mean alpha is about 0.55, `SkyLever`), so predicting the pull is guesswork. This renders the
/// candidate, measures how much of the frame is clipped INSIDE the sky that was not clipped in the
/// original, and bisects the sky mask's exposure until that is gone. Every number is a measurement of
/// this frame (non-negotiable #1).
///
/// Only ever DOWN, only the sky, only clipping the recipe added. A sky already blown in the file is
/// the camera's, not the recipe's, and pulling it grey recovers nothing.
public enum SkyGuard {

    /// `KELVIN_SKY_GUARD=0` turns it off for an A/B. In `RecipeEngine.tuningSignature`.
    public static let enabled: Bool = ProcessInfo.processInfo.environment["KELVIN_SKY_GUARD"] != "0"

    /// Newly clipped sky, as a share of the whole frame, that the guard acts on — and the share it
    /// solves down to. One percent of a frame is a visibly white patch of cloud; half a percent is a
    /// few specular edges.
    static let actAbove = 0.01
    static let solveTo = 0.005
    /// How far the guard may pull a sky, in mask EV. The same floor the styles' own sky pull uses.
    static let deepest = -1.8

    /// What the guard needs from the frame once, shared by every candidate: the sky's weight on the
    /// sample grid, and how much of the sky the original already clipped.
    public struct Frame: @unchecked Sendable {
        let weights: [Float]
        let sourceClip: Double
        let proxy: CIImage
        let bitmaps: [String: CIImage]
    }

    /// Nil when there is no sky to guard.
    /// - Parameter force: measure even when the guard is switched off for the engine — the Fix
    ///   button asks for it by hand, and an A/B of the engine must not disable a button.
    public static func frame(proxy: CIImage, bitmaps: [String: CIImage], force: Bool = false) -> Frame? {
        guard enabled || force, bitmaps["sky"] != nil else { return nil }
        let regions = ResultMatch.Regions.sampling(bitmaps, over: proxy.extent)
        guard let sky = regions.sky,
              let source = ResultMatch.sample(Renderer.render(proxy, with: .neutral, maskBitmaps: [:]))
        else { return nil }
        return Frame(weights: sky, sourceClip: clipped(source.clippedMask, in: sky),
                     proxy: proxy, bitmaps: bitmaps)
    }

    static func clipped(_ mask: [Bool], in weights: [Float]) -> Double {
        var sum = 0.0
        for i in 0..<mask.count where mask[i] { sum += Double(weights[i]) }
        return sum / Double(mask.count)
    }

    /// The sky clipping this recipe ADDED, as a share of the frame.
    static func addedSkyClip(_ recipe: Recipe, _ f: Frame) -> Double? {
        let rendered = Renderer.render(f.proxy, with: recipe, maskBitmaps: f.bitmaps)
        guard let s = ResultMatch.sample(rendered) else { return nil }
        return clipped(s.clippedMask, in: f.weights) - f.sourceClip
    }

    /// `recipe` with its sky held under clipping, or `recipe` itself when the sky is fine. The
    /// returned recipe's sky mask carries the pull; nothing else is changed.
    public static func protect(_ recipe: Recipe, on f: Frame) -> Recipe {
        guard let added = addedSkyClip(recipe, f), added > actAbove else { return recipe }
        var r = recipe
        var masks = r.masks ?? []
        let index: Int
        if let i = masks.firstIndex(where: { $0.type == "sky" }) {
            index = i
        } else {
            masks.append(Mask(id: "sky", type: "sky", source: "segmentation", invert: false,
                              feather: RecipeEngine.SkyLever.feather, opacity: 1.0, adjustments: [:]))
            index = masks.count - 1
        }
        r.masks = masks
        let e0 = masks[index].adjustments["exposure_ev"] ?? 0
        guard e0 > deepest else { return recipe }
        // Bisect for the SHALLOWEST pull that brings the added clip under `solveTo`.
        var lo = deepest, hi = e0
        var best: Recipe?
        for _ in 0..<7 {
            let mid = (lo + hi) / 2
            var t = r
            t.masks?[index].adjustments["exposure_ev"] = (mid * 100).rounded() / 100
            guard let a = addedSkyClip(t, f) else { break }
            if a <= solveTo { best = t; lo = mid } else { hi = mid }
        }
        if let best { return best }
        // Could not get under the target even at the floor: take the floor, which is still the
        // most sky it is possible to give back.
        var t = r
        t.masks?[index].adjustments["exposure_ev"] = deepest
        return (addedSkyClip(t, f) ?? added) < added ? t : recipe
    }
}
