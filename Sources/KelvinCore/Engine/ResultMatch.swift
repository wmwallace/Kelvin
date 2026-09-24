import Foundation
import CoreImage

/// Carry the RESULT of one hand-finished photograph across a shoot, not its sliders.
///
/// The owner's workflow is "edit one photo properly, then apply it to the rest". D13 settled the
/// first half of what that must not mean: copying the hero frame's slider values onto frame 13,
/// which was shot into the sun when frame 12 was not, is the copying this project exists not to do.
/// So a shoot look carried a style id and nothing else — and every tweak the photographer made on
/// the hero ("a touch brighter, a little warmer, lift the people") stayed behind on the one frame.
///
/// This carries those tweaks as what they DID, measured on pixels:
///
/// 1. **Intent.** Render the hero twice — as the style left it, and as the photographer finished
///    it — and measure both: overall lightness, tonal spread, warmth and tint on the near-neutral
///    pixels, colourfulness, and the subject's and the sky's lightness *relative to the rest of
///    the frame*. The difference is the intent: "+6 L*, +2 b*, the people 4 L* further out of the
///    background". A hero nobody touched has an intent of zero, and every frame is left exactly as
///    the style resolved it.
/// 2. **Solve, per frame.** Starting from THIS frame's own resolved style, move one lever at a time
///    — exposure, the subject and sky masks, temperature, tint, contrast, vibrance — until this
///    frame's own change measures the same as the hero's. Each lever is monotone in the quantity it
///    is matched on, so each solve is a short bisection over renders of a small proxy.
///
/// Every number is computed from a measurement of the frame it lands on (non-negotiable #1), none is
/// learned (D18), none is copied (D13). A frame where "+0.3 EV" would clip gets the brightness the
/// hero got, reached through less exposure; a frame already bright enough gets less lift.
///
/// **Relative, never absolute, for the subject** — D20. The engine may never pull a face toward a
/// universal target brightness, because one frame cannot separate shade from complexion. The intent
/// here is the photographer's own move on their own hero, carried as a *difference*: "the people,
/// 4 L* further out of their background than the style had them". Nobody's skin is compared to
/// anybody else's.
public enum ResultMatch {

    // MARK: - Measuring an outcome

    /// What a render looks like, in the handful of numbers a photographer's finishing moves change.
    ///
    /// CIELAB, because equal steps there look roughly equal, which is what makes "the same change on
    /// a different photograph" a meaningful request. Lightness is L* (0…100); warmth and tint are
    /// b* and a* averaged over the frame's near-neutral pixels — the grey-world reading of the light
    /// rather than of the scene's colours, which is the same distinction the white-balance estimator
    /// had to learn (`RecipeEngine.estimator`).
    public struct Outcome: Codable, Equatable, Sendable {
        /// Mean L*.
        public var lightness: Double
        /// L* p90 − p10: how far the tones spread, which is what contrast changes.
        public var spread: Double
        /// Mean b* over the reference's near-neutral pixels. Positive is warmer (yellower).
        public var warmth: Double
        /// Mean a* over the same pixels. Positive is more magenta.
        public var tint: Double
        /// Mean chroma √(a²+b²) over every pixel.
        public var colourfulness: Double
        /// Mean L* inside the subject, the sky and the rest of the frame; nil when that region is
        /// too small to meter.
        public var subject: Double?
        public var sky: Double?
        public var background: Double?
        /// Share of pixels with any channel at or above 254.
        public var clipped: Double

        /// Subject lightness relative to its background: the thing "lift the people" changes.
        public var subjectSeparation: Double? {
            guard let subject, let background else { return nil }
            return subject - background
        }
        /// Sky lightness relative to the land under it: the thing "deepen the sky" changes.
        public var skyDepth: Double? {
            guard let sky, let background else { return nil }
            return sky - background
        }
    }

    /// The sample grid every outcome is read on. Small on purpose: these are aggregates, stable well
    /// below this, and a solve renders a few dozen times per frame.
    static let grid = 128
    /// A region smaller than this share of the frame is not metered.
    static let minimumRegion = 0.03

    /// Which pixels count as near-neutral for warmth and tint, chosen ONCE on a reference render and
    /// then held, so that two renders of one frame are compared on the same pixels. Selecting afresh
    /// on each render would let a warming edit push the warmest greys out of the selection and read
    /// back as less warm than it is.
    public struct NeutralSet: Sendable, Equatable {
        let weights: [Bool]
    }

    /// Where a frame's regions are, sampled on the grid once.
    public struct Regions: Sendable {
        let subject: [Float]?
        let sky: [Float]?
        let background: [Float]?

        public static let none = Regions(subject: nil, sky: nil, background: nil)

        /// Sample the measured bitmaps onto the grid.
        public static func sampling(_ bitmaps: [String: CIImage], over extent: CGRect) -> Regions {
            func weights(_ key: String) -> [Float]? {
                guard let m = bitmaps[key] else { return nil }
                let scaled = LocalMasks.scale(m, to: extent).cropped(to: extent)
                guard let data = try? ImageWriter.rgba8Sampled(scaled, width: grid, height: grid)
                else { return nil }
                var w = [Float](repeating: 0, count: grid * grid)
                data.withUnsafeBytes { raw in
                    let p = raw.bindMemory(to: UInt8.self)
                    for i in 0..<(grid * grid) { w[i] = Float(p[i * 4]) / 255 }
                }
                let share = Double(w.reduce(0, +)) / Double(w.count)
                return share >= minimumRegion ? w : nil
            }
            return Regions(subject: weights("subject"), sky: weights("sky"),
                           background: weights("background"))
        }
    }

    /// Per-pixel Lab of a render on the grid.
    struct Sampled {
        var L: [Double], a: [Double], b: [Double]
        var clipped: Double
    }

    static func sample(_ image: CIImage) -> Sampled? {
        guard let data = try? ImageWriter.rgba8Sampled(image, width: grid, height: grid) else { return nil }
        let n = grid * grid
        var L = [Double](repeating: 0, count: n), A = L, B = L
        var clipped = 0
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<n {
                let r = p[i * 4], g = p[i * 4 + 1], bl = p[i * 4 + 2]
                if r >= 254 || g >= 254 || bl >= 254 { clipped += 1 }
                let lab = Lab.fromSRGB8(r: r, g: g, b: bl)
                L[i] = lab.L; A[i] = lab.a; B[i] = lab.b
            }
        }
        return Sampled(L: L, a: A, b: B, clipped: Double(clipped) / Double(n))
    }

    /// The least-chromatic fifth of a render's pixels, excluding the very dark and the clipped
    /// (neither carries the colour of the light).
    static func neutralSet(of s: Sampled) -> NeutralSet {
        let n = s.L.count
        var candidates: [(Int, Double)] = []
        candidates.reserveCapacity(n)
        for i in 0..<n where s.L[i] > 12 && s.L[i] < 97 {
            candidates.append((i, (s.a[i] * s.a[i] + s.b[i] * s.b[i]).squareRoot()))
        }
        candidates.sort { $0.1 < $1.1 }
        var w = [Bool](repeating: false, count: n)
        for (i, _) in candidates.prefix(max(1, candidates.count / 5)) { w[i] = true }
        return NeutralSet(weights: w)
    }

    static func outcome(_ s: Sampled, neutral: NeutralSet, regions: Regions) -> Outcome {
        let n = Double(s.L.count)
        let lightness = s.L.reduce(0, +) / n
        let sorted = s.L.sorted()
        let spread = sorted[Int(Double(sorted.count - 1) * 0.9)] - sorted[Int(Double(sorted.count - 1) * 0.1)]
        var wa = 0.0, wb = 0.0, wn = 0.0, chroma = 0.0
        for i in 0..<s.L.count {
            chroma += (s.a[i] * s.a[i] + s.b[i] * s.b[i]).squareRoot()
            if neutral.weights[i] { wa += s.a[i]; wb += s.b[i]; wn += 1 }
        }
        func mean(_ w: [Float]?) -> Double? {
            guard let w else { return nil }
            var sum = 0.0, total = 0.0
            for i in 0..<s.L.count where w[i] > 0 { sum += s.L[i] * Double(w[i]); total += Double(w[i]) }
            return total > 0 ? sum / total : nil
        }
        return Outcome(lightness: lightness, spread: spread,
                       warmth: wn > 0 ? wb / wn : 0, tint: wn > 0 ? wa / wn : 0,
                       colourfulness: chroma / n,
                       subject: mean(regions.subject), sky: mean(regions.sky),
                       background: mean(regions.background), clipped: s.clipped)
    }

    /// Measure one render against a reference render of the same frame (whose near-neutral pixels
    /// define warmth and tint for both).
    public static func measure(_ render: CIImage, reference: CIImage, regions: Regions) -> (Outcome, Outcome)? {
        guard let s = sample(render), let r = sample(reference) else { return nil }
        let neutral = neutralSet(of: r)
        return (outcome(s, neutral: neutral, regions: regions),
                outcome(r, neutral: neutral, regions: regions))
    }

    // MARK: - Intent

    /// What a finishing edit changed, in outcome units. Codable because it is what a shoot record
    /// carries (D29): a few numbers measured on the hero, never the hero's sliders.
    public struct Intent: Codable, Equatable, Sendable {
        public var lightness = 0.0
        public var spread = 0.0
        public var warmth = 0.0
        public var tint = 0.0
        public var colourfulness = 0.0
        public var subjectSeparation = 0.0
        public var skyDepth = 0.0
        /// Clipping the hero edit itself added — the allowance a matched frame may spend.
        public var addedClip = 0.0

        public init() {}

        /// Below these, a difference is measurement noise or a move too small to carry, and the
        /// lever is left where the style put it. Also what makes an untouched hero a no-op.
        static let deadband = (lightness: 1.0, spread: 1.5, warmth: 0.8, tint: 0.8,
                               colourfulness: 1.0, region: 1.5)

        public var isNeutral: Bool {
            abs(lightness) < Self.deadband.lightness && abs(spread) < Self.deadband.spread
                && abs(warmth) < Self.deadband.warmth && abs(tint) < Self.deadband.tint
                && abs(colourfulness) < Self.deadband.colourfulness
                && abs(subjectSeparation) < Self.deadband.region && abs(skyDepth) < Self.deadband.region
        }
    }

    /// The intent of a finished render relative to the render its style produced.
    public static func intent(finished: Outcome, baseline: Outcome) -> Intent {
        var i = Intent()
        i.lightness = finished.lightness - baseline.lightness
        i.spread = finished.spread - baseline.spread
        i.warmth = finished.warmth - baseline.warmth
        i.tint = finished.tint - baseline.tint
        i.colourfulness = finished.colourfulness - baseline.colourfulness
        if let f = finished.subjectSeparation, let b = baseline.subjectSeparation { i.subjectSeparation = f - b }
        if let f = finished.skyDepth, let b = baseline.skyDepth { i.skyDepth = f - b }
        i.addedClip = max(0, finished.clipped - baseline.clipped)
        return i
    }

    /// Measure a hero: its style's render and the photographer's finished render, on the same
    /// proxy, with the frame's masks. Nil when either render cannot be sampled.
    public static func intent(proxy: CIImage, baseline: Recipe, finished: Recipe,
                              maskBitmaps: [String: CIImage]) -> Intent? {
        let regions = Regions.sampling(maskBitmaps, over: proxy.extent)
        let b = Renderer.render(proxy, with: baseline, maskBitmaps: maskBitmaps)
        let f = Renderer.render(proxy, with: finished, maskBitmaps: maskBitmaps)
        guard let (fo, bo) = measure(f, reference: b, regions: regions) else { return nil }
        return intent(finished: fo, baseline: bo)
    }

    /// The same, when the finished result is a PICTURE rather than a recipe — a photographer's
    /// export from another editor. This is what lets the paired corpus test the idea: its heroes
    /// are Lightroom exports, not Kelvin recipes. `finished` must frame exactly what `proxy` frames.
    public static func intent(proxy: CIImage, baseline: Recipe, finishedPicture: CIImage,
                              maskBitmaps: [String: CIImage]) -> Intent? {
        let regions = Regions.sampling(maskBitmaps, over: proxy.extent)
        let b = Renderer.render(proxy, with: baseline, maskBitmaps: maskBitmaps)
        guard let (fo, bo) = measure(finishedPicture, reference: b, regions: regions) else { return nil }
        return intent(finished: fo, baseline: bo)
    }

    // MARK: - Solving a frame

    /// The long edge the solve renders at. The outcome is read on a 128-px grid, so rendering much
    /// larger buys nothing but time; much smaller and the masks' feathering stops resembling the
    /// canvas's.
    static let solveEdge: CGFloat = 384

    /// Whether this is on. `KELVIN_RESULT_MATCH=0` turns it off for an A/B, the same switch every
    /// other measured lever has.
    public static let enabled: Bool = ProcessInfo.processInfo.environment["KELVIN_RESULT_MATCH"] != "0"

    /// Carry `intent` onto a frame whose style has already resolved to `baseline`. Returns
    /// `baseline` unchanged when the intent is neutral or the frame cannot be measured.
    ///
    /// - Parameters:
    ///   - proxy: the frame, at any size (it is reduced to `solveEdge` here).
    ///   - maskBitmaps: the frame's own measured masks (`LocalMasks.measure`), any extent.
    public static func apply(_ intent: Intent, to baseline: Recipe, proxy: CIImage,
                             maskBitmaps: [String: CIImage]) -> Recipe {
        guard enabled, !intent.isNeutral else { return baseline }
        let small = reduce(proxy)
        let bitmaps = maskBitmaps.mapValues { LocalMasks.scale($0, to: small.extent) }
        let regions = Regions.sampling(bitmaps, over: small.extent)

        func render(_ r: Recipe) -> Sampled? { sample(Renderer.render(small, with: r, maskBitmaps: bitmaps)) }
        guard let base = render(baseline) else { return baseline }
        let neutral = neutralSet(of: base)
        let start = outcome(base, neutral: neutral, regions: regions)
        func measure(_ r: Recipe) -> Outcome? { render(r).map { outcome($0, neutral: neutral, regions: regions) } }

        var r = baseline
        let d = Intent.deadband

        // Lightness first — the move most edits make, and the one the others are read against.
        // The region solves below are RELATIVE (subject − background), so they do not fight it.
        if abs(intent.lightness) >= d.lightness {
            let target = start.lightness + intent.lightness
            let ev0 = r.global.exposureEV
            r = solve(r, lo: max(Ranges.exposureEV.lowerBound, ev0 - 2), hi: min(Ranges.exposureEV.upperBound, ev0 + 2),
                      set: { $0.global.exposureEV = ($1 * 100).rounded() / 100 },
                      read: { measure($0)?.lightness }, target: target, tolerance: 0.4)
        }
        if abs(intent.subjectSeparation) >= d.region, start.subjectSeparation != nil {
            let target = start.subjectSeparation! + intent.subjectSeparation
            r = solveMask(r, id: "subject", type: "subject", target: target,
                          read: { measure($0)?.subjectSeparation })
        }
        if abs(intent.skyDepth) >= d.region, start.skyDepth != nil {
            let target = start.skyDepth! + intent.skyDepth
            r = solveMask(r, id: "sky", type: "sky", target: target,
                          read: { measure($0)?.skyDepth })
        }
        if abs(intent.warmth) >= d.warmth {
            // Warmer is a RISE in mireds on this engine's axis (a lower target Kelvin renders
            // warmer — `WhiteBalanceDirectionTests`), so b* rises with the mired shift.
            let target = start.warmth + intent.warmth
            let mired0 = 1_000_000 / (r.global.temperatureK ?? 6500)
            let lo = max(1_000_000 / Ranges.temperatureK.upperBound, mired0 - 120)
            let hi = min(1_000_000 / Ranges.temperatureK.lowerBound, mired0 + 120)
            r = solve(r, lo: lo, hi: hi,
                      set: { $0.global.temperatureK = (1_000_000 / $1 / 10).rounded() * 10 },
                      read: { measure($0)?.warmth }, target: target, tolerance: 0.3)
        }
        if abs(intent.tint) >= d.tint {
            // The renderer's positive tint renders GREENER (`LookPresetTests
            // .testRendererTintDirectionIsPositiveGreen`), so a* FALLS as tint rises: solve on −a*.
            let target = -(start.tint + intent.tint)
            let t0 = r.global.tint
            r = solve(r, lo: max(Ranges.tint.lowerBound, t0 - 60), hi: min(Ranges.tint.upperBound, t0 + 60),
                      set: { $0.global.tint = $1.rounded() },
                      read: { measure($0).map { -$0.tint } }, target: target, tolerance: 0.3)
        }
        if abs(intent.spread) >= d.spread {
            let target = start.spread + intent.spread
            let c0 = r.global.contrast
            r = solve(r, lo: max(-100, c0 - 60), hi: min(100, c0 + 60),
                      set: { $0.global.contrast = $1.rounded() },
                      read: { measure($0)?.spread }, target: target, tolerance: 0.6)
        }
        if abs(intent.colourfulness) >= d.colourfulness {
            let target = start.colourfulness + intent.colourfulness
            let v0 = r.global.vibrance
            r = solve(r, lo: max(-100, v0 - 60), hi: min(100, v0 + 60),
                      set: { $0.global.vibrance = $1.rounded() },
                      read: { measure($0)?.colourfulness }, target: target, tolerance: 0.4)
        }
        // Contrast and vibrance move mean lightness a little; one more pass puts it back.
        if abs(intent.lightness) >= d.lightness, r != baseline {
            let target = start.lightness + intent.lightness
            let ev0 = r.global.exposureEV
            r = solve(r, lo: max(Ranges.exposureEV.lowerBound, ev0 - 0.5), hi: min(Ranges.exposureEV.upperBound, ev0 + 0.5),
                      set: { $0.global.exposureEV = ($1 * 100).rounded() / 100 },
                      read: { measure($0)?.lightness }, target: target, tolerance: 0.4)
        }

        // THE CLIPPING ALLOWANCE. A frame may clip as much more than its style did as the hero edit
        // itself clipped more than ITS style did, plus half a percent — and no further. A bright
        // frame asked to take a dark frame's lift reaches the lightness it can without blowing out,
        // rather than all of it.
        let allowed = start.clipped + intent.addedClip + 0.005
        if let now = measure(r), now.clipped > allowed, r.global.exposureEV > baseline.global.exposureEV {
            let ev0 = baseline.global.exposureEV, ev1 = r.global.exposureEV
            var lo = ev0, hi = ev1
            for _ in 0..<7 {
                let mid = (lo + hi) / 2
                var t = r; t.global.exposureEV = mid
                if let c = measure(t)?.clipped, c > allowed { hi = mid } else { lo = mid }
            }
            r.global.exposureEV = (lo * 100).rounded() / 100
        }
        return r
    }

    static func reduce(_ image: CIImage) -> CIImage {
        let e = image.extent
        let long = max(e.width, e.height)
        guard long > solveEdge * 1.05 else { return image }
        let s = solveEdge / long
        return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: -e.origin.x * s, y: -e.origin.y * s))
    }

    /// Bisection on one monotone-increasing lever. Returns the recipe whose reading is closest to
    /// `target` among those tried — including the untouched one, so a lever that cannot reach the
    /// target never makes things worse than leaving it alone.
    static func solve(_ recipe: Recipe, lo: Double, hi: Double,
                      set: (inout Recipe, Double) -> Void,
                      read: (Recipe) -> Double?, target: Double, tolerance: Double) -> Recipe {
        guard lo < hi, let v0 = read(recipe) else { return recipe }
        var best = (recipe: recipe, error: abs(v0 - target))
        var a = lo, b = hi
        for _ in 0..<9 {
            let mid = (a + b) / 2
            var t = recipe; set(&t, mid)
            guard let v = read(t) else { break }
            if abs(v - target) < best.error { best = (t, abs(v - target)) }
            if abs(v - target) <= tolerance { break }
            if v < target { a = mid } else { b = mid }
        }
        return best.recipe
    }

    /// Solve a region's lightness relative to the background with that region's mask exposure,
    /// creating the mask when the style did not emit one. The mask carries only `exposure_ev`, so
    /// a region the style had already adjusted keeps its other moves.
    static func solveMask(_ recipe: Recipe, id: String, type: String, target: Double,
                          read: (Recipe) -> Double?) -> Recipe {
        var r = recipe
        var masks = r.masks ?? []
        let index: Int
        if let i = masks.firstIndex(where: { $0.id == id || $0.type == type }) {
            index = i
        } else {
            masks.append(Mask(id: id, type: type, source: "segmentation", invert: false,
                              feather: 6, opacity: 1.0, adjustments: [:]))
            index = masks.count - 1
        }
        r.masks = masks
        let e0 = masks[index].adjustments["exposure_ev"] ?? 0
        let solved = solve(r, lo: max(-1.5, e0 - 1.0), hi: min(1.5, e0 + 1.0),
                           set: { rec, v in rec.masks?[index].adjustments["exposure_ev"] = (v * 100).rounded() / 100 },
                           read: read, target: target, tolerance: 0.4)
        // A mask the solve created and then left at zero is not worth carrying.
        if let m = solved.masks?[index], m.adjustments.values.allSatisfy({ $0 == 0 }),
           !(recipe.masks ?? []).contains(where: { $0.id == m.id }) {
            var out = solved; out.masks?.remove(at: index)
            if out.masks?.isEmpty == true { out.masks = recipe.masks }
            return out
        }
        return solved
    }
}
