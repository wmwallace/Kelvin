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
                            session.adjustments = Adjustments(light: v[0], warmth: v[1], contrast: v[2])
                            await session.refreshAdjustedPreview()
                        }
                    }
                }
                #endif
        }
    }
}

#if DEBUG
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

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.base.ignoresSafeArea()
                content
            }
            .toolbar { toolbar }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await session.open(item) }
        }
        .sheet(item: Bindable(session).shareItem) { item in
            ShareSheet(url: item.url).ignoresSafeArea()
        }
        .sheet(isPresented: $adjusting) { AdjustPanel() }
        // The adjusted canvas follows both the sliders and the look they are applied to.
        .onChange(of: session.adjustments) { Task { await session.refreshAdjustedPreview() } }
        .onChange(of: session.selectedID) { Task { await session.refreshAdjustedPreview() } }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .empty:
            EmptyStateView(pickerItem: $pickerItem)
        case .working(let stage):
            WorkingView(stage: stage)
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
                LookStrip(composed: composed, columns: composed.looks.count)
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
                HStack(spacing: 0) {
                    LookPager(composed: composed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Caption()
                            LookStrip(composed: composed, columns: 2, describes: true)
                        }
                        .padding(20)
                    }
                    .frame(width: min(380, geo.size.width * 0.38))
                    .background(Theme.surface.ignoresSafeArea())
                }
            } else {
                VStack(spacing: 0) {
                    LookPager(composed: composed)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: 16) {
                        Caption()
                        LookStrip(composed: composed, columns: 4, describes: true)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
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
                Text(session.notice ?? (session.showingOriginal ? "As it came off the camera"
                                                                  : session.selectedLook?.description ?? ""))
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
    @Environment(EditSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: max(columns, 1)),
                  spacing: 14) {
            ForEach(composed.looks) { look in
                let selected = look.id == (session.selectedID ?? composed.openingID)
                Button {
                    withAnimation(Motion.gated(reduceMotion)) { session.selectedID = look.id }
                } label: {
                    VStack(spacing: 6) {
                        // A fixed-shape window the preview fills, so a tile can never grow past
                        // its column — `scaledToFill` alone overflows into its neighbour.
                        Color.clear
                            .aspectRatio(4 / 3, contentMode: .fit)
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
                            Text(look.description)
                                .font(.caption)
                                .foregroundStyle(Theme.inkDim)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(Theme.neutral)
            Text(stage + "…")
                .font(.subheadline)
                .foregroundStyle(Theme.inkDim)
                .contentTransition(.opacity)
        }
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
