import Foundation
import CoreImage

/// The three baselines every eval report compares against (docs/EVALUATION.md). If the
/// engine cannot beat these, it is not ready — baseline 3 (naive-auto) in particular is
/// the honest test of whether the project has a reason to exist.
public enum Baselines {
    public enum Kind: String, CaseIterable, Sendable {
        /// The manufacturer's own rendering. The real floor.
        case cameraJPEG = "camera-jpeg"
        /// A neutral recipe. Proves the pipeline is not making things worse.
        case neutral
        /// Histogram stretch + grey-world white balance. The dumb baseline.
        case naiveAuto = "naive-auto"
    }

    /// Produce the neutral baseline output (identically the decoded source, by the no-op
    /// invariant).
    public static func neutral(_ source: CIImage) -> CIImage {
        Renderer.render(source, with: .neutral)
    }

    /// Grey-world white balance followed by a percentile histogram stretch. Deterministic,
    /// no model. Statistics are read from a downsampled grid; this is the "dumb" baseline
    /// by design, so cheap-and-approximate is the correct amount of effort.
    public static func naiveAuto(_ source: CIImage) throws -> CIImage {
        let sample = try ImageMetrics.sample(source)

        // --- Grey-world white balance ---
        var sr = 0.0, sg = 0.0, sb = 0.0
        var lumas: [Double] = []
        lumas.reserveCapacity(sample.count / 4)
        sample.withUnsafeBytes { dp in
            let p = dp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: sample.count, by: 4) {
                let r = Double(p[i]) / 255.0
                let g = Double(p[i + 1]) / 255.0
                let b = Double(p[i + 2]) / 255.0
                sr += r; sg += g; sb += b
                lumas.append(0.299 * r + 0.587 * g + 0.114 * b)
            }
        }
        let n = Double(max(1, sample.count / 4))
        let avgR = sr / n, avgG = sg / n, avgB = sb / n
        let grey = (avgR + avgG + avgB) / 3.0

        func gain(_ avg: Double) -> Double {
            guard avg > 1e-4 else { return 1.0 }
            return min(2.0, max(0.5, grey / avg))
        }
        let gainR = gain(avgR), gainG = gain(avgG), gainB = gain(avgB)

        var img = source.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gainR, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gainG, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gainB, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        // --- Percentile histogram stretch ---
        lumas.sort()
        func percentile(_ q: Double) -> Double {
            guard !lumas.isEmpty else { return 0 }
            let idx = min(lumas.count - 1, max(0, Int(q * Double(lumas.count - 1))))
            return lumas[idx]
        }
        let low = percentile(0.005)
        let high = percentile(0.995)
        let span = high - low
        if span > 1e-3 {
            let scale = 1.0 / span
            let bias = -low * scale
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
            ])
        }

        return img
    }
}
