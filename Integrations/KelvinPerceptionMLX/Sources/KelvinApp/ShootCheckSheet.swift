import SwiftUI
import AppKit
import KelvinCore

/// The shoot check: a chosen look, shown large on the frames of the shoot least like the one it was
/// chosen on, before it is applied to all of them (D31).
///
/// The candidates are shown large so the choice is an informed one. Until this, the SECOND half of
/// the sentence — "and the chosen one carries across the shoot" — was a leap: a look chosen on a
/// well-lit hero went onto the night end of the same shoot unseen, and the first sight of it was a
/// folder of exports. This is the same principle applied to the carry: see it before you commit.
///
/// Which frames is `ShootCheck.pick`'s job (measured on the strip's cached thumbnails, farthest from
/// the hero and from each other); what each shows is the export's own path — `adaptedRecipe`, the
/// carried hand finish solved on the frame (`matchedRecipe`), the creative look on top
/// (`ShootLook.finished`) — so what is previewed is what will be written, and the resolve it pays
/// for is cached for the export.
@MainActor
@Observable
final class ShootCheckModel: Identifiable {
    struct Preview: Identifiable {
        let id: URL
        let name: String
        let reason: String
        var image: NSImage?
        /// When the curator dropped the chosen style for this frame: the style it will open in.
        var fellBackTo: String?
        var failed = false
    }

    let id = UUID()
    /// "Soft + Portrait film" — the whole choice, named the way the apply will record it.
    let choice: String
    let styleLabel: String
    let carriesAdjustments: Bool
    var previews: [Preview] = []
    /// What the sheet is doing, while it is doing it. Nil when done.
    var stage: String? = "Finding the frames least like this one…"
    /// True once picking finished and found nothing worth showing.
    var uniform = false
    @ObservationIgnored var task: Task<Void, Never>?

    init(choice: String, styleLabel: String, carriesAdjustments: Bool) {
        self.choice = choice
        self.styleLabel = styleLabel
        self.carriesAdjustments = carriesAdjustments
    }
}

extension AppState {

    /// How many frames the check shows. Four fits a 2×2 sheet at a size a face can be read at.
    static let shootCheckCount = 4
    /// Frames measured to choose from. A 400-frame shoot is sampled evenly down to this; picking
    /// from a sample is picking from the shoot's range of light, which is what the check is for.
    static let shootCheckSample = 160
    /// Below this, the shoot is small enough to see in the strip and a check is a speed bump.
    static let shootCheckMinimum = 8

    /// The Apply button. Opens the check first when it is on and the shoot is big enough to hide
    /// its differences; otherwise applies at once, exactly as before.
    func requestApply() {
        guard checkBeforeApply, applyScope().count > Self.shootCheckMinimum,
              let styleId = selectedCandidateId,
              let style = CandidateStyle.all.first(where: { $0.id == styleId }) else {
            applyLookToShoot()
            return
        }
        let lookId = activeLookId.flatMap(LookPreset.named)?.id
        let model = ShootCheckModel(choice: ShootLook.choiceLabel(style: style.label, look: lookId),
                                    styleLabel: style.label,
                                    carriesAdjustments: carryAdjustments && isTouched)
        shootCheck = model
        model.task = Task { [weak self] in await self?.runShootCheck(model, style: style, lookId: lookId) }
    }

    /// Apply from the sheet.
    func confirmShootCheck() {
        shootCheck?.task?.cancel()
        shootCheck = nil
        applyLookToShoot()
    }

    func cancelShootCheck() {
        shootCheck?.task?.cancel()
        shootCheck = nil
    }

    private func runShootCheck(_ model: ShootCheckModel, style: CandidateStyle, lookId: String?) async {
        let hero = loadedURL
        // Evicted originals are left out: previewing one would be a 40–90 s download (see
        // `CloudFile`), and a check that waits on iCloud is a check nobody waits for.
        let scope = applyScope().filter { $0 != hero }
        let step = max(1, scope.count / Self.shootCheckSample)
        let sampled = stride(from: 0, to: scope.count, by: step).map { scope[$0] }
        let heroJob = model.carriesAdjustments ? heroFinishJob(styleId: style.id, lookId: lookId) : nil

        let measured = await Offload.run(.io, qos: .userInitiated) { () -> SignatureBox in
            func signature(_ url: URL) -> ShootCheck.Signature? {
                guard let cg = MediaCache.shared.thumbnailCG(for: url),
                      let stats = try? ImageStatistics.compute(CIImage(cgImage: cg)) else { return nil }
                return ShootCheck.Signature(stats)
            }
            var frames: [(id: URL, signature: ShootCheck.Signature)] = []
            for url in sampled where !CloudFile.isEvicted(url) {
                if let s = signature(url) { frames.append((url, s)) }
            }
            if let hero, let s = signature(hero) { frames.append((hero, s)) }
            return SignatureBox(frames: frames)
        }
        guard !Task.isCancelled else { return }
        let heroSignature = hero.flatMap { h in measured.frames.first { $0.id == h }?.signature }
        let picks = ShootCheck.pick(measured.frames, hero: hero ?? URL(fileURLWithPath: "/"),
                                    count: Self.shootCheckCount)
        guard !picks.isEmpty else {
            model.uniform = true
            model.stage = nil
            return
        }
        model.previews = picks.map { url in
            let sig = measured.frames.first { $0.id == url }?.signature
            return ShootCheckModel.Preview(
                id: url, name: url.lastPathComponent,
                reason: sig.map { s in heroSignature.map { ShootCheck.reason(for: s, hero: $0) } ?? "" } ?? "")
        }

        // The hero's finish, measured once for all four — the same measurement the apply makes.
        var intent: ResultMatch.Intent?
        if let heroJob {
            model.stage = "Measuring your adjustments…"
            intent = await Self.measure(heroJob)
        }
        for (i, url) in picks.enumerated() {
            guard !Task.isCancelled else { return }
            model.stage = "Adapting \(style.label) to frame \(i + 1) of \(picks.count)…"
            do {
                let resolved = try await adaptedRecipe(for: url, style: style)
                let matched = try await matchedRecipe(for: url, resolved: resolved, style: style,
                                                      look: lookId, intent: intent)
                let recipe = ShootLook.finished(matched, look: lookId)
                let rendered = try await Offload.run(.render, qos: .userInitiated) { () -> RenderedCheck in
                    let full = try ImageDecoder.decode(url: url)
                    let canvas = PerceptionProxy.fromFile(url, maxEdge: 1200, matching: full.extent)
                        ?? Self.materialiseDecoded(PerceptionProxy.downsample(full, maxEdge: 1200))
                    let masks = LocalMasks.measure(in: PerceptionProxy.downsample(canvas)).bitmaps
                        .mapValues { LocalMasks.scale($0, to: canvas.extent) }
                    let out = Renderer.render(canvas, with: recipe, maskBitmaps: masks)
                    return RenderedCheck(image: Self.sharedContext.createCGImage(out, from: out.extent))
                }
                guard !Task.isCancelled, let index = model.previews.firstIndex(where: { $0.id == url }) else { return }
                model.previews[index].image = rendered.image.map { NSImage(cgImage: $0, size: .zero) }
                if resolved.id != style.id {
                    model.previews[index].fellBackTo = resolved.label ?? resolved.id
                }
            } catch {
                if let index = model.previews.firstIndex(where: { $0.id == url }) {
                    model.previews[index].failed = true
                }
            }
        }
        model.stage = nil
    }

    private struct SignatureBox: @unchecked Sendable {
        let frames: [(id: URL, signature: ShootCheck.Signature)]
    }
    private struct RenderedCheck: @unchecked Sendable { let image: CGImage? }
}

/// The sheet.
struct ShootCheckSheet: View {
    @Bindable var appState: AppState
    let model: ShootCheckModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(model.choice) on the rest of the shoot")
                    .font(Theme.ui(17, .semibold))
                    .foregroundColor(Theme.ink)
                Text(subtitle)
                    .font(Theme.ui(12))
                    .foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.uniform {
                Text("Every frame here was shot in light like this one, so there is nothing that would come out differently. Apply when you're ready.")
                    .font(Theme.ui(13))
                    .foregroundColor(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(model.previews) { tile($0) }
                }
            }
            HStack(spacing: 12) {
                if let stage = model.stage {
                    ProgressView().controlSize(.small)
                    Text(stage).font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                }
                Spacer()
                Toggle(isOn: $appState.checkBeforeApply) {
                    Text("Check before applying").font(Theme.ui(11))
                }
                .toggleStyle(.checkbox)
                .foregroundColor(Theme.inkDim)
                .help("Show this before a look goes onto a shoot. Off, Apply puts it on at once.")
                Button("Cancel") { appState.cancelShootCheck() }
                    .keyboardShortcut(.cancelAction)
                Button(appState.applyButtonLabel) { appState.confirmShootCheck() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 560)
        .background(Theme.surface)
    }

    private var subtitle: String {
        var s = "The frames least like this one, each adapted on its own — this is what Export edited will write."
        if model.carriesAdjustments { s += " Your adjustments are matched on each frame, not copied." }
        return s
    }

    @ViewBuilder private func tile(_ p: ShootCheckModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Theme.base)
                if let image = p.image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if p.failed {
                    Text("Couldn't read this frame").font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 230)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                Text(p.reason).font(Theme.ui(12, .medium)).foregroundColor(Theme.ink)
                Text(p.name).font(Theme.mono(10)).foregroundColor(Theme.inkDim)
            }
            if let fallback = p.fellBackTo {
                Text("\(model.styleLabel) doesn't suit this frame — it will open in \(fallback)")
                    .font(Theme.ui(11)).foregroundColor(Theme.warn)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(p.reason), \(p.name)" + (p.fellBackTo.map { ", opens in \($0)" } ?? ""))
    }
}
