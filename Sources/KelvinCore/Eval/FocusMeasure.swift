import Foundation
import CoreImage

/// How sharp a frame actually is — the one fault no edit can repair.
///
/// Everything else Kelvin measures is something it can then fix. Missed focus and motion blur are
/// not: detail that was never recorded cannot be recovered, and sharpening a soft frame only makes
/// a crunchier soft frame. So this exists to support a *decision* (reject it and move on), not a
/// correction, and nothing downstream offers to fix what it reports.
///
/// TWO KINDS OF GOOD PHOTOGRAPH THAT A NAIVE SHARPNESS METRIC CONDEMNS, and what is done about
/// each — these are the whole difficulty, not the edge cases:
///
///  1. **Shallow depth of field.** A portrait at f/1.4 is mostly out of focus *on purpose*; the eye
///     is sharp and the rest is bokeh. Measured over the whole frame it scores as badly blurred.
///     So acuity is measured over the SHARPEST part of the frame, not the average of it — the
///     question is "did anything come out sharp", not "is everything sharp".
///
///  2. **Low-contrast scenes.** Fog, snow, haze. Raw high-frequency energy scales with contrast, so
///     a perfectly sharp foggy headland has less of it than a mediocre sunny snapshot. Measuring
///     absolute energy would reject an entire misty shoot. So acuity is the RATIO of two energies
///     that both scale with contrast (see `acuity(of:...)`), which cancels amplitude entirely.
public enum FocusMeasure {

    /// Sampling grid. Blur lives in the high frequencies, so this has to stay large enough to
    /// preserve them — the 96×96 grid the histogram uses would blur every photo into softness and
    /// make the measurement meaningless.
    static let grid = 384

    /// The frame is divided into tiles and the best-scoring tile wins, so a deliberately shallow
    /// depth of field is judged on its in-focus subject rather than its bokeh.
    static let tiles = 6

    public struct Reading: Sendable, Equatable {
        /// Acuity of the sharpest region — amplitude-independent, and inversely proportional to
        /// the width of the blur. Measured on real frames it runs ~3–5 for a sharp photograph and
        /// falls below 2 once softness is visible. Not a 0…1 fraction; it has no ceiling.
        public let acuity: Double
        /// False when the frame had no edges anywhere to judge focus by — a plain sky, a studio
        /// backdrop, a minimalist composition. UNMEASURABLE IS NOT BLURRED: with no verdict
        /// available the honest answer is silence, so both flags below stay false and nothing is
        /// condemned on the strength of a reading that was never taken.
        public let measurable: Bool
        /// Nothing in the frame resolved crisply — missed focus or camera shake.
        public var isSoft: Bool { measurable && acuity < softThreshold }
        /// Bad enough that the frame is not worth editing.
        public var isUnusable: Bool { measurable && acuity < unusableThreshold }

        /// Public so a caller can test what it does WITH a reading without producing one.
        ///
        /// The app decides things from these — which frame of a burst is the sharpest, what the strip
        /// badges — and those rules were untestable while the only way to obtain a `Reading` was to
        /// measure an image, because a synthetic image that lands on a chosen acuity is not something
        /// you can write down. Constructing readings is not a way to fake a measurement: nothing
        /// persists them, and the thresholds above still belong to this type alone.
        public init(acuity: Double, measurable: Bool) {
            self.acuity = acuity
            self.measurable = measurable
        }
    }

    /// Calibrated by measuring real photographs and progressively blurred copies of them.
    ///
    ///     frame                    sharp   +1.5px  +3px   +6px
    ///     fog (sharp, very flat)    3.01    2.63    1.72   1.22
    ///     family portrait           4.23    2.80    1.64   0.74
    ///     cat                       4.02    2.39    1.22   0.66
    ///     car                       4.97    2.24    1.25   0.65
    ///
    /// Set deliberately LOW. Calling a good photograph blurry is far more costly than missing a
    /// mildly soft one: the first makes the feature untrustworthy and gets it ignored. The binding
    /// case is the sharp foggy frame at 3.01 — the weakest legitimate photo here — so `soft` sits
    /// at 2.0, a third below it, and still catches everything blurred by 3px or more.
    static let softThreshold = 2.0
    static let unusableThreshold = 1.1

    /// Whether the engine's soft-focus clarity damping is on. **Off by default**, because the
    /// per-frame cost of the reading has never been priced (D19 said so when the capability left
    /// with the model's `soft-focus` claim, and it is still true). `KELVIN_CLARITY_FOCUS=1` turns
    /// it on everywhere at once — every path that generates candidates measures through
    /// `engineReading(for:)`, so the canvas, the export and the harness cannot disagree about
    /// whether a frame was damped. In `RecipeEngine.tuningSignature`, so a sweep cannot be served
    /// the other arm's cached recipes. `kelvin-perceive bench-load` already times `read` on the
    /// proxy, which is where the pricing comes from.
    public static var engineDampingEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment["KELVIN_CLARITY_FOCUS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "1" || raw == "on"
    }

    /// The reading the engine's clarity damping consumes, or nil while the switch above is off —
    /// nil costs nothing, which is what makes the default free. **Pass the 768 px perception
    /// proxy**, the image the frame's statistics were measured on: the grid resamples internally,
    /// but resampling twice from different sizes perturbs pixels, and a reading that straddled
    /// `softThreshold` between the canvas's proxy and the export's would resolve one photograph
    /// two ways — the exact bug measuring at two sizes has already caused once.
    public static func engineReading(for image: CIImage) -> Reading? {
        engineDampingEnabled ? read(image) : nil
    }

    /// Measure the frame. Pass the proxy, not the full-resolution original — consistency between
    /// frames matters far more than absolute scale, and every frame goes through the same proxy.
    public static func read(_ image: CIImage) -> Reading {
        guard let data = try? ImageWriter.rgba8Sampled(image, width: grid, height: grid) else {
            return Reading(acuity: 0, measurable: false)
        }

        var luma = [Double](repeating: 0, count: grid * grid)
        data.withUnsafeBytes { dp in
            let px = dp.bindMemory(to: UInt8.self)
            for i in 0..<(grid * grid) {
                let o = i * 4
                luma[i] = (0.299 * Double(px[o]) + 0.587 * Double(px[o + 1])
                           + 0.114 * Double(px[o + 2])) / 255.0
            }
        }

        // Best tile wins — see note 1 above.
        let side = grid / tiles
        var best = 0.0
        var anyQualified = false
        for ty in 0..<tiles {
            for tx in 0..<tiles {
                guard let a = acuity(of: luma, originX: tx * side, originY: ty * side, side: side)
                else { continue }
                anyQualified = true
                best = max(best, a)
            }
        }
        return Reading(acuity: best, measurable: anyQualified)
    }

    /// Laplacian energy against GRADIENT energy over one tile.
    ///
    /// The ratio is what makes this contrast-invariant, and the reasoning is worth keeping because
    /// the obvious alternative is wrong. Take an edge of amplitude A blurred across w pixels: its
    /// gradient goes as A/w and its Laplacian as A/w², so the ratio goes as 1/w. The amplitude
    /// cancels exactly — which is the point. Sharpness is how TIGHT a transition is, not how big.
    ///
    /// The first attempt normalised by the tile's tone standard deviation instead, and it failed in
    /// the most informative way: blurring a foggy frame made it score *higher*, because smoothing
    /// the noise out of a flat sky shrank the denominator faster than the numerator, and flat sky
    /// then won the sharpest-tile contest. Hence also `minimumGradient` — a tile with no real edges
    /// in it has nothing to say about focus and is not allowed to answer.
    /// Returns nil when the tile has no edges worth judging, so the caller can tell "no detail
    /// here" apart from "detail here, and it is mush".
    private static func acuity(of luma: [Double], originX: Int, originY: Int, side: Int) -> Double? {
        var lapSquares = 0.0, gradSum = 0.0
        var n = 0.0

        // Skip the tile's outer ring: the Laplacian needs all four neighbours.
        for y in (originY + 1)..<(originY + side - 1) {
            for x in (originX + 1)..<(originX + side - 1) {
                let i = y * grid + x
                let v = luma[i]
                let left = luma[i - 1], right = luma[i + 1]
                let up = luma[i - grid], down = luma[i + grid]
                // 4-neighbour discrete Laplacian: the standard focus operator.
                let lap = 4 * v - left - right - up - down
                lapSquares += lap * lap
                // Central-difference gradient magnitude, same neighbourhood.
                let gx = (right - left) / 2, gy = (down - up) / 2
                gradSum += (gx * gx + gy * gy).squareRoot()
                n += 1
            }
        }
        guard n > 16 else { return nil }

        let gradient = gradSum / n
        // A tile with no edges cannot report on focus — empty sky, a blank wall. Excluding it is
        // what stops noise in a flat region from being read as fine detail.
        guard gradient >= minimumGradient else { return nil }
        return (lapSquares / n).squareRoot() / gradient
    }

    /// Mean gradient below which a tile is considered featureless and ignored.
    static let minimumGradient = 0.010

    // KNOWN LIMIT. The ratio saturates once the blur exceeds the size of the features being
    // measured: a periodic pattern blurred past its own period becomes a sinusoid, and the
    // Laplacian/gradient ratio of a sinusoid is set by its wavelength rather than by how much it
    // was blurred. Beyond that point acuity stops falling and can wobble slightly upward.
    //
    // It does not bite on photographs, whose detail is broadband — every real frame measured fell
    // monotonically at every blur step. It shows up on synthetic single-frequency test images, and
    // it is recorded here so a future reading of "0.36 then 0.44" is understood rather than chased.
    // Both values are deep in soft territory regardless, so the verdict is unaffected.
}
