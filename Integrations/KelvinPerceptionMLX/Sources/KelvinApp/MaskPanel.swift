import SwiftUI
import KelvinCore

/// The things in this photograph, listed, so you can edit one of them.
///
/// Every mask before this one was something the photographer had to *describe*: a circle here, a
/// gradient there, a hue and a tolerance. That is fine for a vignette and hopeless for "make him a
/// bit brighter", which is the edit people actually want and the one they were left drawing by
/// hand. Kelvin already segments the frame into separable subjects — it just never showed them.
///
/// So the list is the interface: what is in the picture, named, in the order that matters. Click
/// one and it becomes a mask. There is nothing to describe, because the app already knows.
struct SubjectList: View {
    let instances: [SubjectInstances.Instance]
    let maskedIds: Set<String>
    @Binding var highlighted: String?
    let onPick: (SubjectInstances.Instance) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("IN THIS PHOTO")
                    .font(Theme.mono(9)).tracking(1.4).foregroundColor(Theme.inkFaint)
                Spacer()
                // The count earns its place: it is how you tell "nothing here" from "not looked
                // yet", and the two feel identical when the list is simply empty.
                Text("\(instances.count)")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
            }
            ForEach(instances, id: \.id) { instance in
                SubjectRow(instance: instance,
                           isMasked: maskedIds.contains(instance.id),
                           isHighlighted: highlighted == instance.id,
                           onPick: { onPick(instance) })
                    .onHover { inside in highlighted = inside ? instance.id : nil }
            }
        }
    }
}

/// One row: what it is, how much of the frame it is, and whether it is already being edited.
private struct SubjectRow: View {
    let instance: SubjectInstances.Instance
    let isMasked: Bool
    let isHighlighted: Bool
    let onPick: () -> Void

    /// A glyph per kind. People, animals and things are told apart at a glance rather than by
    /// reading, which matters in a list you are scanning for one particular subject.
    private var icon: String {
        switch instance.kind {
        case .person: return "person.fill"
        case .animal: return "pawprint.fill"
        case .object: return "square.on.circle"
        }
    }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(isMasked ? Theme.glow : Theme.inkDim)
                    .frame(width: 13)
                Text(instance.label)
                    .font(Theme.ui(11, isMasked ? .semibold : .regular))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                // Coverage, as a share of the frame. Two rows both called "Person" are otherwise
                // indistinguishable in a list, and size is usually how you tell the subject from
                // the passer-by behind them.
                Text(coverageLabel)
                    .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                    .monospacedDigit()
                Image(systemName: isMasked ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 10))
                    .foregroundColor(isMasked ? Theme.glow : Theme.inkFaint)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHighlighted ? Theme.surface2 : Theme.surface.opacity(0.6))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(isMasked ? Theme.glow.opacity(0.5) : Theme.hairline, lineWidth: 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isMasked ? "Already masked — click to select it"
                       : "Edit \(instance.label) on its own")
    }

    /// Rounded to whole percent, floored at 1: a subject that reads "0% of frame" looks like a
    /// detection error rather than a small dog.
    private var coverageLabel: String {
        "\(max(1, Int((instance.coverage * 100).rounded())))%"
    }
}

/// The hovered subject, outlined over the photo.
///
/// Without this the list is a set of labels you have to take on trust — "Person 2" names nobody
/// until you can see which one it is, and picking the wrong one means an edit landing on the wrong
/// face. Drawn from the instance's bounding box, which is already normalised, so it costs a
/// rectangle rather than a mask composite on every pointer move.
struct SubjectHighlight: View {
    let instance: SubjectInstances.Instance
    /// The photo's frame on screen, in view coordinates.
    let imageFrame: CGRect
    /// Maps a SOURCE-normalised point to a view point, undoing straighten and crop on the way.
    ///
    /// Required, not optional polish. The box comes from Vision in SOURCE space — masks are
    /// measured before geometry — while `imageFrame` is the FRAMED image after straightening and
    /// auto-crop. Mapping one straight onto the other means that the moment a photo is
    /// straightened the outline is offset and mis-scaled against the very subject it is pointing
    /// at. Every other on-canvas element already routes through this; this one did not.
    let normToView: (Double, Double) -> CGPoint

    var body: some View {
        // Vision's boxes are bottom-left origin; SwiftUI is top-left.
        let box = instance.boundingBox
        let topLeft = normToView(box.minX, 1 - box.maxY)
        let bottomRight = normToView(box.maxX, 1 - box.minY)
        let rect = CGRect(x: min(topLeft.x, bottomRight.x), y: min(topLeft.y, bottomRight.y),
                          width: abs(bottomRight.x - topLeft.x),
                          height: abs(bottomRight.y - topLeft.y))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .stroke(Theme.glow, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            Text(instance.label)
                .font(Theme.mono(9))
                .foregroundColor(Theme.base)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.glow))
                // Above the box, unless that would put it off the top of the photo.
                .offset(x: rect.minX, y: max(imageFrame.minY, rect.minY - 16))
        }
        // THIS LINE IS LOAD-BEARING, and leaving it out is why the box appeared in the wrong
        // place. `.offset` does not participate in layout, so without a frame the ZStack sizes
        // itself to its largest child — the outline — and `.overlay` then CENTRES that in the
        // canvas. The offsets, which are absolute positions in the canvas, were therefore applied
        // starting from a centred origin rather than the top-left.
        //
        // The displacement was not even constant: the ZStack's size depends on the subject's box,
        // so every subject was wrong by a different amount, which is what made it look like boxes
        // appearing at random. Filling the container makes `.topLeading` mean the canvas's
        // top-left, which is the coordinate space `rect` was computed in.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
