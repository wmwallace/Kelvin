import Foundation

/// CIELAB color and the CIEDE2000 difference formula. Kept dependency-free and
/// unit-tested against the Sharma reference vectors (see tests). This is the backbone of
/// every color metric in the eval harness (docs/EVALUATION.md).
public struct Lab: Equatable, Sendable {
    public var L: Double
    public var a: Double
    public var b: Double

    public init(L: Double, a: Double, b: Double) {
        self.L = L; self.a = a; self.b = b
    }

    /// Convert an 8-bit sRGB triple (0…255) to CIELAB under a D65 white point.
    public static func fromSRGB8(r: UInt8, g: UInt8, b: UInt8) -> Lab {
        func toLinear(_ c8: UInt8) -> Double {
            let c = Double(c8) / 255.0
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = toLinear(r), gl = toLinear(g), bl = toLinear(b)

        // linear sRGB → XYZ (D65)
        let x = 0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = 0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl

        // D65 reference white
        let xn = 0.95047, yn = 1.0, zn = 1.08883
        let eps = 216.0 / 24389.0
        let kappa = 24389.0 / 27.0
        func f(_ t: Double) -> Double {
            t > eps ? Foundation.cbrt(t) : (kappa * t + 16.0) / 116.0
        }
        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return Lab(L: 116.0 * fy - 16.0, a: 500.0 * (fx - fy), b: 200.0 * (fy - fz))
    }
}

public enum ColorDifference {
    /// CIEDE2000 (ΔE₀₀) between two Lab colors. Implements Sharma, Wu & Dalal (2005).
    public static func deltaE2000(_ c1: Lab, _ c2: Lab) -> Double {
        let kL = 1.0, kC = 1.0, kH = 1.0

        let C1 = (c1.a * c1.a + c1.b * c1.b).squareRoot()
        let C2 = (c2.a * c2.a + c2.b * c2.b).squareRoot()
        let Cbar = (C1 + C2) / 2.0

        let Cbar7 = pow(Cbar, 7)
        let G = 0.5 * (1.0 - (Cbar7 / (Cbar7 + pow(25.0, 7))).squareRoot())

        let a1p = (1.0 + G) * c1.a
        let a2p = (1.0 + G) * c2.a

        let C1p = (a1p * a1p + c1.b * c1.b).squareRoot()
        let C2p = (a2p * a2p + c2.b * c2.b).squareRoot()

        func atan2Deg(_ y: Double, _ x: Double) -> Double {
            if y == 0 && x == 0 { return 0 }
            var deg = atan2(y, x) * 180.0 / Double.pi
            if deg < 0 { deg += 360.0 }
            return deg
        }
        let h1p = atan2Deg(c1.b, a1p)
        let h2p = atan2Deg(c2.b, a2p)

        let dLp = c2.L - c1.L
        let dCp = C2p - C1p

        var dhp = 0.0
        if C1p * C2p != 0 {
            var diff = h2p - h1p
            if diff > 180 { diff -= 360 }
            else if diff < -180 { diff += 360 }
            dhp = diff
        }
        let dHp = 2.0 * (C1p * C2p).squareRoot() * sin((dhp / 2.0) * Double.pi / 180.0)

        let Lbarp = (c1.L + c2.L) / 2.0
        let Cbarp = (C1p + C2p) / 2.0

        var hbarp = h1p + h2p
        if C1p * C2p != 0 {
            if abs(h1p - h2p) > 180 {
                if (h1p + h2p) < 360 { hbarp = (h1p + h2p + 360) / 2.0 }
                else { hbarp = (h1p + h2p - 360) / 2.0 }
            } else {
                hbarp = (h1p + h2p) / 2.0
            }
        } else {
            hbarp = h1p + h2p
        }

        let T = 1.0
            - 0.17 * cos((hbarp - 30) * Double.pi / 180.0)
            + 0.24 * cos((2 * hbarp) * Double.pi / 180.0)
            + 0.32 * cos((3 * hbarp + 6) * Double.pi / 180.0)
            - 0.20 * cos((4 * hbarp - 63) * Double.pi / 180.0)

        let dTheta = 30.0 * exp(-pow((hbarp - 275.0) / 25.0, 2))
        let Cbarp7 = pow(Cbarp, 7)
        let Rc = 2.0 * (Cbarp7 / (Cbarp7 + pow(25.0, 7))).squareRoot()
        let Sl = 1.0 + (0.015 * pow(Lbarp - 50.0, 2)) / (20.0 + pow(Lbarp - 50.0, 2)).squareRoot()
        let Sc = 1.0 + 0.045 * Cbarp
        let Sh = 1.0 + 0.015 * Cbarp * T
        let Rt = -sin(2.0 * dTheta * Double.pi / 180.0) * Rc

        let termL = dLp / (kL * Sl)
        let termC = dCp / (kC * Sc)
        let termH = dHp / (kH * Sh)

        return (termL * termL + termC * termC + termH * termH + Rt * termC * termH).squareRoot()
    }
}
