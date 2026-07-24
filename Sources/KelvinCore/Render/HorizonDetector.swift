import Foundation
import CoreImage
import Vision

/// Detects the horizon tilt so the engine (or the user's "Auto" button) can level it. Vision's
/// `VNDetectHorizonRequest` returns the roll of the scene; we convert it to the rotation that
/// makes the horizon flat. Returns nil when no clear horizon is found (portraits, interiors).
public enum HorizonDetector {

    /// Degrees to pass as `Geometry.rotateDeg` to level the horizon, or nil if none is detected.
    /// Positive/negative sign matches the renderer's straighten convention.
    public static func levelingAngle(in image: CIImage) -> Double? {
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        // `angle` is the scene roll in radians. The renderer rotates by -rotateDeg (see
        // applyGeometry), so returning the roll in degrees straightens it.
        return Double(observation.angle) * 180 / .pi
    }
}
