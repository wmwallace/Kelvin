import SwiftUI
import PhotosUI
import KelvinCore

@main
struct KelvinPhoneApp: App {
    @State private var session = EditSession()

    var body: some SwiftUI.Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .preferredColorScheme(.dark)
                #if DEBUG
                // `-regular` forces the regular-width layout, to review the unfolded-Duo arrangement
                // on a simulator that cannot be unfolded from the command line.
                .modifier(ForcedRegularWidth(on: ProcessInfo.processInfo.arguments.contains("-regular")))
                // `-frame 1194x834` lays the app out at that size, scaled to fit the screen — the
                // landscape iPad arrangement, reviewable on a simulator that cannot be rotated from
                // the command line. The layouts choose by size, never by orientation, so it is faithful.
                .modifier(PreviewFrame(size: PreviewFrame.requested))
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    if let i = args.firstIndex(of: "-open"), i + 1 < args.count {
                        await session.open(file: URL(fileURLWithPath: args[i + 1]))
                    }
                    if let i = args.firstIndex(of: "-look"), i + 1 < args.count {
                        session.selectedID = args[i + 1]
                    }
                    // `-adjust <light>,<warmth>,<contrast>` presets the sliders.
                    if let i = args.firstIndex(of: "-adjust"), i + 1 < args.count {
                        let v = args[i + 1].split(separator: ",").compactMap { Double($0) }
                        if v.count == 3 {
                            session.adjustments = LookAdjustments(light: v[0], warmth: v[1], contrast: v[2])
                            await session.refreshAdjustedPreview()
                        }
                    }
                }
                #endif
        }
    }
}

#if DEBUG
private struct PreviewFrame: ViewModifier {
    let size: CGSize?
    static var requested: CGSize? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-frame"), i + 1 < args.count else { return nil }
        let v = args[i + 1].split(separator: "x").compactMap { Double($0) }
        return v.count == 2 ? CGSize(width: v[0], height: v[1]) : nil
    }
    func body(content: Content) -> some View {
        if let size {
            GeometryReader { geo in
                let k = min(geo.size.width / size.width, geo.size.height / size.height)
                content
                    .frame(width: size.width, height: size.height)
                    // A phone-sized frame previews the compact arrangement, anything wider the regular.
                    .environment(\.horizontalSizeClass, size.width < 600 ? .compact : .regular)
                    .scaleEffect(k)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            content
        }
    }
}

private struct ForcedRegularWidth: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.environment(\.horizontalSizeClass, .regular) } else { content }
    }
}
#endif

/// The one screen. What it shows depends on the width it has, never on which device it is —
/// Apple's rule for iPhone Duo, whose inner display is a regular width and whose outer is compact,
/// and the same app has to be right on both as the phone opens in someone's hand.
struct RootView: View {
    @Environment(EditSession.self) private var session
    @Environment(\.horizontalSizeClass) private var width
    @State private var pickerItem: PhotosPickerItem?
    @State private var adjusting = false
    @State private var applyItems: [PhotosPickerItem] = []
    @State private var choosingMore = false
    @State private var choosingPhoto = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.base.ignoresSafeArea()
                content
            }
            .toolbar { toolbar }
            .toolbarBackground(.hidden, for: .navigationBar)
            .background { LookKeys() }
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $pickerItem, matching: .images,
                      photoLibrary: .shared())
        // A photograph dragged in from Files, Photos or another app opens here — how an iPad is used
        // side by side with the place the photographs live.
        .dropDestination(for: PickedPhoto.self) { items, _ in
            guard let first = items.first else { return false }
            Task { await session.open(file: first.url) }
            return true
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await session.open(item) }
        }
        .sheet(item: Bindable(session).shareItem) { item in
            ShareSheet(url: item.url).ignoresSafeArea()
        }
        .sheet(isPresented: $adjusting) { AdjustPanel() }
        .photosPicker(isPresented: $choosingMore, selection: $applyItems, maxSelectionCount: 200,
                      matching: .images, photoLibrary: .shared())
        .onChange(of: applyItems) { _, items in
            guard !items.isEmpty else { return }
            session.apply(to: items)
            applyItems = []
        }
        // The adjusted canvas follows both the sliders and the look they are applied to.
        .onChange(of: session.adjustments) {
            session.persistChoice()
            Task { await session.refreshAdjustedPreview() }
        }
        .onChange(of: session.selectedID) {
            session.persistChoice()
            Task { await session.refreshAdjustedPreview() }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .empty:
            EmptyStateView(pickerItem: $pickerItem)
        case .working(let stage):
            WorkingView(stage: stage, preview: session.workingPreview)
        case .failed(let message):
            FailedView(message: message, pickerItem: $pickerItem)
        case .ready(let composed):
            if width == .regular {
                SideBySideLayout(composed: composed)
            } else {
                StackedLayout(composed: composed)
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if width == .regular { regularToolbar } else { compactToolbar }
    }

    /// Regular width: every action named, none hidden in a menu — there is room, and a word is
    /// easier to find than an icon for someone who is not a photographer. Adjust is not here: on
    /// this width its sliders are on screen beside the looks.
    @ToolbarContentBuilder private var regularToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { choosingPhoto = true } label: {
                ToolbarText("Photos", systemImage: "photo.on.rectangle")
            }
            .keyboardShortcut("o", modifiers: .command)
        }
        if session.composed != nil {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if session.batch == nil {
                    Button { choosingMore = true } label: {
                        ToolbarText("Apply to More…", systemImage: "square.stack.3d.down.right")
                    }
                } else {
                    Button(role: .destructive) { session.stopApplying() } label: {
                        Label("Stop Applying", systemImage: "stop.circle")
                    }
                }
                Button { Task { await session.share() } } label: {
                    ToolbarText("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(session.isSaving)
                Button { Task { await session.saveToPhotos() } } label: {
                    if session.isSaving { ProgressView() } else {
                        ToolbarText("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(session.isSaving)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    @ToolbarContentBuilder private var compactToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
        }
        if session.composed != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adjusting = true } label: {
                    Label("Adjust", systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await session.saveToPhotos() } } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    if session.batch == nil {
                        Button { choosingMore = true } label: {
                            Label("Apply to More Photos…", systemImage: "square.stack.3d.down.right")
                        }
                    } else {
                        Button(role: .destructive) { session.stopApplying() } label: {
                            Label("Stop Applying", systemImage: "stop.circle")
                        }
                    }
                    Button { Task { await session.share() } } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    if session.isSaving {
                        ProgressView()
                    } else {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(session.isSaving)
            }
        }
    }
}

// MARK: - The two layouts

/// Compact width: an iPhone, or iPhone Duo folded. The photograph takes the screen; the looks sit
/// under it as a strip, and a swipe on the photograph moves through them.
struct StackedLayout: View {
    let composed: Composed
    @Environment(EditSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            LookPager(composed: composed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 12) {
                Caption()
                // A fixed tile height: tiles take the photograph's shape now, and a portrait's would
                // otherwise grow the strip and shrink the photograph on a phone.
                LookStrip(composed: composed, columns: composed.looks.count, tileHeight: 76)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
        }
    }
}

/// Regular width: iPhone Duo open, whose inner display is close to square (about 669 × 951 pt
/// upright). The photograph stays the largest thing on screen whichever way it is held:
///
///   wider than tall   → photograph | a panel with the looks in two columns
///   taller than wide  → photograph above, the four looks in one row of four below
///
/// Both grids have an even number of columns — Apple's ask for a grid that may straddle the fold —
/// and both show each look's description, because on this screen there is room to say it.
struct SideBySideLayout: View {
    let composed: Composed

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height {
                // Wide: the photograph, and a panel beside it with everything else — the looks in two
                // columns, then the three adjustments. On an iPad in landscape the panel is a quarter
                // of the screen and the photograph keeps the rest.
                HStack(spacing: 0) {
                    PhotoStage(composed: composed)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            StatusLine()
                            LookStrip(composed: composed, columns: 2, describes: true, tileHeight: 140)
                            InlineAdjust(columns: 1)
                        }
                        .padding(20)
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: min(400, max(300, geo.size.width * 0.32)))
                    .background(Theme.surface.ignoresSafeArea())
                }
            } else {
                // Tall: the photograph above; the looks in one row of four, then the adjustments in a
                // row of three — an iPad upright is wide enough for each to sit side by side.
                VStack(spacing: 0) {
                    PhotoStage(composed: composed)
                    VStack(alignment: .leading, spacing: 16) {
                        StatusLine()
                        LookStrip(composed: composed, columns: 4, describes: true,
                                  tileHeight: min(170, geo.size.height * 0.15))
                        InlineAdjust(columns: 3)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

/// A toolbar button's icon AND its name. The glass toolbar draws a `Label` as its icon alone
/// whatever label style it is given, and on a regular width the words are the point.
struct ToolbarText: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
        .font(.subheadline.weight(.medium))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// The photograph with the compare control on it — on a regular width the control belongs to the
/// picture, where the eye already is, rather than to a caption that no longer needs to exist.
struct PhotoStage: View {
    let composed: Composed

    var body: some View {
        LookPager(composed: composed)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .overlay(alignment: .bottomTrailing) {
                CompareButton().padding(16)
            }
    }
}

/// What is happening, only while something is: saving, applying to more photographs, a restored
/// choice, the original on show. The look's own name and words are on its tile already.
struct StatusLine: View {
    @Environment(EditSession.self) private var session

    private var text: String? {
        if let b = session.batch {
            return "Applying \(session.selectedLook?.name ?? "the look") — \(b.done) of \(b.total)"
        }
        if let notice = session.notice { return notice }
        if session.showingOriginal { return "Showing the original, as it came off the camera" }
        if session.restoredEdit { return "Your choice from last time" }
        return nil
    }

    var body: some View {
        if let text {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.inkDim)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }
}

/// The three adjustments, on screen rather than in a sheet, where the width allows it.
struct InlineAdjust: View {
    let columns: Int
    @Environment(EditSession.self) private var session

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Adjust").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Button("Reset") { session.adjustments = LookAdjustments() }
                    .disabled(session.adjustments.isNeutral)
                    .font(.subheadline)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20, alignment: .top),
                                     count: max(1, columns)),
                      alignment: .leading, spacing: 14) {
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
        }
    }
}

/// Hardware-keyboard choosing, for an iPad with a keyboard: ← and → move through the looks, 1–4
/// pick one. Invisible buttons, because that is how a key equivalent attaches in SwiftUI.
struct LookKeys: View {
    @Environment(EditSession.self) private var session

    var body: some View {
        if let composed = session.composed {
            let ids = composed.looks.map(\.id)
            let current = ids.firstIndex(of: session.selectedID ?? composed.openingID) ?? 0
            ZStack {
                Button("") { session.selectedID = ids[max(0, current - 1)] }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { session.selectedID = ids[min(ids.count - 1, current + 1)] }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                ForEach(Array(ids.prefix(9).enumerated()), id: \.offset) { i, id in
                    Button("") { session.selectedID = id }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [])
                }
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - The photograph

/// The looks, one page each, swiped between. The canvas is flat and opaque — no glass behind the
/// photograph, ever — and holding the compare control shows the photograph as it came in.
struct LookPager: View {
    let composed: Composed
    @Environment(EditSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var session = session
        TabView(selection: Binding(
            get: { session.selectedID ?? composed.openingID },
            set: { id in withAnimation(Motion.gated(reduceMotion)) { session.selectedID = id } })) {
            ForEach(composed.looks) { look in
                Image(decorative: session.showingOriginal ? composed.original
                                  : (look.id == session.selectedLook?.id ? session.adjustedPreview : nil) ?? look.preview,
                      scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(look.id)
                    .accessibilityElement()
                    .accessibilityLabel("\(look.name). \(look.description)")
                    .accessibilityHint("Swipe left or right with three fingers for another look.")
                    .accessibilityAction(named: session.showingOriginal ? "Show the edit" : "Show the original") {
                        session.showingOriginal.toggle()
                    }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .sensoryFeedback(.selection, trigger: session.selectedID)
    }
}

/// The look's name and what it does, in words, plus the hold-to-compare control.
struct Caption: View {
    @Environment(EditSession.self) private var session

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.showingOriginal ? "Original" : (session.selectedLook?.name ?? ""))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(session.batch.map { "Applying \(session.selectedLook?.name ?? "the look") — \($0.done) of \($0.total)" }
                     ?? session.notice ?? (session.showingOriginal ? "As it came off the camera"
                                        : (session.restoredEdit ? "Your choice from last time · " : "")
                                          + (session.selectedLook?.description ?? "")))
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkDim)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            CompareButton()
        }
    }
}

/// Press and hold to see the original; let go to come back. A button, not a gesture hidden on the
/// photograph, so it can be found — and VoiceOver gets the same toggle as an action on the photo.
struct CompareButton: View {
    @Environment(EditSession.self) private var session

    var body: some View {
        Image(systemName: "square.split.2x1")
            .font(.body.weight(.medium))
            .foregroundStyle(session.showingOriginal ? Theme.base : Theme.ink)
            .frame(width: 44, height: 44)
            .background(session.showingOriginal ? AnyShapeStyle(Theme.neutral) : AnyShapeStyle(.clear),
                        in: Circle())
            .chromeGlass(in: Circle())
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}) { pressing in
                session.showingOriginal = pressing
            }
            .sensoryFeedback(.impact(weight: .light), trigger: session.showingOriginal)
            .accessibilityLabel("Compare with original")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { session.showingOriginal.toggle() }
    }
}

// MARK: - Choosing

/// The looks as tiles. The one you are on is lit along its lower edge by the blackbody hairline —
/// the one loud gesture in the interface, and it means exactly one thing.
struct LookStrip: View {
    let composed: Composed
    let columns: Int
    /// Show each look's description under its name — where the screen has room for it.
    var describes = false
    /// A fixed height for the tile, its width following the photograph's shape — so a portrait
    /// photograph's tiles do not grow tall enough to shrink the photograph itself. Nil: fill the
    /// column (the phone's strip).
    var tileHeight: CGFloat? = nil
    @Environment(EditSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The tile takes the PHOTOGRAPH's shape, so a portrait is shown whole rather than cropped to a
        // landscape window — on the iPad the crop was taking the subject's head off in every look.
        // Clamped so a panorama or a tall crop still makes a usable tile.
        let aspect = min(16.0 / 9.0, max(3.0 / 4.0, Double(composed.original.width) / Double(max(1, composed.original.height))))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: max(columns, 1)),
                  alignment: .center, spacing: 14) {
            ForEach(composed.looks) { look in
                let selected = look.id == (session.selectedID ?? composed.openingID)
                Button {
                    withAnimation(Motion.gated(reduceMotion)) { session.selectedID = look.id }
                } label: {
                    VStack(spacing: 6) {
                        // A fixed-shape window the preview fills, so a tile can never grow past
                        // its column — `scaledToFill` alone overflows into its neighbour.
                        // Fitted inside BOTH the column's width and the height cap: capped by height
                        // alone, a landscape tile in the two-column side panel was wider than its
                        // column and overlapped its neighbour.
                        Color.clear
                            .aspectRatio(aspect, contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: tileHeight ?? .infinity)
                            .overlay {
                                Image(decorative: look.preview, scale: 1)
                                    .resizable()
                                    .scaledToFill()
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .bottom) {
                                Capsule().fill(Theme.rimLight).frame(height: 2)
                                    .padding(.horizontal, 10).offset(y: 6)
                                    .opacity(selected ? 1 : 0)
                            }
                        Text(look.name)
                            .font(.footnote.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.ink : Theme.inkDim)
                            .padding(.top, 4)
                        if describes {
                            // Two lines reserved on every tile, so a one-line description does not
                            // leave its tile sitting lower than a two-line neighbour's.
                            Text(look.description)
                                .font(.caption)
                                .foregroundStyle(Theme.inkDim)
                                .multilineTextAlignment(.center)
                                .lineLimit(2, reservesSpace: true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("\(look.name). \(look.description)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

// MARK: - The other states

struct EmptyStateView: View {
    @Binding var pickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 20) {
            Text("Pick a photo and get four finished edits to choose from.")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("Everything happens on this phone. Nothing is uploaded.")
                .font(.body)
                .foregroundStyle(Theme.inkDim)
                .multilineTextAlignment(.center)
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text("Choose a photo")
                    .font(.headline)
                    .foregroundStyle(Theme.base)
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(Theme.neutral, in: Capsule())
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: 480)
    }
}

struct WorkingView: View {
    let stage: String
    /// The photograph as it came in, once it is decoded — shown dimmed under the progress, so the
    /// wait is spent looking at the picture rather than at an empty screen.
    var preview: CGImage? = nil

    var body: some View {
        ZStack {
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                    .opacity(0.45)
                    .transition(.opacity)
            }
            VStack(spacing: 14) {
                ProgressView().tint(Theme.neutral)
                Text(stage + "…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .chromeGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .animation(.easeOut(duration: 0.25), value: preview != nil)
        .accessibilityElement(children: .combine)
    }
}

struct FailedView: View {
    let message: String
    @Binding var pickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 16) {
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                Text("Choose another photo").font(.headline)
            }
        }
        .padding(32)
    }
}

/// The system share sheet, for a file the export just wrote.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
