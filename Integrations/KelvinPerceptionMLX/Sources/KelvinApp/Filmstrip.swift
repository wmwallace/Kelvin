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
        thumbnailCG(for: url, maxPixel: maxPixel).map { NSImage(cgImage: $0, size: .zero) }
    }

    /// The same work, stopping at the CGImage.
    ///
    /// Thumbnails are decoded off the main actor and the result has to cross back. NSImage's
    /// Sendable conformance is available on the macOS 27 SDK and unavailable on the one CI builds
    /// against, so returning one from a detached task compiles on this Mac and fails everywhere
    /// else. CGImage is Sendable on both, and the wrapper costs nothing on the main actor.
    static func thumbnailCG(for url: URL, maxPixel: Int = 160) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
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
    /// The tallest the strip may be drawn, measured from the workspace rather than assumed. This is
    /// what replaced a hard six-row ceiling; see `rowCount`.
    var maxHeight: Double = 6 * 64
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
    /// The sharpest frame of each run of more than one, when the strip is grouped into bursts or
    /// near-duplicates. Advisory: it marks, it never decides.
    var sharpest: Set<URL> = []
    /// What else the scan noticed — a frame with no readable detail left at either end of the tone
    /// range. Focus is excluded; the soft badge already covers it.
    var exposureConcerns: (URL) -> [PhotoTriage.Concern] = { _ in [] }
    /// The scan's readings for one frame, in words, for the tooltip.
    var scanNote: (URL) -> String? = { _ in nil }
    @Binding var sortKey: PhotoSortKey
    @Binding var sortReversed: Bool
    /// How the strip is partitioned, and the runs to draw. `nil` groups is a flat strip — not one
    /// group holding everything, which would make this view draw a heading over the whole shoot.
    @Binding var grouping: AppState.StripGrouping
    var groups: [AppState.StripGroup]? = nil
    /// False when nothing in the folder carries a position, which is most folders.
    var canGroupByPlace: Bool = false
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

    /// How tall the strip is, and therefore how many rows of thumbnails fit in it.
    ///
    /// One row was fine while the strip was a list and useless once it became groups: a burst of
    /// twenty needs horizontal scrolling INSIDE a column that is already scrolling horizontally, so
    /// the grouping showed you the structure of the shoot and then hid its contents. Dragging the
    /// top edge trades preview space for strip space, which is a judgement only the person looking
    /// at the photograph can make — some shoots are about one frame, some are about forty.
    @AppStorage("filmstrip.height") private var stripHeight = Self.oneRow
    @State private var heightAtDragStart: Double?
    /// The height while a drag is in flight, held here rather than written straight to
    /// `@AppStorage`. Every write to that is a synchronous defaults write AND a change every
    /// observer of the store reacts to, and doing one per drag frame is most of why resizing felt
    /// like it was catching. The store is written once, when the drag ends.
    @State private var liveHeight: Double?

    /// What the strip is sized by right now: the drag if there is one, the remembered value if not.
    private var effectiveHeight: Double { liveHeight ?? stripHeight }

    /// A cell is 56 tall; the rest is the gap between rows.
    private static let cellHeight: Double = 56
    private static let rowSpacing: Double = 8
    static let oneRow: Double = cellHeight
    /// One row's worth of vertical space, which is the unit everything here counts in.
    private static let rowPitch: Double = cellHeight + rowSpacing

    /// How many rows fit, and the reason there is no longer a fixed ceiling.
    ///
    /// This used to stop at six rows however far the top edge was dragged, so a shoot pulled open
    /// to half the window showed six rows of thumbnails and then a band of empty grey — the space
    /// was taken from the photograph and given to nothing. The limit now comes from the room the
    /// workspace actually has (`maxHeight`), so dragging up keeps adding rows until the strip is
    /// as tall as it is allowed to be, and every point of that height has photographs in it.
    private var rowCount: Int {
        let usable = min(effectiveHeight, maxHeight)
        // Rounded, not floored: a row should appear when the edge is dragged halfway towards it,
        // rather than the drag feeling stuck for most of a row and then jumping.
        return max(1, Int((usable / Self.rowPitch).rounded()))
    }

    /// The height the rows actually occupy. The container is pinned to this rather than to the
    /// dragged value, which is what removes the dead band: a drag that lands between two row counts
    /// no longer leaves the difference as empty space under the last row.
    private var rowsHeight: Double {
        Double(rowCount) * Self.rowPitch - Self.rowSpacing
    }

    /// Fill each column top to bottom, then move right — the reading order of a horizontal scroll.
    /// Wrapping left-to-right instead would put frame 2 offscreen while frame 1 has an empty space
    /// beneath it.
    private func columns(_ urls: [URL]) -> [[URL]] {
        guard rowCount > 1 else { return urls.map { [$0] } }
        return stride(from: 0, to: urls.count, by: rowCount).map {
            Array(urls[$0..<min($0 + rowCount, urls.count)])
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .overlay(resizeHandle)
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
                //
                // "Scan" rather than "Check focus", because the pass stopped being about focus: one
                // 1200 px proxy per frame now yields the sharpness reading, the exposure extremes,
                // and the fingerprint the Similar grouping and the sharpest-of-run marker are built
                // on. The old label undersold it to the point where it read as doing nothing.
                Button(action: onScanFocus) {
                    Text("Scan shoot").font(Theme.mono(9)).foregroundColor(Theme.inkDim)
                }
                .buttonStyle(.plain)
                .help("""
                      Measure every frame once: sharpness, exposure extremes, and which frames are \
                      near-duplicates of each other. Nothing is flagged or discarded — the findings \
                      are surfaced for you to look at.
                      """)
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

            groupControl
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

    /// How the strip is partitioned. ONE control on ONE axis — None / Burst / Day / Place / Similar
    /// — rather than a metadata grouping and a separate near-duplicate grouping that a photographer
    /// would have to combine in their head. See docs/DECISIONS.md, D-browse-1.
    ///
    /// A menu for the same reason the sort is one: there is already a segmented control in this row,
    /// and a second one beside it reads as a single control with more positions. The label says the
    /// current lens, so the strip is never partitioned by something you cannot see.
    private var groupControl: some View {
        Menu {
            Picker("Group by", selection: $grouping) {
                ForEach(AppState.StripGrouping.allCases, id: \.self) { key in
                    // Place is dropped from the choices when the folder carries no position at all.
                    if key != .place || canGroupByPlace {
                        Text(key.longLabel).tag(key)
                    }
                }
            }
            .pickerStyle(.inline)
            if !canGroupByPlace {
                Divider()
                // Present and unavailable, with the reason. A choice that silently does not exist
                // reads as a missing feature; one that says "no position recorded" tells you
                // something true about your files. Most folders are this case — a camera without
                // GPS records no position, and the phone in your pocket is the exception.
                Button("Place — no location in these files") {}
                    .disabled(true)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: grouping == .none ? "rectangle.grid.1x2" : "square.stack.3d.down.right.fill")
                    .font(.system(size: 8, weight: .bold))
                Text(grouping == .none ? "Group" : grouping.label).font(Theme.mono(9))
            }
            .foregroundColor(grouping == .none ? Theme.inkDim : Theme.glow)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(grouping == .none
              ? "Group the shoot into bursts, days, places, or near-duplicates"
              : "Grouped by \(grouping.longLabel.lowercased()) — click to change")
    }

    private var strip: some View {
        Group {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    Group {
                        if let groups {
                            groupedRuns(groups)
                        } else {
                            grid(photos, lazy: true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                // Pinned to whole rows — see `rowsHeight`.
                .frame(height: rowsHeight + 20)
                .onChange(of: current) { _, url in
                    guard let url else { return }
                    // A travelled scroll rather than a jump: arrowing through a shoot, the strip
                    // moving is how you keep your place in it.
                    withAnimation(Motion.gated(Motion.standard, reduceMotion)) {
                        proxy.scrollTo(url, anchor: .center)
                    }
                }
                .onChange(of: photos) { 
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

    /// The shoot as headed runs, still one horizontal scroll. A run is a column — its heading above
    /// its own thumbnails — because the alternative (headings interleaved in the same row) leaves
    /// nothing marking where one group ends and the next begins.
    private func groupedRuns(_ groups: [AppState.StripGroup]) -> some View {
        // LAZY. See `grid` — with a real shoot in the strip this is the most expensive view in the
        // app, and it is rebuilt by edits that have nothing to do with it.
        LazyHStack(alignment: .top, spacing: 12) {
            ForEach(groups) { group in
                // A rule between runs, not around them: the boundary is the information, and a box
                // per group would put 300 borders on screen for a shoot of near-duplicates.
                if group.id != groups.first?.id {
                    Divider().frame(height: 62)
                }
                VStack(alignment: .leading, spacing: 5) {
                    heading(for: group)
                    grid(group.urls)
                }
            }
        }
    }

    @ViewBuilder
    private func heading(for group: AppState.StripGroup) -> some View {
        // The row is reserved whether or not this group has a heading, so a strip of mixed headed
        // and unheaded runs — which is every Similar and every Burst grouping, since a lone frame
        // gets no label — keeps its thumbnails on one line instead of stepping up and down.
        HStack(spacing: 5) {
            if let text = group.heading {
                Text(text.uppercased())
                    .font(Theme.mono(9, .semibold)).tracking(1)
                    .foregroundColor(Theme.inkDim)
                    .lineLimit(1)
                if let detail = group.detail {
                    Text(detail)
                        .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                        .lineLimit(1)
                }
            }
        }
        // FIXED SIZE, and it is not cosmetic: inside a horizontal `ScrollView` the available width is
        // shared out among the runs, and `Text` accepts whatever it is offered. Without this the
        // headings truncated to "9:14… 3 fra…" while the thumbnails beneath them — which have fixed
        // frames and cannot compress — stayed the size they were. A heading that says "3 fra…" is
        // worse than no heading: it is a label you have to guess at.
        .fixedSize()
        .frame(height: 11, alignment: .leading)
    }

    /// Thumbnails filling the available rows before advancing rightwards.
    ///
    /// LAZY WHEN IT IS THE WHOLE SHOOT, and this is the edit panel's stutter rather than anything in
    /// the panel. A plain `HStack` builds every column it is given, so opening one frame of a
    /// 438-file shoot put 438 thumbnails in the view tree — and SwiftUI rebuilt all of them on every
    /// change to `AppState`, which includes every tick of every slider drag. Measured with an
    /// automated 200-step drag on the same photograph: 668 ms per step from a folder of 438,
    /// 72 ms per step from a folder of 4. Nine tenths of a drag was the strip.
    ///
    /// `LazyHStack` builds the columns that are on screen, so the cost stops scaling with the size
    /// of the shoot. Scrolling to a frame still works — `ScrollViewReader.scrollTo` resolves an id
    /// inside a lazy stack whether or not that item has been created yet.
    ///
    /// Grouped runs pass `lazy: false` because their own container is already a `LazyHStack`, and
    /// nesting lazy stacks along the same axis makes the inner one size all its content anyway.
    private func grid(_ urls: [URL], lazy: Bool = false) -> some View {
        let cols = Array(columns(urls).enumerated())
        return Group {
            if lazy {
                LazyHStack(alignment: .top, spacing: 8) { columnStack(cols) }
            } else {
                HStack(alignment: .top, spacing: 8) { columnStack(cols) }
            }
        }
    }

    private func columnStack(_ cols: [(offset: Int, element: [URL])]) -> some View {
        ForEach(cols, id: \.offset) { _, column in
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(column, id: \.self) { url in
                    cell(url).id(url)
                }
            }
        }
    }

    /// The grab area for resizing: the strip's top edge. A hairline is too small a target, so the
    /// gesture covers a few points either side of it and the cursor says so on hover.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = heightAtDragStart ?? stripHeight
                        if heightAtDragStart == nil { heightAtDragStart = start }
                        // Upward drag is a taller strip, so the translation is inverted.
                        let proposed = start - value.translation.height
                        liveHeight = min(maxHeight, max(Self.oneRow, proposed))
                    }
                    .onEnded { _ in
                        // Settle on whole rows, so what is stored is what is drawn and reopening
                        // the app cannot restore a height that leaves a part-row of empty space.
                        if liveHeight != nil {
                            stripHeight = min(maxHeight, max(Self.oneRow, rowsHeight))
                        }
                        liveHeight = nil
                        heightAtDragStart = nil
                    }
            )
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
                    // The tone concern sits beside it in the same language, and fires on almost
                    // nothing: every threshold behind it is past the most extreme frame in 836 real
                    // photographs, so a triangle here means genuinely unusual.
                    HStack(spacing: 2) {
                        if !exposureConcerns(url).isEmpty {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Theme.warn)
                                .padding(3)
                                .background(Circle().fill(Theme.base.opacity(0.85)))
                        }
                        if softURLs.contains(url) {
                            Image(systemName: "eye.trianglebadge.exclamationmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(Theme.warn)
                                .padding(3)
                                .background(Circle().fill(Theme.base.opacity(0.85)))
                        }
                    }
                    .padding(3)
                }
                // The sharpest frame of this run. Top-LEFT: every other corner is taken (flags
                // bottom-left, warnings bottom-right, the edited dot and the dismiss button
                // top-right), and a marker that moves depending on what else is on the thumbnail is
                // a marker you cannot scan a strip for.
                .overlay(alignment: .topLeading) {
                    if sharpest.contains(url) {
                        Image(systemName: "scope")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.glow)
                            .padding(3)
                            .background(Circle().fill(Theme.base.opacity(0.85)))
                            .padding(3)
                            .help("Sharpest frame in this run — measured, not chosen")
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
        // The filename, and what the scan measured if it has been past. The number travels with the
        // flag deliberately: an automatic judgement with no visible measurement behind it is one you
        // can neither check nor disagree with.
        .help(scanNote(url).map { "\(url.lastPathComponent) — \($0)" } ?? url.lastPathComponent)
    }
}

/// The Open panel's accessory: whether the rest of the shoot comes too.
///
/// This exists because the behaviour was reported as a surprise. Opening one photograph also listed
/// its folder in the strip, which is the right default — culling, Batch apply and the arrow keys all
/// work on the strip, so an editor that opens exactly one file makes all three useless — but nothing
/// anywhere said it would happen, and unannounced helpfulness reads as an app doing what it likes.
///
/// A checkbox rather than a dialog: the choice is a property of how someone works, so it is asked
/// once, in the place they are already making the decision, and remembered.
struct OpenOptions: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $appState.includeFolderOnOpen) {
                Text("Include the rest of the folder")
            }
            Text(appState.includeFolderOnOpen
                 ? "The other photos are listed in the strip below. Nothing is read from them until the strip is open."
                 : "Only the photo you pick — no filmstrip, no arrow keys. Batch apply is unaffected; it asks for its own folder.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: 460, alignment: .leading)
    }
}

/// The save panel's accessory: what travels out with the file.
///
/// One checkbox, and it is deliberately not a list of metadata fields. The choice a photographer
/// actually makes is "does this file say where I was" — the camera, the lens, the date and the
/// exposure are photographic facts they want kept, and offering them as separate switches would turn
/// one decision into five and make the important one easy to miss.
struct ExportOptions: View {
    @ObservedObject var appState: AppState

    private static let sizes: [(String, Int)] = [
        ("Full resolution", 0), ("4096 px", 4096), ("2048 px", 2048),
        ("1600 px", 1600), ("1080 px", 1080)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Format", selection: $appState.exportFormatId) {
                    Text("JPEG").tag("jpeg")
                    Text("HEIC").tag("heic")
                    Text("PNG").tag("png")
                    Text("TIFF 16-bit").tag("tiff16")
                }
                .frame(width: 190)

                // Long edge, not width: it is the number every submission guideline is written in
                // and the only one that means the same thing for a portrait and a landscape frame.
                Picker("Size", selection: $appState.exportLongEdge) {
                    ForEach(Self.sizes, id: \.1) { Text($0.0).tag($0.1) }
                }
                .frame(width: 190)
            }

            HStack(spacing: 12) {
                Picker("Colour", selection: $appState.exportColorSpaceId) {
                    ForEach(ImageWriter.ColorSpace.allCases, id: \.rawValue) {
                        Text($0.label).tag($0.rawValue)
                    }
                }
                .frame(width: 260)

                // Shown only where it means something. A quality slider next to PNG is a control
                // that does nothing, which is the thing this codebase keeps finding and removing.
                if appState.exportFormat.isLossy {
                    HStack(spacing: 6) {
                        Text("Quality").font(.callout)
                        Slider(value: $appState.exportQuality, in: 0.4...1)
                            .frame(width: 90)
                        Text("\(Int(appState.exportQuality * 100))")
                            .font(.callout).monospacedDigit().frame(width: 26, alignment: .trailing)
                    }
                }
            }

            Divider()

            Toggle(isOn: $appState.stripLocationOnExport) {
                Text("Remove location and camera serial")
            }
            // The consequence of each state, spelled out, because the whole reason this control
            // exists is that the previous behaviour was invisible.
            Text(appState.stripLocationOnExport
                 ? "Camera, lens, date and exposure still travel with the file."
                 : "The file will carry where the photo was taken and which body took it.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: 520, alignment: .leading)
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
