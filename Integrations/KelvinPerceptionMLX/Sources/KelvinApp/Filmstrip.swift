import SwiftUI
import CoreImage
import ImageIO
import AppKit
import KelvinCore

/// Browsing the folder you opened a photo from — the thing every photo app has and Kelvin didn't:
/// somewhere to see the rest of the shoot, and a way back to a frame you already worked on.
enum PhotoBrowser {

    /// Image files sitting alongside `url`. Uses the same extension list the batch path does, so
    /// what you can browse is what Kelvin can actually edit.
    ///
    /// Ordering lives in `PhotoOrder` (KelvinCore) rather than here, because the order a shoot
    /// reads in is a rule worth testing without a window. This returns the cheap, immediate order —
    /// filename, no file reads beyond the directory listing. Capture-time order needs an EXIF pass
    /// and arrives later; see `AppState.loadCaptureDates`.
    static func siblings(of url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        guard let files = try? BatchApply.imageFiles(in: dir), !files.isEmpty else { return [url] }
        return PhotoOrder.sorted(files, by: .filename)
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

/// Whether the filmstrip starts folded, and — separately — whether the user has ever said.
///
/// Opening one frame used to pull the whole folder into view: 437 thumbnails, a strip you did not
/// ask for, from a double-click on a single file. The fix is to let the *intent* of the open set
/// the default. Open a single file and the shoot is listed but folded away — available, not
/// imposed. Open a folder and it is expanded, because that is plainly what was asked for.
///
/// But a photographer who has deliberately folded or unfolded the strip has overruled all of that,
/// and having their choice quietly undone by the next open is worse than either default. So the
/// intent only ever writes while `hasUserChoice` is false: the first time the fold control is
/// clicked, the choice is recorded and the intent stops writing for good. Nothing here fights the
/// user; it fills in for them until they say, and then it stops.
enum FilmstripFold {
    static let expandedKey = "filmstrip.expanded"
    /// Deliberately a second key rather than making the first one optional: `expanded == true`
    /// cannot tell you whether that was a decision or the default it shipped with, and the whole
    /// question here is which of the two it was.
    private static let userChoiceKey = "filmstrip.expanded.chosen"

    static var hasUserChoice: Bool { UserDefaults.standard.bool(forKey: userChoiceKey) }

    /// Called from the fold control. From here on the strip does what it is told.
    static func recordUserChoice(expanded: Bool) {
        UserDefaults.standard.set(expanded, forKey: expandedKey)
        UserDefaults.standard.set(true, forKey: userChoiceKey)
    }

    /// Apply the default implied by how a photo was opened. A no-op once the user has decided.
    /// - Parameter openedFolder: true when a directory was opened (dropped, or picked in ⌘O),
    ///   false for a single file.
    static func applyOpenIntent(openedFolder: Bool) {
        guard !hasUserChoice else { return }
        // Written straight to UserDefaults rather than through a binding because the view that
        // owns the fold state does not exist yet at this point — the strip is only built once a
        // folder has more than one photo in it. `@AppStorage` observes the store, so the value is
        // there when the view appears and updates it in place if it is already on screen.
        UserDefaults.standard.set(openedFolder, forKey: expandedKey)
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
    /// The separable subjects found in this frame. Cached with everything else because the mask
    /// list is per-photo: without it, switching away and back leaves the previous photograph's
    /// people listed under this one — and detection is a Vision pass, far too slow to redo on
    /// every switch when the whole point of this cache is that coming back is instant.
    let subjectInstances: [SubjectInstances.Instance]
    let subjectLuma: Double?
    let skyLuma: Double?
    let healSpots: [HealSpot]
    let detectedSpotCount: Int

    /// What the camera recorded. Cached with the rest because `restore` puts a photo back WITHOUT
    /// re-reading it — so without this field, coming back to photo A showed A's pixels under B's
    /// camera, lens, shutter, ISO, capture date and map link. Plausible, silent, and wrong.
    var capture: CaptureInfo
    /// The look applied to THIS photo. Also absent before, and it carried the black-and-white
    /// conversion with it: apply Mono to B, click back to A, and A rendered monochrome while its
    /// own saved edit knew nothing about it.
    var activeLookId: String?
    /// Per-mask overrides. The auto masks are keyed by literal strings ("subject", "sky"), so they
    /// collide across every photo in the folder — pull the sky down two stops on A and B's sky
    /// came back two stops down too, slider and all.
    var maskAdjustments: [String: [String: Double]]
    var maskFeather: [String: Double]
    var maskTightness: [String: Double]
    var maskInvert: [String: Bool]

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
            || activeLookId != nil
            || !maskAdjustments.isEmpty || !maskFeather.isEmpty
            || !maskTightness.isEmpty || !maskInvert.isEmpty
            || !maskEnabled.isEmpty || !maskStrength.isEmpty
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
    @Binding var sortKey: PhotoSortKey
    @Binding var sortReversed: Bool
    /// True while the EXIF pass is still running, so the header can say the order is provisional
    /// rather than let the strip silently rearrange under the pointer.
    var sortPending: Bool = false
    /// Called when the strip is unfolded, so the deferred per-folder read can happen then.
    var onExpand: () -> Void = {}
    @State private var hovered: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The fold. Which way it starts is set by how the photo was opened (see `FilmstripFold`);
    /// once the user has clicked this control, their choice wins from then on.
    @AppStorage(FilmstripFold.expandedKey) private var expanded = true

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
            Button {
                withAnimation(Motion.gated(Motion.quick, reduceMotion)) { expanded.toggle() }
                // A click here is a decision. Record it, and the open-intent default stops
                // overriding the fold from the next photo onwards.
                FilmstripFold.recordUserChoice(expanded: expanded)
                // Unfolding is the moment the rest of the shoot is actually wanted, so it is the
                // moment its per-file detail gets read. Opening one photograph no longer pays for
                // a folder that stays shut.
                if expanded { onExpand() }
            } label: {
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

            sortControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        // The culling keys used to be spelled out here in a run of static text. That text was the
        // widest thing in an already-full row (the comment above measures it at 575 pt against a
        // 580 pt pane), and it is read once and then never again — where the sort order is a
        // decision a photographer changes per shoot. So the hint moved to the row's tooltip: the
        // shortcuts stay discoverable by hovering the strip's own header, which is where you
        // already are when you are culling, and the width went to the control that earns it.
        .help("P keep · X reject · ←→ move")
    }

    /// Sort: what "the shoot in order" means, and which way round.
    ///
    /// A menu rather than another segmented picker — there is one segmented control in this row
    /// already, and two side by side read as one control with six positions. The button says the
    /// current order so the strip is never silently sorted by something you cannot see.
    private var sortControl: some View {
        Menu {
            Picker("Order", selection: $sortKey) {
                ForEach(PhotoSortKey.allCases, id: \.self) { key in
                    Text(key.longLabel).tag(key)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Reverse", isOn: $sortReversed)
        } label: {
            HStack(spacing: 4) {
                // The arrow shows the direction, so reverse is legible without opening the menu.
                Image(systemName: sortReversed ? "arrow.down" : "arrow.up")
                    .font(.system(size: 8, weight: .bold))
                Text(sortKey.label).font(Theme.mono(9))
                // Capture-time order is provisional until the EXIF read lands. Saying so is the
                // difference between "still working" and "sorted wrong".
                if sortPending {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 10)
                }
            }
            .foregroundColor(Theme.inkDim)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(sortPending
              ? "Reading capture times — showing filename order until they land"
              : "Sort the shoot by \(sortKey.longLabel.lowercased())")
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
                .onChange(of: photos) { _ in
                    // The list itself changed under you — re-sorted, or the capture times landed
                    // and moved everything. Put the frame you are actually editing back under the
                    // pointer, without animating: the content has already moved, and sliding it
                    // afterwards would read as the strip drifting on its own.
                    guard let url = current else { return }
                    proxy.scrollTo(url, anchor: .center)
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
                        // Clickable, so a flag can be taken back where it was put. `onFlag` was
                        // declared and wired and never called from anywhere in this file: keep and
                        // reject existed only on P and X, applied only to the OPEN photo, so there
                        // was no way at all to flag a frame with the mouse or to change your mind
                        // about one you had flagged.
                        Button(action: { onFlag(url, flag) }) {
                            Image(systemName: flag == .keep ? "flag.fill" : "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(flag == .keep ? Theme.base : Theme.ink)
                                .padding(3)
                                .background(Circle().fill(flag == .keep ? Theme.glow : Theme.surface2))
                                .padding(3)
                        }
                        .buttonStyle(.plain)
                        .help(flag == .keep ? "Keeping this — click to clear"
                                            : "Rejected — click to clear")
                    }
                }
                // Hovering an unflagged frame offers both verdicts, so culling does not require
                // opening every photograph to press a key at it.
                .overlay(alignment: .bottomLeading) {
                    if hovered == url, flags[url] == nil {
                        HStack(spacing: 3) {
                            Button(action: { onFlag(url, .keep) }) {
                                Image(systemName: "flag")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Theme.glow)
                                    .padding(3)
                                    .background(Circle().fill(Theme.base.opacity(0.85)))
                            }
                            .buttonStyle(.plain).help("Keep (P)")
                            Button(action: { onFlag(url, .reject) }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(Theme.inkDim)
                                    .padding(3)
                                    .background(Circle().fill(Theme.base.opacity(0.85)))
                            }
                            .buttonStyle(.plain).help("Reject (X)")
                        }
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
