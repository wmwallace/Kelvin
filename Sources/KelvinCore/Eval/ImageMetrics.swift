import Foundation
import CoreImage

/// Image-level metrics from docs/EVALUATION.md, computed over fixed-size sample grids so
/// images of differing dimensions are comparable. All inputs are row-major RGBA8.
public enum ImageMetrics {
    /// Sample grid edge. Aggregate color/tone metrics are stable well below full res;
    /// this keeps the full-corpus run inside the five-minute budget.
    public static let sampleEdge = 96

    /// Mean CIEDE2000 between two equally-sized RGBA8 sample grids.
    public static func meanDeltaE2000(_ a: Data, _ b: Data) -> Double {
        precondition(a.count == b.count && a.count % 4 == 0, "sample grids must match")
        let count = a.count / 4
        guard count > 0 else { return 0 }
        var sum = 0.0
        a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in
                let pa = ap.bindMemory(to: UInt8.self)
                let pb = bp.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: a.count, by: 4) {
                    let l1 = Lab.fromSRGB8(r: pa[i], g: pa[i + 1], b: pa[i + 2])
                    let l2 = Lab.fromSRGB8(r: pb[i], g: pb[i + 1], b: pb[i + 2])
                    sum += ColorDifference.deltaE2000(l1, l2)
                }
            }
        }
        return sum / Double(count)
    }

    public struct Clipping: Equatable, Sendable {
        /// Fraction of pixels with any channel at/above 254 (blown highlights).
        public var highlights: Double
        /// Fraction of pixels with every channel at/below 1 (crushed blacks).
        public var shadows: Double
    }

    public static func clipping(_ data: Data) -> Clipping {
        let count = data.count / 4
        guard count > 0 else { return Clipping(highlights: 0, shadows: 0) }
        var hi = 0, lo = 0
        data.withUnsafeBytes { dp in
            let p = dp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) {
                let r = p[i], g = p[i + 1], b = p[i + 2]
                if r >= 254 || g >= 254 || b >= 254 { hi += 1 }
                if r <= 1 && g <= 1 && b <= 1 { lo += 1 }
            }
        }
        return Clipping(highlights: Double(hi) / Double(count), shadows: Double(lo) / Double(count))
    }

    /// Mean CIELAB chromaticity (a, b) — a proxy for overall color cast. White-balance
    /// error is the Euclidean distance between two images' mean chromaticity.
    public static func meanChroma(_ data: Data) -> (a: Double, b: Double) {
        let count = data.count / 4
        guard count > 0 else { return (0, 0) }
        var sa = 0.0, sb = 0.0
        data.withUnsafeBytes { dp in
            let p = dp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) {
                let lab = Lab.fromSRGB8(r: p[i], g: p[i + 1], b: p[i + 2])
                sa += lab.a; sb += lab.b
            }
        }
        return (sa / Double(count), sb / Double(count))
    }

    /// Convenience: rasterize a CIImage to the standard sample grid.
    public static func sample(_ image: CIImage) throws -> Data {
        try ImageWriter.rgba8Sampled(image, width: sampleEdge, height: sampleEdge)
    }
}
