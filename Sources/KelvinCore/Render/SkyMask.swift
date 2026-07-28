import Foundation
import CoreImage
import CoreVideo

/// Heuristic sky segmentation for landscapes — no ML model, and robust across the three skies
/// that matter: clear blue, flat overcast, and hazy/foggy white. There is no Vision request for
/// "sky" on macOS, and a smooth bright region is exactly what the classic cues describe well:
///
///   • **Colour** — either blue-dominant (clear sky) or bright-and-desaturated (overcast/haze).
///   • **Smoothness** — sky is textureless; foliage, rock, and buildings are not. Local luma
///     gradient separates a bright sky from bright-but-busy ground (snow, sand, a white wall).
///   • **Position** — sky sits high in the frame; the weight ramps to zero below the midline.
///
/// Like the subject mask this is a *reference, not a bitmap* (docs/RECIPE-SCHEMA.md #6): the
/// recipe records that a sky mask exists; the pixels are produced here on demand at render
/// resolution. The mask is computed on a small grid and delivered through a one-component
/// pixel buffer — the same orientation path the proven `SubjectMask` uses — so it aligns with
/// the source without a coordinate flip.
public enum SkyMask {

    /// Where the overcast/haze cue starts believing a bright desaturated cell is sky.
    ///
    /// **0.50, and every digit of it was measured.** It was 0.60, which is a fair description of a
    /// bright sky and not of the one over the Oregon coast: on `_DSC6390` from 2026-04-26 Cannon
    /// Beach — Haystack Rock under a full marine overcast filling the top two thirds of the frame —
    /// the sky reads luma 0.52…0.67 at saturation 0.05, and the sand under it reads 0.32 at 0.22.
    /// A floor of 0.60 scored most of that sky at zero, which is why "the lever does nothing on an
    /// overcast frame" was a precise description of it.
    ///
    /// Swept with `kelvin-cli sky-metrics` over twelve Cannon Beach frames (real skies) against
    /// eight Sunriver frames (interiors and people — no sky at all) and eight Rocky Brook Falls
    /// frames (the waterfall-and-foliage case this file's connectivity rule exists for):
    ///
    /// | floor | sky mask α | sky orphaned | spill | no mask at all | skies where there is none |
    /// |---|---|---|---|---|---|
    /// | 0.60 (was) | 0.230 | 0.481 | 0.001 | 2 of 12 | 0 |
    /// | **0.50** | **0.426** | **0.234** | **0.009** | **1 of 12** | **0** |
    /// | 0.45 | 0.653 | 0.056 | 0.019 | 0 of 12 | **2 of 8** |
    /// | 0.40 | 0.752 | 0.044 | 0.080 | 0 of 12 | **2 of 8** |
    ///
    /// 0.45 is where it breaks: the mask starts finding skies in a living room, which is the
    /// false-positive failure the flood fill and the desaturation gate exist to prevent and which
    /// no amount of better coverage pays for. 0.50 nearly doubles the alpha every sky adjustment is
    /// multiplied by, halves the orphaned sky, and costs eight thousandths of spill.
    ///
    /// Overridable so the next corpus can re-measure this rather than argue about it — the same
    /// reason `PerceptionProxy.defaultMaxEdge` is overridable. Re-run the sweep before moving it.
    static let brightFloor = ProcessInfo.processInfo.environment["KELVIN_SKY_BRIGHT"]
        .flatMap(Double.init).map { min(0.9, max(0.2, $0)) } ?? 0.50

    /// How much brighter than `brightFloor` a cell must be before the overcast cue is fully
    /// convinced. **0.20, and it was swept the same way**, at floor 0.50, on the same three shoots:
    ///
    /// | ramp | sky mask α | sky orphaned | spill | skies where there is none |
    /// |---|---|---|---|---|
    /// | 0.30 (was) | 0.426 | 0.234 | 0.009 | 0 |
    /// | **0.20** | **0.589** | **0.126** | **0.012** | **0** |
    /// | 0.15 | 0.648 | 0.097 | 0.013 | 0 |
    /// | 0.10 | 0.693 | 0.077 | 0.014 | 0 |
    ///
    /// Unlike the floor, this one has no cliff in it — three shoots cannot separate 0.20 from 0.10
    /// on the false-positive side, where every value scores the same 0.00 spill on the waterfall and
    /// finds no sky in any interior. So the choice is the most conservative value that takes most of
    /// the gain, and it is recorded as that rather than as a discovered optimum. A flat overcast now
    /// reaches full confidence at luma 0.70 instead of 0.80, which is the difference between a mask
    /// that states a sky is sky and one that hedges at 0.39.
    static let brightRamp = ProcessInfo.processInfo.environment["KELVIN_SKY_RAMP"]
        .flatMap(Double.init).map { min(0.6, max(0.05, $0)) } ?? 0.20

    /// Grayscale sky mask (white = sky) at `image`'s extent, or nil when the frame holds little
    /// or no sky (coverage below `coverageFloor`, 0…1 fraction of the frame).
    public static func detect(in image: CIImage, coverageFloor: Double = 0.015) -> CIImage? {
        let ext = image.extent
        guard !ext.isInfinite, ext.width > 0, ext.height > 0 else { return nil }

        // Classify on a small grid: enough to see texture, cheap enough to be free. A soft mask
        // upscales cleanly, so there is no need to classify at full resolution.
        let gw = 160
        let gh = max(1, Int((Double(gw) * ext.height / ext.width).rounded()))
        guard let data = try? ImageWriter.rgba8Sampled(image, width: gw, height: gh) else { return nil }

        var luma = [Double](repeating: 0, count: gw * gh)
        var colour = [Double](repeating: 0, count: gw * gh)
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in 0..<(gw * gh) {
                let r = Double(px[i*4]) / 255, g = Double(px[i*4+1]) / 255, b = Double(px[i*4+2]) / 255
                let l = 0.299*r + 0.587*g + 0.114*b
                luma[i] = l
                let maxc = max(r, g, b), minc = min(r, g, b)
                let sat = maxc <= 0 ? 0 : (maxc - minc) / maxc
                // Clear sky: blue leads the other channels and the pixel is at least mid-bright.
                let blue = l > 0.30 ? min(1, max(0, (b - max(r, g)) * 3.0)) : 0
                // Overcast / hazy sky: bright and desaturated. Ramp brightness in from
                // `brightFloor` over `brightRamp` — both calibrated, see their notes — and fade out
                // as saturation climbs past ~0.22 (a coloured surface, not sky).
                let bright = l > brightFloor ? min(1, (l - brightFloor) / brightRamp) : 0
                let desat = sat < 0.22 ? 1.0 : max(0, 1 - (sat - 0.22) / 0.18)
                colour[i] = max(blue, bright * desat)
            }
        }

        // Score = colour × smoothness × position, quantised to 8-bit.
        var score = [UInt8](repeating: 0, count: gw * gh)
        for y in 0..<gh {
            let yn = gh > 1 ? Double(y) / Double(gh - 1) : 0     // 0 = top row (top-left sampling)
            let pos = yn < 0.45 ? 1.0 : max(0, 1 - (yn - 0.45) / 0.27)   // full to 45%, gone by ~72%
            for x in 0..<gw {
                let i = y * gw + x
                var grad = 0.0
                if x > 0      { grad += abs(luma[i] - luma[i - 1]) }
                if x < gw - 1 { grad += abs(luma[i] - luma[i + 1]) }
                if y > 0      { grad += abs(luma[i] - luma[i - gw]) }
                if y < gh - 1 { grad += abs(luma[i] - luma[i + gw]) }
                let smooth = max(0, 1 - grad * 6.0)
                score[i] = UInt8(min(255, max(0, colour[i] * pos * smooth * 255)))
            }
        }

        // Keep only sky connected to the top edge. Real sky borders the top of the frame; a bright
        // smooth feature lower down — a waterfall, a snowfield, a white wall — does not, and would
        // otherwise be mistaken for sky. Flood-fill down from the top rows through plausibly-sky
        // cells and discard everything the fill can't reach.
        let skyish: (Int) -> Bool = { score[$0] > 48 }
        var keep = [Bool](repeating: false, count: gw * gh)
        var stack: [Int] = []
        for y in 0..<min(3, gh) {                     // seed from the top few rows
            for x in 0..<gw where skyish(y * gw + x) && !keep[y * gw + x] {
                keep[y * gw + x] = true; stack.append(y * gw + x)
            }
        }
        while let i = stack.popLast() {
            let x = i % gw, y = i / gw
            let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            for (nx, ny) in neighbours where nx >= 0 && nx < gw && ny >= 0 && ny < gh {
                let ni = ny * gw + nx
                if !keep[ni] && skyish(ni) { keep[ni] = true; stack.append(ni) }
            }
        }
        var coverage = 0.0
        for i in 0..<(gw * gh) {
            if keep[i] { coverage += Double(score[i]) / 255 } else { score[i] = 0 }
        }
        guard coverage / Double(gw * gh) >= coverageFloor else { return nil }

        // Deliver through a one-component pixel buffer (row r → row r), matching how Vision hands
        // back the subject mask, so the scale-and-align below needs no vertical flip.
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, gw, gh, kCVPixelFormatType_OneComponent8,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pb)
        guard let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        if let base = CVPixelBufferGetBaseAddress(buf) {
            let rowBytes = CVPixelBufferGetBytesPerRow(buf)
            for y in 0..<gh {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<gw { row[x] = score[y * gw + x] }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])

        var mask = CIImage(cvPixelBuffer: buf)
        let sx = ext.width / mask.extent.width
        let sy = ext.height / mask.extent.height
        mask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        return mask.transformed(by: CGAffineTransform(translationX: ext.origin.x, y: ext.origin.y))
    }
}
