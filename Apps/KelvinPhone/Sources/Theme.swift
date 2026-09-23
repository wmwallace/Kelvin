import SwiftUI

/// The darkroom, the same one the Mac app is built in (`KelvinApp/ContentView.swift`, `Theme`).
///
/// Copied rather than shared for now because the Mac's lives inside its executable target; the
/// two move into one shared UI package when the Mac app's model is split out of `ContentView`
/// (the plan in the iPhone feasibility audit). Until then, change both or neither.
enum Theme {
    static let base     = Color(hex: 0x121418)   // cool near-black: the surround a grade is judged against
    static let surface  = Color(hex: 0x1A1D23)
    static let hairline = Color(hex: 0x30363F)
    static let ink      = Color(hex: 0xEDEFF3)
    static let inkDim   = Color(hex: 0x8B93A0)
    static let warm     = Color(hex: 0xFF9A55)   // ~2700 K
    static let neutral  = Color(hex: 0xF1EADC)   // ~5500 K
    static let cool     = Color(hex: 0x6FACFF)   // ~9000 K

    /// The signature: a hairline lit along the blackbody curve, warm to daylight to cool — the
    /// physics the product is named after, used as the one edge light in the interface. On the
    /// phone it marks the look you are on, and nothing else.
    static let rimLight = LinearGradient(colors: [warm, neutral.opacity(0.8), cool],
                                         startPoint: .leading, endPoint: .trailing)
}

/// Motion in a darkroom: enough to say that something changed, never enough to look at. Ease-out
/// only, and nothing at all under Reduce Motion.
enum Motion {
    static let standard = Animation.easeOut(duration: 0.2)
    static func gated(_ reduced: Bool) -> Animation? { reduced ? nil : standard }
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// Liquid Glass where the system has it, the material before it where it does not. Chrome only
    /// — **glass never touches the photograph**, the Mac app's one rule about it: translucency is a
    /// colour cast in the surround the eye uses to judge a grade.
    @ViewBuilder
    func chromeGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
