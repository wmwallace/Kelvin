import SwiftUI
import AppKit

/// Looking at two of Kelvin's answers at once, big, before choosing one.
///
/// This is the one act the whole app exists for, and until now it was performed by squinting at
/// four 62-point thumbnails and a line of numbers. That is a fair way to ask a professional which
/// grade they want — they can read `+18 contrast` and picture it. It is not a fair way to ask
/// anybody else, and everybody else is who this app is for. A person who cannot name what they
/// prefer can still see it, given something to see.
///
/// It is also the only comparison in the app that is Kelvin-shaped. `showingOriginal` holds the
/// edit against the untouched frame, which every editor has. Holding one *interpretation* against
/// another only means something in a tool that generates several, and the curator has already
/// guaranteed these are at least `minimumSeparation` apart — then drew that difference at 62 points.
enum CandidateCompare {

    /// Two at a time, or all four.
    ///
    /// Two is the default because a comparison is a question, and "this one or that one" is a
    /// question anybody can answer. Four is a survey, which is useful once you know what you are
    /// looking for and paralysing before that.
    enum Mode: String, CaseIterable, Codable {
        case two, four

        var label: String { self == .two ? "2 up" : "4 up" }
        var columns: Int { self == .two ? 2 : 2 }
    }

    /// Which candidates a tile grid shows, in order — the whole rule, pure, so it can be checked
    /// without a window.
    ///
    /// In 2-up the selected candidate is always first and always present: the comparison is
    /// "against what I have now", so the thing you have now cannot fall off the screen. The partner
    /// defaults to the next candidate rather than the highest-scoring one, because the next one is
    /// where the eye goes and because "best of the rest" is a judgment the picker has already made
    /// and the user is entitled to disagree with.
    static func tiles(candidateIds: [String],
                      selectedId: String?,
                      partnerId: String?,
                      mode: Mode) -> [String] {
        guard candidateIds.count >= 2 else { return [] }
        let anchor = selectedId.flatMap { candidateIds.contains($0) ? $0 : nil } ?? candidateIds[0]
        switch mode {
        case .four:
            // Engine order, unchanged. The grid is a survey and the order it is surveyed in should
            // not depend on which one happens to be selected — moving the tiles under someone
            // between glances is how a comparison stops being one.
            return Array(candidateIds.prefix(4))
        case .two:
            let partner: String
            if let partnerId, partnerId != anchor, candidateIds.contains(partnerId) {
                partner = partnerId
            } else {
                let i = candidateIds.firstIndex(of: anchor) ?? 0
                partner = candidateIds[(i + 1) % candidateIds.count]
            }
            return partner == anchor ? [anchor] : [anchor, partner]
        }
    }

    /// The number key that chooses a given candidate — the picker's own numbering, so the keys mean
    /// the same thing in both places. A tile in the compare view showing "3" and the third row in
    /// the panel are the same candidate and the same keystroke.
    static func shortcutNumber(for id: String, in candidateIds: [String]) -> Int? {
        guard let i = candidateIds.firstIndex(of: id), i < 4 else { return nil }
        return i + 1
    }
}

/// The compare grid itself. Draws over the canvas, borrows the canvas's zoom and pan so every tile
/// is showing the same part of the photograph, and hands a click straight to the pick.
struct CandidateCompareView: View {
    @ObservedObject var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ids: [String] {
        CandidateCompare.tiles(candidateIds: appState.candidates.map(\.id),
                               selectedId: appState.selectedCandidateId,
                               partnerId: appState.comparePartnerId,
                               mode: appState.compareMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let shown = ids.compactMap { id in appState.candidates.first { $0.id == id } }
                let columns = min(CandidateCompare.Mode.two.columns, max(1, shown.count))
                let rows = Int(ceil(Double(shown.count) / Double(columns)))
                let tileW = geo.size.width / Double(columns)
                let tileH = geo.size.height / Double(max(1, rows))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0),
                                         count: columns), spacing: 0) {
                    ForEach(shown) { candidate in
                        tile(candidate, size: CGSize(width: tileW, height: tileH))
                    }
                }
            }
            footer
        }
        .background(Theme.base)
        .transition(.opacity)
        .animation(Motion.gated(Motion.standard, reduceMotion), value: appState.compareMode)
    }

    /// One candidate, drawn as large as the grid will allow.
    private func tile(_ candidate: CandidateViewModel, size: CGSize) -> some View {
        let isSelected = candidate.id == appState.selectedCandidateId
        // The canvas-resolution render when it has arrived, the picker's 768 px thumbnail until
        // then. The fallback matters more than it looks: building four proxy renders takes a
        // moment, and a compare view that opens on four grey rectangles reads as broken, while one
        // that opens soft and sharpens reads as loading.
        let image = appState.compareRenders[candidate.id] ?? candidate.previewImage
        let number = CandidateCompare.shortcutNumber(for: candidate.id,
                                                     in: appState.candidates.map(\.id))
        return Button { appState.pickFromCompare(id: candidate.id) } label: {
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
                    // The same zoom and pan the canvas has, applied identically to every tile —
                    // which is the entire point of a comparison. Two crops of different parts of
                    // the frame are not a comparison of two grades.
                    .scaleEffect(appState.zoom, anchor: .center)
                    .offset(appState.pan)
                    .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if let number {
                            Text("\(number)")
                                .font(Theme.mono(10))
                                .foregroundColor(Theme.inkDim)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface2))
                        }
                        Text(candidate.label)
                            .font(Theme.ui(13, .semibold))
                            .foregroundColor(isSelected ? Theme.ink : Theme.inkDim)
                    }
                    if isSelected {
                        Text("chosen")
                            .font(Theme.mono(9)).tracking(1.2)
                            .foregroundColor(Theme.glow)
                    }
                }
                .padding(12)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .overlay(
                Rectangle()
                    .stroke(isSelected ? Theme.glow : Theme.hairline,
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help("Choose \(candidate.label)")
        .accessibilityLabel("\(candidate.label)\(isSelected ? ", chosen" : "")")
        .accessibilityHint("Choose this interpretation")
    }

    /// What the keys do, said once rather than learned. A compare view nobody knows how to leave is
    /// a modal trap, and this one is entered with a single keystroke.
    private var footer: some View {
        HStack(spacing: 14) {
            ForEach(CandidateCompare.Mode.allCases, id: \.self) { mode in
                Button(mode.label) { appState.compareMode = mode }
                    .buttonStyle(.plain)
                    .font(Theme.mono(10))
                    .foregroundColor(appState.compareMode == mode ? Theme.ink : Theme.inkFaint)
            }
            Divider().frame(height: 12)
            Text("Click a photograph to choose it · 1–4 chooses · C or Esc closes")
                .font(Theme.mono(10)).foregroundColor(Theme.inkFaint)
            Spacer()
            if appState.zoom > 1.01 {
                Text(String(format: "%.0f%%", appState.zoom * 100))
                    .font(Theme.mono(10)).foregroundColor(Theme.inkFaint)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}
