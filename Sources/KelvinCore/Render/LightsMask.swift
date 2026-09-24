import Foundation
// @preconcurrency for the reason given in `LocalMasks`: CoreImage's Sendable annotations differ by
// SDK, and CI's Xcode rejects what the author's Mac accepts.
@preconcurrency import CoreImage
import CoreVideo

/// The light sources in a frame — flames, candles, warm lamps — found by measurement on the SOURCE,
/// so a look that brightens the picture can be kept from brightening them too.
///
/// **Why this exists.** Every lever that lifts a frame — exposure, whites, the range stretch, a
/// style's contrast — lifts its brightest content hardest in absolute terms, and a light source is
/// already at the top of the range before the edit starts. On a firelit night frame (`_DSC0486`,
/// Family at Jacks Parents) the Natural look's +0.43 EV took the fire from an orange flame with a
/// glowing bed of rocks to a white blob on a bed of flat pure red: 1.24% of the frame newly flat
/// (one channel ≥250 while another ≤150) and +0.92% newly clipped, and `look-audit --ablate` put
/// all of it on `exposure_ev` — with the lift removed, 0.00% flat. The global `highlights` guard
/// (`RecipeEngine.highlightHeadroom`) was already at its −85 clamp on that frame. A global lever
/// cannot hold back one small region; a mask can.
///
/// **What counts, and why each rule.**
///
///   • **Max channel, not luma, for the extent.** Firelight is saturated red-orange: a flame edge
///     reading (255, 150, 40) has luma 0.56 and is one stop from nowhere. On `_DSC0507` a 0.94 floor
///     on luma finds 2.3% of the frame and on the max channel 5.2% — the difference is the flame's
///     orange edge, which is exactly what a lift flattens. The thing that clips is a CHANNEL, so
///     the thing measured is the channel.
///   • **Near clipping in the source (`coreFloor`).** A light source is what is already at the
///     ceiling before the edit. Content with headroom is the rest of the photograph, and lifting it
///     is what the look is for.
///   • **Not a person (`excluding person`).** Firelit skin reaches the ceiling in the red exactly as
///     a flame does, and no pixel statistic separates the two. D20 is the rule here: the engine does
///     not make brightness decisions about skin it cannot justify, and dimming a face because the
///     fire lit it is one. Person segmentation is the one signal that tells them apart, so it is a
///     hard exclusion — only person segmentation, not the salient-object fallback, because the
///     salient object in a frame of a fire pit can be the fire.
///   • **Not the sky.** A blown sky is the sky mask's job, and it already carries a recovery; two
///     masks pulling the same pixels would compound.
///   • **Small (`componentCap`).** A lamp is a small bright island; an overcast sky, a white studio
///     backdrop or sunlit sand is a large one, and none of them is a light source in the sense
///     that matters — pulling a backdrop down is a different look, not a protected highlight. Each
///     8-connected island on the grid is kept only below this fraction of the frame. (The largest
///     real light measured is `_DSC0482`'s close-up fire at 9.5%, so a fire filling more of the
///     frame than that goes unprotected; the warm and white-hot rules below would let the cap
///     rise, and nothing measured yet says it needs to.)
///   • **White-hot somewhere (`hotFloor`).** An emitter clips in every channel at its heart; a
///     surface it lights clips in one. This is what keeps a firelit forearm that person
///     segmentation missed out of the mask.
///   • **Warm around it (`warmFloor`).** The light falling off around the island has to be warm —
///     which is where the flat single-channel clip this mask prevents happens, and what separates
///     a flame from the overcast seen through a tree. See the constant for the measurements.
///   • **Not touching the sky** the sky mask saw, even faintly — the same reason.
///   • **And its glow (`glowFloor`, `glowRadiusCells`).** Bright cells near a kept light join it:
///     the lit bed of rocks round a fire is what a lift turns flat red first.
///
/// Like `SkyMask` this is a *reference, not a bitmap* (RECIPE-SCHEMA #6): the recipe records that a
/// `lights` mask exists and how hard it pulls, and this regenerates the pixels at whatever
/// resolution is being rendered. The grid is a fixed width whatever the input size, so the 768 px
/// perception proxy and the 2048 px delivery measurement find the same islands.
public enum LightsMask {

    /// The mask `type` and `id` the engine emits and `LocalMasks` keys the bitmap under.
    public static let maskType = "lights"

    /// Classification grid width. 256 on a 3:2 frame is a cell of 3 px on the perception proxy —
    /// fine enough that a candle flame is several cells, coarse enough to be free.
    static let gridWidth = 256

    /// A cell's max channel (sRGB-encoded, 0…1) at or above which it is part of a light.
    /// `KELVIN_LIGHTS_CORE`, in `RecipeEngine.tuningSignature`.
    static let coreFloor: Double = ProcessInfo.processInfo.environment["KELVIN_LIGHTS_CORE"]
        .flatMap(Double.init).map { min(0.995, max(0.70, $0)) } ?? 0.94

    /// The largest single island, as a fraction of the frame, that still counts as a light.
    /// `KELVIN_LIGHTS_MAX_COMPONENT`, in `RecipeEngine.tuningSignature`.
    static let componentCap: Double = ProcessInfo.processInfo.environment["KELVIN_LIGHTS_MAX_COMPONENT"]
        .flatMap(Double.init).map { min(1, max(0.001, $0)) } ?? 0.10

    /// How far the region grows past the near-clipped core, in grid cells, to take the glow a
    /// lift would push over the edge with it. `KELVIN_LIGHTS_DILATE`, in `tuningSignature`.
    static let dilationCells: Int = ProcessInfo.processInfo.environment["KELVIN_LIGHTS_DILATE"]
        .flatMap(Int.init).map { min(12, max(0, $0)) } ?? 2

    /// An island counts as a light only if it is WHITE-HOT somewhere: at least one cell with luma
    /// at or above this. The extent is measured on the max channel (above); the qualification is
    /// measured on luma, because what separates a light from the surface it lights is that an
    /// emitter clips in EVERY channel at its heart and a lit surface clips in one. Measured on the
    /// firelit shoot, on the 256-cell grid: every flame island peaks at luma 0.96–1.00, while the
    /// firelit forearms Vision's person segmentation missed (`_DSC0487`, `_DSC0488`, a man at the
    /// frame edge) are the two largest islands in their frames and peak at 0.73 and 0.77 — without
    /// this rule the engine held a person's arm out of the look, which is the D20 decision about
    /// skin the engine does not get to make. `KELVIN_LIGHTS_HOT`, in `tuningSignature`.
    static let hotFloor: Double = ProcessInfo.processInfo.environment["KELVIN_LIGHTS_HOT"]
        .flatMap(Double.init).map { min(1, max(0, $0)) } ?? 0.90

    /// The GLOW tier: a cell at least this bright (max channel) within `glowRadiusCells` of a kept
    /// light joins the region — the lit bed of rocks round a fire, the bright wall beside a lamp.
    /// These are what a lift pushes over the edge first (they are bright but not yet clipped), and
    /// holding only the clipped core left them to go flat pure red around a correctly held flame.
    /// `KELVIN_LIGHTS_GLOW` / `KELVIN_LIGHTS_GLOW_RADIUS`, in `tuningSignature`.
    static let glowFloor: Double = ProcessInfo.processInfo.environment["KELVIN_LIGHTS_GLOW"]
        .flatMap(Double.init).map { min(1, max(0.3, $0)) } ?? 0.80
    static let glowRadiusCells: Int = ProcessInfo.processInfo.environment["KELVIN_LIGHTS_GLOW_RADIUS"]
        .flatMap(Int.init).map { min(40, max(0, $0)) } ?? 6

    /// An island counts only if its light is WARM: across the island and its lit surround,
    /// (R − B) / max(R, G, B) at or above this. `KELVIN_LIGHTS_WARM`, in `tuningSignature`.
    ///
    /// **This makes the mask a warm-light mask, on purpose, and on a measured separation.** The
    /// damage it exists to prevent is the flat single-channel clip — the red channel runs out while
    /// green and blue do not — and that happens in the falloff of a warm source: firelight,
    /// candles, tungsten. A neutral highlight clips evenly to white, which is what the global
    /// `highlights` guard (`RecipeEngine.highlightHeadroom`) already buys back. And the neutral
    /// white islands in real frames are overwhelmingly not emitters. Measured on this grid, over
    /// each white-hot island and its lit surround (the rule as built), the six largest islands a
    /// frame has:
    ///
    /// | islands | (R − B)/max |
    /// |---|---|
    /// | flames, marshmallow, fire-pit glow (`_DSC0474`–`0507`, 8 frames) | 0.30 – 0.76 |
    /// | tungsten lamps (Thanksgiving `_DSC3164`, `_DSC3172`) | 0.17 – 0.31 |
    /// | white paint on warm-sunlit asphalt (Cabin Trip `_DSC2879`) | 0.14 – 0.28 |
    /// | overcast through branches (Ocean Shores `_DSC6034`, `_DSC6041`, `_DSC6043`) | −0.01 – 0.06 |
    /// | a daylit window (Sunriver `_DSC3952`) | −0.17 – 0.02 |
    ///
    /// 0.20 is where the overcast and the window fall away with a wide margin and every flame
    /// island stays. Without it, the sky seen through a tree was held out of a campsite's lift and
    /// rendered as grey patches in a white sky. The costs, named: a neutral LED bulb or a daylit
    /// window is not protected by this mask, the dimmer of a tungsten lamp's islands fall below
    /// it, and sunlit white paint in a warm late sun partly clears it.
    static let warmFloor: Double = ProcessInfo.processInfo.environment["KELVIN_LIGHTS_WARM"]
        .flatMap(Double.init).map { min(1, max(-1, $0)) } ?? 0.20

    /// A sky-mask value (0…255) at or above which a cell counts as sky for the "touches the sky"
    /// rule — deliberately far below the 128 that excludes a cell outright. See `detect`.
    static let skyTouch: UInt8 = 24

    /// Below this share of the frame the kept core is noise — a specular glint — and no mask is
    /// returned.
    static let coverageFloor = 0.0005

    public struct Found {
        /// Grayscale, white = light, at the measured image's extent.
        public let mask: CIImage
        /// The share of the frame the kept core covers (before dilation), 0…1.
        public let coverage: Double
    }

    /// The light-source mask for `image`, or nil when there is none worth protecting.
    /// - Parameters:
    ///   - person: a PERSON segmentation mask to exclude (nil for none). Pass only a person mask —
    ///     see the type's notes on why the salient fallback is not an exclusion.
    ///   - sky: the sky mask to exclude.
    public static func detect(in image: CIImage, excludingPerson person: CIImage? = nil,
                              sky: CIImage? = nil) -> Found? {
        let ext = image.extent
        guard !ext.isInfinite, ext.width > 0, ext.height > 0 else { return nil }
        let gw = gridWidth
        let gh = max(1, Int((Double(gw) * ext.height / ext.width).rounded()))
        let n = gw * gh
        guard let data = try? ImageWriter.rgba8Sampled(image, width: gw, height: gh) else { return nil }

        // Exclusions sampled onto the same grid (row 0 = top, as `rgba8Sampled` returns it).
        func sampled(_ mask: CIImage?) -> [UInt8]? {
            guard let mask, let d = try? ImageWriter.rgba8Sampled(mask.cropped(to: ext), width: gw, height: gh)
            else { return nil }
            return stride(from: 0, to: d.count, by: 4).map { d[$0] }
        }
        let personCells = sampled(person)
        let skyCells = sampled(sky)
        // Cells at or next to any sky the sky mask saw, even faintly. Overcast seen through
        // branches is white-hot, small and broken into islands — every property of a light — and
        // `SkyMask` scores it low rather than zero (its smoothness term fails in foliage). Measured
        // on `_DSC6043` (Ocean Shores, a campsite under an overcast): without this, 2.75% of the
        // frame's sky-through-trees was held out of the lift and rendered as grey patches in a
        // white sky. A lamp, a flame or a window is not next to the sky; the sun in it is the sky
        // mask's to treat.
        var nearSky = [Bool](repeating: false, count: n)
        if let sc = skyCells {
            let reach = 2
            for i in 0..<n where sc[i] >= skyTouch {
                let x = i % gw, y = i / gw
                for dy in -reach...reach {
                    let ny = y + dy
                    guard ny >= 0, ny < gh else { continue }
                    for dx in -reach...reach {
                        let nx = x + dx
                        guard nx >= 0, nx < gw else { continue }
                        nearSky[ny * gw + nx] = true
                    }
                }
            }
        }

        let floor = UInt8(min(255, max(0, (coreFloor * 255).rounded(.up))))
        let glow = UInt8(min(255, max(0, (glowFloor * 255).rounded(.up))))
        var core = [Bool](repeating: false, count: n)
        var bright = [Bool](repeating: false, count: n)   // glow-tier candidates
        var hot = [Bool](repeating: false, count: n)      // white-hot: qualifies an island
        var rgb = [(Float, Float, Float)](repeating: (0, 0, 0), count: n)
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in 0..<n {
                let r = Double(px[i * 4]), g = Double(px[i * 4 + 1]), b = Double(px[i * 4 + 2])
                rgb[i] = (Float(r), Float(g), Float(b))
                hot[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255 >= hotFloor
                let mx = max(px[i * 4], px[i * 4 + 1], px[i * 4 + 2])
                guard mx >= min(floor, glow) else { continue }
                if let p = personCells, p[i] >= 128 { continue }
                if let s = skyCells, s[i] >= 128 { continue }
                if mx >= glow { bright[i] = true }
                if mx >= floor { core[i] = true }
            }
        }

        // Islands, 8-connected; keep the small ones.
        let cap = Int((componentCap * Double(n)).rounded(.down))
        var label = [Int32](repeating: 0, count: n)
        var kept = [Bool](repeating: false, count: n)
        var keptCount = 0
        var next: Int32 = 0
        var stack: [Int] = []
        var members: [Int] = []
        var fringeStamp = [Int32](repeating: 0, count: n)
        let fringeReach = 6                                  // cells; ~3.5% of the short edge
        let fringeFloor: Float = 0.35 * 255
        for start in 0..<n where core[start] && label[start] == 0 {
            next += 1
            label[start] = next
            stack.append(start)
            members.removeAll(keepingCapacity: true)
            var whiteHot = false, touchesSky = false
            while let i = stack.popLast() {
                members.append(i)
                if hot[i] { whiteHot = true }
                if nearSky[i] { touchesSky = true }
                let x = i % gw, y = i / gw
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < gh else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < gw, dx != 0 || dy != 0 else { continue }
                        let j = ny * gw + nx
                        if core[j] && label[j] == 0 { label[j] = next; stack.append(j) }
                    }
                }
            }
            // The light's colour: the island and every cell within `fringeReach` of it that is lit
            // (max channel ≥ 0.35) and not a person — the emitter and what falls off around it. The
            // island itself counts because a light cut out sharply against black has no lit
            // surround, and its own orange edge is then all the evidence there is.
            var warm = false
            if whiteHot && !touchesSky && members.count <= cap {
                var sr: Float = 0, sg: Float = 0, sb: Float = 0
                for i in members {
                    let x = i % gw, y = i / gw
                    for dy in -fringeReach...fringeReach {
                        let ny = y + dy
                        guard ny >= 0, ny < gh else { continue }
                        for dx in -fringeReach...fringeReach {
                            let nx = x + dx
                            guard nx >= 0, nx < gw else { continue }
                            let j = ny * gw + nx
                            guard fringeStamp[j] != next else { continue }
                            fringeStamp[j] = next
                            let c = rgb[j]
                            guard max(c.0, c.1, c.2) >= fringeFloor else { continue }
                            if let p = personCells, p[j] >= 128 { continue }
                            sr += c.0; sg += c.1; sb += c.2
                        }
                    }
                }
                let peak = max(sr, sg, sb)
                warm = peak > 0 && Double((sr - sb) / peak) >= warmFloor
            }
            if whiteHot && !touchesSky && warm && members.count <= cap {
                for i in members { kept[i] = true }
                keptCount += members.count
            }
        }
        let coverage = Double(keptCount) / Double(n)
        guard coverage >= coverageFloor else { return nil }

        // Grow by `dilationCells` (a disc), then one 3×3 box pass so the upscale is a ramp rather
        // than a staircase. The renderer's feather does the rest at render resolution.
        //
        // The glow tier first: bright cells within `glowRadiusCells` of a kept light. Distance is a
        // chamfer transform from the kept core (two passes, 8-neighbour, in cells), so this is
        // O(cells) whatever the radius.
        var region = kept
        if glowRadiusCells > 0 {
            let far = Float(gw + gh)
            var dist = kept.map { $0 ? Float(0) : far }
            let diag: Float = 1.4142
            for y in 0..<gh {
                for x in 0..<gw {
                    let i = y * gw + x
                    var d = dist[i]
                    if x > 0 { d = min(d, dist[i - 1] + 1) }
                    if y > 0 {
                        d = min(d, dist[i - gw] + 1)
                        if x > 0 { d = min(d, dist[i - gw - 1] + diag) }
                        if x < gw - 1 { d = min(d, dist[i - gw + 1] + diag) }
                    }
                    dist[i] = d
                }
            }
            for y in stride(from: gh - 1, through: 0, by: -1) {
                for x in stride(from: gw - 1, through: 0, by: -1) {
                    let i = y * gw + x
                    var d = dist[i]
                    if x < gw - 1 { d = min(d, dist[i + 1] + 1) }
                    if y < gh - 1 {
                        d = min(d, dist[i + gw] + 1)
                        if x < gw - 1 { d = min(d, dist[i + gw + 1] + diag) }
                        if x > 0 { d = min(d, dist[i + gw - 1] + diag) }
                    }
                    dist[i] = d
                }
            }
            let reach = Float(glowRadiusCells)
            for i in 0..<n where bright[i] && dist[i] <= reach { region[i] = true }
        }
        var grown = [Float](repeating: 0, count: n)
        let r = dilationCells
        for i in 0..<n where region[i] {
            let x = i % gw, y = i / gw
            for dy in -r...r {
                let ny = y + dy
                guard ny >= 0, ny < gh else { continue }
                for dx in -r...r where dx * dx + dy * dy <= r * r {
                    let nx = x + dx
                    guard nx >= 0, nx < gw else { continue }
                    grown[ny * gw + nx] = 1
                }
            }
        }
        var cells = [UInt8](repeating: 0, count: n)
        for y in 0..<gh {
            for x in 0..<gw {
                var sum: Float = 0, count: Float = 0
                for dy in -1...1 {
                    let ny = y + dy
                    guard ny >= 0, ny < gh else { continue }
                    for dx in -1...1 {
                        let nx = x + dx
                        guard nx >= 0, nx < gw else { continue }
                        sum += grown[ny * gw + nx]; count += 1
                    }
                }
                cells[y * gw + x] = UInt8(min(255, max(0, (sum / count * 255).rounded())))
            }
        }

        // Deliver through a one-component pixel buffer, row r → row r, exactly as `SkyMask` does —
        // the orientation path that already aligns with the source without a flip.
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
                for x in 0..<gw { row[x] = cells[y * gw + x] }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])

        var mask = CIImage(cvPixelBuffer: buf)
        mask = mask
            .transformed(by: CGAffineTransform(scaleX: ext.width / mask.extent.width,
                                               y: ext.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: ext.origin.x, y: ext.origin.y))
            .cropped(to: ext)
        // The grid excluded the person and the sky from the CORE; the grown ring can still reach
        // into them. Multiply both out again at full resolution, so the protection stops at the
        // silhouette Vision drew rather than at a 3 px grid cell: a firelit forearm next to a flame
        // keeps its own edit right up to its edge.
        for exclusion in [person, sky].compactMap({ $0 }) {
            mask = exclusion.cropped(to: ext).applyingFilter("CIColorInvert")
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
                .cropped(to: ext)
        }
        return Found(mask: mask, coverage: coverage)
    }
}
