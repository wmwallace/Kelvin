import SwiftUI
import KelvinCore

/// Three sliders, named for what they do to the picture rather than for the parameter they move.
///
/// "Pro edits without being pros": the chosen look already made every professional decision, and
/// what is left is taste — a little brighter, a little warmer, a little more punch. Each slider is an
/// offset on the look, centred on it, and says in words which way it goes.
struct AdjustPanel: View {
    @Environment(EditSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Adjust \(session.selectedLook?.name ?? "")")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button("Reset") { session.adjustments = LookAdjustments() }
                    .disabled(session.adjustments.isNeutral)
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
            AdjustSlider(title: "Light", low: "Darker", high: "Brighter",
                         value: $session.adjustments.light, range: -1.5...1.5,
                         spoken: { String(format: "%+.1f stops", $0) })
            AdjustSlider(title: "Warmth", low: "Cooler", high: "Warmer",
                         value: $session.adjustments.warmth, range: -40...40,
                         spoken: { $0 == 0 ? "as the look" : ($0 > 0 ? "warmer" : "cooler") })
            AdjustSlider(title: "Contrast", low: "Softer", high: "Punchier",
                         value: $session.adjustments.contrast, range: -40...40,
                         spoken: { String(format: "%+.0f", $0) })
        }
        .padding(20)
        .presentationDetents([.height(300)])
        .presentationBackground(.thinMaterial)
    }
}

private struct AdjustSlider: View {
    let title: String
    let low: String
    let high: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let spoken: (Double) -> String

    /// Which side of the look's own value the slider is on — the haptic fires when it crosses back
    /// through zero, so "exactly as the look made it" can be found without looking.
    private var side: Int { value > 0.0001 ? 1 : (value < -0.0001 ? -1 : 0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
            HStack(spacing: 10) {
                Text(low).font(.caption).foregroundStyle(Theme.inkDim)
                Slider(value: Binding(
                    get: { value },
                    // A light snap to zero: within 3% of the range of centre is centre.
                    set: { v in value = abs(v) < (range.upperBound - range.lowerBound) * 0.03 ? 0 : v }),
                       in: range)
                    .tint(Theme.neutral)
                    .accessibilityLabel(title)
                    .accessibilityValue(spoken(value))
                Text(high).font(.caption).foregroundStyle(Theme.inkDim)
            }
        }
        .sensoryFeedback(.selection, trigger: side)
    }
}
