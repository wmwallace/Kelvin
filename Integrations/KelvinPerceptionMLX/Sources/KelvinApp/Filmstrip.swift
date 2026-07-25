import SwiftUI
import CoreImage
import ImageIO
import AppKit
import KelvinCore

/// Browsing the folder you opened a photo from — the thing every photo app has and Kelvin didn't:
/// somewhere to see the rest of the shoot, and a way back to a frame you already worked on.
enum PhotoBrowser {

    /// Image files sitting alongside `url`, in a stable order. Uses the same extension list the
    /// batch path does, so what you can browse is what Kelvin can actually edit.
    static func siblings(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        return (try? BatchApply.imageFiles(in: dir))?.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? [url]
    }

    /// A small thumbnail for the strip. Decoding a 60 MP RAW per thumbnail would be absurd, so this
    /// asks ImageIO for an embedded/downsampled one — fast, and it never touches the edit pipeline.
    /// - Important: `…FromImageIfAbsent`, never `…FromImageAlways`. `Always` makes ImageIO ignore
    ///   the preview every camera embeds and decode the full frame instead — on a 60 MP ARW that is
    ///   roughly a second of work *per thumbnail*, for a 160 px image. `IfAbsent` takes the embedded
    ///   preview when there is one (there almost always is) and only decodes as a fallback.
    static func thumbnail(for url: URL, maxPixel: Int = 160) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}

/// Everything needed to put a photo back exactly as you left it, without re-running the model.
/// Cached per photo so switching away and back is instant and lossless.
struct PhotoSession {
    let url: URL
    let imageId: String
    let fullResCI: CIImage
    let proxyCI: CIImage
    let originalPreviewImage: NSImage?
    let perception: Perception?
    let candidates: [CandidateViewModel]
    let proxyMaskBitmaps: [String: CIImage]
    let subjectLuma: Double?
    let skyLuma: Double?
    let healSpots: [HealSpot]
    let detectedSpotCount: Int

    // The edit itself.
    var selectedCandidateId: String?
    var edit: GlobalAdjustments
    var editBaseline: GlobalAdjustments
    var baseMasks: [Mask]
    var maskEnabled: [String: Bool]
    var maskStrength: [String: Double]
    var userMasks: [UserMaskVM]
    var straighten: Double
    var hsl: [String: HSLAdjustment]
    var removeDust: Bool

    /// Whether the user actually changed anything from the candidate Kelvin generated — drives the
    /// "edited" dot in the strip.
    var isEdited: Bool {
        edit != editBaseline || !userMasks.isEmpty || straighten != 0 || !hsl.isEmpty || removeDust
    }
}

/// A horizontal strip of the folder's photos under the preview. Bottom placement is the
/// convention in editing software and keeps the strip clear of the edit panel.
struct FilmstripView: View {
    let photos: [URL]
    let current: URL?
    let editedURLs: Set<URL>
    let thumbnail: (URL) -> NSImage?
    let onSelect: (URL) -> Void
    var onDismiss: (URL) -> Void = { _ in }
    var flags: [URL: PhotoFlag] = [:]
    var totalCount: Int = 0
    var keeperCount: Int = 0
    var rejectCount: Int = 0
    var onFlag: (URL, PhotoFlag) -> Void = { _, _ in }
    @Binding var filter: AppState.StripFilter
    var softURLs: Set<URL> = []
    var softCount: Int = 0
    var scanProgress: Double? = nil
    var onScanFocus: () -> Void = {}
    @State private var hovered: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Collapsed by default is wrong — you would not know the strip exists — but it must be
    /// possible to get the shoot off the screen entirely when working one photo.
    @AppStorage("filmstrip.expanded") private var expanded = true

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            header
            if expanded { strip }
        }
        .background(Theme.surface.opacity(0.6))
    }

    /// Counts, the filter, and the fold. Visible whether or not the strip is showing, so a folded
    /// strip still reports where the cull has got to.
    private var header: some View {
        HStack(spacing: 10) {
            Button { withAnimation(Motion.gated(Motion.quick, reduceMotion)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("\(photos.count) of \(totalCount)")
                        .font(Theme.mono(10, .semibold)).tracking(1)
                }
                .foregroundColor(Theme.inkDim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the shoot" : "Show the shoot")

            if keeperCount > 0 || rejectCount > 0 {
                HStack(spacing: 8) {
                    if keeperCount > 0 {
                        Label("\(keeperCount)", systemImage: "flag.fill")
                            .font(Theme.mono(9)).foregroundColor(Theme.glow)
                    }
                    if rejectCount > 0 {
                        Label("\(rejectCount)", systemImage: "xmark")
                            .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                    }
                }
                .labelStyle(.titleAndIcon)
            }

            // Focus review. A count, never an action — the frames are surfaced for a look,
            // and nothing is flagged or discarded on the strength of the measurement.
            if let progress = scanProgress {
                HStack(spacing: 6) {
                    ProgressView(value: progress).controlSize(.small).frame(width: 54)
                    Text("\(Int(progress * 100))%")
                        .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                }
            } else if softCount > 0 {
                Button { filter = .soft } label: {
                    Label("\(softCount) soft", systemImage: "eye.trianglebadge.exclamationmark")
                        .font(Theme.mono(9)).foregroundColor(Theme.warn)
                }
                .buttonStyle(.plain)
                .help("Review the frames that measured soft — check them, they are not always right")
            } else {
                // No glyph here, unlike the sidebar. Measured, this header row already comes to
                // 575 pt against a 580 pt pane at the window's minimum width, so an icon buys a
                // truncated Picker rather than a faster read.
                Button(action: onScanFocus) {
                    Text("Check focus").font(Theme.mono(9)).foregroundColor(Theme.inkDim)
                }
                .buttonStyle(.plain)
                .help("Measure every frame and flag the soft ones for review")
            }

            Spacer()

            // Three states, not a menu of them: everything, what you kept, what you have not
            // decided about yet. The third is the one that makes a long shoot finishable.
            Picker("", selection: $filter) {
                ForEach(AppState.StripFilter.allCases, id: \.self) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .controlSize(.small)

            Text("P keep · X reject · ←→ move")
                .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var strip: some View {
        Group {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos, id: \.self) { url in
                            cell(url).id(url)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .onChange(of: current) { url in
                    guard let url else { return }
                    // A travelled scroll rather than a jump: arrowing through a shoot, the strip
                    // moving is how you keep your place in it.
                    withAnimation(Motion.gated(Motion.standard, reduceMotion)) {
                        proxy.scrollTo(url, anchor: .center)
                    }
                }
            }
        }
    }

    private func cell(_ url: URL) -> some View {
        let isCurrent = url == current
        return Button(action: { onSelect(url) }) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = thumbnail(url) {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Theme.surface2)
                    }
                }
                .frame(width: 78, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                // A rejected frame stays visible but recedes — you can see the decision without
                // it competing with the frames still in play.
                .opacity(flags[url] == .reject ? 0.32 : 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isCurrent ? Theme.glow : Theme.hairline,
                                lineWidth: isCurrent ? 2 : 1)
                )
                .overlay(alignment: .bottomTrailing) {
                    // Soft is a QUESTION, not a decision — a marker you look at, in a different
                    // colour and corner from the keep/reject flags so the two are never confused.
                    if softURLs.contains(url) {
                        Image(systemName: "eye.trianglebadge.exclamationmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Theme.warn)
                            .padding(3)
                            .background(Circle().fill(Theme.base.opacity(0.85)))
                            .padding(3)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let flag = flags[url] {
                        Image(systemName: flag == .keep ? "flag.fill" : "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(flag == .keep ? Theme.base : Theme.ink)
                            .padding(3)
                            .background(Circle().fill(flag == .keep ? Theme.glow : Theme.surface2))
                            .padding(3)
                    }
                }
                // A dot marks frames you've already worked on, so a pass through a shoot is legible.
                if editedURLs.contains(url) && hovered != url {
                    Circle().fill(Theme.glow)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Theme.base, lineWidth: 1))
                        .padding(4)
                }
                // Hovering reveals a way to drop the frame from the working set.
                if hovered == url {
                    Button(action: { onDismiss(url) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white, Color.black.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help("Remove from this session")
                }
            }
            .opacity(isCurrent ? 1 : 0.72)
        }
        .buttonStyle(.plain)
        // Two separate keys on purpose. The selection border hands over between frames as you
        // arrow through a shoot; the dismiss button fades up under the pointer instead of
        // appearing on top of the edited-dot it replaces. Neither may be triggered by anything
        // else in this cell — a thumbnail must never animate because a render finished.
        .animation(Motion.gated(Motion.quick, reduceMotion), value: isCurrent)
        .animation(Motion.gated(Motion.quick, reduceMotion), value: hovered == url)
        .onHover { hovered = $0 ? url : (hovered == url ? nil : hovered) }
        .help(url.lastPathComponent)
    }
}

/// Chips that wrap onto as many lines as they need — SwiftUI has no built-in flow layout on the
/// deployment target, and a horizontal ScrollView would hide half the looks behind a scroll.
struct FlowRow<Content: View>: View {
    let ids: [String]
    let content: (String) -> Content
    private let perRow = 3

    init(_ ids: [String], @ViewBuilder content: @escaping (String) -> Content) {
        self.ids = ids; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: ids.count, by: perRow)), id: \.self) { start in
                HStack(spacing: 6) {
                    ForEach(ids[start..<min(start + perRow, ids.count)], id: \.self) { content($0) }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
