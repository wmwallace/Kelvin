import SwiftUI
// @preconcurrency: this file hands CIImages to detached tasks in several places. CIImage is
// Sendable on the macOS 27 SDK and not on the one CI builds against, so those crossings are
// clean here and data-race errors there. See KelvinCore/Render/ImageWriter for the full note.
@preconcurrency import CoreImage
import CryptoKit
import UniformTypeIdentifiers
import Metal
import KelvinCore
import KelvinPerceptionMLX

// MARK: - Design system: "an instrument for light"
//
// Kelvin is the unit of colour temperature — the blackbody scale from warm amber (~2700K)
// through daylight white to cool blue (~9000K). The whole identity derives from that scale,
// which is also real data (every recipe carries a temperature). Dark "darkroom" base so images
// are judged against neutral surrounds; monospaced readouts for the measured numbers; the
// signature is the temperature rail marking each look's white balance on the Kelvin scale.

enum Theme {
    static let base     = Color(hex: 0x121418)   // darkroom, cool near-black
    static let surface  = Color(hex: 0x1A1D23)
    static let surface2 = Color(hex: 0x232830)
    static let hairline = Color(hex: 0x30363F)
    static let ink      = Color(hex: 0xEDEFF3)
    static let inkDim   = Color(hex: 0x8B93A0)
    static let inkFaint = Color(hex: 0x565E6A)
    static let warm     = Color(hex: 0xFF9A55)   // ~2700K
    static let neutral  = Color(hex: 0xF1EADC)   // ~5500K
    static let cool     = Color(hex: 0x6FACFF)   // ~9000K
    static let glow     = Color(hex: 0xFF9A55)   // primary accent
    /// "Look at this" — deliberately NOT the accent colour, and not red. A soft-focus flag is a
    /// question for the photographer, not an error and not a recommendation.
    static let warn     = Color(hex: 0xE8C468)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Motion in a darkroom: enough to say that something changed, never enough to look at.
///
/// Two durations and one curve, so nothing in the app can ease differently from anything else,
/// and so no amount of later editing can turn this into a place where things bounce. Ease-out
/// only — a movement that decelerates into place reads as the UI settling, where anything that
/// overshoots reads as the UI performing.
///
/// Everything goes through `gated`. Reduce Motion is a photographer asking for stillness, and
/// `nil` is what both `withAnimation` and `.animation(_:value:)` take to mean "make the change
/// now, without moving".
enum Motion {
    static let quick    = Animation.easeOut(duration: 0.14)
    static let standard = Animation.easeOut(duration: 0.20)

    static func gated(_ animation: Animation, _ reduced: Bool) -> Animation? {
        reduced ? nil : animation
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// The Kelvin scale: temperature → the colour a blackbody glows at, used for the rail and the
/// per-candidate white-balance dot. Amber (warm/low K) → daylight → blue (cool/high K).
enum KelvinScale {
    static let minK = 2000.0, maxK = 10000.0
    private static let warm:    (Double, Double, Double) = (255, 154, 85)
    private static let neutral: (Double, Double, Double) = (241, 234, 220)
    private static let cool:    (Double, Double, Double) = (111, 172, 255)

    static func position(_ k: Double) -> Double {
        (min(max(k, minK), maxK) - minK) / (maxK - minK)
    }

    static func color(_ k: Double) -> Color {
        let t = min(max(k, minK), maxK)
        let (a, b, f): ((Double, Double, Double), (Double, Double, Double), Double)
        if t <= 5500 { a = warm; b = neutral; f = (t - minK) / (5500 - minK) }
        else { a = neutral; b = cool; f = (t - 5500) / (maxK - 5500) }
        return Color(.sRGB,
                     red: (a.0 + (b.0 - a.0) * f) / 255,
                     green: (a.1 + (b.1 - a.1) * f) / 255,
                     blue: (a.2 + (b.2 - a.2) * f) / 255)
    }

    static let gradient = LinearGradient(
        colors: [color(2700), color(4200), color(5500), color(7000), color(9000)],
        startPoint: .leading, endPoint: .trailing)
}

struct CandidateViewModel: Identifiable {
    let id: String
    let label: String
    let baseRecipe: Recipe
    let previewImage: NSImage
}

// MARK: - App state (pipeline logic unchanged; presentation reimagined)

@MainActor
final class AppState: ObservableObject {
    @Published var imageURL: URL?
    @Published var fullResCI: CIImage?
    @Published var proxyCI: CIImage?
    // Subject mask at proxy resolution (for live previews) and the measured subject brightness.
    /// Proxy-resolution subject/sky bitmaps for live previews (keyed "subject"/"sky").
    private var proxyMaskBitmaps: [String: CIImage] = [:]
    private var subjectLuma: Double?
    private var skyLuma: Double?
    @Published var imageId: String = ""
    @Published var perception: Perception?
    @Published var candidates: [CandidateViewModel] = []
    @Published var selectedCandidateId: String?
    @Published var activeRecipe: Recipe?
    /// A preview image and THE PHOTO IT WAS MADE FROM. The pair is the unit here, never the image
    /// on its own.
    ///
    /// Held separately, the two drift. `imageURL` is set at the top of `loadPhoto`, before the
    /// decode has produced anything, so for the whole of a decode the app believed it was showing
    /// the new photo while every pixel on screen still belonged to the old one — and press-and-hold
    /// compared against the *previous* photograph's original. The same window opens on the cached
    /// path: `restore` swaps the original in immediately and the rendered preview only catches up
    /// when the background render lands. A failed decode left the mismatch in place permanently.
    ///
    /// Carrying the URL makes the mismatch unrepresentable rather than something each of those
    /// paths has to remember to avoid: an image belonging to another photo simply reads as nil, and
    /// the compare falls back to showing nothing rather than to showing the wrong photograph.
    private struct TaggedPreview {
        let url: URL
        let image: NSImage
    }
    @Published private var active: TaggedPreview?
    @Published private var original: TaggedPreview?

    /// The current edit, rendered — nil until the first render for THIS photo has landed.
    var activePreviewImage: NSImage? { active.flatMap { $0.url == imageURL ? $0.image : nil } }
    /// The untouched original (proxy) of the photo now open, for the press-and-hold compare.
    var originalPreviewImage: NSImage? { original.flatMap { $0.url == imageURL ? $0.image : nil } }
    @Published var showingOriginal = false
    /// Objective craft flags on the current edit (clipping, skin, cast) — empty when clean.
    @Published var activeCraftIssues: [AestheticEvaluator.Issue] = []
    /// The measurement those flags came from, kept so a fix can be sized from what is on screen and
    /// so the UI can ask whether a fix has anywhere left to go (see `canFix`).
    @Published private var lastCraftReading: CraftFix.Reading?
    /// Subject fixes that have been clicked and come back with nothing to give — the control is at
    /// its ceiling, or it cannot move this photo's metric at all. Cleared whenever the base changes
    /// (new photo, new candidate, reset), because then the question is open again.
    @Published private var exhaustedFixes: Set<AestheticEvaluator.Issue> = []

    /// The full editable global adjustment set, held as ABSOLUTE values rather than deltas. Sliders bind
    /// straight to its fields; it starts from the chosen candidate and the user takes it from there.
    @Published var edit = GlobalAdjustments.neutral
    /// The candidate's values as generated — the baseline manual edits are measured against (for
    /// the "carry my tweaks to the batch" and preference logging), and what Reset returns to.
    private var editBaseline = GlobalAdjustments.neutral
    /// Manual straighten angle (degrees); auto-crops the corners. Per-photo framing.
    @Published var straighten = 0.0
    /// What the camera recorded — body, lens, exposure, when and where.
    @Published var capture = CaptureInfo()
    /// The creative look layered on the chosen candidate, if any (see `LookPreset`).
    @Published var activeLookId: String?
    /// Per-colour HSL (the colour mixer): band → {h,s,l}. Empty bands are dropped.
    @Published var hsl: [String: HSLAdjustment] = [:]
    @Published var hslBand = "red"
    let hslBands = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]

    /// A binding to one HSL component of the currently-selected colour band.
    func hslBinding(_ kp: WritableKeyPath<HSLAdjustment, Double>) -> Binding<Double> {
        Binding(
            get: { self.hsl[self.hslBand]?[keyPath: kp] ?? 0 },
            set: { newValue in
                var a = self.hsl[self.hslBand] ?? HSLAdjustment(h: 0, s: 0, l: 0)
                a[keyPath: kp] = newValue
                if a.h == 0 && a.s == 0 && a.l == 0 { self.hsl[self.hslBand] = nil }
                else { self.hsl[self.hslBand] = a }
            })
    }
    /// Manual mask control: which auto-masks are on, and each one's strength (0…100 → opacity).
    @Published var maskEnabled: [String: Bool] = [:]
    @Published var maskStrength: [String: Double] = [:]
    private var baseMasks: [Mask] = []
    /// Per-mask local adjustments the user has edited, keyed by mask id then by adjustment name.
    /// The engine proposes values (a sky mask arrives with highlights pulled down); these are the
    /// overrides on top, so an untouched mask keeps exactly what the engine chose.
    @Published var maskAdjustments: [String: [String: Double]] = [:]
    @Published var maskFeather: [String: Double] = [:]
    @Published var maskTightness: [String: Double] = [:]
    @Published var maskInvert: [String: Bool] = [:]
    @Published var showMaskOverlay: Bool = false
    /// True while a mask's TONE slider is being dragged, which hides the overlay for the duration
    /// so the photograph is visible underneath. Set by the editors, not by the renderer.
    @Published var isAdjustingMaskTone: Bool = false

    /// Whether the overlay is actually drawing anything — the toggle being on is not enough, since
    /// with nothing selected there is no mask to draw. The pill and the `O` key report this rather
    /// than the raw flag, so the control cannot claim to be doing something invisible.
    var isOverlayShowing: Bool { showMaskOverlay && selectedMask != nil }

    /// Presentation for every adjustment in `Mask.adjustmentKeys` — the renderer's contract, which
    /// lives in Core and is tested there. This list supplies only the label, range and unit; it
    /// must not decide WHICH adjustments exist, because that is exactly how the two mask editors
    /// drifted apart (auto masks had six, hand-drawn masks three).
    ///
    /// `assertCoversTheContract()` below checks the two agree at launch in debug builds, since the
    /// app package has no test target to check it properly.
    static let maskAdjustmentSpecs: [(key: String, label: String, range: ClosedRange<Double>, unit: String)] = [
        ("exposure_ev", "Exposure",   -3...3,      " EV"),
        // RECOVERY ONLY, and the range says so. `CIHighlightShadowAdjust`'s highlight amount is
        // documented 0…1 with 1.0 meaning "no change", so the renderer's `1.0 + highlights/100`
        // clamps for any positive value and does exactly nothing — measured at ΔE 0.0. Offering a
        // slider that is dead across half its travel is worse than offering a shorter one.
        ("highlights",  "Highlight recovery", -100...0, ""),
        ("shadows",     "Shadows",    -100...100,  ""),
        ("contrast",    "Contrast",   -100...100,  ""),
        ("saturation",  "Saturation", -100...100,  ""),
        ("vibrance",    "Vibrance",   -100...100,  "")
    ]

    /// Fails loudly in debug if the panel and the renderer disagree about which adjustments exist.
    ///
    /// The app package has no test target, so this is the only place the drift that motivated
    /// `Mask.adjustmentKeys` can be caught automatically. A missing key means a slider the
    /// renderer honours that nobody can reach; an extra one means a slider that does nothing.
    static func assertCoversTheContract() {
        assert(Set(maskAdjustmentSpecs.map(\.key)) == Set(Mask.adjustmentKeys),
               "mask panel and renderer disagree: panel has "
               + "\(Set(maskAdjustmentSpecs.map(\.key)).symmetricDifference(Set(Mask.adjustmentKeys)))"
               + " that the other does not")
    }

    /// Binding for one adjustment of one mask, falling back to the engine's own value.
    func maskAdjustmentBinding(_ maskId: String, _ key: String) -> Binding<Double> {
        Binding(
            get: {
                if let v = self.maskAdjustments[maskId]?[key] { return v }
                return self.baseMasks.first { $0.id == maskId }?.adjustments[key] ?? 0
            },
            set: { newValue in
                var all = self.maskAdjustments[maskId]
                    ?? self.baseMasks.first { $0.id == maskId }?.adjustments ?? [:]
                all[key] = newValue
                self.maskAdjustments[maskId] = all
            })
    }

    func maskFeatherBinding(_ maskId: String) -> Binding<Double> {
        Binding(get: { self.maskFeather[maskId]
                        ?? self.baseMasks.first { $0.id == maskId }?.feather ?? 0 },
                set: { self.maskFeather[maskId] = $0 })
    }

    func maskTightnessBinding(_ maskId: String) -> Binding<Double> {
        Binding(get: { self.maskTightness[maskId]
                        ?? self.baseMasks.first { $0.id == maskId }?.tightness ?? 0 },
                set: { self.maskTightness[maskId] = $0 })
    }

    func maskInvertBinding(_ maskId: String) -> Binding<Bool> {
        Binding(get: { self.maskInvert[maskId]
                        ?? self.baseMasks.first { $0.id == maskId }?.invert ?? false },
                set: { self.maskInvert[maskId] = $0 })
    }

    /// Put one mask back to exactly what the engine proposed.
    func resetMask(_ maskId: String) {
        maskAdjustments.removeValue(forKey: maskId)
        maskFeather.removeValue(forKey: maskId)
        maskTightness.removeValue(forKey: maskId)
        maskInvert.removeValue(forKey: maskId)
        onEdit()
    }
    /// Hand-added parametric gradient masks (radial / linear) — the user's own local edits.
    @Published var userMasks: [UserMaskVM] = []

    /// Every separable subject Vision found in this photo — *this* person, *that* dog, the hillside
    /// — each with its own mask, ready to be edited on its own. Empty is a real answer (a flat
    /// landscape has no subject), not a failure.
    @Published var subjectInstances: [SubjectInstances.Instance] = []
    /// The instance the pointer is over in the list, outlined on the canvas. A row reading
    /// "Person 2" tells you nothing about which person that is until you can see it.
    @Published var highlightedInstanceId: String?

    /// True while the pointer is over the Repair controls, which draws a ring around every detected
    /// spot on the photograph.
    ///
    /// Dust spots are a few pixels across and the whole difficulty is that you cannot see them at
    /// preview size — so a toggle you switch on and cannot verify is a toggle you have to take on
    /// faith. Hover rather than a switch, for two reasons: it is the pattern the subject list
    /// already uses (hover a row, see which person it means), and rings over a photograph are
    /// clutter for every second you are not asking the question.
    ///
    /// Deliberately NOT a before/after: the app already has one. Hold to compare shows the frame
    /// with the spots back, which answers "what did it change". This answers "what did it find".
    @Published var showingRepairSpots = false

    /// Instances that already have a mask, so the list can show which are in play and clicking one
    /// again selects it rather than adding a duplicate.
    var maskedInstanceIds: Set<String> {
        Set(userMasks.compactMap { $0.kind == .instance ? $0.instanceId : nil })
    }

    /// Point saved per-subject masks back at the subjects in the CURRENT detection.
    ///
    /// A sidecar outlives the detection pass that made it. Reopen the photo and Vision runs again,
    /// handing out fresh per-pass indices — so a saved mask on `person1` is a mask on nothing, and
    /// the local edit the photographer saved comes back silently inert. The mask remembers where
    /// its subject *was* instead, and that survives: match the stored box against this pass by
    /// geometry and adopt whatever id it goes by now.
    ///
    /// A subject that cannot be found again keeps its old id rather than being deleted. The mask
    /// renders as nothing, but it is still in the list with its settings intact, so a detection
    /// that misses someone once does not destroy the work — reopening after it comes back finds
    /// it again.
    private func rekeyInstanceMasks() {
        let saved = userMasks.enumerated().filter { $0.element.boundInstanceId != nil }
        guard !saved.isEmpty, !subjectInstances.isEmpty else { return }
        let references = saved.compactMap { entry -> SubjectInstances.Reference? in
            guard let id = entry.element.instanceId, let box = entry.element.instanceBox else { return nil }
            return SubjectInstances.Reference(id: id, kind: entry.element.instanceKind ?? .object,
                                              boundingBox: box)
        }
        guard !references.isEmpty else { return }

        let matched = SubjectInstances.reidentify(subjectInstances, as: references)
        for (index, mask) in saved {
            guard let oldId = mask.instanceId, let now = matched.instances[oldId] else { continue }
            userMasks[index].instanceId = now.id
            userMasks[index].instanceBox = now.boundingBox
            userMasks[index].instanceKind = now.kind
        }
    }

    /// Add (or re-select) the mask for one detected subject.
    func addInstanceMask(_ instance: SubjectInstances.Instance) {
        // Kind-checked: a SKIN mask scoped to this person is a different tool, and its existence
        // must not make the pick-list refuse to create the person's lift mask.
        if let existing = userMasks.first(where: { $0.kind == .instance && $0.instanceId == instance.id }) {
            selectedUserMaskId = existing.id
            onEdit()          // selecting is not creating — do not re-arm the overlay
            return
        }
        var m = UserMaskVM(kind: .instance)
        m.instanceId = instance.id
        m.instanceLabel = instance.label
        m.instanceBox = instance.boundingBox
        m.instanceKind = instance.kind
        // A visible starting nudge, like every other mask here: a new mask that changes nothing
        // looks broken. Up for a subject (the usual reason to isolate one is that it is too dark),
        // and gentle enough to be a starting point rather than a decision.
        m.exposure = 0.3
        userMasks.append(m)
        selectedUserMaskId = m.id
        // Shown once, on CREATION only. A mask you cannot see when it appears looks broken —
        // but re-selecting an existing one used to turn the overlay back on too, which is why it
        // felt like it could not be dismissed. Turn it off and it stays off until you make
        // another mask.
        showMaskOverlay = true
        onEdit()
    }

    func adjustBrushRadius(by delta: Double) {
        brushRadius = min(0.35, max(0.02, brushRadius + delta))
    }

    /// Sensor dust/spots detected once on load (normalised → resolution-independent, so the same
    /// set heals the proxy preview, the full-res export, and every frame of a batch — dust sits at
    /// a fixed sensor position across a whole shoot).
    /// Readable so the canvas can ring them on hover; still only written here.
    private(set) var healSpots: [HealSpot] = []
    @Published var detectedSpotCount = 0
    /// Opt-in: dust removal is off by default so a clean frame is never touched, and the user
    /// decides when a spot is dust versus real detail.
    @Published var removeDust = false { didSet { updateActiveRecipe() } }

    @Published var isProcessing = false
    @Published var statusMessage = "Drop a photo or a folder to read the light."
    @Published var batchOutcome: BatchApply.Outcome?
    @Published var showBatchSheet = false

    private let store: PreferenceStore
    /// GPU-backed Core Image context — the "accelerator". A Metal device + cached intermediates and
    /// fast downsampling make live slider previews render on the GPU instead of the CPU.
    private let context: CIContext = {
        // Force the high-performance GPU (matters on multi-GPU Macs), cache intermediates, and skip
        // high-quality downsampling for previews. This is PREVIEW ONLY — export renders through
        // ImageWriter's own full-precision context, so output quality is never affected.
        let opts: [CIContextOption: Any] = [
            .cacheIntermediates: true, .highQualityDownsample: false, .allowLowPower: false
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: opts)
        }
        return CIContext(options: opts)
    }()
    /// Zoom (1 = fit) and pan (view points) for inspecting the photo.
    @Published var zoom = 1.0
    @Published var pan = CGSize.zero
    // The real on-device VLM. An actor, so the model loads once and is reused across photos.
    private let perceptionProvider = MLXPerceptionProvider()

    /// Used when the model can't run (not yet downloaded, offline). Low confidence keeps the
    /// engine on its conservative, measurement-only path rather than committing to a scene.
    private static let conservativeRead = Perception(
        scene: .other,
        subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
        lighting: Perception.Lighting(condition: .indoorDaylight, direction: .diffuse, contrastRange: .normal),
        problems: [], intent: .natural, confidence: 0.3)

    init() {
        Self.assertCoversTheContract()
        let appSupport = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support"))
            .appendingPathComponent(Branding.displayName)
        let logURL = appSupport.appendingPathComponent("preferences.jsonl")
        self.store = PreferenceStore(logFileURL: logURL)
    }

    /// Screenshot/demo affordance: KELVIN_DEMO_IMAGE=<path> auto-loads a photo on launch. Inert
    /// unless the variable is set.
    func loadDemoIfRequested() async {
        guard candidates.isEmpty,
              let path = ProcessInfo.processInfo.environment["KELVIN_DEMO_IMAGE"] else { return }
        await loadPhoto(from: URL(fileURLWithPath: path))
    }

    // MARK: Folder browsing + per-photo sessions

    /// The other photos sitting in the folder you opened from, for the filmstrip, in the order the
    /// strip shows them.
    @Published var folderPhotos: [URL] = []
    /// Photos whose edit differs from the candidate Kelvin generated (drives the strip's dot).
    @Published var editedURLs: Set<URL> = []

    // MARK: Strip order
    //
    // The strip sorted by filename, which is only a proxy for the order the frames were taken in:
    // two bodies, two cards, a renamed export or a frame counter past 9999 all interleave wrongly
    // and there was no way to say so. The rules live in `PhotoOrder` (KelvinCore) so they are
    // testable without a window; what lives here is when to re-sort and where the dates come from.

    /// Time, because "the shoot in order" means time. Not persisted: which order a folder wants is
    /// a property of the folder — a wedding wants time, a folder of numbered scans wants names —
    /// so carrying last week's choice into an unrelated shoot would be a worse guess than the
    /// default is.
    @Published var photoSort: PhotoSortKey = .captureTime { didSet { reorderFolderPhotos() } }
    @Published var photoSortReversed = false { didSet { reorderFolderPhotos() } }

    /// When and where each photo in `captureIndexFolder` was taken. Empty until the background read
    /// lands, which `PhotoOrder.sorted` treats as "nothing is dated" — so the strip shows filename
    /// order in the meantime rather than an empty or jumping list.
    ///
    /// One index rather than a dates dictionary, because grouping by place needs the positions and
    /// they come out of the SAME header read. Reading the folder twice to get them separately would
    /// double the slowest part of opening a shoot.
    /// Written by `loadCaptureIndex` and by tests that need a folder with known dates and positions;
    /// nothing else should assign it.
    @Published var captureIndex = PhotoOrder.CaptureIndex()
    /// Which directory `captureIndex` describes. One folder at a time, which is how a shoot is
    /// worked: opening every frame of a 437-shot folder must not re-read 437 EXIF headers each
    /// time. Leaving for another folder and coming back costs one re-read, which is the price of
    /// not carrying an unbounded cache of dates for folders nobody is looking at.
    private var captureIndexFolder: URL?
    private var captureIndexTask: Task<Void, Never>?
    /// True while the read is in flight, so the strip's sort control can say the order is not
    /// settled yet instead of appearing to have sorted wrongly.
    @Published private(set) var captureInfoPending = false

    /// Whether the order on screen is still provisional. Only true under capture-time sort — the
    /// read also runs when you are sorting by name (so switching later is instant), but a name
    /// sort is not waiting on it and must not display as though it were.
    var sortOrderPending: Bool { captureInfoPending && photoSort == .captureTime }

    /// Put `folderPhotos` back in the order the controls currently ask for. Cheap — a sort of a
    /// few hundred URLs against an in-memory dictionary, no file access.
    private func reorderFolderPhotos() {
        folderPhotos = PhotoOrder.sorted(folderPhotos, by: photoSort,
                                         reversed: photoSortReversed, captureDates: captureIndex.dates)
    }

    /// The per-file work a filmstrip needs — capture times, which photos carry edits, which are
    /// flagged — run only when the strip is actually on screen.
    ///
    /// Deferred rather than dropped: the strip still shows everything the moment you open it. What
    /// changed is that opening a single photograph no longer pays for a shoot you did not ask to
    /// see. Called again when the strip is unfolded, and idempotent, so the cost lands once.
    func loadFolderDetailIfVisible(for folder: URL, photos: [URL]) {
        guard UserDefaults.standard.bool(forKey: FilmstripFold.expandedKey) else {
            pendingFolderDetail = (folder, photos)
            return
        }
        pendingFolderDetail = nil
        loadCaptureIndex(for: folder, photos: photos)
        editedURLs.formUnion(EditStore.edited(among: photos))
        flags = FlagStore.flags(among: photos)
    }

    /// The folder whose detail has not been read yet, held so unfolding the strip can pay the cost
    /// then instead of on open.
    private var pendingFolderDetail: (folder: URL, photos: [URL])?

    /// Called when the strip is unfolded. Pays the deferred cost, once.
    func filmstripDidExpand() {
        guard let pending = pendingFolderDetail else { return }
        pendingFolderDetail = nil
        loadCaptureIndex(for: pending.folder, photos: pending.photos)
        editedURLs.formUnion(EditStore.edited(among: pending.photos))
        flags = FlagStore.flags(among: pending.photos)
    }

    /// Read when and where each frame was taken, **off the main thread**, and re-sort when it lands.
    ///
    /// An EXIF read is a header read, not a decode, so it is cheap per file — but 437 files is 437
    /// file opens, and this codebase has twice put the window on the floor by doing per-file work
    /// on the main thread (thumbnails once decoded whole RAWs during view layout and the window
    /// never appeared). So: never on the main thread, never blocking the open, and the strip is
    /// usable in filename order throughout.
    private func loadCaptureIndex(for folder: URL, photos: [URL]) {
        guard captureIndexFolder != folder else { return }      // already have this folder
        captureIndexTask?.cancel()
        captureIndexFolder = folder
        captureIndex = PhotoOrder.CaptureIndex()
        captureInfoPending = true
        // The one place that knows the shoot has changed, so it is where everything keyed to the
        // OLD shoot is let go of.
        //
        // The scan is the expensive one: 8½ minutes of decoding on a 437-frame RAW folder, which
        // used to carry on regardless and hold the progress flag that stops the next folder's scan
        // from ever starting. The dictionaries are cheap each but unbounded across a session — the
        // thumbnail cache is ~68 KB a frame, so five shoots is ~150 MB of 160 px previews for
        // folders nobody has open, and it was never cleared anywhere.
        scanTask?.cancel()
        focusScanProgress = nil
        let keep = Set(photos)
        thumbnails = thumbnails.filter { keep.contains($0.key) }
        focus = focus.filter { keep.contains($0.key) }
        triage = triage.filter { keep.contains($0.key) }
        captureIndexTask = Task { [weak self] in
            let index = await Task.detached(priority: .utility) {
                PhotoOrder.captureIndex(for: photos)
            }.value
            guard !Task.isCancelled, let self else { return }
            // Guard against a folder switch that started while this read was running — a late
            // result must not re-sort the strip you are looking at now using another folder's
            // dates.
            guard self.captureIndexFolder == folder else { return }
            self.captureIndex = index
            self.captureInfoPending = false
            self.reorderFolderPhotos()
            // A folder with no positions in it cannot be grouped by place, and leaving the lens
            // selected would partition the shoot into one group called "No location" — which looks
            // like the grouping is broken rather than like the files have no GPS. The menu says why
            // the choice is unavailable; the strip goes back to flat.
            if self.stripGrouping == .place, !index.hasAnyLocation {
                self.stripGrouping = .none
            }
        }
    }

    // MARK: Culling — deciding what stays, before editing what's left
    //
    // A folder is often two hundred frames and the workspace showed all of them, which is the
    // thing that makes a shoot feel unmanageable. The established answer is to decide first and
    // edit second: one binary decision per frame, driven from the keyboard, then hide everything
    // you rejected. Ratings and colour labels are deliberately absent — dozens of possible states
    // per photo is what makes culling slow.

    /// Keep/reject per photo, loaded for the current folder.
    @Published var flags: [URL: PhotoFlag] = [:]

    /// Which frames the strip is showing.
    enum StripFilter: String, CaseIterable {
        case all = "All", keepers = "Keepers", undecided = "Undecided"
        case edited = "Edited", soft = "Focus"
    }
    @Published var stripFilter: StripFilter = .all

    /// Photos the strip should actually display, after the filter. The frame you are editing is
    /// always included — filtering the open photo out from under yourself is disorienting.
    var visiblePhotos: [URL] {
        folderPhotos.filter { url in
            if url == imageURL { return true }
            switch stripFilter {
            case .all:       return flags[url] != .reject
            case .keepers:   return flags[url] == .keep
            case .undecided: return flags[url] == nil
            // What you have actually worked on. The strip has drawn a dot for this since the
            // filmstrip existed; it just could not be filtered on, which is the half that makes it
            // useful — "show me the twenty I edited" is the last step of a shoot.
            case .edited:    return editedURLs.contains(url)
            // Review, not a verdict: this is the list to LOOK at, so the false positives are
            // the point of it rather than something hidden by it.
            case .soft:      return focus[url]?.isSoft == true
            }
        }
    }

    // MARK: Grouping — how the strip is partitioned
    //
    // ONE control, ONE axis. Two passes in Core partition a shoot and they are complementary rather
    // than competing: `PhotoOrder.grouped` by when and where (day / burst / place, from one EXIF
    // header read), `PhotoTriage.groups` by what the picture looks like (a 64-bit difference hash
    // plus a time signal, from the triage scan).
    //
    // Surfacing both as separate menus would be worse than either. "How is the strip organised" is
    // ONE question, and a photographer who has picked "by day" and then meets a second, orthogonal
    // grouping control has to hold two partitions in their head to predict what they will see. So
    // similarity is a PEER of the metadata lenses — None / Burst / Day / Place / Similar — and not a
    // second dimension over them. See docs/DECISIONS.md, D-browse-1, including why the nested
    // version was rejected despite being strictly more expressive.

    /// The lens the strip is read through.
    enum StripGrouping: String, CaseIterable, Hashable {
        case none, burst, day, place, similar

        /// Short, for the control's own label.
        var label: String {
            switch self {
            case .none:    return "None"
            case .burst:   return "Burst"
            case .day:     return "Day"
            case .place:   return "Place"
            case .similar: return "Similar"
            }
        }

        /// Spelled out, for the menu — where there is room to say what the lens actually does.
        var longLabel: String {
            switch self {
            case .none:    return "No grouping"
            case .burst:   return "Bursts"
            case .day:     return "Capture day"
            case .place:   return "Place"
            case .similar: return "Similar pictures"
            }
        }

        /// The Core lens, where there is one. `nil` for the two cases Core does not own: no grouping
        /// at all, and similarity — which comes from the triage scan rather than the EXIF index.
        var coreKey: PhotoOrder.PhotoGroupKey? {
            switch self {
            case .burst:   return .burst
            case .day:     return .day
            case .place:   return .location
            case .none, .similar: return nil
            }
        }
    }

    @Published var stripGrouping: StripGrouping = .none {
        didSet {
            // Similarity needs fingerprints, and the fingerprints come out of the scan the "Check
            // focus" button already runs — one pass, one 1200 px proxy per frame, both readings.
            // So asking for the lens IS asking for the measurement. The alternative is a menu item
            // that appears to do nothing on any folder nobody happens to have scanned yet, which is
            // indistinguishable from a broken control. Idempotent, and a no-op once the folder is
            // measured.
            if stripGrouping == .similar { scanFocus() }
        }
    }

    /// Whether grouping by place can say anything. False for most folders — a camera without GPS
    /// records no position at all — and false while the header read is still in flight, when the
    /// honest answer is "not yet" rather than "everything is in one place".
    var canGroupByPlace: Bool { captureIndex.hasAnyLocation }

    /// A run of the strip drawn under one heading.
    struct StripGroup: Identifiable, Equatable {
        let id: String
        /// `nil` draws no heading. A lone frame is not a burst and not a cluster of alike pictures,
        /// and heading every singleton would bury the runs that ARE one under a row of labels. Day
        /// and Place always have one: a day with a single frame in it is still that day.
        let heading: String?
        /// The second line — a count, a time span, a position. Never load-bearing on its own.
        let detail: String?
        let urls: [URL]
    }

    /// `visiblePhotos`, partitioned by the current lens.
    ///
    /// `nil` under `.none`, deliberately: a flat strip is a different rendering, not a grouping with
    /// one bucket — the same reason `PhotoGroupKey` carries no `.none` case. Modelling it as one
    /// bucket would make the view unwrap a heading it must not draw.
    var stripGroups: [StripGroup]? {
        guard stripGrouping != .none else { return nil }
        let photos = visiblePhotos
        guard !photos.isEmpty else { return [] }

        if stripGrouping == .similar { return similarGroups(photos) }
        guard let key = stripGrouping.coreKey else { return nil }
        // Groups and their members arrive in FINAL order — residue last, the strip's reverse already
        // applied. Do not re-sort them here.
        return PhotoOrder.grouped(photos, by: key, index: captureIndex,
                                  reversed: photoSortReversed)
            .map { group in
                StripGroup(id: group.id,
                           heading: heading(for: group),
                           detail: detail(for: group),
                           urls: group.urls)
            }
    }

    /// Near-duplicates, from the fingerprints the scan produced.
    ///
    /// Unmeasured frames are a residue group at the end rather than singletons scattered through the
    /// strip, because "no fingerprint yet" is not the same claim as "this picture is unique" and the
    /// two must not read alike. The group empties itself as the scan lands.
    private func similarGroups(_ photos: [URL]) -> [StripGroup] {
        // In CAPTURE order, not strip order: `PhotoTriage.groups` is order-dependent by construction
        // — a different order seeds different groups — and it documents capture order as its
        // contract, because that makes the seed the first frame of a burst and it is what the time
        // half of its rule assumes. Reversing the strip must change the order runs are SHOWN in,
        // never which frames are in a run together.
        let chronological = PhotoOrder.sorted(photos, by: .captureTime, captureDates: captureIndex.dates)
        let frames = chronological.compactMap { url -> PhotoTriage.Frame? in
            guard let signature = triage[url]?.signature else { return nil }
            return PhotoTriage.Frame(url: url, signature: signature, captured: captureIndex.dates[url])
        }
        let unmeasured = chronological.filter { triage[$0] == nil }

        var groups = PhotoTriage.groups(frames).map { urls in
            StripGroup(id: "similar:\(urls.first?.path ?? "")",
                       heading: urls.count > 1 ? "\(urls.count) alike" : nil,
                       detail: nil,
                       urls: urls)
        }
        if photoSortReversed { groups.reverse() }
        if !unmeasured.isEmpty {
            groups.append(StripGroup(id: "similar:unmeasured",
                                     heading: "Not measured yet",
                                     detail: "\(unmeasured.count) \(unmeasured.count == 1 ? "frame" : "frames")",
                                     urls: unmeasured))
        }
        return groups
    }

    /// Headings are the app's to format — Core does no localisation on purpose.
    private func heading(for group: PhotoOrder.PhotoGroup) -> String? {
        if group.isResidue {
            switch group.kind {
            case .day, .burst: return "No date"
            case .location:    return "No location"
            }
        }
        switch group.kind {
        case .day:
            guard let start = group.start else { return nil }
            return DateFormatter.localizedString(from: start, dateStyle: .full, timeStyle: .none)
        case .burst:
            // A run of one is not a burst. Saying so for every unrepeated frame in a shoot would be
            // several hundred headings, and the runs worth seeing would be lost among them.
            guard group.count > 1, let start = group.start else { return nil }
            return Self.timeOfDay.string(from: start)
        case .location:
            guard let anchor = group.anchor else { return nil }
            // Coordinates, not a place name. Reverse geocoding is a network call, and this app does
            // not make network calls (non-negotiable: everything runs on-device). Degrees with one
            // decimal place is about 11 km — enough to tell two venues apart, and it does not
            // pretend to a precision the heading is not for.
            return Self.coordinates(anchor)
        }
    }

    private func detail(for group: PhotoOrder.PhotoGroup) -> String? {
        let frames = "\(group.count) \(group.count == 1 ? "frame" : "frames")"
        guard !group.isResidue else { return frames }
        switch group.kind {
        case .day, .location:
            return frames
        case .burst:
            guard group.count > 1 else { return nil }
            // The span, so a six-frame run over two seconds reads differently from one over a
            // minute. Whole seconds: EXIF records the shutter to the second, so a decimal here
            // would be inventing resolution the file does not have.
            guard let duration = group.duration, duration >= 1 else { return frames }
            return "\(frames) · \(Int(duration.rounded()))s"
        }
    }

    /// Shared, because a `DateFormatter` is expensive to build and these are formatted per heading
    /// during view layout.
    private static let timeOfDay: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    /// "50.4°N, 4.1°W" — hemisphere letters rather than signs, which is how a position is read.
    static func coordinates(_ point: GeoPoint) -> String {
        let lat = String(format: "%.1f°%@", abs(point.latitude), point.latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.1f°%@", abs(point.longitude), point.longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }

    // MARK: Focus review
    //
    // Soft frames are SURFACED, never acted on. The measurement is good but not infallible, and an
    // automatic reject would quietly bin a frame you would have kept while hiding the evidence
    // that it got it wrong. Flagging for review keeps a false positive visible and one keystroke
    // from being corrected — which is also the only way the thresholds ever get better.

    /// Acuity per photo, filled in by the scan. Absent = not yet measured, which is distinct from
    /// measured-and-fine and is why this is not a Set.
    @Published var focus: [URL: FocusMeasure.Reading] = [:]
    @Published var focusScanProgress: Double?      // nil = not scanning

    /// What a scan concluded about each frame, beyond sharpness.
    ///
    /// Read in the SAME pass as focus rather than a second one. Both want the same 1200 px proxy,
    /// and on a RAW folder that proxy costs about 900 ms of decode per frame — 6.6 minutes across
    /// a 437-frame shoot. Scanning twice would pay that twice for a measurement that adds 2 ms.
    ///
    /// Deliberately NOT wired to any filter that hides frames. The concerns are advisory: the rule
    /// from the culling work is that photos are flagged for review, never auto-rejected, "so you
    /// can discover false positives" — and the pass that produces these deleted four of its own
    /// seven proposed verdicts after they fired on perfectly good photographs.
    ///
    /// This was declared, published, and never written to: the scan called a focus-only helper, so
    /// every verdict Core had been taught to produce was discarded before it reached the window.
    /// Nothing read the dictionary either, so it cost nothing and did nothing — the same shape as
    /// the dead `onFlag` the audit found, and it is why the near-duplicate grouping had no
    /// fingerprints to group on.
    @Published var triage: [URL: PhotoTriage.Verdict] = [:]

    var softCount: Int { folderPhotos.filter { focus[$0]?.isSoft == true }.count }

    /// What else the scan noticed about a frame, beyond sharpness: a frame so dark or so bright that
    /// most of it carries no detail. Focus concerns are excluded because the soft badge and the Focus
    /// filter already say that, and saying it twice in two glyphs on one thumbnail is noise.
    ///
    /// These fire on almost nothing by design — every threshold sits past the most extreme frame in
    /// 836 of the owner's real photographs — so a badge here means something unusual, which is
    /// exactly what makes it worth drawing.
    func exposureConcerns(for url: URL) -> [PhotoTriage.Concern] {
        (triage[url]?.concerns ?? []).filter { $0 != .softFocus && $0 != .outOfFocus }
    }

    /// The scan's findings for one frame, in words, for the strip's tooltip. The measurement travels
    /// with the flag on purpose: an automatic judgement you cannot see the number behind is one you
    /// can neither trust nor argue with.
    func scanNote(for url: URL) -> String? {
        guard let verdict = triage[url] else { return nil }
        var parts: [String] = []
        if verdict.focus.measurable {
            parts.append(String(format: "acuity %.1f", verdict.focus.acuity))
        }
        parts.append(contentsOf: verdict.concerns.map(\.message))
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The sharpest frame of each run the strip is currently showing, where the run has more than one
    /// frame in it.
    ///
    /// This is the whole point of paying for the scan. Culling a burst is one question — "which of
    /// these six is the one" — and sharpness is the part of that question a machine can answer, on a
    /// measurement already taken. It stays a MARKER: nothing is flagged, hidden or rejected on the
    /// strength of it, because the sharpest frame of a run is not always the keeper (the one where
    /// the subject's eyes are open usually beats it) and a pass that decided for you would be wrong
    /// in exactly the cases you care most about.
    ///
    /// Only under Burst and Similar. Under Day or Place a "sharpest" is the sharpest frame of a whole
    /// afternoon, which answers no question anyone was asking.
    var sharpestInRun: Set<URL> {
        guard stripGrouping == .burst || stripGrouping == .similar,
              let groups = stripGroups else { return [] }
        var picks: Set<URL> = []
        for group in groups where group.urls.count > 1 {
            let measured = group.urls.compactMap { url -> (URL, Double)? in
                guard let reading = focus[url], reading.measurable else { return nil }
                return (url, reading.acuity)
            }
            // Two frames of one pose can measure identically to the last decimal; `max(by:)` would
            // pick whichever the array order happens to put last. Ties go to the earlier frame, so
            // the mark does not move about between renders.
            guard let best = measured.max(by: { $0.1 < $1.1 }), measured.count > 1 else { continue }
            picks.insert(measured.first(where: { $0.1 == best.1 })?.0 ?? best.0)
        }
        return picks
    }

    /// The scan, held so leaving the folder can stop it. See `scanFocus` for why that matters.
    private var scanTask: Task<Void, Never>?

    /// Measure every frame in the folder, newest results published as they arrive so the strip
    /// fills in progressively rather than freezing until the end.
    func scanFocus() {
        guard focusScanProgress == nil else { return }      // already running
        let photos = folderPhotos
        guard !photos.isEmpty else { return }
        focusScanProgress = 0

        // Only the ones not already read — the scan used to walk every frame in the folder and skip
        // them one at a time, which made the progress bar lie about how much work was left.
        //
        // Keyed on the VERDICT, not on `focus`. Opening a photograph measures its focus as part of
        // the edit path, and that path produces no fingerprint — so skipping frames that merely have
        // a focus reading would leave whichever frames you had opened with no signature, and the
        // near-duplicate grouping silently missing exactly the pictures you had been working on.
        let pending = photos.filter { triage[$0] == nil }
        guard !pending.isEmpty else { focusScanProgress = nil; return }

        // HELD AND CANCELLABLE, because this pass is minutes long and it was neither.
        //
        // The measured cost is ~1170 ms per RAW frame; across a 437-frame folder that is 8½ minutes
        // of decoding. Nothing stored the task and nothing cancelled it, so leaving for another
        // folder left all of it running — four cores decoding frames nobody is looking at, each
        // in-flight task holding a 1200 px proxy. Worse, `focusScanProgress` is the re-entry guard,
        // so the new folder's scan (and the Similar lens, which asks for one) silently did nothing
        // until the abandoned one drained.
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            var done = 0
            // SEVERAL AT ONCE. This was one photo at a time, and on a folder of large frames that
            // is minutes: the cost is dominated by decoding, and decoding one file leaves nine
            // cores idle.
            //
            // Safe to parallelise where the measurement passes on a single photo were not:
            // `FocusMeasure` is a Laplacian and a gradient, with no Vision anywhere in it. Vision
            // is the framework that crashes when two of its requests race, and none of this
            // touches it.
            //
            // Bounded rather than unbounded, but the bound is looser than it was, because the cost
            // it was protecting against has largely gone. It used to be 4 because each task could
            // hold a fully decoded 60 MP frame; `PerceptionProxy.measurementProxy` now reads a RAW
            // file's embedded preview, so a task in flight holds a few megabytes rather than a few
            // hundred. What remains is the FALLBACK — a body that embeds no usable preview still
            // pays for a real decode — so this stays bounded rather than becoming `cores`.
            let limit = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
            await withTaskGroup(of: (URL, PhotoTriage.Verdict?).self) { group in
                var next = 0
                func start() {
                    guard next < pending.count else { return }
                    let url = pending[next]; next += 1
                    // .userInitiated: somebody pressed a button and is watching a progress bar.
                    group.addTask(priority: .userInitiated) { (url, PhotoTriage.read(url: url)) }
                }
                for _ in 0..<min(limit, pending.count) { start() }
                for await (url, verdict) in group {
                    guard let self else { return }
                    // Cancellation is checked where the work is HANDED OUT as well as where it
                    // lands: `group.cancelAll()` stops the queue from issuing more decodes, which is
                    // the expensive half. The already-measured frames are kept — a verdict is a
                    // verdict whether or not you stayed to watch it arrive.
                    if Task.isCancelled { group.cancelAll(); break }
                    if let verdict {
                        self.triage[url] = verdict
                        // The focus reading rides INSIDE the verdict — same 1200 px proxy, same
                        // `FocusMeasure.read`. Published separately as well because `softCount`, the
                        // Focus filter and the strip's soft badge all key off this dictionary, and a
                        // measurement moving house is not a reason to make three working things
                        // reach through a verdict for it.
                        self.focus[url] = verdict.focus
                    }
                    done += 1
                    self.focusScanProgress = Double(done) / Double(pending.count)
                    start()          // keep `limit` in flight until the queue is empty
                }
            }
            self?.focusScanProgress = nil
        }
    }

    // `readFocus` lived here and is gone: `PhotoTriage.read(url:)` does the same proxy-first decode
    // (ImageIO's decode-to-size where there is one, a real decode for RAW, materialised once) and
    // returns the focus reading inside a verdict. Two copies of the scan's decode path is how the
    // 1200 px proxy the soft/unusable thresholds were calibrated against quietly becomes two
    // different proxies.

    // MARK: What leaves the app

    /// Whether an export takes the photograph's position and the camera body's serial out with it.
    ///
    /// OFF by default, which is the owner's call and matches every other editor: metadata travelling
    /// with a photograph is the convention, and a photographer exporting for a client usually wants
    /// the camera, lens, date and exposure to survive. What was missing was any way to say no — the
    /// GPS fix and `BodySerialNumber` were re-encoded into every export and every batch frame, with
    /// nothing anywhere saying so.
    ///
    /// Persisted, because it is a property of how you work rather than of one export. A photographer
    /// who strips location does it every time, and asking them to remember a checkbox per file is how
    /// the one that matters gets missed.
    @Published var stripLocationOnExport = UserDefaults.standard.bool(forKey: AppState.stripLocationKey) {
        didSet { UserDefaults.standard.set(stripLocationOnExport, forKey: AppState.stripLocationKey) }
    }
    static let stripLocationKey = "export.stripLocation"

    // The rest of the export configuration. Persisted for the same reason: a photographer who
    // exports 2048 px sRGB JPEGs for a gallery does it every time, and re-choosing it per file is
    // how the one that matters gets exported at the wrong size.
    @Published var exportFormatId = UserDefaults.standard.string(forKey: "export.format") ?? "jpeg" {
        didSet { UserDefaults.standard.set(exportFormatId, forKey: "export.format") }
    }
    @Published var exportQuality = UserDefaults.standard.object(forKey: "export.quality") as? Double ?? 0.97 {
        didSet { UserDefaults.standard.set(exportQuality, forKey: "export.quality") }
    }
    /// 0 means full resolution. Stored as a plain number so the setting survives a schema change.
    @Published var exportLongEdge = UserDefaults.standard.object(forKey: "export.longEdge") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(exportLongEdge, forKey: "export.longEdge") }
    }
    @Published var exportColorSpaceId = UserDefaults.standard.string(forKey: "export.colorSpace") ?? "sRGB" {
        didSet { UserDefaults.standard.set(exportColorSpaceId, forKey: "export.colorSpace") }
    }
    @Published var exportNamingId = UserDefaults.standard.string(forKey: "export.naming") ?? "descriptive" {
        didSet { UserDefaults.standard.set(exportNamingId, forKey: "export.naming") }
    }

    var exportFormat: ImageWriter.Format {
        switch exportFormatId {
        case "png":    return .png
        case "tiff16": return .tiff16
        case "heic":   return .heic(quality: exportQuality)
        default:       return .jpeg(quality: exportQuality)
        }
    }
    var exportSize: ImageWriter.Size {
        exportLongEdge > 0 ? .longEdge(exportLongEdge) : .fullResolution
    }
    var exportColorSpace: ImageWriter.ColorSpace {
        ImageWriter.ColorSpace(rawValue: exportColorSpaceId) ?? .sRGB
    }
    var exportNaming: ExportNaming.Scheme {
        ExportNaming.Scheme(rawValue: exportNamingId) ?? .descriptive
    }

    var exportMetadata: ImageWriter.MetadataPolicy {
        stripLocationOnExport ? .withoutLocation : .asShot
    }

    /// Whether opening ONE photograph also lists the rest of its folder in the strip.
    ///
    /// On by default, because a shoot is the unit of work here — culling, batch apply and the arrow
    /// keys all operate on the strip, and an editor that opens exactly one file makes all three
    /// useless. But it was never stated anywhere, so opening a single frame and watching a folder
    /// appear read as the app doing something it had not been asked to do. Reported exactly that way.
    ///
    /// Now it is a choice, surfaced in the Open panel and remembered. Applies to drops as well as the
    /// panel: it is a statement about how someone works, not about one gesture.
    ///
    /// Note this only governs LISTING. Nothing in the folder is read — no EXIF, no sidecars, no
    /// thumbnails — until the strip is unfolded; see `loadFolderDetailIfVisible`.
    @Published var includeFolderOnOpen = UserDefaults.standard.object(forKey: AppState.includeFolderKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeFolderOnOpen, forKey: AppState.includeFolderKey) }
    }
    static let includeFolderKey = "open.includeFolder"

    /// How many frames in this shoot carry an edit — drives the export button's label, so it says
    /// what it will actually do rather than making someone guess.
    var editedCount: Int { folderPhotos.filter { editedURLs.contains($0) }.count }

    /// Not persisted, on purpose: which photos to export is a per-shoot decision, and a remembered
    /// "kept only" from last week is how someone exports three photos and believes they exported
    /// thirty.
    @Published var exportKeepersOnly = false

    /// Edited AND flagged Keep — what "kept only" export would write. Named so the checkbox can
    /// show its count, because a scope control that doesn't say how many is a guessing game.
    var editedKeeperCount: Int {
        folderPhotos.filter { editedURLs.contains($0) && flags[$0] == .keep }.count
    }

    /// The photos an "Export edited" run will write, in filmstrip order. Pure and separated from
    /// the export loop so the rule is testable without rendering anything.
    func exportTargets(keepersOnly: Bool) -> [URL] {
        folderPhotos.filter { url in
            editedURLs.contains(url) && (!keepersOnly || flags[url] == .keep)
        }
    }

    /// Same idea for Batch apply. Not persisted, same reason as `exportKeepersOnly`.
    @Published var batchKeepersOnly = false

    /// The photos a batch run over the open shoot will adapt, in filmstrip order. An edit is not
    /// required — batch creates edits — so the only narrowing is the Keep flag when asked.
    func batchTargets(keepersOnly: Bool) -> [URL] {
        folderPhotos.filter { !keepersOnly || flags[$0] == .keep }
    }

    var keeperCount: Int { folderPhotos.filter { flags[$0] == .keep }.count }
    var rejectCount: Int { folderPhotos.filter { flags[$0] == .reject }.count }

    func setFlag(_ flag: PhotoFlag, for url: URL) {
        FlagStore.toggle(flag, for: url)
        flags[url] = FlagStore.flag(for: url)
    }

    /// Flag the open photo and step to the next one — the whole point of a cull pass is that one
    /// keystroke both decides and advances.
    func flagCurrentAndAdvance(_ flag: PhotoFlag) {
        guard let url = imageURL else { return }
        setFlag(flag, for: url)
        Task { await advance(by: 1) }
    }

    /// Move through the folder in the order the strip shows.
    func advance(by step: Int) async {
        let list = visiblePhotos
        guard let url = imageURL, let index = list.firstIndex(of: url), list.count > 1 else { return }
        let next = list[(index + step + list.count) % list.count]
        await openPhoto(next)
    }
    /// Frames dismissed from the strip this session. Held separately because opening any photo
    /// re-scans the folder — without this, a dismissed frame simply reappeared.
    private var dismissedURLs: Set<URL> = []
    /// Full editing state per photo, so switching away and back is instant and lossless — no
    /// re-running the model. Bounded, because each entry pins decoded images.
    private var sessions: [URL: PhotoSession] = [:]
    private var sessionOrder: [URL] = []
    private static let maxSessions = 8
    @Published private var thumbnails: [URL: NSImage] = [:]
    /// URLs whose thumbnail is being fetched, so a redrawn strip doesn't queue the same work twice.
    private var thumbnailsInFlight: Set<URL> = []

    /// A filmstrip thumbnail, **never decoded on the calling thread**.
    ///
    /// This used to decode inline. Called from `FilmstripView.cell` during view-body evaluation,
    /// that put a full image decode on the main thread once per visible cell — and for a folder of
    /// 60 MP RAWs it meant dozens of full RAW decodes before SwiftUI could finish a single layout
    /// pass. The window could not draw at all, which read as "the app won't open my photos".
    ///
    /// Now: return whatever is cached, start a background fetch for anything missing, and publish
    /// it when it arrives. A cell with no thumbnail yet simply shows its placeholder.
    func thumbnail(for url: URL) -> NSImage? {
        if let hit = thumbnails[url] { return hit }
        guard !thumbnailsInFlight.contains(url) else { return nil }
        thumbnailsInFlight.insert(url)
        Task { [weak self] in
            // Returns a CGImage rather than an NSImage: NSImage's Sendable conformance exists on
            // the macOS 27 SDK and is unavailable on the one CI builds against, so handing one out
            // of a detached task compiles here and fails there. CGImage is Sendable on both, and
            // the NSImage is wanted on the main actor anyway.
            let cg = await Task.detached(priority: .utility) {
                PhotoBrowser.thumbnailCG(for: url)
            }.value
            let image = cg.map { NSImage(cgImage: $0, size: .zero) }
            guard let self else { return }
            self.thumbnailsInFlight.remove(url)
            if let image { self.thumbnails[url] = image }
        }
        return nil
    }

    /// How many masks are actually doing something, for the folded section's badge. A collapsed
    /// section must still say whether there is anything inside it, or folding it away hides work.
    var maskCountLabel: String? {
        let active = baseMaskIds.filter { maskEnabled[$0] ?? true }.count + userMasks.count
        return active > 0 ? "\(active)" : nil
    }

    /// The filename Kelvin suggests for an export — built from what it understood about the
    /// photo, so a folder of exports is searchable instead of a wall of `kelvin-edit`.
    func suggestedExportName(ext: String = "jpg") -> String {
        guard let url = imageURL else { return "\(Branding.exportStem)." + ext }
        let look = activeLookId.flatMap { LookPreset.named($0)?.name }
            ?? candidates.first { $0.id == selectedCandidateId }?.label
        return ExportNaming.filename(for: url, perception: perception, look: look, ext: ext,
                                     scheme: exportNaming)
    }

    /// "12 Mar, 14:03" from an ISO timestamp — a restored edit should say *when*, not show a
    /// machine string.
    static func friendlyDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "an earlier session" }
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }

    // MARK: Reusing a read across near-duplicates
    //
    // A burst of twenty frames of one pose is one scene: same subject, same light, same problems.
    // Reading it twenty times costs twenty generations — measured at ~6.5 s each, and measured to be
    // dominated by writing the answer rather than by looking at the photograph, so a smaller image
    // would not have helped. Reading it once and reusing the answer costs one.
    //
    // THIS DOES NOT SHARE ANY NUMBERS. The model only ever returns categories — scene, subject,
    // lighting, what is technically wrong — and every actual parameter is computed per frame from
    // that frame's own histogram and EXIF. Sharing "backlit portrait, subject underexposed" across a
    // burst is sharing a true statement about all of them; the exposure each one gets is still its
    // own. Non-negotiable #1 is untouched.
    //
    // The fingerprint is the same 64-bit difference hash the Similar grouping uses, at the same
    // threshold, so "close enough to reuse" means exactly what "close enough to group" means — one
    // definition of near-duplicate in the app rather than two that can disagree.

    private var perceptionBySignature: [(signature: PhotoTriage.Signature, perception: Perception)] = []
    private static let maxRememberedReads = 32

    /// The signature for `url`, from the scan if it has run, measured now if not. Cheap either way
    /// now that a RAW's embedded preview is enough to measure.
    private func signature(for url: URL) -> PhotoTriage.Signature? {
        if let known = triage[url]?.signature { return known }
        guard let proxy = PerceptionProxy.measurementProxy(url, maxEdge: PhotoTriage.proxyEdge)
        else { return nil }
        return PhotoTriage.signature(of: proxy)
    }

    private func reusablePerception(for url: URL) -> Perception? {
        guard let mine = signature(for: url), mine.isMeasurable else { return nil }
        // An unmeasurable fingerprint means "no signal", not "unique" — never reuse against one.
        return perceptionBySignature.first {
            $0.signature.isMeasurable
                && $0.signature.distance(to: mine) <= PhotoTriage.nearDuplicateDistance
        }?.perception
    }

    private func rememberPerception(_ perception: Perception, for url: URL) {
        guard let signature = signature(for: url), signature.isMeasurable else { return }
        perceptionBySignature.append((signature, perception))
        if perceptionBySignature.count > Self.maxRememberedReads {
            perceptionBySignature.removeFirst()
        }
    }

    /// Load the perception model in the background at launch, so the first photograph does not pay
    /// for it. See `MLXPerceptionProvider.preload`.
    func warmPerception() async {
        await perceptionProvider.preload()
    }

    /// What the model said it saw, for the panel — the categorical read on one line, and its own
    /// sentence beneath.
    ///
    /// Deliberately not a confidence number. A model's stated confidence is the least reliable thing
    /// it produces, and putting 0.82 next to a description invites it to be read as a measurement
    /// when everything else on this screen genuinely is one.
    var sceneSummary: (headline: String, note: String?)? {
        guard let p = perception else { return nil }
        var parts: [String] = [p.scene.rawValue]
        if let light = ExportNaming.descriptor(for: p.lighting.condition) {
            parts.append(light.replacingOccurrences(of: "-", with: " "))
        }
        if p.subject.present, p.subject.type != .none {
            parts.append(p.subject.type.rawValue)
        }
        if !p.problems.isEmpty {
            parts.append(p.problems.map(\.rawValue).joined(separator: ", "))
        }
        let note = p.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (parts.joined(separator: " · "), (note?.isEmpty == false) ? note : nil)
    }

    /// Whether any photograph has been read since launch. Only ever used to tell the truth about
    /// how long the first one takes.
    private var hasReadAPhoto = false

    /// The current edit, in the form that goes to disk.
    private func currentSavedEdit() -> SavedEdit {
        SavedEdit(styleId: selectedCandidateId, global: edit, userMasks: userMasks,
                  maskEnabled: maskEnabled, maskStrength: maskStrength,
                  straighten: straighten, hsl: hsl, blackAndWhite: activeRecipe?.blackAndWhite,
                  removeDust: removeDust,
                  // The composed recipe, so this edit can be re-rendered without re-perceiving the
                  // photograph. See SavedEdit.recipe.
                  recipe: activeRecipe,
                  savedAt: ISO8601DateFormatter().string(from: Date()), contentHint: imageId)
    }

    /// Write the edit for `url` if it differs from what Kelvin generated, or clear it if the user
    /// has reset back to the candidate — otherwise a stale file would keep resurrecting an edit
    /// they undid.
    private func persistEdit(for url: URL) {
        if isTouched { EditStore.save(currentSavedEdit(), for: url) }
        else { EditStore.remove(for: url) }
    }

    /// Has this photograph been edited at all — the ONE definition, used everywhere.
    ///
    /// This test existed in three places, written out longhand each time, and every copy omitted
    /// the same things: the mask panel's dictionaries and the active look. Two consequences, and
    /// the second is the bad one.
    ///
    /// Turn off the sky mask, or change its strength, or adjust it, and the photo did not count as
    /// edited — so no dot in the strip, and nothing saved. Then, because `persistEdit` takes the
    /// other branch when untouched, reverting the globals while KEEPING a mask change did not
    /// merely fail to save: it called `EditStore.remove` and deleted the sidecar that was already
    /// on disk.
    ///
    /// One property, so the next thing added to the edit surface has one place to be declared
    /// rather than three places to be forgotten.
    var isTouched: Bool {
        edit != editBaseline
            || !userMasks.isEmpty
            || straighten != 0
            || !hsl.isEmpty
            || removeDust
            || activeLookId != nil
            || !maskAdjustments.isEmpty
            || !maskFeather.isEmpty
            || !maskTightness.isEmpty
            || !maskInvert.isEmpty
            // Explicitly-set enable/strength: a mask switched OFF is an edit, and an untouched
            // photo has no entries here at all.
            || !maskEnabled.isEmpty
            || !maskStrength.isEmpty
    }

    /// Restore a saved edit onto the freshly-generated candidates.
    private func apply(_ saved: SavedEdit) {
        if let styleId = saved.styleId, candidates.contains(where: { $0.id == styleId }) {
            selectCandidate(id: styleId)      // sets the baseline for this style first
        }
        edit = saved.global
        userMasks = saved.userMasks
        rekeyInstanceMasks()
        maskEnabled = saved.maskEnabled
        maskStrength = saved.maskStrength
        straighten = saved.straighten
        hsl = saved.hsl
        removeDust = saved.removeDust
        brushCache = [:]
        updateActiveRecipe()
        resetHistory()
    }

    /// The photo whose decoded images are actually in memory right now.
    ///
    /// NOT the same thing as `imageURL`, and the difference is load-bearing. `imageURL` is what the
    /// app is *showing you*, and `loadPhoto` sets it the moment you pick a photo — seconds before
    /// the decode finishes. `loadedURL` is what is actually in `fullResCI`/`proxyCI`/`original`, and
    /// it only moves when a decode lands. Everything that files the current state away has to key
    /// on this one: keyed on `imageURL`, opening a third photo while the second was still decoding
    /// filed the FIRST photo's images, edit and sidecar under the SECOND photo's URL, and reopening
    /// that frame from the strip then showed someone else's picture.
    private var loadedURL: URL?

    /// Capture the current photo's state before leaving it.
    private func stashCurrentSession() {
        guard let url = loadedURL, let full = fullResCI, let proxy = proxyCI else { return }
        let session = PhotoSession(
            url: url, imageId: imageId, fullResCI: full, proxyCI: proxy,
            originalPreviewImage: original.flatMap { $0.url == url ? $0.image : nil },
            perception: perception,
            candidates: candidates, proxyMaskBitmaps: proxyMaskBitmaps,
            subjectInstances: subjectInstances,
            subjectLuma: subjectLuma, skyLuma: skyLuma,
            healSpots: healSpots, detectedSpotCount: detectedSpotCount,
            capture: capture, activeLookId: activeLookId,
            maskAdjustments: maskAdjustments, maskFeather: maskFeather,
            maskTightness: maskTightness, maskInvert: maskInvert,
            selectedCandidateId: selectedCandidateId, edit: edit, editBaseline: editBaseline,
            baseMasks: baseMasks, maskEnabled: maskEnabled, maskStrength: maskStrength,
            userMasks: userMasks, straighten: straighten, hsl: hsl, removeDust: removeDust)
        sessions[url] = session
        sessionOrder.removeAll { $0 == url }
        sessionOrder.append(url)
        if session.isEdited { editedURLs.insert(url) } else { editedURLs.remove(url) }
        persistEdit(for: url)
        while sessionOrder.count > Self.maxSessions, let oldest = sessionOrder.first {
            sessions.removeValue(forKey: oldest); sessionOrder.removeFirst()
        }
    }

    /// Drop everything derived from the photograph being left behind.
    ///
    /// Not the same as `closeCurrentPhoto`, which also clears the URL and returns to the empty
    /// state — a switch is arriving somewhere rather than leaving. `loadedURL` deliberately stays
    /// put until the new photo actually loads, so a failed load can still be retried.
    private func clearPerPhotoState() {
        activeRecipe = nil; active = nil; original = nil; lastRenderedCI = nil
        candidates = []; selectedCandidateId = nil; perception = nil
        activeCraftIssues = []; lastCraftReading = nil; exhaustedFixes = []
        userMasks = []; paintingMaskId = nil; selectedMask = nil
        subjectInstances = []; highlightedInstanceId = nil
        proxyMaskBitmaps = [:]; brushCache = [:]
        healSpots = []; detectedSpotCount = 0; removeDust = false
        baseMasks = []; maskEnabled = [:]; maskStrength = [:]
        maskAdjustments = [:]; maskFeather = [:]; maskTightness = [:]; maskInvert = [:]
        hsl = [:]; straighten = 0; activeLookId = nil
        showingOriginal = false; showingRepairSpots = false
    }

    /// Put a previously-edited photo back exactly as it was.
    private func restore(_ s: PhotoSession) {
        imageURL = s.url; imageId = s.imageId
        loadedURL = s.url
        fullResCI = s.fullResCI; proxyCI = s.proxyCI
        original = s.originalPreviewImage.map { TaggedPreview(url: s.url, image: $0) }
        perception = s.perception; candidates = s.candidates
        proxyMaskBitmaps = s.proxyMaskBitmaps
        subjectInstances = s.subjectInstances
        highlightedInstanceId = nil
        subjectLuma = s.subjectLuma; skyLuma = s.skyLuma
        healSpots = s.healSpots; detectedSpotCount = s.detectedSpotCount
        // Restored, not left standing. Every one of these was previously carried over from
        // whichever photo happened to be open before.
        capture = s.capture
        activeLookId = s.activeLookId
        maskAdjustments = s.maskAdjustments; maskFeather = s.maskFeather
        maskTightness = s.maskTightness; maskInvert = s.maskInvert
        selectedCandidateId = s.selectedCandidateId
        edit = s.edit; editBaseline = s.editBaseline
        baseMasks = s.baseMasks; maskEnabled = s.maskEnabled; maskStrength = s.maskStrength
        userMasks = s.userMasks; straighten = s.straighten; hsl = s.hsl; removeDust = s.removeDust
        brushCache = [:]; selectedMask = nil; paintingMaskId = nil
        zoom = 1; pan = .zero; showingOriginal = false
        updateActiveRecipe()
        resetHistory()
        statusMessage = "\(s.url.lastPathComponent) · picking up where you left off"
        isProcessing = false
    }

    /// Close the current photo and go back to the empty state. The edit is saved first — closing
    /// is not discarding — and the session cache is kept, so reopening from the strip is instant.
    func closeCurrentPhoto() {
        stashCurrentSession()
        imageURL = nil; loadedURL = nil
        // Every early return in `loadPhoto` guards on `imageURL == url` and bails without reaching
        // the `isProcessing = false` at the end — so closing a photo mid-decode left the empty
        // state showing a spinner that never stopped.
        isProcessing = false
        fullResCI = nil; proxyCI = nil
        candidates = []; selectedCandidateId = nil
        activeRecipe = nil; active = nil; original = nil
        lastRenderedCI = nil; activeCraftIssues = []; lastCraftReading = nil; exhaustedFixes = []
        userMasks = []; paintingMaskId = nil; selectedMask = nil
        subjectInstances = []; highlightedInstanceId = nil
        brushCache = [:]
        proxyMaskBitmaps = [:]; healSpots = []; detectedSpotCount = 0
        zoom = 1; pan = .zero; showingOriginal = false
        statusMessage = "Drop a photo or a folder to read the light."
    }

    /// Remove a photo from the strip for this session, and forget any edit it had. The file itself
    /// is never touched — this is about clearing the working set, not deleting someone's work.
    func dismiss(_ url: URL) {
        dismissedURLs.insert(url)      // survives the folder re-scan that happens on every open
        // THE SIDECAR STAYS. This called `EditStore.remove(for:)`, while the tooltip said "Remove
        // from this session" and this method's own doc comment said "The file itself is never
        // touched — this is about clearing the working set, not deleting someone's work." It was
        // deleting the work: hide a frame you had already edited and the edit was gone for good,
        // with nothing named delete anywhere near the click.
        //
        // Dismissing is about what is IN FRONT OF YOU. Un-dismiss the frame, or open it directly,
        // and the edit is still there — which is what "session" means.
        editedURLs.remove(url)
        sessions.removeValue(forKey: url)
        sessionOrder.removeAll { $0 == url }
        folderPhotos.removeAll { $0 == url }
        if url == imageURL {
            // Forget what is in memory BEFORE moving on, or the stash on the way to the next photo
            // writes this frame's session and sidecar straight back after they were just removed.
            loadedURL = nil
            original = nil; active = nil
            if let next = folderPhotos.first {
                Task { await openPhoto(next) }
            } else {
                closeCurrentPhoto()
            }
        }
    }

    /// Switch photos from the filmstrip: stash what you were doing, then restore or load fresh.
    func openPhoto(_ url: URL) async {
        // `|| loadedURL != url` so a photo whose load failed can be retried. Without it, a transient
        // failure left `imageURL` set and this guard then refused every attempt at the same file.
        // It used to read `proxyCI == nil`, which stopped being true after the FIRST photo loaded:
        // a failed decode leaves the previous photo's proxy in place, so the retry was refused.
        guard url != imageURL || loadedURL != url else { return }
        stashCurrentSession()
        if let cached = sessions[url] {
            restore(cached)
            sessionOrder.removeAll { $0 == url }; sessionOrder.append(url)
            return
        }
        await loadPhoto(from: url)
    }

    /// The single way a photo gets into Kelvin, whatever the source — the Open panel, ⌘O, a drop,
    /// or the filmstrip. Everything funnels here so opening behaves identically in every case:
    /// a folder opens its first frame, an already-open photo's edit is stashed rather than lost,
    /// and anything unreadable says so instead of failing silently.
    func open(_ url: URL) async {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            statusMessage = "That file isn't there any more."
            return
        }
        if isDirectory.boolValue {
            // Dragging a shoot folder in is a natural thing to try; open the first frame and let
            // the filmstrip carry the rest.
            guard let first = (try? BatchApply.imageFiles(in: url))
                .map({ PhotoOrder.sorted($0, by: .filename) })?.first else {
                statusMessage = "No photos \(Branding.displayName) can read in \(url.lastPathComponent)."
                return
            }
            // Opening a folder is an explicit request for the shoot, so the strip starts open.
            // (First frame by filename, not capture time — picking by time would mean reading
            // every EXIF header before the first photo could appear. Once the dates land the strip
            // re-sorts around whichever frame is open, which costs nothing.)
            FilmstripFold.applyOpenIntent(openedFolder: true)
            await openPhoto(first)
            return
        }
        guard BatchApply.imageExtensions.contains(url.pathExtension.lowercased()) else {
            statusMessage = "\(Branding.displayName) can't read .\(url.pathExtension) files."
            return
        }
        // One file was asked for, so one file is what takes over the screen. The rest of the folder
        // is still listed and one click away — it just does not arrive uninvited.
        FilmstripFold.applyOpenIntent(openedFolder: false)
        await openPhoto(url)
    }

    /// Resolve a drag-and-drop payload to a file and open it. Takes the first item that resolves,
    /// so dragging a selection of several frames opens one rather than doing nothing.
    func openDropped(_ providers: [NSItemProvider]) async {
        for provider in providers {
            guard provider.canLoadObject(ofClass: URL.self) else { continue }
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    continuation.resume(returning: url)
                }
            }
            if let url {
                await open(url)
                return
            }
        }
        statusMessage = "Couldn't read what was dropped."
    }

    /// The Open panel, behind both File ▸ Open… (⌘O) and the empty state's button.
    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = false
        // Choosing a folder opens the shoot — the same thing dropping one does.
        panel.canChooseDirectories = true
        panel.prompt = "Open"
        // Reported as confusing, and fairly: the button said "choose a photo" while the panel
        // quietly accepted folders and opening one frame listed its neighbours in the strip. The
        // behaviour is deliberate — a shoot is the unit of work — but nothing said so, which made
        // it read as the app doing something it had not been asked to do.
        panel.message = "Open one photo, or a folder to work through a whole shoot."
        // The checkbox that makes the folder listing a decision rather than a surprise.
        // AppKit, not SwiftUI — see PanelAccessories. A hosting view inside a modal panel renders
        // once and then stops updating, so the checkbox looked stuck while the preference behind it
        // flipped on every click.
        panel.accessoryView = PanelAccessories.openOptions(self)
        panel.isAccessoryViewDisclosed = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await open(url) }
        }
    }

    /// "· 9 more in this folder", or nothing when there are none and nothing when the folder was not
    /// listed at all.
    ///
    /// The other half of the reported confusion: a folder appearing in the strip was a surprise
    /// because nothing ever said it had happened. Saying it costs one clause and removes the
    /// surprise entirely — and when the count is zero or the setting is off, it says nothing, so it
    /// never becomes noise.
    var statusNote: String {
        let others = folderPhotos.count - 1
        guard includeFolderOnOpen, others > 0 else { return "" }
        return " · \(others) more \(others == 1 ? "photo" : "photos") in this folder"
    }

    func loadPhoto(from url: URL) async {
        isProcessing = true
        statusMessage = "Decoding…"
        // Keep whatever you were working on before this photo takes over.
        if loadedURL != nil, loadedURL != url { stashCurrentSession() }
        // AND THEN LET GO OF IT. Reported as "it tries to apply settings from the old pic, and the
        // preview stays on the previous one".
        //
        // Everything derived from a photograph — the recipe, the candidates, the rendered preview,
        // the craft flags, the masks measured on its proxy — used to survive until the NEW
        // photograph's equivalents replaced it, several seconds later. In between, the sliders held
        // the previous frame's values, the footer showed its colour temperature, and the canvas
        // showed its pixels, all under the new photo's name. Anything the user touched in that
        // window applied the old frame's numbers to the new frame.
        //
        // Stashed first, so nothing is lost — this only clears what has just been saved.
        if loadedURL != url { clearPerPhotoState() }
        imageURL = url
        // `includeFolderOnOpen` off means exactly this photograph and nothing else. The strip
        // disappears (it only draws above one photo), which also takes the arrow keys, culling and
        // Batch apply with it — that is the deal, and it is the user's to make.
        let siblings = includeFolderOnOpen
            ? PhotoBrowser.siblings(of: url).filter { !dismissedURLs.contains($0) || $0 == url }
            : [url]
        folderPhotos = PhotoOrder.sorted(siblings, by: photoSort,
                                         reversed: photoSortReversed, captureDates: captureIndex.dates)
        // THE REST OF THE FOLDER IS NOT READ UNTIL YOU ASK TO SEE IT.
        //
        // Reported as "it automatically opens every single photo in the folder", and that was
        // fair. Listing the directory is one cheap readdir, but everything after it was per-file
        // and ran unconditionally: an EXIF header read for every sibling, a sidecar existence
        // check for every sibling, a flag lookup for every sibling. Open one frame in a
        // 437-photo shoot and that is some thirteen hundred file operations nobody asked for,
        // for a strip that is folded shut.
        //
        // So the enrichment waits for the strip. Folded, opening a photo touches that photo.
        // Unfolded — which is what opening a FOLDER means — it runs immediately, because then
        // the shoot is the thing you asked for.
        loadFolderDetailIfVisible(for: url.deletingLastPathComponent(), photos: siblings)
        capture = CaptureInfoReader.read(url: url)
        userMasks = []; paintingMaskId = nil; selectedMask = nil   // hand-drawn masks are per-photo
        // The subjects belong to the photograph, so they go out with it. Left standing,
        // the list would offer the last photo's people while this one decoded.
        subjectInstances = []; highlightedInstanceId = nil
        zoom = 1; pan = .zero
        do {
            // DECODE OFF THE MAIN THREAD. Decoding a 60 MP RAW, materialising the proxy and
            // SHA-256-ing a 60 MB file together take many seconds; run on the main thread they
            // block every frame, so the window could not paint and the app looked dead on exactly
            // the files it exists to edit.
            let decoded = try await Task.detached(priority: .userInitiated) { () throws -> DecodedPhoto in
                let fullRes = try ImageDecoder.decode(url: url)

                let fileData = try Data(contentsOf: url)
                let hash = SHA256.hash(data: fileData)
                let id = "sha256:" + hash.compactMap { String(format: "%02x", $0) }.joined()

                // The model wants a small 768px proxy (non-negotiable #4); the EDIT proxy is a bit
                // larger so zooming shows more detail, but not so large that live rendering slows
                // down (1200px balances zoom detail against snappy sliders). Masks build from it,
                // so they stay aligned when zoomed.
                let perceptionProxy = PerceptionProxy.fromFile(url, matching: fullRes.extent)
                    ?? PerceptionProxy.downsample(fullRes)
                // MATERIALISE the edit proxy. `downsample` returns a *lazy* CIImage — a filter
                // graph over the full-resolution original — so every later measurement (mask
                // coverage, subject luma, dust scan, histogram) silently re-renders all 60
                // megapixels again. Rendering once here means everything downstream works on real
                // 1200 px pixels.
                //
                // Better still, for anything that is not RAW, is never to decode the full frame:
                // ImageIO can decode a JPEG straight to the size we want. Profiled on a 9504×6336
                // frame, the proxy went 2017 ms -> 120 ms, which was the single largest cost in
                // opening a photo. RAW keeps the real decode — see `PerceptionProxy.fromFile` for
                // why taking the camera's embedded preview would be wrong rather than merely
                // faster.
                let proxy = PerceptionProxy.fromFile(url, maxEdge: 1200, matching: fullRes.extent)
                    ?? Self.materialiseShared(PerceptionProxy.downsample(fullRes, maxEdge: 1200))
                return DecodedPhoto(fullRes: fullRes, perceptionProxy: perceptionProxy,
                                    proxy: proxy, originalPreview: Self.ciToNSImageShared(proxy),
                                    imageId: id)
            }.value
            guard imageURL == url else { return }

            // The decode has landed, so these images now belong to `url` — and `loadedURL` moves
            // with them, in the same breath, never before.
            self.fullResCI = decoded.fullRes
            self.imageId = decoded.imageId
            self.proxyCI = decoded.proxy
            self.loadedURL = url
            // The untouched original, for the before/after compare.
            self.original = decoded.originalPreview.map { TaggedPreview(url: url, image: $0) }
            let perceptionProxy = decoded.perceptionProxy
            let proxy = decoded.proxy

            // The FIRST read of a session is not like the others: 1.6 GB of weights load before
            // anything is looked at, which is fifteen seconds where a message identical to the
            // two-second reads that follow makes a working app look like a hung one. Say which one
            // this is. The flag flips once, so the long sentence never becomes wallpaper.
            statusMessage = hasReadAPhoto
                ? "Reading the scene…"
                : "Loading the perception model — about 15 seconds, once per launch…"
            // Real perception: Qwen2.5-VL reads the 768px proxy. First call loads the model (a few
            // seconds once cached); if it can't run, fall back to a conservative read so the
            // app still produces candidates from the measured statistics.
            let perceptionRead: Perception
            if let shared = reusablePerception(for: url) {
                // Same picture, same answer. See `reusablePerception`.
                perceptionRead = shared
                statusMessage = "Same scene as a frame already read — reusing it"
            } else {
                // ONE read in flight, ever. The provider is an actor, so reads queue — and a read
                // for a photograph the user has already arrowed away from would still burn its
                // seconds of generation ahead of the frame on screen. Cancelling the previous
                // task makes the abandoned read throw at the actor's door instead of running.
                perceiveTask?.cancel()
                let job = Task { [perceptionProvider] in
                    try await perceptionProvider.perceive(perceptionProxy)
                }
                perceiveTask = job
                do {
                    perceptionRead = try await job.value
                    rememberPerception(perceptionRead, for: url)
                } catch is CancellationError {
                    // A newer photo superseded this one mid-read. Its own load owns the window
                    // now — same contract as every `imageURL == url` guard in this function.
                    return
                } catch {
                    perceptionRead = Self.conservativeRead
                    statusMessage = "Couldn't run the perception model — using a conservative read"
                }
            }
            guard imageURL == url else { return }
            self.perception = perceptionRead

            hasReadAPhoto = true
            statusMessage = "Measuring…"
            // Also off the main thread: the statistics pass, Vision's person/sky segmentation and
            // the dust scan each render the proxy, and together they were the second-biggest block
            // on the main thread after decode.
            // ...and partly CONCURRENTLY. These passes take no input from each other and ran one
            // after another for 973–1058 ms, dominated by subject instances (631–746 ms) with
            // everything else waiting behind it for no reason.
            //
            // BUT THE VISION PASSES MUST STAY SERIAL WITH EACH OTHER. Running all four at once
            // crashed the app: EXC_BAD_ACCESS in `objc_release` inside Vision's own
            // `VNGenerateSemanticSegmentationCompoundRequest detectorTypeForSemanticSegmentationRequest`,
            // on Vision's request queue. `LocalMasks.measure` and `SubjectInstances.detect` both
            // perform person segmentation, and Vision over-releases something while resolving
            // which detector to use for two of those at once. It is a race, so it is intermittent
            // — reproduced at 2 crashes in 6 runs through the CLI's `bench-load --only par`, which
            // is exactly the sort of failure that reaches a user and not a test.
            //
            // Dust and focus touch no Vision at all (integral images and a Laplacian), so they
            // still overlap the Vision block for free. The win drops from ~28% to ~15%. A quarter
            // of a second is not worth a segfault.
            let measurement = try await Task.detached(priority: .userInitiated) { () throws -> MeasuredPhoto in
                async let dust = DustDetector.detect(in: proxy)
                async let focus = FocusMeasure.read(proxy)

                let sampleBytes = try ImageMetrics.sample(proxy)
                let stats = ImageStatistics.compute(from: sampleBytes)
                // Serial, deliberately. Do not turn these into `async let`.
                let masks = LocalMasks.measure(in: proxy)
                let instances = SubjectInstances.detect(in: proxy)

                return await MeasuredPhoto(stats: stats, masks: masks, dust: dust,
                                           focus: focus, instances: instances)
            }.value

            guard imageURL == url else { return }

            let stats = measurement.stats
            self.subjectInstances = measurement.instances
            // Each instance's bitmap goes in under its own id, so a mask naming that instance
            // renders it. `LocalMasks`' merged "subject"/"sky" stay alongside — the engine's
            // automatic local edits still use those.
            self.proxyMaskBitmaps = measurement.masks.bitmaps
                .merging(measurement.instances.reduce(into: [:]) { $0[$1.id] = $1.mask }) { a, _ in a }
            self.subjectLuma = measurement.masks.subjectLuma
            self.skyLuma = measurement.masks.skyLuma
            let proxyMasks = measurement.masks.bitmaps

            self.focus[url] = measurement.focus
            self.healSpots = measurement.dust
            self.detectedSpotCount = self.healSpots.count
            self.removeDust = false

            statusMessage = "Composing candidates…"
            // Clean candidates straight from the engine — no cross-image "profile". The way to
            // reuse an edit is to pick/tune one photo, then Batch apply that exact look.
            let recipes = RecipeEngine.candidates(perception: perceptionRead, statistics: stats,
                                                  subjectLuma: self.subjectLuma, skyLuma: self.skyLuma,
                                                  iso: ExifReader.iso(url: url))

            // Render every style, score each on the craft floors, then CURATE. The engine offers
            // eight looks and several will be wrong for any given photo — Dramatic silhouettes a
            // backlit sunset, Vivid pushes skin past plausible. Showing those beside the good ones
            // makes the photographer do the culling and implies Kelvin rates them equally. It
            // doesn't, and the evaluator already knows which is which.
            // Rendering eight candidates and scoring each — every score runs Vision face detection
            // and a full statistics pass — is far too much to do on the main thread: it froze the
            // window for the whole of it. Hand the batch to a background task and come back with
            // the results.
            let built = await Task.detached(priority: .userInitiated) { () -> CandidateBatch in
                var scored: [CandidateCurator.Scored] = []
                var previews: [String: NSImage] = [:]
                for recipe in recipes {
                    let renderedCI = Renderer.render(proxy, with: recipe, maskBitmaps: proxyMasks)
                    guard let cg = Self.sharedContext.createCGImage(renderedCI, from: renderedCI.extent),
                          let score = AestheticEvaluator.score(rendered: renderedCI) else { continue }
                    let key = recipe.id ?? UUID().uuidString
                    previews[key] = NSImage(cgImage: cg, size: .zero)
                    scored.append(.init(recipe: recipe, score: score))
                }
                return CandidateBatch(scored: scored, previews: previews)
            }.value
            // Building candidates is now asynchronous, so a second photo can be opened while the
            // first is still working. Without this guard those results would land on whichever
            // photo happens to be showing — thumbnails from one frame beside the preview of
            // another. If we've moved on, drop them.
            guard imageURL == url else { return }
            let scored = built.scored
            let previews = built.previews
            let curated = CandidateCurator.select(from: scored, count: 4)
            self.candidates = curated.compactMap { item in
                let key = item.recipe.id ?? ""
                guard let image = previews[key] else { return nil }
                return CandidateViewModel(
                    id: key,
                    label: item.recipe.label ?? key,
                    baseRecipe: item.recipe,
                    previewImage: image)
            }
            let models = self.candidates
            if let first = models.first { selectCandidate(id: first.id) }

            // If this photo was edited in an earlier session, put that work back rather than
            // handing back a fresh candidate and quietly losing it.
            if let saved = EditStore.load(for: url) {
                apply(saved)
                editedURLs.insert(url)
                statusMessage = "Ready · restored your edit from \(Self.friendlyDate(saved.savedAt))\(statusNote)"
            } else {
                statusMessage = "Ready · pick a look, or Batch apply it to a folder\(statusNote)"
            }
        } catch {
            statusMessage = "Couldn't read that photo — \(error.localizedDescription)"
        }
        isProcessing = false
    }

    func selectCandidate(id: String) {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return }
        selectedCandidateId = id
        showingOriginal = false          // never leave the before/after compare stuck on
        straighten = 0; hsl = [:]; activeLookId = nil
        // Load the candidate's actual values into the editable set — the user edits from here.
        edit = candidate.baseRecipe.global
        editBaseline = candidate.baseRecipe.global
        baseMasks = candidate.baseRecipe.masks ?? []
        maskEnabled = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, true) })
        maskStrength = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, $0.opacity * 100) })
        maskAdjustments = [:]; maskFeather = [:]; maskInvert = [:]
        maskTightness = [:]      // omitted here while `resetMask` cleared it — a slip, not a policy
        updateActiveRecipe()
        resetHistory()          // the chosen candidate is the new base for undo
        // NOTE: selecting/browsing candidates does NOT record a pick — only a deliberate
        // choice (export) does. Recording on every selection floods the store with fake
        // preferences and corrupts the learned profile.
    }

    /// Revert every manual edit back to the candidate as Kelvin generated it.
    func resetToCandidate() {
        edit = editBaseline
        straighten = 0
        hsl = [:]
        activeLookId = nil
        maskEnabled = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, true) })
        maskStrength = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, $0.opacity * 100) })
        maskAdjustments = [:]; maskFeather = [:]; maskInvert = [:]
        maskTightness = [:]      // omitted here while `resetMask` cleared it — a slip, not a policy
        updateActiveRecipe()
    }

    func selectCandidateIndex(_ index: Int) {
        guard index >= 0, index < candidates.count else { return }
        selectCandidate(id: candidates[index].id)
    }

    func onEdit() { updateActiveRecipe(); scheduleCommit() }

    /// True while a Fix click is still working, so a second click can't start a parallel loop.
    @Published private(set) var fixInProgress = false

    /// Apply a targeted correction for a flagged craft issue — the "Fix" the warning offers.
    ///
    /// One nudge often isn't enough — a badly over-saturated frame needs more than −16 saturation —
    /// so a click nudges more than once. But the nudges are RELATIVE, and an earlier version simply
    /// repeated them while the flag was up, which compounds: on a cat beside a pale pink toy, one
    /// click drove `highlights` to −100 and turned the toy vividly orange. The convergence rules —
    /// an excursion budget, evidence that the nudge is working, and a refusal to clip colour on
    /// the way — live in `CraftFix` in Core, where they are tested against the real renderer.
    ///
    /// The loop runs off the main thread: it renders and measures the proxy once per pass, and
    /// only the settled result comes back. It used to be driven from `scheduleCommit`, which fires
    /// after *any* edit — so a slider the user dragged afterwards could trigger another nudge.
    func applyFix(_ issue: AestheticEvaluator.Issue) {
        // Subject problems are fixed ON THE SUBJECT, not globally — the frame as a whole is not the
        // problem, the person in it is.
        if CraftFix.subjectStep(for: issue) != nil { applySubjectFix(issue); return }

        guard !fixInProgress, let proxy = proxyCI, let recipe = activeRecipe else { return }
        fixInProgress = true
        let start = edit
        // WHICH PHOTOGRAPH THIS RUN IS ABOUT, captured before the work starts.
        //
        // `CraftFix.converge` renders and measures the proxy once per pass, so it runs for seconds.
        // Every landing site in this file that assigns edit state has to say which photo it was
        // measuring — `loadPhoto` guards three times, renders carry a `renderedURL` — and these fix
        // paths were the ones that did not. Click Fix, arrow to the next frame, and photo A's
        // converged exposure and contrast were written onto photo B and then persisted by
        // `scheduleCommit`. Silent, plausible, and wrong: exactly the bug the sessions cache was
        // built to stop.
        let photo = imageURL
        let input = RenderInput(
            recipe: recipe, proxy: proxy,
            bitmaps: proxyMaskBitmaps.merging(brushBitmaps(extent: proxy.extent)) { _, baked in baked })
        Task.detached(priority: .userInitiated) {
            // Vision's face-rectangle detector fires on animals — it reports a face on a cat — so
            // every skin rule would otherwise be applied to fur. The semantic person segmentation
            // answers honestly, and its cost is one click's worth, not one render's.
            let isPerson = SubjectMask.person(in: input.proxy) != nil
            let settled = try? CraftFix.converge(issue: issue, from: start,
                                                 subjectIsPerson: isPerson) { g in
                var recipe = input.recipe
                recipe.global = g
                let rendered = Renderer.render(input.proxy, with: recipe, maskBitmaps: input.bitmaps)
                return CraftFix.Reading(stats: try ImageStatistics.compute(rendered),
                                        face: FaceSkin.read(in: rendered))
            }.global
            await MainActor.run {
                // Cleared even when the result is discarded, or the Fix buttons stay wedged on the
                // photograph you moved to.
                self.fixInProgress = false
                guard self.imageURL == photo else { return }
                guard let settled, settled != self.edit else { return }
                self.edit = settled
                self.onEdit()
            }
        }
    }

    /// Resolve every flagged craft issue in one click.
    ///
    /// Not a loop over `applyFix`. The corrections pull against each other — `.flat` adds contrast
    /// while `.crushedShadows` takes it out, `.blownHighlights` narrows the range that `.flat`
    /// complains about — so run in sequence they trade the photograph back and forth, each one
    /// reading as a success on its own metric while it undoes the last. The order, the rule for
    /// which of a contradictory pair wins, and the end-to-end check that throws the whole excursion
    /// away if the frame did not actually improve all live in `CraftFix.fixAll`, in Core, where they
    /// are measured against the real renderer.
    ///
    /// ONE undo step: the settled state is assigned once, so the coalescing commit records a single
    /// entry however many corrections the run applied.
    func applyFixAll() {
        guard !fixInProgress, let proxy = proxyCI, let recipe = activeRecipe else { return }
        fixInProgress = true
        statusMessage = "Working through the craft flags…"
        let start = edit
        let photo = imageURL            // see `applyFix`: this run belongs to one photograph
        let input = RenderInput(
            recipe: recipe, proxy: proxy,
            bitmaps: proxyMaskBitmaps.merging(brushBitmaps(extent: proxy.extent)) { _, baked in baked })
        Task.detached(priority: .userInitiated) {
            let isPerson = SubjectMask.person(in: input.proxy) != nil
            let run = try? CraftFix.fixAll(from: start, subjectIsPerson: isPerson) { g in
                var recipe = input.recipe
                recipe.global = g
                let rendered = Renderer.render(input.proxy, with: recipe, maskBitmaps: input.bitmaps)
                return CraftFix.Reading(stats: try ImageStatistics.compute(rendered),
                                        face: FaceSkin.read(in: rendered))
            }
            await MainActor.run {
                self.fixInProgress = false
                guard self.imageURL == photo else { return }
                guard let run else {
                    self.statusMessage = "Couldn't measure this photo — nothing changed"
                    return
                }
                if run.global != self.edit {
                    self.edit = run.global
                    self.onEdit()
                }
                self.statusMessage = Self.fixAllStatus(run)
            }
        }
    }

    /// What the run actually achieved, in the status line. It must never claim more than it did:
    /// the flags it could not clear are still on screen with their own Fix buttons, and a run that
    /// handed the photo back untouched says so rather than going quiet and looking successful.
    private static func fixAllStatus(_ run: CraftFix.RunResult) -> String {
        let total = run.resolved.count + run.remaining.count
        switch run.outcome {
        case .nothingToDo:
            return "Nothing flagged — this frame is already clean"
        case .allResolved:
            return "Fixed all \(total) craft flag\(total == 1 ? "" : "s")"
        case .partlyResolved where run.resolved.isEmpty:
            return "Eased what it could · \(run.remaining.count) still flagged"
        case .partlyResolved where run.deferred.count == run.remaining.count:
            // Subject flags are deferred BEFORE any work starts (`deferredForSubject` is intersected
            // with the starting issues), so "they pull against what was fixed" stated a reason the
            // code knows to be false — nothing was tried against them at all.
            return "Fixed \(run.resolved.count) of \(total) · "
                + "\(run.remaining.count) need their own Fix"
        case .partlyResolved:
            return "Fixed \(run.resolved.count) of \(total) · \(run.remaining.count) still flagged"
        case .nothingSafeToDo:
            return "Left as it was — no automatic fix here without breaking something else"
        case .reverted:
            return "Left as it was — every fix cost the photo more than it bought"
        }
    }

    /// One click of a subject fix — `.subjectTooDark`, `.subjectBlown`, `.subjectFlat` — pressed to
    /// the fixed point of the control that corrects it.
    ///
    /// THE BUG THIS EXISTS FOR. This used to apply one fixed nudge per click with nothing measuring
    /// the result: +0.35 EV on the subject mask for `.subjectTooDark`, whatever the photo. On a
    /// backlit portrait that is a sixth of the correction, so the reported behaviour followed
    /// exactly — click, the picture changes, the warning stays; click, it changes again, the
    /// warning stays; and from the seventh click the mask was pinned at its ±2 EV ceiling and the
    /// button did nothing at all while still being offered. The mask itself was working perfectly:
    /// measured, face luma went 0.217 → 0.409 over those six clicks. The nudge was simply the wrong
    /// size and nobody was checking.
    ///
    /// Now the step is SIZED from what is measured (see `CraftFix.subjectStep`) and pressed by
    /// `CraftFix.convergeSubject`, which re-renders and re-measures between passes and stops the
    /// moment the flag clears, the control runs out, or a pass fails to earn its place. One click,
    /// one answer. And when the answer is "this cannot be finished", `canFix` stops offering the
    /// button rather than leaving the user to discover it by clicking.
    ///
    /// Off the main thread, like the global fix: it renders and measures the proxy once per pass.
    private func applySubjectFix(_ issue: AestheticEvaluator.Issue) {
        guard !fixInProgress, let proxy = proxyCI, let recipe = activeRecipe else { return }
        guard hasPerson else {
            // No segmentation, no mask, no control. `adjustSubjectMask` used to return silently
            // here, which is a button that does nothing and does not say why.
            exhaustedFixes.insert(issue)
            statusMessage = "No subject \(Branding.displayName) can isolate in this frame — that one needs a mask you draw"
            return
        }
        // The subject mask the fixes accumulate on. Found (not created) up front, so the loop can
        // measure trial values without mutating anything the user would see.
        let existing = userMasks.first { $0.kind == .subject }
        let maskId = existing?.id ?? UUID()
        let saturation = existing?.saturation ?? 0
        let start = CraftFix.SubjectState(exposureEV: existing?.exposure ?? 0,
                                          contrast: existing?.contrast ?? 0)
        let others = (recipe.masks ?? []).filter { $0.id != maskId.uuidString }
        fixInProgress = true
        // See `applyFix`. This one lands via `adjustSubjectMask`, so without the guard it writes a
        // converged subject exposure into whichever photograph's mask stack happens to be open.
        let photo = imageURL
        let input = RenderInput(
            recipe: recipe, proxy: proxy,
            bitmaps: proxyMaskBitmaps.merging(brushBitmaps(extent: proxy.extent)) { _, baked in baked })
        Task.detached(priority: .userInitiated) {
            let settled = try? CraftFix.convergeSubject(issue: issue, from: start) { state in
                var trial = input.recipe
                var vm = UserMaskVM(kind: .subject)
                vm.id = maskId
                vm.exposure = state.exposureEV
                vm.contrast = state.contrast
                vm.saturation = saturation
                trial.masks = others + [vm.toMask()]
                let rendered = Renderer.render(input.proxy, with: trial, maskBitmaps: input.bitmaps)
                return CraftFix.Reading(stats: try ImageStatistics.compute(rendered),
                                        face: FaceSkin.read(in: rendered))
            }
            await MainActor.run {
                self.fixInProgress = false
                guard self.imageURL == photo else { return }
                guard let settled else {
                    self.statusMessage = "Couldn't measure this photo — nothing changed"
                    return
                }
                if settled.passes > 0 {
                    self.adjustSubjectMask { mask in
                        mask.exposure = settled.state.exposureEV
                        mask.contrast = settled.state.contrast
                    }
                    self.onEdit()
                }
                switch settled.outcome {
                case .resolved:
                    self.statusMessage = "Fixed · \(issue.message)"
                case .notFlagged:
                    break
                default:
                    // The control has gone as far as it goes. Record it so the button stops being
                    // offered: a fix that provably cannot finish must say so, not invite a
                    // seventh click.
                    self.exhaustedFixes.insert(issue)
                    self.statusMessage = Self.subjectFixStatus(issue, settled)
                }
            }
        }
    }

    /// What a subject click actually achieved, in the status line — never claiming more than it did.
    private static func subjectFixStatus(_ issue: AestheticEvaluator.Issue,
                                         _ result: CraftFix.SubjectResult) -> String {
        switch result.outcome {
        case .noProgress, .notApplicable:
            return "No automatic fix for \(issue.message) on this frame — the subject controls "
                + "can't move it"
        case .wouldHarm:
            return "Went as far as it could · any further and the subject starts losing detail"
        default:
            return result.passes > 0
                ? "Eased \(issue.message) as far as the subject control goes — still flagged"
                : "The subject control is already at its limit here"
        }
    }

    /// Whether the Fix button should be offered for `issue` at all.
    ///
    /// Global fixes are always offerable — `CraftFix.converge` decides for itself whether a step is
    /// worth taking and hands the photo back untouched if not. The subject family is different: its
    /// controls have hard ceilings (±2 EV, ±30 contrast), and a mask already sitting on one has
    /// nothing left to give however many times the button is pressed. Asked of the CURRENT
    /// measurement rather than cached, so a user who pulls the subject exposure back down gets the
    /// button back.
    func canFix(_ issue: AestheticEvaluator.Issue) -> Bool {
        guard CraftFix.subjectStep(for: issue) != nil else { return true }
        guard hasPerson, !exhaustedFixes.contains(issue), let reading = lastCraftReading else {
            return false
        }
        let mask = userMasks.first { $0.kind == .subject }
        return CraftFix.subjectStep(for: issue, reading: reading,
                                    exposureEV: mask?.exposure ?? 0,
                                    contrast: mask?.contrast ?? 0) != nil
    }

    /// Find the subject mask, creating one if this is the first subject fix, and adjust it.
    /// Repeated fixes accumulate on the same mask rather than stacking up duplicates.
    private func adjustSubjectMask(_ change: (inout UserMaskVM) -> Void) {
        guard hasPerson else { return }     // nothing to act on; the flag will simply persist
        if let i = userMasks.firstIndex(where: { $0.kind == .subject }) {
            change(&userMasks[i])
        } else {
            var m = UserMaskVM(kind: .subject)
            m.exposure = 0                  // start neutral; the change below supplies the amount
            change(&m)
            userMasks.append(m)
        }
    }

    /// Apply a creative look on top of the current candidate — or clear it with nil. Looks are
    /// deltas on the candidate's baseline, so switching between them never compounds: each one is
    /// applied to the untouched baseline rather than to whatever the last look left behind.
    func applyLook(_ id: String?) {
        activeLookId = id
        var g = editBaseline
        if let id, let look = LookPreset.named(id) {
            look.apply(to: &g)
            // ONLY when the look actually carries one. `hsl = look.hsl ?? [:]` wiped hand-tuned
            // per-band colour on every look tap — and most looks carry no `hsl` at all, so
            // choosing any of them silently discarded work in a panel the user was not looking at.
            // Clearing the look does the same. Undoable, but nothing said it had happened.
            if let lookHSL = look.hsl { hsl = lookHSL }
        }
        edit = g
        onEdit()
    }

    /// The black-and-white mix of the active look, folded into the rendered recipe.
    private var activeLookMono: BlackAndWhiteMix? {
        activeLookId.flatMap { LookPreset.named($0) }?.mono
    }

    /// Level the horizon automatically (Vision). No-op if no clear horizon is found.
    func autoStraighten() {
        // Vision, off the actor. `HorizonDetector` performs a `VNDetectHorizonRequest`, and this
        // ran it synchronously on `@MainActor` — the same class of freeze as export and batch, just
        // shorter, so it read as the button being slow rather than as the window being blocked.
        guard let proxy = proxyCI else { return }
        let input = ImageBox(image: proxy)
        let photo = imageURL            // see `applyFix`: a horizon belongs to one photograph
        Task { [weak self] in
            let deg = await Task.detached(priority: .userInitiated) {
                HorizonDetector.levelingAngle(in: input.image)
            }.value
            guard let self, let deg, self.imageURL == photo else { return }
            self.straighten = min(15, max(-15, deg))
            self.onEdit()
        }
    }

    /// A `CIImage` on its way to a detached task. Boxed to say the crossing is deliberate.
    private struct ImageBox: @unchecked Sendable { let image: CIImage }

    // MARK: Undo / redo (coalesced edit history)

    @Published var canUndo = false
    @Published var canRedo = false
    private var undoStack: [EditSnapshot] = []
    private var redoStack: [EditSnapshot] = []
    private var committed: EditSnapshot?
    private var commitToken = 0

    private func snapshot() -> EditSnapshot {
        EditSnapshot(edit: edit, userMasks: userMasks, maskEnabled: maskEnabled,
                     maskStrength: maskStrength, straighten: straighten, hsl: hsl)
    }
    private func applySnapshot(_ s: EditSnapshot) {
        edit = s.edit; userMasks = s.userMasks; maskEnabled = s.maskEnabled
        maskStrength = s.maskStrength; straighten = s.straighten; hsl = s.hsl
        updateActiveRecipe()
    }
    /// Reset the history to the current state — call when a fresh candidate/photo becomes the base.
    /// A new base also re-opens the question of which fixes are reachable, so anything a subject
    /// fix gave up on is forgotten here rather than following the user to the next photograph.
    func resetHistory() {
        undoStack = []; redoStack = []; committed = snapshot(); exhaustedFixes = []
        refreshUndoState()
    }

    /// After an edit burst settles (~0.45 s of no further edits), record the prior stable state as
    /// one undo step — so dragging a slider is a single undo, not hundreds.
    private func scheduleCommit() {
        commitToken += 1
        let t = commitToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.commitToken == t else { return }
            if let prev = self.committed, prev != self.snapshot() {
                self.undoStack.append(prev)
                if self.undoStack.count > 60 { self.undoStack.removeFirst() }
                self.redoStack.removeAll()
            }
            self.committed = self.snapshot()
            self.refreshUndoState()
            // Keep the filmstrip's "edited" dot honest as you work, not just on switch, and put
            // the edit on disk so quitting the app doesn't throw the work away.
            if let url = self.imageURL {
                if self.isTouched { self.editedURLs.insert(url) } else { self.editedURLs.remove(url) }
                self.persistEdit(for: url)
            }
        }
    }
    private func refreshUndoState() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(snapshot()); committed = prev
        applySnapshot(prev); refreshUndoState()
    }
    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot()); committed = next
        applySnapshot(next); refreshUndoState()
    }

    /// Which brush mask is currently being painted (drag on the preview paints into it), and the
    /// brush size (fraction of the smaller edge).
    @Published var paintingMaskId: UUID?
    @Published var brushRadius = 0.09
    /// The user mask being edited ON THE CANVAS (drag its handles to move/size it).
    /// WHICH MASK IS BEING WORKED ON — auto (subject/sky) or hand-drawn, one selection covering
    /// both. It used to be `selectedUserMaskId: UUID?`, which could only ever name a hand-drawn
    /// mask, and that single gap produced the reported bug: the sky came up covered in red that
    /// you could not edit or dismiss.
    ///
    /// What actually happened is that with nothing selected, the overlay fell back to "the first
    /// enabled auto mask" and drew it. So the red was not the sky mask being ON, it was the
    /// overlay GUESSING — and since an auto mask could not be selected, there was no way to edit
    /// the thing you were looking at, and no way to deselect it to make the red go away. An
    /// overlay that shows something the selection model cannot name is an overlay with no off
    /// switch.
    enum MaskRef: Equatable {
        case auto(String)       // "subject", "sky" — the engine's own masks
        case user(UUID)         // anything hand-drawn or picked from the subject list
    }
    @Published var selectedMask: MaskRef?

    /// The hand-drawn selection, for the call sites that only make sense for one (canvas handles,
    /// brush painting). Setting it selects; reading it yields nil when an auto mask is selected.
    var selectedUserMaskId: UUID? {
        get { if case .user(let id) = selectedMask { return id } else { return nil } }
        set { selectedMask = newValue.map { .user($0) } }
    }

    /// Show me this mask — or, if it is already the one being shown, put the selection down.
    ///
    /// The other half of the same reported bug. Selecting a hand-drawn mask assigned
    /// unconditionally, so a selection could be moved to another mask but never cleared, and
    /// everything the canvas draws for the selected mask (a subject's outline, a gradient's
    /// handles) stayed until the mask was DELETED. Reaching for the trash to dismiss an annotation
    /// is how a photographer loses the adjustments they just made.
    ///
    /// Auto masks have toggled since the day they became selectable, for this exact reason. This is
    /// the same rule for the other half of the panel.
    func toggleMaskSelection(_ id: UUID) {
        if selectedUserMaskId == id {
            selectedMask = nil
            // With nothing selected the overlay draws nothing, so a still-armed brush would be
            // painting strokes the canvas has stopped showing. Putting the mask down puts the
            // brush down.
            if paintingMaskId == id { paintingMaskId = nil }
        } else {
            selectedUserMaskId = id
        }
        // Rebuilds the render, which is what chooses the overlay bitmap. Without it the red stays
        // on the mask that is no longer selected.
        onEdit()
    }

    // MARK: Canvas coordinate mapping (view ⇄ normalised image space)

    /// The geometry currently applied to the preview (nil when the photo isn't straightened).
    var activeGeometry: Geometry? {
        straighten != 0 ? Geometry(rotateDeg: straighten, crop: nil, lensCorrection: false) : nil
    }

    /// The extent of the image AS DISPLAYED — after straighten/crop. The preview shows the framed
    /// result, so the letterbox must use its aspect, not the uncropped source's.
    private var framedExtent: CGRect {
        guard let proxy = proxyCI else { return .zero }
        guard straighten != 0 else { return proxy.extent }
        return Renderer.largestInscribedRect(proxy.extent, angleDeg: straighten)
    }

    /// The rectangle the image actually occupies inside the padded preview area, accounting for
    /// the current zoom + pan — so on-canvas masks and brush strokes stay aligned when zoomed.
    func imageRect(in container: CGSize, pad: CGFloat = 24) -> CGRect {
        let availW = container.width - 2 * pad, availH = container.height - 2 * pad
        let framed = framedExtent
        guard framed.width > 0, framed.height > 0, availW > 0, availH > 0 else { return .zero }
        let aspect = framed.width / framed.height
        var w = availW, h = availH
        if aspect > availW / availH { h = availW / aspect } else { w = availH * aspect }
        w *= zoom; h *= zoom
        let cx = container.width / 2 + pan.width
        let cy = container.height / 2 + pan.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    func resetZoom() { zoom = 1; pan = .zero }
    func setZoom(_ z: Double) { zoom = min(8, max(1, z)); if zoom == 1 { pan = .zero } }
    /// Mask coordinates are stored in SOURCE space (masks are applied before geometry), while the
    /// preview shows the FRAMED image — so both directions route through the renderer's geometry
    /// transform. Without this a mask placed on a straightened photo lands offset.
    func normToView(_ nx: Double, _ ny: Double, in rect: CGRect) -> CGPoint {
        let f = Renderer.framedNormalized(fromSource: CGPoint(x: nx, y: ny),
                                          geometry: activeGeometry,
                                          sourceExtent: proxyCI?.extent ?? .zero)
        return CGPoint(x: rect.minX + f.x * rect.width, y: rect.minY + f.y * rect.height)
    }
    func viewToNorm(_ p: CGPoint, in rect: CGRect) -> (Double, Double) {
        guard rect.width > 0, rect.height > 0 else { return (0.5, 0.5) }
        let framed = CGPoint(x: (p.x - rect.minX) / rect.width, y: (p.y - rect.minY) / rect.height)
        let s = Renderer.sourceNormalized(fromFramed: framed, geometry: activeGeometry,
                                          sourceExtent: proxyCI?.extent ?? .zero)
        return (Double(s.x), Double(s.y))
    }

    private func withMask(_ id: UUID, _ body: (inout UserMaskVM) -> Void) {
        guard let i = userMasks.firstIndex(where: { $0.id == id }) else { return }
        body(&userMasks[i]); onEdit()
    }
    func moveMask(_ id: UUID, to nx: Double, _ ny: Double) {
        withMask(id) { $0.cx = min(1, max(0, nx)); $0.cy = min(1, max(0, ny)) }
    }
    /// Resize a radial mask so its edge passes through the dragged point.
    func resizeRadial(_ id: UUID, edgeAt p: CGPoint, in rect: CGRect) {
        guard let m = userMasks.first(where: { $0.id == id }) else { return }
        let c = normToView(m.cx, m.cy, in: rect)
        let distPx = ((p.x - c.x) * (p.x - c.x) + (p.y - c.y) * (p.y - c.y)).squareRoot()
        // The drag is measured against the FRAMED image on screen, but `radius` is a fraction of
        // the SOURCE image's short edge (masks live in source space) — rescale when cropped.
        let frac = distPx / min(rect.width, rect.height)
        withMask(id) { $0.radius = min(1.2, max(0.05, Double(frac) * framedToSourceScale)) }
    }

    /// How much smaller the framed (post-straighten, post-crop) image is than the source, on its
    /// short edge. One definition, because the resize and the drawing must agree: they did not,
    /// and the circle disagreed with the effect by about 23% at 15° of straighten.
    var framedToSourceScale: Double {
        let framed = framedExtent, source = proxyCI?.extent ?? framed
        guard min(source.width, source.height) > 0 else { return 1 }
        return Double(min(framed.width, framed.height) / min(source.width, source.height))
    }
    /// Rotate a linear mask so its gradient direction points at the dragged handle.
    func rotateLinear(_ id: UUID, handleAt p: CGPoint, in rect: CGRect) {
        guard let m = userMasks.first(where: { $0.id == id }) else { return }
        let c = normToView(m.cx, m.cy, in: rect)
        let ang = atan2(p.x - c.x, -(p.y - c.y)) * 180 / .pi   // 0° = up
        withMask(id) { $0.angle = (ang < 0 ? ang + 360 : ang) }
    }

    /// Add a hand-drawn gradient mask, centred, with a gentle starting darken so the user sees it.
    func addUserMask(_ kind: UserMaskVM.Kind) {
        var m = UserMaskVM(kind: kind)
        m.exposure = -0.6
        if kind == .colorRange { m.selCenter = 0.0; m.selRange = 0.1 }    // reds by default
        if kind == .luminance { m.selCenter = 0.78; m.selRange = 0.2 }    // highlights by default
        if kind == .skin { m.selCenter = 0.06; m.selRange = 0.06; m.selSoftness = 0.05; m.exposure = 0.3 }
        if kind == .background { m.exposure = -0.5 }   // darken the background by default
        if kind == .subject { m.exposure = 0.3 }
        userMasks.append(m)
        selectedUserMaskId = m.id                      // show its canvas handles
        // Shown once, on CREATION only. A mask you cannot see when it appears looks broken —
        // but re-selecting an existing one used to turn the overlay back on too, which is why it
        // felt like it could not be dismissed. Turn it off and it stays off until you make
        // another mask.
        showMaskOverlay = true
        if kind == .brush { paintingMaskId = m.id }    // brush: start painting right away
        onEdit()
    }

    /// Move a mask up or down the stack.
    ///
    /// Order is not cosmetic: `activeMasks()` hands the renderer the array as it stands and each
    /// mask composites over the result of the ones before it, so two overlapping masks give a
    /// different photograph depending which is on top. The stack was therefore already meaningful
    /// and simply not adjustable — you got creation order and nothing else.
    func moveUserMask(_ id: UUID, by offset: Int) {
        guard let i = userMasks.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard j >= 0, j < userMasks.count else { return }
        userMasks.swapAt(i, j)
        onEdit()
    }

    func removeUserMask(_ id: UUID) {
        userMasks.removeAll { $0.id == id }
        if paintingMaskId == id { paintingMaskId = nil }
        onEdit()
    }

    func clearStrokes(_ id: UUID) {
        guard let i = userMasks.firstIndex(where: { $0.id == id }) else { return }
        userMasks[i].stamps = []; onEdit()
    }

    /// Paint a brush dab at a point in the preview area. `loc` is in the preview view's coordinate
    /// space (which is padded by `pad`); we back out the aspect-fit letterboxing to get normalised
    /// image coordinates, then drop a stamp. Throttled by distance so a stroke isn't thousands of
    /// stamps.
    func paintAt(_ loc: CGPoint, container: CGSize, pad: CGFloat = 24) {
        guard let pid = paintingMaskId,
              let idx = userMasks.firstIndex(where: { $0.id == pid }) else { return }
        // Use the SHARED mapping so painting honours zoom, pan, and straighten exactly like the
        // on-canvas handles do. (It used to do its own letterbox math and ignored all three.)
        let rect = imageRect(in: container, pad: pad)
        guard rect.width > 0, rect.height > 0 else { return }
        let framedX = (loc.x - rect.minX) / rect.width
        let framedY = (loc.y - rect.minY) / rect.height
        guard framedX >= 0, framedX <= 1, framedY >= 0, framedY <= 1 else { return }
        let (nx, ny) = viewToNorm(loc, in: rect)
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return }
        // Spacing between dabs: about a third of the brush radius, so consecutive stamps overlap
        // heavily and their soft edges union into one continuous shape. Scaled by zoom, since a
        // screen-inch covers less of the image the further in you are.
        let minStep = brushRadius * 0.33 / max(1, zoom)

        // Round to 4 decimals: sub-pixel even on a 9504 px export, and it keeps the sidecar (and
        // every undo snapshot) compact — stamps are the one recipe field that grows with use.
        func r4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        func stamp(_ x: Double, _ y: Double) {
            userMasks[idx].stamps.append(
                BrushStamp(x: r4(x), y: r4(y), radius: r4(brushRadius), hardness: 0.6))
        }

        guard let last = userMasks[idx].stamps.last else {
            stamp(nx, ny); onEdit(); return
        }

        // THE STROKE IS INTERPOLATED, and this is what "the brush adds rough dots" was. A drag
        // gesture reports a position per screen refresh, so a quick stroke can travel several brush
        // widths between two reports. The old code stamped only where the pointer WAS and threw away
        // anything closer than one step — which correctly avoided piling dabs on one spot, and did
        // nothing at all about the gaps between distant ones. Paint slowly and it looked continuous;
        // paint at any speed and it was a row of discs.
        //
        // So walk the line from the previous dab to this one, placing a dab every step. The throttle
        // survives as the first case below: nearer than one step, there is nothing to add.
        let dx = nx - last.x, dy = ny - last.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < minStep { return }

        // Bounded. A pointer that jumps the width of the image — a stylus lifted and set down, or a
        // window dragged across a second display — must not enqueue thousands of dabs and stall the
        // bake. Past the cap the stroke is left broken, which is honest and recoverable, where a
        // frozen app is neither.
        let steps = min(64, max(1, Int((distance / minStep).rounded(.down))))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            stamp(last.x + dx * t, last.y + dy * t)
        }
        onEdit()
    }

    /// The masks to render: the candidate's masks (minus any switched off, scaled to strength),
    /// plus the user's hand-drawn gradient masks.
    private func activeMasks() -> [Mask]? {
        var ms = baseMasks.compactMap { m -> Mask? in
            guard maskEnabled[m.id] ?? true else { return nil }
            var m = m
            m.opacity = Self.clampStep((maskStrength[m.id] ?? m.opacity * 100) / 100, 0...1, 0.01)
            // Whatever the user has dialled in for this mask overrides the engine's proposal.
            // Absent = untouched, so the engine's own values stand.
            if let edited = maskAdjustments[m.id] { m.adjustments = edited }
            if let f = maskFeather[m.id] { m.feather = f }
            if let t = maskTightness[m.id] { m.tightness = t }
            if let inv = maskInvert[m.id] { m.invert = inv }
            return m
        }
        ms += userMasks.map { $0.toMask() }
        return ms.isEmpty ? nil : ms
    }

    private func activeSelectedMaskBitmap(extent: CGRect) -> (bitmap: CIImage, invert: Bool, feather: Double, tightness: Double)? {
        let bitmaps = proxyMaskBitmaps.merging(brushBitmaps(extent: extent)) { _, baked in baked }
        if let mid = selectedUserMaskId, let userMask = userMasks.first(where: { $0.id == mid }) {
            let maskStruct = userMask.toMask()
            var bitmap: CIImage? = nil
            if let stamps = maskStruct.stamps, !stamps.isEmpty {
                bitmap = bitmaps[maskStruct.id] ?? Renderer.brushMask(stamps, extent: extent)
            } else if let shape = maskStruct.shape {
                bitmap = Renderer.gradientMask(shape, extent: extent)
            } else if let sel = maskStruct.selection, let cube = SelectionMask.makeData(sel) {
                bitmap = (proxyCI ?? CIImage()).applyingFilter("CIColorCubeWithColorSpace", parameters: [
                    "inputCubeDimension": SelectionMask.dimension,
                    "inputCubeData": cube,
                    "inputColorSpace": ImageWriter.outputColorSpace
                ]).cropped(to: extent)
            } else {
                bitmap = bitmaps[maskStruct.id] ?? bitmaps[maskStruct.type]
            }
            if var b = bitmap {
                // The red must show what the mask will EDIT. The renderer narrows a refined mask
                // (skin = the subject ∩ skin hues) before applying its adjustments — but this
                // overlay skipped the refinement, so a Skin mask painted the entire person and was
                // reported as "the same as the person mask". The pixels it edited were right all
                // along; the pixels it CLAIMED were wrong.
                if let refine = maskStruct.refine, let cube = SelectionMask.makeData(refine),
                   let proxy = proxyCI {
                    let selected = proxy.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                        "inputCubeDimension": SelectionMask.dimension,
                        "inputCubeData": cube,
                        "inputColorSpace": ImageWriter.outputColorSpace
                    ]).cropped(to: extent)
                    b = selected.applyingFilter("CIMultiplyCompositing", parameters: [
                        kCIInputBackgroundImageKey: b])
                }
                return (b, maskStruct.invert, maskStruct.feather, maskStruct.tightness ?? 0)
            }
        }
        // An AUTO mask, now that the selection can name one.
        if case .auto(let id) = selectedMask, let b = proxyMaskBitmaps[id] {
            return (b, maskInvert[id] ?? false, maskFeather[id] ?? 0, maskTightness[id] ?? 0)
        }
        // NO FALLBACK, deliberately. This used to answer "the first enabled auto mask" and then
        // "the first hand-drawn one" when nothing was selected, which is how the sky ended up
        // covered in red that nothing could edit and nothing could turn off. Nothing selected now
        // means nothing drawn, so the overlay always answers to something the user can point at.
        return nil
    }

    /// The scene read currently in flight, so opening a newer photo can cancel it. See the
    /// perceive site in `loadPhoto` — an actor queues reads, and only cancellation stops an
    /// abandoned one from spending real seconds ahead of the photo on screen.
    private var perceiveTask: Task<Perception, Error>?

    /// The last rendered proxy (for the histogram + the debounced craft check).
    @Published var lastRenderedCI: CIImage?
    private var craftToken = 0

    /// Baked brush strokes, keyed by mask id, with the stamp count they were baked at. Compositing
    /// a long stroke costs O(stamps) *per render* (18 ms at 1200 stamps — worse than the whole rest
    /// of the pipeline), so it's flattened to a concrete bitmap once and reused until it changes.
    private var brushCache: [UUID: (count: Int, image: CIImage)] = [:]

    /// Pre-baked preview bitmaps for the user's brush masks, to hand the renderer.
    private func brushBitmaps(extent: CGRect) -> [String: CIImage] {
        var out: [String: CIImage] = [:]
        var live = Set<UUID>()
        for m in userMasks where m.kind == .brush && !m.stamps.isEmpty {
            live.insert(m.id)
            if let hit = brushCache[m.id], hit.count == m.stamps.count {
                out[m.id.uuidString] = hit.image
                continue
            }
            // INCREMENTAL. The cache keys on stamp count, so every new dab invalidated it and the
            // WHOLE stroke was re-composited — `Renderer.brushMask` is O(stamps), measured at
            // 18 ms for 1200 of them, and this runs on the main actor from `updateActiveRecipe`.
            // So the cost was 18 ms *per dab* near the end of a long stroke, and the stroke got
            // slower the longer you painted: O(N²) over a gesture, which is the shape of a brush
            // that feels fine for two seconds and then drags.
            //
            // Only the new stamps need compositing, over the bitmap already baked.
            let baked = brushCache[m.id]
            let fresh = (baked.map { m.stamps.count > $0.count } ?? false)
                ? Array(m.stamps.suffix(m.stamps.count - (baked?.count ?? 0)))
                : m.stamps
            guard let addition = Renderer.brushMask(fresh, extent: extent) else { continue }
            let composited: CIImage
            if let baked, m.stamps.count > baked.count {
                // Lighten, not source-over: a mask is coverage, and two overlapping dabs must not
                // read as more opaque than one.
                composited = addition.applyingFilter("CILightenBlendMode", parameters: [
                    kCIInputBackgroundImageKey: baked.image
                ]).cropped(to: extent)
            } else {
                composited = addition
            }
            guard let cg = context.createCGImage(composited, from: extent) else { continue }
            let flat = CIImage(cgImage: cg)          // concrete — breaks the O(N) filter chain
            brushCache[m.id] = (m.stamps.count, flat)
            out[m.id.uuidString] = flat
        }
        brushCache = brushCache.filter { live.contains($0.key) }   // drop deleted/cleared masks
        return out
    }

    /// Moves the thread-safe-but-not-Sendable Core Image inputs across the concurrency boundary.
    /// CIContext/CIImage are documented thread-safe, so this is sound.
    private struct RenderInput: @unchecked Sendable {
        let recipe: Recipe; let proxy: CIImage; let bitmaps: [String: CIImage]
    }
    private struct RenderOutput: @unchecked Sendable { let ci: CIImage; let cg: CGImage? }
    /// The two things the detached render captures that the SDK cannot always vouch for: a
    /// CIContext, and the overlay bitmap. Both are Sendable on the macOS 27 SDK and neither is
    /// on the one CI builds against, where capturing them directly makes the closure itself
    /// non-Sendable — which no @preconcurrency import can reach. Boxing them says once, in one
    /// place, what is already true: the context is thread-safe and the bitmap is immutable.
    private struct RenderSideload: @unchecked Sendable {
        let ctx: CIContext
        let overlay: (bitmap: CIImage, invert: Bool, feather: Double, tightness: Double)?
    }
    private var renderInFlight = false
    private var renderDirty = false

    /// Build the recipe (fast, on the main thread — export always sees the latest), then hand the
    /// GPU render + read-back to a background task so the UI thread stays free while you drag. Only
    /// one render runs at a time; newer edits coalesce so we never queue a backlog of stale frames.
    private func updateActiveRecipe() {
        guard let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }),
              let proxy = proxyCI else { return }
        var finalRecipe = candidate.baseRecipe
        finalRecipe.global = edit                       // absolute manual values
        finalRecipe.masks = activeMasks()
        finalRecipe.heal = removeDust && !healSpots.isEmpty ? healSpots : nil
        finalRecipe.geometry = straighten != 0
            ? Geometry(rotateDeg: straighten, crop: nil, lensCorrection: false) : nil
        finalRecipe.hsl = hsl.isEmpty ? candidate.baseRecipe.hsl : hsl
        finalRecipe.blackAndWhite = activeLookMono
        self.activeRecipe = finalRecipe

        if renderInFlight { renderDirty = true; return }
        renderInFlight = true
        // Segmentation bitmaps + any pre-baked brush strokes (so a long stroke stays O(1)/frame).
        let bitmaps = proxyMaskBitmaps.merging(brushBitmaps(extent: proxy.extent)) { _, baked in baked }
        let input = RenderInput(recipe: finalRecipe, proxy: proxy, bitmaps: bitmaps)
        // Which photo these pixels are of. A render started before a photo switch can still land
        // after it; tagged, that frame is ignored instead of being shown under the new photo's name.
        let renderedURL = loadedURL
        // SUPPRESSED WHILE ADJUSTING. The overlay is composited into the preview at 0.6 opacity,
        // so while it is up you are grading a photograph you cannot see — drag Exposure and the
        // red is what changes. Reported exactly that way: "if I use a slider, I can't really tell
        // what has changed".
        //
        // The two things the overlay is for are opposites. Placing a mask needs the shape visible;
        // adjusting one needs the picture visible. So it stays up for the first and gets out of
        // the way for the second, and comes back on its own when you let go.
        let showOverlay = showMaskOverlay && !isAdjustingMaskTone
        let side = RenderSideload(ctx: context,
                                  overlay: showOverlay ? activeSelectedMaskBitmap(extent: proxy.extent) : nil)
        Task.detached(priority: .userInitiated) {
            var rendered = Renderer.render(input.proxy, with: input.recipe, maskBitmaps: input.bitmaps)
            if let ov = side.overlay {
                rendered = Renderer.renderMaskOverlay(rendered, maskBitmap: ov.bitmap, invert: ov.invert, feather: ov.feather, tightness: ov.tightness, opacity: 0.6)
            }
            let cg = side.ctx.createCGImage(rendered, from: rendered.extent)
            let out = RenderOutput(ci: rendered, cg: cg)
            await MainActor.run {
                self.lastRenderedCI = out.ci
                if let cg = out.cg, let renderedURL {
                    self.active = TaggedPreview(url: renderedURL,
                                                image: NSImage(cgImage: cg, size: .zero))
                }
                self.renderInFlight = false
                self.scheduleCraftCheck()
                if self.renderDirty { self.renderDirty = false; self.updateActiveRecipe() }
            }
        }
    }

    /// The objective craft self-check (clipping / skin / cast) runs ~200 ms after the last edit, so
    /// dragging a slider stays smooth and the flags settle once you stop.
    private func scheduleCraftCheck() {
        craftToken += 1
        let token = craftToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.craftToken == token, let r = self.lastRenderedCI else { return }
            // Statistics and face are kept, not just the flag list: a subject fix is sized from the
            // same measurement the flags came from, so what the button does and what the warning
            // says can never be reading different numbers.
            guard let stats = try? ImageStatistics.compute(r) else {
                self.lastCraftReading = nil; self.activeCraftIssues = []; return
            }
            // The scene reading goes in with the measurement. Warm light measures exactly like a
            // white-balance error, and only the perception layer knows which one this is — without
            // it, every golden-hour frame is told it has a "strong colour cast" and offered a Fix
            // button that would take the golden hour out of it.
            let reading = CraftFix.Reading(stats: stats, face: FaceSkin.read(in: r),
                                           condition: self.perception?.lighting.condition)
            self.lastCraftReading = reading
            self.activeCraftIssues = reading.issues
        }
    }

    func recordCurrentPick() {
        guard let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }) else { return }
        // Log the manual adjustments as the DIFF from the candidate Kelvin generated.
        let edits = manualTweaks()
        let pick = PreferencePick(
            imageId: imageId,
            perceptionHash: candidate.baseRecipe.provenance?.perceptionHash,
            shown: candidates.map { $0.id },
            chosen: selectedId,
            subsequentManualEdits: edits.isEmpty ? nil : edits)
        Task { try? await store.record(pick: pick) }
    }

    /// The mask bitmaps for a full-resolution render — the merged subject/sky pair, plus a mask for
    /// every per-subject mask the recipe names.
    ///
    /// The per-subject part cannot simply re-detect and use what comes back. Instance ids are
    /// Vision's per-pass indices: run the segmentation again at 60 MP instead of 1200 px and
    /// `person0` may be a different person, or nobody. Trusting the id would export an edit landing
    /// on the wrong face, in a file that looked right on screen the whole time. So the pass the
    /// photographer actually edited against is handed forward as references, and the fresh
    /// detection is matched back onto it by geometry.
    ///
    /// A subject that cannot be matched is *reported*, not papered over: its bitmap is absent, the
    /// renderer skips that mask, and the status line says whose edit did not make it. Silently
    /// dropping a local edit from an export is the failure worth avoiding here.
    private func fullResolutionMaskBitmaps(for fullRes: CIImage) -> [String: CIImage] {
        var bitmaps = LocalMasks.measure(in: fullRes).bitmaps
        let wanted = Set(userMasks.compactMap(\.boundInstanceId))
        guard !wanted.isEmpty else { return bitmaps }

        let references = subjectInstances.filter { wanted.contains($0.id) }.map(\.reference)
        let matched = SubjectInstances.reidentify(SubjectInstances.detect(in: fullRes),
                                                  as: references)
        bitmaps.merge(matched.bitmaps) { _, fresh in fresh }
        if !matched.unmatched.isEmpty {
            let names = matched.unmatched
                .compactMap { id in userMasks.first { $0.instanceId == id }?.label }
                .joined(separator: ", ")
            statusMessage = "Couldn't find \(names) again at full size — that edit is not in the export"
        }
        return bitmaps
    }

    /// The name a photographer gave a subject mask, or the name Vision gave it — never a raw id.
    private func label(forInstanceId id: String) -> String {
        userMasks.first { $0.instanceId == id }?.name
            ?? userMasks.first { $0.instanceId == id }?.instanceLabel
            ?? subjectInstances.first { $0.id == id }?.label
            ?? "a subject mask"
    }

    func exportFullResolution(to exportURL: URL) async {
        // NOT a bare `return`. The workspace and the Export button appear as soon as the proxy
        // decodes, but `activeRecipe` is nil until the candidates land — so clicking Export in that
        // window, naming a file and pressing Save produced no file, no error and no message at all.
        // The user is left believing they exported something.
        guard let fullRes = fullResCI, let recipe = activeRecipe else {
            statusMessage = "Still preparing this photo — try the export again in a moment"
            return
        }
        // Refuse a destination that is one of the source photographs. Batch export refuses this
        // inside `Destination.prepare`; the single-photo path has only the save panel's generic
        // "Replace?" prompt, which is no defence against writing over the original being edited.
        let target = exportURL.standardizedFileURL.resolvingSymlinksInPath()
        let sources = folderPhotos + (imageURL.map { [$0] } ?? [])
        if sources.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath() == target }) {
            statusMessage = "That would overwrite an original — choose a different name or folder"
            return
        }
        isProcessing = true
        statusMessage = "Rendering full resolution…"
        // OFF THE MAIN ACTOR. `AppState` is `@MainActor`, and `async` does NOT move work off an
        // actor — an async method on a main-actor type runs on the main thread until it awaits
        // something that hops. So this ran a full-resolution render, an `ImageWriter.write`, and —
        // via `fullResolutionMaskBitmaps` — TWO 60-megapixel Vision passes, all on the thread
        // drawing the window. The app was frozen for the entire export, including the
        // "Rendering full resolution…" message, which could not paint.
        //
        // This is the third instance of a failure mode this codebase has documented twice
        // already: thumbnails decoding whole RAWs during view layout, and decode on the MainActor.
        // The pattern is always the same and always looks like correct code.
        //
        // The bitmaps are still computed on the detached side, because that is where the Vision
        // passes are, and they are the expensive part.
        let masksNeeded = recipe.masks?.isEmpty == false
        let references = subjectInstances.filter { inst in
            userMasks.contains { $0.boundInstanceId == inst.id }
        }.map(\.reference)
        let input = ExportInput(fullRes: fullRes, recipe: recipe, url: exportURL,
                                metadata: exportMetadata, format: exportFormat,
                                size: exportSize, colorSpace: exportColorSpace)

        // Carries back WHICH subject masks could not be found again at full resolution, because the
        // renderer's response to a missing bitmap is to skip that mask silently. A per-subject local
        // edit could therefore be absent from the exported file while the status line said
        // "Exported IMG_1234.jpg". The code that was supposed to report this existed
        // (`fullResolutionMaskBitmaps`) and was never called from anywhere — dead since it was
        // written, while the live path inlined the re-identification and discarded `unmatched`.
        let result: Result<[String], Error> = await Task.detached(priority: .userInitiated) {
            do {
                var bitmaps: [String: CIImage] = [:]
                var lost: [String] = []
                if masksNeeded {
                    bitmaps = LocalMasks.measure(in: input.fullRes).bitmaps
                    if !references.isEmpty {
                        let matched = SubjectInstances.reidentify(
                            SubjectInstances.detect(in: input.fullRes), as: references)
                        bitmaps.merge(matched.bitmaps) { _, fresh in fresh }
                        lost = matched.unmatched
                    }
                }
                try ImageWriter.write(
                    Renderer.render(input.fullRes, with: input.recipe, maskBitmaps: bitmaps),
                    to: input.url, format: input.format, metadata: input.metadata,
                    size: input.size, colorSpace: input.colorSpace)
                return .success(lost)
            } catch { return .failure(error) }
        }.value

        switch result {
        case .success(let lost):
            if lost.isEmpty {
                statusMessage = "Exported \(exportURL.lastPathComponent)"
            } else {
                // Named, not counted. "One mask is missing" sends someone hunting; "Person 2" tells
                // them what to check.
                let names = lost.map { label(forInstanceId: $0) }.joined(separator: ", ")
                statusMessage = "Exported \(exportURL.lastPathComponent) — but \(names) "
                    + "couldn't be found again at full size, so that edit is not in the file"
            }
            // Exporting is the one unambiguous signal of preference, so it's logged. NOTE: nothing
            // currently reads this back — candidates are generated fresh per photo, by design (the
            // way to reuse an edit is Batch apply, not a cross-image average). The log exists so
            // that decision can be revisited with real data; it is not a live learning loop, and
            // the UI must not claim otherwise.
            recordCurrentPick()
        case .failure(let error):
            statusMessage = "Export failed — \(error)"
        }
        isProcessing = false
    }

    /// Render every photograph in this shoot that carries a saved edit, each with ITS OWN recipe.
    ///
    /// The hole this fills: `exportFullResolution` handles one photo, and Batch apply propagates ONE
    /// look across a folder by re-perceiving every frame. Neither renders the twenty frames somebody
    /// actually sat down and edited — which was the last step of a shoot, and had no button.
    ///
    /// Masks are re-measured per photograph, exactly as batch does: a subject mask is measured on
    /// the proxy and must be re-found at full resolution, and the frames differ.
    func exportEdited(to directory: URL) async {
        let targets = exportTargets(keepersOnly: exportKeepersOnly)
        guard !targets.isEmpty else {
            statusMessage = exportKeepersOnly
                ? "No edited photos are flagged Keep — press P on the ones you want, or untick Kept only"
                : "Nothing edited in this shoot yet"
            return
        }

        // Refuses to write into the folder the originals live in. `prepare` compares filesystem
        // identity rather than path strings, so a symlink or a /tmp-vs-/private/tmp spelling cannot
        // sneak past it — the same guard batch uses, for the same reason.
        let destination = BatchApply.Destination(directory: directory, onCollision: .uniqueSuffix,
                                                 format: exportFormat, metadata: exportMetadata)
        do { try destination.prepare(sources: targets) }
        catch {
            statusMessage = "Can't export there — \(error)"
            return
        }

        isProcessing = true
        var written = 0, failed = 0, unreadable = 0
        var needsReopening: [String] = []
        let size = exportSize, space = exportColorSpace, scheme = exportNaming

        for (index, url) in targets.enumerated() {
            statusMessage = "Exporting \(index + 1) of \(targets.count)…"
            // Counted, not `continue`d silently: a sidecar that exists but won't decode used to
            // vanish from the arithmetic entirely, and "Exported 0" with no reason attached reads
            // as a broken button — which is exactly how its own developer read it.
            guard let saved = EditStore.load(for: url) else { unreadable += 1; continue }
            // A sidecar written before recipes were stored cannot be reproduced without re-running
            // perception. Say which ones, rather than exporting something that is not what they saw.
            guard let recipe = saved.recipe else {
                needsReopening.append(url.lastPathComponent); continue
            }
            let look = saved.styleId
            let out = ExportNaming.uniqueURL(
                in: directory,
                stem: ExportNaming.stem(for: url, perception: nil, look: look, scheme: scheme),
                ext: exportFormat.fileExtension)

            // Read off the actor once, before the work crosses to a detached task. Reaching back
            // into `self` from inside it is an await per property and, worse, a value that could
            // change between photographs mid-export.
            let format = exportFormat, metadata = exportMetadata
            let result: Bool = await Task.detached(priority: .userInitiated) {
                guard let image = try? ImageDecoder.decode(url: url) else { return false }
                let bitmaps = recipe.masks?.isEmpty == false
                    ? LocalMasks.measure(in: image).bitmaps : [:]
                let rendered = Renderer.render(image, with: recipe, maskBitmaps: bitmaps)
                do {
                    try ImageWriter.write(rendered, to: out, format: format, metadata: metadata,
                                          size: size, colorSpace: space)
                    return true
                } catch { return false }
            }.value
            if result { written += 1 } else { failed += 1 }
        }

        isProcessing = false
        // When nothing was written, the REASON is the message — "Exported 0" with the explanation
        // trailing after a folder name is how a working feature gets reported as a broken one.
        if written == 0 {
            if !needsReopening.isEmpty {
                statusMessage = "Nothing exported — \(needsReopening.count) of these edits were saved "
                    + "before looks were stored inside them. Open each photo once (it re-saves in "
                    + "the current form), then export again"
            } else if unreadable > 0 {
                statusMessage = "Nothing exported — \(unreadable) saved edit\(unreadable == 1 ? "" : "s") "
                    + "could not be read back. Open those photos once to re-save them"
            } else {
                statusMessage = "Nothing exported — \(failed) failed to render or write"
            }
            return
        }
        var message = "Exported \(written) edited photo\(written == 1 ? "" : "s") to \(directory.lastPathComponent)"
        if failed > 0 { message += " · \(failed) failed" }
        if unreadable > 0 { message += " · \(unreadable) unreadable — open those photos once to re-save" }
        if !needsReopening.isEmpty {
            message += " · \(needsReopening.count) saved before this version — open each once to include it"
        }
        statusMessage = message
    }

    /// Everything a detached export needs, boxed so it can cross the actor boundary. `CIImage` and
    /// `Recipe` are safe to read from another thread here — the box exists to say so explicitly
    /// rather than to launder a race.
    private struct ExportInput: @unchecked Sendable {
        let fullRes: CIImage
        let recipe: Recipe
        let url: URL
        let metadata: ImageWriter.MetadataPolicy
        let format: ImageWriter.Format
        let size: ImageWriter.Size
        let colorSpace: ImageWriter.ColorSpace
    }

    /// Apply the chosen *look* across a folder with per-photo intelligence: the style is held
    /// constant, but every photo is re-perceived and re-measured so its own corrective baseline
    /// (exposure / white balance / tone) is derived fresh. A shoot's frames differ in exposure
    /// and scene — copying identical slider values would wreck half of them. The manual tweaks
    /// you made on the reference photo ride along on top of each adapted recipe.
    func runBatchApply(inputDir: URL, outputDir: URL) async {
        do {
            let files = try BatchApply.imageFiles(in: inputDir)
            await runBatchApply(files: files, outputDir: outputDir)
        } catch {
            statusMessage = "Batch failed — \(error)"
        }
    }

    func runBatchApply(files: [URL], outputDir: URL) async {
        // Backstop only — the panel checks this before it opens, so nobody chooses folders for a
        // batch that was never going to run.
        guard let styleId = selectedCandidateId,
              let style = CandidateStyle.all.first(where: { $0.id == styleId }) else {
            statusMessage = "Pick a look first — Batch apply adapts the one you have chosen"
            return
        }
        guard !files.isEmpty else {
            statusMessage = batchKeepersOnly
                ? "No photos are flagged Keep — press P on the ones you want, or untick Kept only"
                : "Nothing to batch — the folder has no photos Kelvin can read"
            return
        }
        let tweaks = manualTweaks()
        // Snapshotted as VALUES before the loop. `applyLookBeyondGlobals` reads five pieces of
        // actor state, and reaching back for them from a detached task is how a data race gets
        // written by accident. The look does not change during a batch, so capture it once.
        let look = BatchLook(hsl: hsl, straighten: straighten, maskEnabled: maskEnabled,
                             maskStrength: maskStrength, userMasks: userMasks)
        isProcessing = true
        do {
            // THE DESTINATION IS CHECKED BEFORE A SINGLE BYTE IS WRITTEN. Measured in Core: the
            // CLI's batch, pointed at its own source folder, silently rewrote every original in
            // place — shasums before and after. Non-negotiable #3 says the original is never
            // written to. `prepare` refuses that, refuses a non-folder, creates the destination,
            // and compares filesystem identity rather than path strings, so a symlink or a
            // /tmp-vs-/private/tmp spelling cannot sneak past it.
            let destination = BatchApply.Destination(directory: outputDir,
                                                     onCollision: .uniqueSuffix,
                                                     format: .jpeg(quality: 0.97),
                                                     metadata: exportMetadata)
            try destination.prepare(sources: files)

            var items: [BatchApply.Outcome.Item] = []
            for (i, file) in files.enumerated() {
                statusMessage = "Adapting \(style.label) to photo \(i + 1) of \(files.count)…"
                do {
                    // PERCEPTION STAYS HERE — it is an actor hop of its own and the only part that
                    // was ever off this thread.
                    let image = try ImageDecoder.decode(url: file)
                    // Materialised, not lazy. A lazy proxy is a filter graph over the FULL frame,
                    // so every measurement below would silently re-render all 60 megapixels again —
                    // the exact trap `loadPhoto` documents and avoids.
                    let proxy = Self.materialiseShared(PerceptionProxy.downsample(image))
                    let perception = try await perceptionProvider.perceive(proxy)

                    // ...AND EVERYTHING ELSE GOES OFF THE MAIN ACTOR. `AppState` is `@MainActor`,
                    // so decode, statistics, two Vision passes, a full-resolution render and a file
                    // write were all running on the thread drawing the window — for every frame in
                    // the shoot. The app was locked for the whole batch, which on a real shoot is
                    // minutes, and the per-file progress it sets each iteration could not repaint,
                    // so the one thing telling you it was alive was invisible.
                    let work = BatchInput(image: image, proxy: proxy, source: file,
                                          perception: perception, style: style, tweaks: tweaks,
                                          heal: (removeDust && !healSpots.isEmpty) ? healSpots : nil,
                                          look: look, destination: destination)
                    let item = await Task.detached(priority: .userInitiated) { () -> BatchApply.Outcome.Item in
                        do {
                            let stats = try ImageStatistics.compute(work.proxy)
                            // Per-photo subject + sky masks — each frame gets its own local decisions.
                            let m = LocalMasks.measure(in: work.proxy)
                            var recipe = RecipeEngine.candidate(
                                perception: work.perception, statistics: stats, style: work.style,
                                subjectLuma: m.subjectLuma, skyLuma: m.skyLuma,
                                iso: ExifReader.iso(url: work.source))
                            Self.applyTweaks(work.tweaks, to: &recipe.global)
                            work.look.apply(to: &recipe)
                            // Sensor dust sits at the same normalised position on every frame of a
                            // shoot, so the spots found on the reference photo heal the whole batch.
                            recipe.heal = work.heal
                            let masks = (recipe.masks?.isEmpty == false)
                                ? LocalMasks.measure(in: work.image).bitmaps : [:]
                            // Named from what the model read about THAT frame, so a batch comes out
                            // searchable rather than as a wall of camera serial numbers.
                            switch work.destination.plan(for: work.source,
                                                         perception: work.perception,
                                                         look: work.style.label) {
                            case .skip(let existing):
                                return .skipped(source: work.source, existing: existing)
                            case .write(let out):
                                try ImageWriter.write(
                                    Renderer.render(work.image, with: recipe, maskBitmaps: masks),
                                    to: out, format: work.destination.format)
                                return .written(source: work.source, to: out)
                            }
                        } catch {
                            return .failed(source: work.source, message: "\(error)")
                        }
                    }.value
                    items.append(item)
                } catch {
                    items.append(.failed(source: file, message: "\(error)"))
                }
            }
            let outcome = BatchApply.Outcome(items: items)
            self.batchOutcome = outcome
            self.showBatchSheet = true
            statusMessage = "Batch done · \(outcome.succeeded) edited as \(style.label), "
                + "\(outcome.skippedCount) skipped, \(outcome.failed) failed"
        } catch {
            // `"\(error)"` rather than `localizedDescription`: `Destination.Problem` writes a
            // sentence a photographer can act on, and `localizedDescription` would replace it with
            // a generic Cocoa string.
            statusMessage = "Batch failed — \(error)"
        }
        isProcessing = false
    }

    /// One photo's worth of batch work, boxed to cross the actor boundary.
    private struct BatchInput: @unchecked Sendable {
        let image: CIImage
        let proxy: CIImage
        let source: URL
        let perception: Perception
        let style: CandidateStyle
        let tweaks: [String: Double]
        let heal: [HealSpot]?
        let look: BatchLook
        let destination: BatchApply.Destination
    }

    /// The parts of the reference photo's look that are not global slider values, captured as
    /// values so a batch worker never reads back into the main actor.
    private struct BatchLook: @unchecked Sendable {
        let hsl: [String: HSLAdjustment]
        let straighten: Double
        let maskEnabled: [String: Bool]
        let maskStrength: [String: Double]
        let userMasks: [UserMaskVM]

        func apply(to recipe: inout Recipe) {
            if !hsl.isEmpty { recipe.hsl = hsl }
            if straighten != 0 {
                recipe.geometry = Geometry(rotateDeg: straighten, crop: nil, lensCorrection: false)
            }
            // Honour the reference photo's auto-mask toggles/strengths, then append the user's.
            var ms = (recipe.masks ?? []).compactMap { m -> Mask? in
                guard maskEnabled[m.id] ?? true else { return nil }
                var m = m
                if let pct = maskStrength[m.id] { m.opacity = min(1, max(0, pct / 100)) }
                return m
            }
            ms += userMasks.map { $0.toMask() }
            recipe.masks = ms.isEmpty ? nil : ms
        }
    }

    /// Carry the parts of the look that AREN'T global slider values onto a batch photo: the colour
    /// mixer, straighten, the user's hand-made masks, and their on/off + strength decisions for the
    /// auto masks. Without this, "apply this look to the shoot" silently dropped everything except
    /// the basic sliders.
    ///
    /// Note the split that makes batch intelligent: the auto subject/sky masks are REGENERATED per
    /// photo by the engine (so they land on this frame's subject and sky), while the user's masks
    /// carry over as authored — semantic ones (colour/luma/skin/background) re-select against each
    /// new photo automatically, and positional ones (radial/graduated/brush) hold their placement,
    /// which is what syncing a local adjustment across a shoot means.
    private func applyLookBeyondGlobals(to recipe: inout Recipe) {
        if !hsl.isEmpty { recipe.hsl = hsl }
        if straighten != 0 {
            recipe.geometry = Geometry(rotateDeg: straighten, crop: nil, lensCorrection: false)
        }
        // Honour the reference photo's auto-mask toggles/strengths, then append the user's masks.
        var ms = (recipe.masks ?? []).compactMap { m -> Mask? in
            guard maskEnabled[m.id] ?? true else { return nil }
            var m = m
            if let pct = maskStrength[m.id] { m.opacity = min(1, max(0, pct / 100)) }
            return m
        }
        ms += userMasks.map { $0.toMask() }
        recipe.masks = ms.isEmpty ? nil : ms
    }

    /// The manual edits as a DIFF from the candidate Kelvin generated — carried onto every batch
    /// photo (as offsets, so each frame keeps its own adapted baseline) and logged as the pick's
    /// subsequent edits. Only meaningfully-changed fields are included.
    private func manualTweaks() -> [String: Double] {
        var t: [String: Double] = [:]
        func d(_ key: String, _ a: Double, _ b: Double, _ eps: Double) { if abs(a - b) > eps { t[key] = a - b } }
        d("exposure_ev", edit.exposureEV, editBaseline.exposureEV, 0.01)
        d("contrast", edit.contrast, editBaseline.contrast, 0.5)
        d("highlights", edit.highlights, editBaseline.highlights, 0.5)
        d("shadows", edit.shadows, editBaseline.shadows, 0.5)
        d("whites", edit.whites, editBaseline.whites, 0.5)
        d("blacks", edit.blacks, editBaseline.blacks, 0.5)
        d("vibrance", edit.vibrance, editBaseline.vibrance, 0.5)
        d("saturation", edit.saturation, editBaseline.saturation, 0.5)
        d("clarity", edit.clarity, editBaseline.clarity, 0.5)
        d("texture", edit.texture, editBaseline.texture, 0.5)
        d("dehaze", edit.dehaze, editBaseline.dehaze, 0.5)
        d("fusion", edit.fusion, editBaseline.fusion, 0.5)
        d("tint", edit.tint, editBaseline.tint, 0.5)
        if let et = edit.temperatureK, let bt = editBaseline.temperatureK, abs(et - bt) > 5 {
            t["temperatureK"] = et - bt
        }
        return t
    }

    /// Pure: reads only its arguments, so a batch worker can call it off the actor.
    nonisolated static func applyTweaks(_ t: [String: Double], to g: inout GlobalAdjustments) {
        g.exposureEV = Self.clampStep(g.exposureEV + (t["exposure_ev"] ?? 0), -5...5, 0.05)
        g.contrast = Self.clampStep(g.contrast + (t["contrast"] ?? 0), -100...100, 1)
        g.highlights = Self.clampStep(g.highlights + (t["highlights"] ?? 0), -100...100, 1)
        g.shadows = Self.clampStep(g.shadows + (t["shadows"] ?? 0), -100...100, 1)
        g.whites = Self.clampStep(g.whites + (t["whites"] ?? 0), -100...100, 1)
        g.blacks = Self.clampStep(g.blacks + (t["blacks"] ?? 0), -100...100, 1)
        g.vibrance = Self.clampStep(g.vibrance + (t["vibrance"] ?? 0), -100...100, 1)
        g.saturation = Self.clampStep(g.saturation + (t["saturation"] ?? 0), -100...100, 1)
        g.clarity = Self.clampStep(g.clarity + (t["clarity"] ?? 0), -100...100, 1)
        g.texture = Self.clampStep(g.texture + (t["texture"] ?? 0), -100...100, 1)
        g.dehaze = Self.clampStep(g.dehaze + (t["dehaze"] ?? 0), 0...100, 1)
        g.fusion = Self.clampStep(g.fusion + (t["fusion"] ?? 0), 0...100, 1)
        g.tint = Self.clampStep(g.tint + (t["tint"] ?? 0), -100...100, 1)
        if let dt = t["temperatureK"] { g.temperatureK = (g.temperatureK ?? 5500) + dt }
    }

    /// The ids of the auto-masks on the current candidate (e.g. "subject", "sky"), for the UI.
    var baseMaskIds: [String] { baseMasks.map { $0.id } }

    /// Whether a person was segmented in this photo. Skin and Background masks are built from that
    /// segmentation, so without it they can't do anything — the UI says so rather than going quiet.
    var hasPerson: Bool { proxyMaskBitmaps["subject"] != nil }

    /// A binding for the white-balance slider (absolute Kelvin; nil → as-shot shown as 5500).
    var temperatureBinding: Binding<Double> {
        Binding(get: { self.edit.temperatureK ?? 5500 },
                set: { self.edit.temperatureK = $0; self.updateActiveRecipe() })
    }

    // Active look's white balance for the rail (nil = as-shot).
    var activeTemperature: Double? { activeRecipe?.global.temperatureK }

    /// Pure, so the batch worker can clamp off the actor too.
    nonisolated static func clampStep(_ v: Double, _ r: ClosedRange<Double>, _ step: Double) -> Double {
        let c = min(r.upperBound, max(r.lowerBound, v))
        return (c / step).rounded() * step
    }

    /// Results of the off-main candidate build. CIContext/CGImage are thread-safe; NSImage built
    /// from a CGImage is immutable here, so carrying them across is sound.
    private struct CandidateBatch: @unchecked Sendable {
        let scored: [CandidateCurator.Scored]
        let previews: [String: NSImage]
    }

    /// Everything the decode stage produces. Bundled so the whole of it can be computed on a
    /// background thread and handed back in one hop — decoding a 60 MP RAW, materialising the
    /// proxy and hashing the file are all far too slow to sit on the main thread.
    private struct DecodedPhoto: @unchecked Sendable {
        let fullRes: CIImage
        let perceptionProxy: CIImage
        let proxy: CIImage
        let originalPreview: NSImage?
        let imageId: String
    }

    /// What measuring the proxy yields: histogram statistics, the local mask stack, and the dust
    /// scan. Vision segmentation and the statistics pass are both heavy enough to freeze the UI.
    private struct MeasuredPhoto: @unchecked Sendable {
        let stats: ImageStatistics
        let masks: LocalMasks.Measured
        let dust: [HealSpot]
        let focus: FocusMeasure.Reading
        /// Each separable subject in the frame, for the mask list.
        let instances: [SubjectInstances.Instance]
    }

    /// Shared with the background candidate build — a CIContext is thread-safe and expensive to
    /// create, so one instance serves both.
    ///
    /// KEEP the `(unsafe)`. Xcode 27 reports it as unnecessary because the macOS 27 SDK marks
    /// CIContext Sendable; the SDK CI builds against does not, and there plain `nonisolated`
    /// cannot be applied to a non-Sendable constant at all. Same trap as
    /// KelvinCore/Render/ImageWriter — this site is where it was taken.
    nonisolated(unsafe) static let sharedContext: CIContext = {
        let opts: [CIContextOption: Any] = [.cacheIntermediates: true, .highQualityDownsample: false]
        if let device = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: device, options: opts) }
        return CIContext(options: opts)
    }()

    /// Render a lazy CIImage into a concrete bitmap-backed one, so downstream passes sample real
    /// pixels instead of re-evaluating the whole graph each time.
    private func materialise(_ image: CIImage) -> CIImage { Self.materialiseShared(image) }

    private func ciToNSImage(_ ciImage: CIImage) -> NSImage? { Self.ciToNSImageShared(ciImage) }

    // Static twins of the two above, for use inside `Task.detached` during load. `CIContext` is
    // documented as thread-safe and `sharedContext` is already used this way by the candidate
    // build, so both stages can share the one GPU context rather than each making its own.
    nonisolated static func materialiseShared(_ image: CIImage) -> CIImage {
        guard let cg = sharedContext.createCGImage(image, from: image.extent) else { return image }
        return CIImage(cgImage: cg)
    }

    nonisolated static func ciToNSImageShared(_ ciImage: CIImage) -> NSImage? {
        guard let cg = sharedContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSZeroSize)
    }
}

// MARK: - Signature: the temperature rail

struct TemperatureRail: View {
    /// Marks along the scale, coloured by their Kelvin. nil temperatures (as-shot) are omitted.
    let marks: [(k: Double, emphasized: Bool)]
    var showTicks = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(KelvinScale.gradient)
                    .frame(height: 3)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .opacity(0.55)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    let x = CGFloat(KelvinScale.position(mark.k)) * geo.size.width
                    Circle()
                        .fill(KelvinScale.color(mark.k))
                        .frame(width: mark.emphasized ? 11 : 6, height: mark.emphasized ? 11 : 6)
                        .overlay(Circle().stroke(Theme.base, lineWidth: mark.emphasized ? 2.5 : 1.5))
                        .shadow(color: mark.emphasized ? KelvinScale.color(mark.k).opacity(0.6) : .clear, radius: 5)
                        .position(x: min(max(x, 6), geo.size.width - 6), y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 14)
    }
}

// MARK: - Root

struct ContentView: View {
    /// Owned by `KelvinApp` rather than created here, so the File menu can drive the same state
    /// the window shows — a menu command with no route to the app's state is a dead menu.
    @ObservedObject var appState: AppState
    @State private var isTargeted = false
    @State private var panStart = CGSize.zero
    @State private var zoomStart = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            // As soon as the photo is decoded. Waiting for perception before showing ANYTHING
            // meant dropping a file and watching an empty drop zone for the length of a model
            // run — the photo is right there, so show it and let the looks arrive around it.
            if appState.proxyCI != nil {
                workspace
            } else {
                emptyState
            }
        }
        .background(Theme.base)
        .preferredColorScheme(.dark)
        // The drop target is the WHOLE WINDOW, not just the empty state. It used to live only on
        // the empty state, which meant that once you had a photo open there was no way at all to
        // bring another one in — dragging did nothing, and there was no Open command either. The
        // filmstrip only ever shows the folder you came from, so a second shoot was unreachable.
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { @MainActor in await appState.openDropped(providers) }
            return true
        }
        // A drop hint over the workspace too — without it, dragging onto an open photo gives no
        // sign the window will take it.
        .overlay {
            if isTargeted && appState.proxyCI != nil {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.glow.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .background(Theme.base.opacity(0.35))
                    .overlay(
                        Text("Drop to open")
                            .font(Theme.ui(15, .semibold))
                            .foregroundColor(Theme.ink)
                    )
                    .padding(18)
                    .allowsHitTesting(false)
            }
        }
        // Culling is keyboard work. Clicking a flag costs a second or two per frame, which across
        // a few hundred frames is most of an hour of pure motion — so the decision and the move to
        // the next photo are one keystroke. Hidden buttons rather than a visible toolbar: they
        // exist to carry the shortcut, not to be clicked.
        .overlay {
            if appState.proxyCI != nil {
                Group {
                    Button("") { appState.flagCurrentAndAdvance(.keep) }
                        .keyboardShortcut("p", modifiers: [])
                    Button("") { appState.flagCurrentAndAdvance(.reject) }
                        .keyboardShortcut("x", modifiers: [])
                    Button("") { appState.showMaskOverlay.toggle(); appState.onEdit() }
                        .keyboardShortcut("o", modifiers: [])
                    Button("") { appState.adjustBrushRadius(by: -0.02) }
                        .keyboardShortcut("[", modifiers: [])
                    Button("") { appState.adjustBrushRadius(by: 0.02) }
                        .keyboardShortcut("]", modifiers: [])
                    Button("") { appState.selectCandidateIndex(0) }
                        .keyboardShortcut("1", modifiers: [])
                    Button("") { appState.selectCandidateIndex(1) }
                        .keyboardShortcut("2", modifiers: [])
                    Button("") { appState.selectCandidateIndex(2) }
                        .keyboardShortcut("3", modifiers: [])
                    Button("") { appState.selectCandidateIndex(3) }
                        .keyboardShortcut("4", modifiers: [])
                    Button("") { Task { await appState.advance(by: 1) } }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { Task { await appState.advance(by: -1) } }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                }
                .opacity(0).frame(width: 0, height: 0)
            }
        }
        .task { await appState.loadDemoIfRequested() }
        .sheet(isPresented: $appState.showBatchSheet) { batchSheet }
        .sheet(isPresented: $showShortcutsSheet) { ShortcutsSheet() }
    }

    @State private var showShortcutsSheet = false

    // MARK: Header — wordmark + instrument status readout

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(KelvinScale.gradient)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                Text(Branding.displayName.uppercased())
                    .font(Theme.ui(15, .semibold))
                    .tracking(4)
                    .foregroundColor(Theme.ink)
            }
            Spacer()
            HStack(spacing: 12) {
                if appState.isProcessing {
                    ProgressView().controlSize(.small).tint(Theme.glow)
                } else {
                    Circle().fill(Theme.glow).frame(width: 5, height: 5)
                }
                Text(appState.statusMessage)
                    .font(Theme.mono(11))
                    .foregroundColor(Theme.inkDim)
                Button(action: { showShortcutsSheet = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard").font(.system(size: 10))
                        Text("Shortcuts").font(Theme.mono(10))
                    }
                    .foregroundColor(Theme.inkDim)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                // ⌘/ rather than the "?" the tooltip used to promise: nothing was bound to "?",
                // and it needs Shift on most layouts anyway, so it would not have fired reliably
                // even if it had been. ⌘/ is the macOS convention for this and takes no modifier
                // gymnastics.
                .keyboardShortcut("/", modifiers: .command)
                .help("Keyboard shortcuts (⌘/)")

                // ⌘, has always worked and the menu item has always been there, but there was no
                // way to DISCOVER either from inside the window — and this app hides its title bar,
                // so the menu is the last place someone looks. Two preferences that change what
                // happens to your files live in there; they should not be a thing you have to
                // already know about.
                // Next to Settings, because the two things someone wants after using an app for ten
                // minutes are to change something and to ask for something. A pre-alpha with no
                // route for the second is one that only hears from people annoyed enough to go
                // looking for the repository.
                Button(action: { NSWorkspace.shared.open(AppInfo.featureRequestURL) }) {
                    Image(systemName: "lightbulb")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkDim)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Request a feature")

                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.inkDim)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Capsule().stroke(Theme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.base)
    }

    // MARK: Empty state — the scale is the hero

    private var emptyState: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Text("Read the light.")
                        .font(Theme.ui(40, .medium))
                        .foregroundColor(Theme.ink)
                    Text("Drop a photo — or a whole folder. \(Branding.displayName) reads the scene on-device and offers a few finished looks: pick one, tune it, then apply it across the shoot. Open a single frame and the rest of its folder is listed alongside it, ready when you want it.")
                        .textSelection(.enabled)
                        .font(Theme.ui(14))
                        .foregroundColor(Theme.inkDim)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }

                // The blackbody scale, labelled — the signature, front and centre.
                VStack(spacing: 8) {
                    TemperatureRail(marks: [(2900, false), (5500, false), (8600, false)], showTicks: true)
                        .frame(width: 440)
                    HStack {
                        Text("2900K warm").foregroundColor(KelvinScale.color(2900))
                        Spacer()
                        Text("5500K daylight").foregroundColor(Theme.inkDim)
                        Spacer()
                        Text("8600K cool").foregroundColor(KelvinScale.color(8600))
                    }
                    .font(Theme.mono(10))
                    .frame(width: 440)
                }

                Button(action: appState.chooseAndOpen) {
                    // "or folder", because the panel accepts both and always has. Saying only
                    // "photo" made opening a folder look like something the app was not offering,
                    // and made the shoot appearing in the strip look like a surprise.
                    Text("Choose a photo or folder")
                        .font(Theme.ui(13, .semibold))
                        .foregroundColor(Theme.base)
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(Capsule().fill(Theme.glow))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("RAW · JPEG · HEIC · PNG · TIFF   —   on-device, your photos never leave your Mac")
                .font(Theme.mono(10))
                .foregroundColor(Theme.inkFaint)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 0)
                .fill(isTargeted ? Theme.glow.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .center) {
            if isTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.glow.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                    .padding(24)
            }
        }
    }

    // MARK: Workspace

    private var workspace: some View {
        HSplitView {
            // Preview + the active look's white balance on the rail
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack {
                        let shown = appState.showingOriginal
                            ? appState.originalPreviewImage
                            : (appState.activePreviewImage ?? appState.originalPreviewImage)
                        if let img = shown {
                            Image(nsImage: img)
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(24)
                                .scaleEffect(appState.zoom, anchor: .center)
                                .offset(appState.pan)
                                // Identity is the PHOTOGRAPH, not the rendered image. `shown` is
                                // replaced on every slider move, so keying the transition on it
                                // would crossfade the live edit and destroy the one thing this
                                // preview exists for. Keyed on the URL, only a genuinely new frame
                                // arriving gets the fade.
                                .id(appState.imageURL)
                                .transition(.opacity)
                        } else if appState.isProcessing {
                            // A LOADING STATE, not a blank canvas and not the previous photograph.
                            //
                            // The previews are tagged with the photo they belong to, so once the
                            // open moves on there is nothing to draw until the new frame decodes —
                            // and an empty rectangle for a second or two reads as the app having
                            // dropped something. Showing the OLD photo instead would be worse: it
                            // is the wrong picture under the new one's name, which is how somebody
                            // ends up editing a frame they are not looking at.
                            //
                            // So: say what is happening. The status line carries the detail
                            // ("Loading the perception model", "Reading the scene"); this is just
                            // the acknowledgement that the click landed.
                            VStack(spacing: 14) {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(Theme.glow)
                                Text(appState.statusMessage)
                                    .font(Theme.mono(11))
                                    .foregroundColor(Theme.inkDim)
                                    .transition(.opacity)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    // Photos come in from the filmstrip, a drop, or the arrow keys. A hard cut
                    // between two frames of the same shoot reads as a flicker; a short fade makes
                    // it obvious that the frame changed rather than the edit.
                    .animation(Motion.gated(Motion.standard, reduceMotion), value: appState.imageURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        if appState.showingOriginal { beforeBadge }
                        else if appState.paintingMaskId != nil { paintingBadge }
                    }
                    .contentShape(Rectangle())
                    // One drag does the right thing: paint (brush armed), else pan (zoomed in).
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if appState.paintingMaskId != nil { appState.paintAt(v.location, container: geo.size) }
                            else if appState.zoom > 1.01 {
                                appState.pan = CGSize(width: panStart.width + v.translation.width,
                                                      height: panStart.height + v.translation.height)
                            }
                        }
                        .onEnded { _ in panStart = appState.pan })
                    // Pinch to zoom (trackpad).
                    .simultaneousGesture(MagnificationGesture()
                        .onChanged { appState.setZoom(zoomStart * $0) }
                        .onEnded { _ in zoomStart = appState.zoom })
                    // Draggable handles for the selected radial / graduated mask.
                    .overlay { maskCanvasOverlay(in: geo.size) }
                    .overlay { subjectHighlightOverlay(in: geo.size) }
                    // Double-click to fit.
                    .onTapGesture(count: 2) { appState.resetZoom(); zoomStart = 1 }
                }
                previewFooter
                if appState.folderPhotos.count > 1 {
                    FilmstripView(photos: appState.visiblePhotos,
                                  current: appState.imageURL,
                                  editedURLs: appState.editedURLs,
                                  thumbnail: appState.thumbnail(for:),
                                  onSelect: { url in Task { await appState.openPhoto(url) } },
                                  onDismiss: { appState.dismiss($0) },
                                  flags: appState.flags,
                                  totalCount: appState.folderPhotos.count,
                                  keeperCount: appState.keeperCount,
                                  rejectCount: appState.rejectCount,
                                  onFlag: { url, flag in appState.setFlag(flag, for: url) },
                                  filter: $appState.stripFilter,
                                  softURLs: Set(appState.focus.filter { $0.value.isSoft }.keys),
                                  softCount: appState.softCount,
                                  scanProgress: appState.focusScanProgress,
                                  onScanFocus: appState.scanFocus,
                                  sharpest: appState.sharpestInRun,
                                  exposureConcerns: appState.exposureConcerns(for:),
                                  scanNote: appState.scanNote(for:),
                                  sortKey: $appState.photoSort,
                                  sortReversed: $appState.photoSortReversed,
                                  grouping: $appState.stripGrouping,
                                  groups: appState.stripGroups,
                                  canGroupByPlace: appState.canGroupByPlace,
                                  sortPending: appState.sortOrderPending,
                                  onExpand: appState.filmstripDidExpand)
                }
            }
            .frame(minWidth: 460)
            .background(Theme.base)

            sidebar
                .frame(width: 360)
                .background(Theme.surface)
        }
    }

    private var beforeBadge: some View {
        Text("BEFORE")
            .font(Theme.mono(11, .semibold)).tracking(2).foregroundColor(Theme.base)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.ink.opacity(0.75))).padding(30)
    }

    private var paintingBadge: some View {
        Text("PAINTING · drag to brush")
            .font(Theme.mono(11, .semibold)).tracking(1).foregroundColor(Theme.base)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.glow.opacity(0.9))).padding(30)
    }

    /// Which subject the pointer is over in the mask list, outlined on the photo. "Person 2" names
    /// nobody until you can see which one it is, and picking the wrong row means an edit landing on
    /// the wrong face.
    @ViewBuilder
    private func subjectHighlightOverlay(in container: CGSize) -> some View {
        if !appState.showingOriginal, let id = appState.highlightedInstanceId,
           let instance = appState.subjectInstances.first(where: { $0.id == id }) {
            let rect = appState.imageRect(in: container)
            SubjectHighlight(instance: instance, imageFrame: rect,
                             normToView: { appState.normToView($0, $1, in: rect) })
        }
    }

    /// Every detected dust spot, ringed, while the pointer is over the Repair controls.
    @ViewBuilder
    private func repairSpotOverlay(in container: CGSize) -> some View {
        if appState.showingRepairSpots, !appState.showingOriginal, !appState.healSpots.isEmpty {
            let rect = appState.imageRect(in: container)
            ZStack(alignment: .topLeading) {
                ForEach(Array(appState.healSpots.enumerated()), id: \.offset) { _, spot in
                    // A RING, not a disc: the point is to see the spot inside it and judge whether
                    // it is dust or a bird. Filling it would hide the only evidence.
                    let centre = appState.normToView(spot.x, spot.y, in: rect)
                    let radius = max(9, spot.radius * min(rect.width, rect.height) * 2.2)
                    Circle()
                        .stroke(Theme.glow.opacity(0.9), lineWidth: 1.5)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(centre)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    /// On-canvas handles for the selected radial / graduated mask — drag directly on the image to
    /// place, size, and rotate the mask instead of nudging sliders.
    @ViewBuilder
    private func maskCanvasOverlay(in container: CGSize) -> some View {
        if !appState.showingOriginal, let mid = appState.selectedUserMaskId,
           let m = appState.userMasks.first(where: { $0.id == mid }) {
            let rect = appState.imageRect(in: container)
            let center = appState.normToView(m.cx, m.cy, in: rect)
            switch m.kind {
            case .radial:
                // Divided by the same framed/source scale `resizeRadial` MULTIPLIES by. `radius`
                // is a fraction of the SOURCE short edge (masks live in source space, before
                // geometry), while `rect` is the FRAMED image on screen — so on a straightened
                // photo, where the auto-crop shrinks the frame, drawing without the divide made
                // the dashed circle jump smaller the instant you dragged the size handle, and stop
                // marking where the effect actually lands.
                let rPx = m.radius * min(rect.width, rect.height) / appState.framedToSourceScale
                Circle().stroke(Theme.glow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(width: rPx * 2, height: rPx * 2).position(center).allowsHitTesting(false)
                handle(at: center) { appState.moveMask(mid, to: appState.viewToNorm($0, in: rect).0,
                                                        appState.viewToNorm($0, in: rect).1) }
                handle(at: CGPoint(x: center.x + rPx, y: center.y), small: true) {
                    appState.resizeRadial(mid, edgeAt: $0, in: rect)
                }
            case .linear:
                let rad = m.angle * .pi / 180
                let dir = CGPoint(x: sin(rad), y: -cos(rad))            // gradient direction (0° = up)
                let perp = CGPoint(x: dir.y, y: -dir.x)
                let len = max(rect.width, rect.height)
                Path { p in
                    p.move(to: CGPoint(x: center.x - perp.x * len, y: center.y - perp.y * len))
                    p.addLine(to: CGPoint(x: center.x + perp.x * len, y: center.y + perp.y * len))
                }.stroke(Theme.glow.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .allowsHitTesting(false)
                handle(at: center) { appState.moveMask(mid, to: appState.viewToNorm($0, in: rect).0,
                                                        appState.viewToNorm($0, in: rect).1) }
                handle(at: CGPoint(x: center.x + dir.x * 54, y: center.y + dir.y * 54), small: true) {
                    appState.rotateLinear(mid, handleAt: $0, in: rect)
                }
            case .instance, .skin:
                // No handles — the shape is the subject's, not something to drag. But show WHICH
                // subject: the sliders below say "Exposure", and on a frame with three people
                // there is otherwise nothing on screen saying whose. A skin mask scoped to one
                // person gets the same box for the same reason; scoped to everyone it has no
                // instanceId, the lookup below finds nothing, and no box is drawn.
                //
                // GATED ON THE OVERLAY TOGGLE, and that is the fix for a real complaint: this box
                // used to be drawn for as long as the mask was selected, with nothing anywhere
                // that would put it away. The Overlay button (O) hid the red and left the box
                // sitting on the photograph, so the only control that removed it was the mask's
                // trash can — which takes the edits with it. The box is a label saying where the
                // mask falls, exactly like the red is, so it belongs to the same switch. The
                // radial and linear guides above are deliberately NOT gated: those are handles you
                // drag, and hiding a control is a different thing from hiding an annotation.
                if appState.showMaskOverlay,
                   let instance = appState.subjectInstances.first(where: { $0.id == m.instanceId }) {
                    SubjectHighlight(instance: instance, imageFrame: rect,
                                     normToView: { appState.normToView($0, $1, in: rect) })
                }
            case .brush, .colorRange, .luminance, .background, .subject:
                EmptyView()
            }
        }
    }

    private func handle(at p: CGPoint, small: Bool = false, onDrag: @escaping (CGPoint) -> Void) -> some View {
        let d: CGFloat = small ? 13 : 17
        return Circle().fill(Theme.glow)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: d, height: d).position(p)
            .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { onDrag($0.location) })
    }

    private var previewFooter: some View {
        let temp = appState.activeTemperature
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(appState.selectedCandidateId?.capitalized ?? "—")
                    .font(Theme.ui(16, .semibold)).foregroundColor(Theme.ink)
                Spacer()
                // Zoom control (pinch or double-click also work).
                HStack(spacing: 6) {
                    Button(action: { appState.showMaskOverlay.toggle(); appState.onEdit() }) {
                        HStack(spacing: 4) {
                            Image(systemName: appState.showMaskOverlay ? "eye.fill" : "eye")
                                .font(.system(size: 10))
                            Text("Overlay")
                                .font(Theme.ui(10, appState.isOverlayShowing ? .semibold : .regular))
                        }
                        .foregroundColor(appState.isOverlayShowing ? Theme.glow : Theme.inkDim)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(
                            Capsule().fill(appState.isOverlayShowing ? Theme.glow.opacity(0.15) : Theme.surface2)
                                .overlay(Capsule().stroke(appState.isOverlayShowing ? Theme.glow.opacity(0.6) : Theme.hairline, lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Toggle Mask Overlay (O)")

                    Button(action: { appState.setZoom(appState.zoom - 0.5); zoomStart = appState.zoom }) {
                        Image(systemName: "minus.magnifyingglass").foregroundColor(Theme.inkDim)
                    }.buttonStyle(.plain)
                    Text("\(Int(appState.zoom * 100))%").font(Theme.mono(10)).foregroundColor(Theme.inkDim).frame(width: 40)
                    Button(action: { appState.setZoom(appState.zoom + 0.5); zoomStart = appState.zoom }) {
                        Image(systemName: "plus.magnifyingglass").foregroundColor(Theme.inkDim)
                    }.buttonStyle(.plain)
                    if appState.zoom > 1.01 {
                        Button(action: { appState.resetZoom(); zoomStart = 1 }) {
                            Text("Fit").font(Theme.ui(10, .semibold)).foregroundColor(Theme.glow)
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
                Text(temp.map { "\(Int($0)) K" } ?? "as-shot")
                    .font(Theme.mono(12))
                    .foregroundColor(temp.map(KelvinScale.color) ?? Theme.inkDim)
            }
            TemperatureRail(marks: temp.map { [($0, true)] } ?? [])
            // Craft self-check: each flagged problem gets a one-click Fix.
            //
            // Deliberately NOT animated. These flags appear and disappear as the craft check
            // re-runs behind a drag, so a transition here would be a row of warnings fading in and
            // out under the photograph the whole time a slider is moving.
            if !appState.activeCraftIssues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    // Only once there is more than one problem. With a single flag the button
                    // beside it says exactly what will happen, and "Fix all" would be the same
                    // click wearing a vaguer word.
                    if appState.activeCraftIssues.count > 1 {
                        HStack(spacing: 8) {
                            Image(systemName: "checklist")
                                .font(.system(size: 10)).foregroundColor(Theme.inkDim)
                            Text("\(appState.activeCraftIssues.count) craft flags")
                                .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                            Spacer(minLength: 4)
                            Button(action: { appState.applyFixAll() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "wand.and.stars")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("Fix all").font(Theme.ui(10, .semibold))
                                }
                                .foregroundColor(Theme.base)
                                .padding(.horizontal, 10).padding(.vertical, 3)
                                .background(Capsule().fill(Theme.glow))
                            }
                            .buttonStyle(.plain)
                            .disabled(appState.fixInProgress)
                            .opacity(appState.fixInProgress ? 0.45 : 1)
                            .animation(Motion.gated(Motion.quick, reduceMotion),
                                       value: appState.fixInProgress)
                            // "frame-wide", because subject flags are excluded by construction:
                            // `CraftFix.deferredForSubject` permanently defers .subjectFlat,
                            // .subjectTooDark and .subjectBlown, while this button appears whenever
                            // there is more than one flag of any kind. On a backlit portrait it was
                            // offering to fix flags it provably would not touch.
                            .help("Work through the frame-wide flags in one step, worst damage "
                                  + "first — clipping, then tone, then colour and skin. "
                                  + "Subject flags keep their own Fix.")
                        }
                    }
                    ForEach(appState.activeCraftIssues, id: \.self) { issue in
                        HStack(spacing: 8) {
                            // Theme.warn, not red: a craft flag is a question for the photographer,
                            // and it wears the same colour as the soft-focus marker in the strip.
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 10)).foregroundColor(Theme.warn)
                            Text(issue.message).font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                            Spacer(minLength: 4)
                            // A FIX BUTTON IS A PROMISE. The subject corrections run into hard
                            // ceilings (±2 EV on the mask), and once one is spent, clicking again
                            // cannot do anything — which is precisely how "I click fix, it applies
                            // a change, I click again, and it never fixes" felt from the outside.
                            // So the button is withdrawn and the row says why instead.
                            if appState.canFix(issue) {
                                Button(action: { appState.applyFix(issue) }) {
                                    Text("Fix").font(Theme.ui(10, .semibold)).foregroundColor(Theme.base)
                                        .padding(.horizontal, 10).padding(.vertical, 3)
                                        .background(Capsule().fill(Theme.glow))
                                }
                                .buttonStyle(.plain)
                                .disabled(appState.fixInProgress)
                                .opacity(appState.fixInProgress ? 0.45 : 1)
                            } else {
                                Text("no fix").font(Theme.mono(9)).foregroundColor(Theme.inkDim)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().stroke(Theme.inkDim.opacity(0.35), lineWidth: 1))
                                    // Two different reasons wore one sentence. A subject flag with
                                    // no person segmentation never had a correction ATTEMPTED —
                                    // saying it "is already as far as it goes" describes a fix that
                                    // never ran. Live case, not a corner: Vision's face detector
                                    // fires on animals, so a cat portrait raises .subjectTooDark
                                    // with hasPerson false.
                                    .help(appState.hasPerson
                                          ? "\(Branding.displayName)'s automatic correction for this is already as far "
                                            + "as it goes — from here it's a manual adjustment"
                                          : "No subject \(Branding.displayName) can isolate in this frame — "
                                            + "this one needs a mask you draw")
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                // Discoverable way to bring in a photo from a different folder. The filmstrip only
                // ever shows the folder you arrived from, so without this the only routes out were
                // ⌘O or a drag — neither of them visible.
                Button(action: appState.chooseAndOpen) { toolbarLabel("Open", filled: false) }
                    .buttonStyle(.plain)
                    .help("Open another photo or folder (⌘O)")
                Button(action: appState.closeCurrentPhoto) { toolbarLabel("Close", filled: false) }
                    .buttonStyle(.plain)
                    .help("Close this photo — your edit is saved")
                // Only when there is something to export. A button that reports "nothing edited yet"
                // is a button that exists to disappoint.
                if appState.editedCount > 0 {
                    Button(action: openExportEditedPanel) {
                        toolbarLabel("Export \(appState.editedCount) edited", filled: false)
                    }
                    .buttonStyle(.plain)
                    .help("Render every photo you have edited in this shoot, each with its own edit")
                }
                Button(action: openBatchPanel) { toolbarLabel("Batch apply", filled: false) }
                    .buttonStyle(.plain)
                // Press and hold to see the untouched original. DragGesture(minimumDistance:0) is
                // a reliable press-and-hold (onLongPressGesture's `pressing` state is flaky).
                toolbarLabel(appState.showingOriginal ? "Original" : "Hold to compare",
                             filled: appState.showingOriginal)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !appState.showingOriginal { appState.showingOriginal = true } }
                        .onEnded { _ in appState.showingOriginal = false })
                Spacer()
                Button(action: openExportPanel) { toolbarLabel("Export full-res", filled: true) }
                    .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(Theme.base)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    /// Deliberately still text-only, unlike every other button in this pass.
    ///
    /// Measured, these five pills already come to 557 pt and the preview pane is only 580 pt wide
    /// when the window is at its 940 pt minimum — and less than that once the splitter is dragged.
    /// A glyph each costs ~20 pt, which buys truncated labels at the app's own default size. An
    /// icon that pushes the word it is helping off the end of the button is not helping.
    private func toolbarLabel(_ text: String, filled: Bool) -> some View {
        Text(text)
            .font(Theme.ui(12, .semibold))
            .foregroundColor(filled ? Theme.base : Theme.ink)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(
                Capsule().fill(filled ? Theme.glow : Theme.surface2)
                    .overlay(Capsule().stroke(filled ? Color.clear : Theme.hairline, lineWidth: 1))
            )
    }

    static func bandColor(_ band: String) -> Color {
        switch band {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "aqua": return .cyan
        case "blue": return .blue
        case "purple": return .purple
        default: return Color(red: 1, green: 0.2, blue: 0.85)   // magenta
        }
    }

    /// What the camera recorded. Read-only — this is the photograph's own history, not something
    /// to edit, so it's presented as a record rather than as controls.
    private var capturePanel: some View {
        let c = appState.capture
        return VStack(alignment: .leading, spacing: 7) {
            if let camera = c.camera {
                Text(camera).font(Theme.ui(12, .medium)).foregroundColor(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lens = c.lens {
                Text(lens).font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = c.summaryText {
                Text(summary).font(Theme.mono(10)).foregroundColor(Theme.glow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let bias = c.exposureBiasText {
                Text("Exposure bias " + bias).font(Theme.mono(9)).foregroundColor(Theme.inkDim)
            }
            if let size = c.dimensionsText {
                Text(size).font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
            }
            if let date = c.captured {
                Text(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short))
                    .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
            }
            if let location = c.locationText {
                // WHERE, AND A WAY OUT TO A MAP — deliberately as a hand-off rather than a map
                // drawn in this window.
                //
                // MapKit renders by fetching tiles from Apple, so an inline map would send this
                // photograph's coordinates off the machine every time you opened the panel. The
                // first line of CLAUDE.md is "Everything runs on-device. No cloud, no account, no
                // upload", and a location is the most sensitive single field in the file. Handing
                // off means Kelvin itself never makes the request: nothing leaves until you click,
                // and then it is Maps doing it, visibly, because you asked.
                //
                // Which is also why the button says "Show in Maps" instead of just being a
                // clickable coordinate. An affordance that quietly leaves the app is the thing
                // being avoided here.
                VStack(alignment: .leading, spacing: 3) {
                    Text(location).font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                        .textSelection(.enabled)
                    if let url = c.mapURL {
                        Link(destination: url) {
                            HStack(spacing: 4) {
                                Image(systemName: "mappin.and.ellipse").font(.system(size: 9))
                                Text("Show in Maps").font(Theme.mono(9))
                            }.foregroundColor(Theme.glow)
                        }
                        .help("Opens Maps with these coordinates. \(Branding.displayName) does not fetch anything itself.")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Selectable HERE and not app-wide: enabling it globally let text selection swallow
        // clicks meant for buttons and sliders. This panel is the one place with values worth
        // pasting somewhere else — a lens name, coordinates, the pixel dimensions.
        .textSelection(.enabled)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline.opacity(0.6), lineWidth: 1))
        )
    }

    private func lookChip(_ look: LookPreset) -> some View {
        let on = appState.activeLookId == look.id
        return Button(action: { appState.applyLook(on ? nil : look.id) }) {
            Text(look.name)
                .font(Theme.ui(11, on ? .semibold : .regular))
                .foregroundColor(on ? Theme.base : Theme.ink)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(
                    Capsule().fill(on ? Theme.glow : Theme.surface2)
                        .overlay(Capsule().stroke(on ? Color.clear : Theme.hairline, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        // The chip settling into "on" is the same class of feedback as a candidate becoming
        // selected, and wears the same 0.14s.
        .animation(Motion.gated(Motion.quick, reduceMotion), value: on)
        .help(look.blurb)
    }

    private func editToolLabel(_ text: String, enabled: Bool, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(Theme.ui(11, .semibold))
        }
        .foregroundColor(enabled ? Theme.ink : Theme.inkFaint)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7).fill(Theme.surface2.opacity(enabled ? 1 : 0.4))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
        )
    }

    /// The mask buttons are a 3×3 grid of near-identical capsules, and "+ Luma" next to "+ Skin"
    /// next to "+ Colour" is a paragraph to be read rather than a palette to be reached into. The
    /// glyph says what kind of selection you are about to make; the word stays because a picture
    /// of a mask type is not a name for one.
    private func addMaskLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Theme.inkDim)
            Text(text)
                .font(Theme.ui(11, .semibold)).foregroundColor(Theme.ink)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface2)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
        )
    }

    private var sidebar: some View {
        let ch = appState.onEdit   // re-render on any slider change
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HistogramView(image: appState.lastRenderedCI)

                HStack(spacing: 8) {
                    Button(action: appState.undo) { editToolLabel("Undo", enabled: appState.canUndo, icon: "arrow.uturn.backward") }
                        .buttonStyle(.plain).disabled(!appState.canUndo)
                        .keyboardShortcut("z", modifiers: .command)
                    Button(action: appState.redo) { editToolLabel("Redo", enabled: appState.canRedo, icon: "arrow.uturn.forward") }
                        .buttonStyle(.plain).disabled(!appState.canRedo)
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    Spacer()
                    // "Reset sliders", not "Reset all": `resetToCandidate` restores the global
                    // adjustments, straighten, HSL, the look and the auto-mask dictionaries — and
                    // deliberately leaves hand-drawn masks and dust removal alone. Three brush masks
                    // surviving a button called "Reset all" is a broken promise; renaming the button
                    // is the honest fix, because silently deleting someone's masks would be worse.
                    Button(action: appState.resetToCandidate) { editToolLabel("Reset sliders", enabled: true, icon: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                }

                Group {
                CollapsibleSection("Candidates", icon: "rectangle.stack", defaultOpen: true) {
                // WHAT IT SAW, above what it proposes — so the panel reads as a chain of reasoning
                // rather than four options from nowhere.
                //
                // This is the app's only account of itself. Everything below is computed from the
                // read: if a candidate comes out wrong, this is what tells you whether the READ was
                // wrong ("golden hour" on an overcast morning) or the MAPPING was (a correct read
                // turned into the wrong numbers). Those are entirely different bugs and, without
                // this, indistinguishable from the outside.
                if let seen = appState.sceneSummary {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(seen.headline)
                            .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                            .textSelection(.enabled)
                        if let note = seen.note {
                            Text(note)
                                .font(Theme.ui(11)).foregroundColor(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                }
                if appState.candidates.isEmpty {
                    // Say what's happening instead of leaving a hole. The photo is already on
                    // screen, so this is the only part still pending.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the scene…")
                            .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                    }
                    .padding(.vertical, 6)
                }
                VStack(spacing: 8) {
                    ForEach(appState.candidates) { candidate in
                        CandidateRow(candidate: candidate,
                                     isSelected: candidate.id == appState.selectedCandidateId) {
                            appState.selectCandidate(id: candidate.id)
                        }
                    }
                }
                }

                CollapsibleSection("Looks", icon: "camera.filters", trailing: appState.activeLookId == nil ? nil : "On") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(LookPreset.Group.allCases, id: \.self) { group in
                        let looks = LookPreset.library.filter { $0.group == group }
                        if !looks.isEmpty {
                            Text(group.rawValue.uppercased())
                                .font(Theme.mono(9)).tracking(1.4).foregroundColor(Theme.inkFaint)
                            FlowRow(looks.map(\.id)) { id in
                                if let look = LookPreset.named(id) {
                                    lookChip(look)
                                }
                            }
                        }
                    }
                    if appState.activeLookId != nil {
                        Button(action: { appState.applyLook(nil) }) {
                            Text("Clear look").font(Theme.ui(10, .semibold)).foregroundColor(Theme.inkDim)
                        }.buttonStyle(.plain)
                    }
                }
                }

                // LIGHT — white balance and tone together. They are one decision: how the frame
                // is exposed and coloured by its light source. Open by default because this is
                // what gets touched on essentially every photograph.
                CollapsibleSection("Light", icon: "sun.max", defaultOpen: true) {
                VStack(spacing: 14) {
                    ToneSlider(label: "Temp", value: appState.temperatureBinding, range: 2500...9500, step: 10, unit: " K", onChange: ch, identity: .temperature, neutral: 6500)
                    ToneSlider(label: "Tint", value: $appState.edit.tint, range: -100...100, step: 1, unit: "", onChange: ch, identity: .tint)
                    Divider().overlay(Theme.hairline).padding(.vertical, 2)
                    ToneSlider(label: "Exposure", value: $appState.edit.exposureEV, range: -5...5, step: 0.05, unit: " EV", onChange: ch, identity: .exposure)
                    ToneSlider(label: "Contrast", value: $appState.edit.contrast, range: -100...100, step: 1, unit: "", onChange: ch, identity: .contrast)
                    // RECOVERY ONLY, exactly as the masked version already is. `CIHighlightShadowAdjust`
                    // documents its highlight amount as 0…1 with 1.0 meaning no change, so the
                    // renderer's `1.0 + highlights/100` clamps for every positive value and does
                    // nothing — measured at ΔE 0.0 when this was found on the mask panel. The
                    // global slider went through byte-identical code and was left at full range,
                    // so half its travel moved a number and not the photograph.
                    ToneSlider(label: "Highlight recovery", value: $appState.edit.highlights, range: -100...0, step: 1, unit: "", onChange: ch, identity: .highlights)
                    ToneSlider(label: "Shadows", value: $appState.edit.shadows, range: -100...100, step: 1, unit: "", onChange: ch, identity: .shadows)
                    ToneSlider(label: "Whites", value: $appState.edit.whites, range: -100...100, step: 1, unit: "", onChange: ch, identity: .highlights)
                    ToneSlider(label: "Blacks", value: $appState.edit.blacks, range: -100...100, step: 1, unit: "", onChange: ch, identity: .shadows)
                }
                }

                }
                Group {
                CollapsibleSection("Presence", icon: "sun.haze") {
                VStack(spacing: 14) {
                    ToneSlider(label: "Texture", value: $appState.edit.texture, range: -100...100, step: 1, unit: "", onChange: ch, identity: .presence)
                    ToneSlider(label: "Clarity", value: $appState.edit.clarity, range: -100...100, step: 1, unit: "", onChange: ch, identity: .presence)
                    ToneSlider(label: "Dehaze", value: $appState.edit.dehaze, range: 0...100, step: 1, unit: "", onChange: ch, identity: .presence)
                    // Fusion lives in Presence but is not one: it opens the shadows and holds the
                    // highlights, so it wears the shadow rail rather than the haze one.
                    ToneSlider(label: "Fusion", value: $appState.edit.fusion, range: 0...100, step: 1, unit: "", onChange: ch, identity: .shadows)
                }
                }

                // COLOUR — the global pair and the per-colour mixer are the same decision at two
                // levels of detail, so they live together rather than as two headings.
                CollapsibleSection("Colour", icon: "paintpalette") {
                VStack(spacing: 14) {
                    ToneSlider(label: "Vibrance", value: $appState.edit.vibrance, range: -100...100, step: 1, unit: "", onChange: ch, identity: .saturation(hue: nil))
                    ToneSlider(label: "Saturation", value: $appState.edit.saturation, range: -100...100, step: 1, unit: "", onChange: ch, identity: .saturation(hue: nil))
                }
                VStack(spacing: 12) {
                    Divider().overlay(Theme.hairline).padding(.vertical, 2)
                    HStack(spacing: 6) {
                        ForEach(appState.hslBands, id: \.self) { band in
                            Circle().fill(Self.bandColor(band))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(appState.hslBand == band ? Theme.ink : Theme.hairline,
                                                         lineWidth: appState.hslBand == band ? 2.5 : 1))
                                .overlay(Circle().stroke(.white.opacity(appState.hsl[band] != nil ? 0.9 : 0), lineWidth: 1).padding(3))
                                .onTapGesture { appState.hslBand = band }
                        }
                    }
                    // The mixer's rails follow the selected band, so the panel shows which colour is
                    // under the knife — the swatch row above says which band, not what it does.
                    ToneSlider(label: "Hue", value: appState.hslBinding(\.h), range: -100...100, step: 1, unit: "", onChange: ch,
                               identity: .hueShift(center: ToneIdentity.bandHue(appState.hslBand)))
                    ToneSlider(label: "Saturation", value: appState.hslBinding(\.s), range: -100...100, step: 1, unit: "", onChange: ch,
                               identity: .saturation(hue: ToneIdentity.bandHue(appState.hslBand)))
                    ToneSlider(label: "Luminance", value: appState.hslBinding(\.l), range: -100...100, step: 1, unit: "", onChange: ch, identity: .exposure)
                }
                }

                CollapsibleSection("Geometry", icon: "crop.rotate") {
                VStack(spacing: 12) {
                    ToneSlider(label: "Straighten", value: $appState.straighten, range: -15...15, step: 0.1, unit: "°", onChange: ch)
                    Button(action: appState.autoStraighten) { addMaskLabel("Auto-level horizon", icon: "level") }
                        .buttonStyle(.plain)
                }
                }

                CollapsibleSection("Masks", icon: "circle.dashed", trailing: appState.maskCountLabel) {
                VStack(spacing: 12) {
                    // The subjects Kelvin found, first — before the shapes you have to draw
                    // yourself. Picking a thing out of a list is the cheap path and it should be
                    // the one you meet first; the geometry below is the fallback for when the
                    // segmentation has not found what you meant.
                    if !appState.subjectInstances.isEmpty {
                        SubjectList(instances: appState.subjectInstances,
                                    maskedIds: appState.maskedInstanceIds,
                                    highlighted: $appState.highlightedInstanceId,
                                    onPick: appState.addInstanceMask)
                    }
                    // Auto-detected masks (subject / sky): toggle + strength.
                    ForEach(appState.baseMaskIds, id: \.self) { mid in
                        MaskControl(
                            name: mid.capitalized,
                            isOn: Binding(get: { appState.maskEnabled[mid] ?? true },
                                          set: { appState.maskEnabled[mid] = $0 }),
                            strength: Binding(get: { appState.maskStrength[mid] ?? 100 },
                                              set: { appState.maskStrength[mid] = $0 }),
                            onChange: appState.onEdit,
                            maskId: mid,
                            adjustment: { key in appState.maskAdjustmentBinding(mid, key) },
                            feather: appState.maskFeatherBinding(mid),
                            tightness: appState.maskTightnessBinding(mid),
                            invert: appState.maskInvertBinding(mid),
                            onReset: { appState.resetMask(mid) },
                            // Selectable, like every other mask. Without this an auto mask could
                            // be shown by the overlay but never named by the selection, so the
                            // sky came up red with nothing to click and no way to clear it.
                            isSelected: appState.selectedMask == .auto(mid),
                            onSelect: {
                                // The eye is "show me this one", so it arms the overlay as well as
                                // selecting. Clicking the same eye again clears the selection, and
                                // with nothing selected the overlay draws nothing — which is the
                                // off switch the auto masks never had.
                                if appState.selectedMask == .auto(mid) {
                                    appState.selectedMask = nil
                                } else {
                                    appState.selectedMask = .auto(mid)
                                    appState.showMaskOverlay = true
                                }
                                appState.onEdit()
                            },
                            onAdjustBegin: { appState.isAdjustingMaskTone = true },
                            onAdjustEnd: { appState.isAdjustingMaskTone = false; appState.onEdit() })
                    }
                    // Hand-drawn masks: gradient geometry or brush strokes + local adjustments.
                    ForEach($appState.userMasks) { $m in
                        UserMaskEditor(
                            mask: $m, onChange: appState.onEdit,
                            onDelete: { appState.removeUserMask(m.id) },
                            isSelected: appState.selectedUserMaskId == m.id,
                            // `onEdit()` is what rebuilds the render, and the render is what
                            // chooses the overlay bitmap — without it the red stayed on the
                            // previously selected mask until you happened to nudge a slider.
                            onSelect: { appState.selectedUserMaskId = m.id; appState.onEdit() },
                            onToggleSelected: { appState.toggleMaskSelection(m.id) },
                            isPainting: appState.paintingMaskId == m.id,
                            togglePaint: { appState.paintingMaskId = (appState.paintingMaskId == m.id) ? nil : m.id },
                            clearStrokes: { appState.clearStrokes(m.id) },
                            brushRadius: Binding(get: { appState.brushRadius },
                                                 set: { appState.brushRadius = $0 }),
                            hasPerson: appState.hasPerson,
                            people: appState.subjectInstances.filter { $0.kind == .person },
                            onAdjustBegin: { appState.isAdjustingMaskTone = true },
                            onAdjustEnd: { appState.isAdjustingMaskTone = false },
                            canMoveUp: appState.userMasks.first?.id != m.id,
                            canMoveDown: appState.userMasks.last?.id != m.id,
                            onMoveUp: { appState.moveUserMask(m.id, by: -1) },
                            onMoveDown: { appState.moveUserMask(m.id, by: 1) })
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        // The "+" used to be repeated on all eight buttons. Said once over the
                        // grid it costs a line and buys every button back the width its glyph
                        // needs — and the row stops reading as a list of things called "+ Luma".
                        Text("ADD A MASK — PICK WHAT DEFINES THE REGION")
                            .font(Theme.mono(9)).tracking(1.4).foregroundColor(Theme.inkFaint)
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.radial) }) { addMaskLabel("Radial", icon: "circle.circle") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.linear) }) { addMaskLabel("Grad", icon: "rectangle.tophalf.filled") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.brush) }) { addMaskLabel("Brush", icon: "paintbrush") }.buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.colorRange) }) { addMaskLabel("Colour", icon: "eyedropper") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.luminance) }) { addMaskLabel("Luma", icon: "circle.lefthalf.filled") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.skin) }) { addMaskLabel("Skin", icon: "face.smiling") }.buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.subject) }) { addMaskLabel("Subject", icon: "person.fill") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.background) }) { addMaskLabel("Background", icon: "photo") }.buttonStyle(.plain)
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                // A new mask panel is tall, and it lands above the buttons you just clicked, which
                // pushes them down the panel. Fading it in over the layout move is the difference
                // between "where did the buttons go" and seeing what arrived. Keyed on the COUNT:
                // adjusting a mask must never animate anything.
                .animation(Motion.gated(Motion.quick, reduceMotion), value: appState.userMasks.count)
                }

                CollapsibleSection("Repair", icon: "bandage", trailing: appState.detectedSpotCount > 0 ? "\(appState.detectedSpotCount) spots" : nil) {
                Toggle(isOn: $appState.removeDust) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove dust spots").font(Theme.ui(13, .medium)).foregroundColor(Theme.ink)
                        Text(appState.detectedSpotCount > 0
                             ? "Patch \(appState.detectedSpotCount) detected spot\(appState.detectedSpotCount == 1 ? "" : "s") from nearby pixels"
                             : "No spots detected on this frame")
                            .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                    }
                }
                .toggleStyle(.switch).tint(Theme.glow)
                .disabled(appState.detectedSpotCount == 0)
                // Hovering the control rings every spot it would patch. Nothing to switch on, and
                // nothing left on the photograph once the pointer moves away.
                .onHover { appState.showingRepairSpots = $0 && appState.detectedSpotCount > 0 }
                if appState.detectedSpotCount > 0 {
                    Text("Hover to see where they are · hold Compare to see them back")
                        .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                }
                }

                // Last: a record of the photograph, not a control reached for mid-edit.
                if appState.capture.camera != nil || appState.capture.summaryText != nil {
                    // Open by default. This is the one section that is pure information rather
                    // than a control — what the camera recorded, which you read to decide what to
                    // do, not something you fold away once you have set it.
                    CollapsibleSection("Capture", icon: "camera", defaultOpen: true) { capturePanel }
                }
                }
            }
            .padding(20)
        }
    }

    /// A sidebar section that can be folded away, remembering its state between launches.
    ///
    /// The panel had eleven sections stacked in one scroll, every one of them always open. Most of
    /// them are not touched on most photos, so reaching the ones that are meant scrolling past the
    /// rest — and the sheer wall of controls is the thing that makes an editor feel heavy. Folded
    /// by default, the panel shows what you actually reach for and hides the rest until asked.
    private struct CollapsibleSection<Content: View>: View {
        let title: String
        /// One SF Symbol per section. Folded, the panel is nine near-identical rows of tracked-out
        /// capitals; a glyph gives each row a silhouette, so the section you want is found by shape
        /// before the word is read. It is drawn faint and fixed-width on purpose — a label that has
        /// to compete with its own icon has been made harder to read, not easier.
        let icon: String
        var trailing: String?
        var accent: Bool = false
        @AppStorage private var isOpen: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ViewBuilder let content: () -> Content

        init(_ title: String, icon: String, trailing: String? = nil, accent: Bool = false,
             defaultOpen: Bool = false, @ViewBuilder content: @escaping () -> Content) {
            self.title = title
            self.icon = icon
            self.trailing = trailing
            self.accent = accent
            // Keyed by title so a section keeps its state across launches. Sections a photographer
            // opens once tend to be ones they want open every time.
            self._isOpen = AppStorage(wrappedValue: defaultOpen, "sidebar.section.\(title)")
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    withAnimation(Motion.gated(Motion.quick, reduceMotion)) { isOpen.toggle() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.inkFaint)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundColor(isOpen ? Theme.inkDim : Theme.inkFaint)
                            // Fixed width so every title starts on the same left edge whatever the
                            // glyph is; the column of words has to stay a column.
                            .frame(width: 13)
                        Text(title.uppercased())
                            .font(Theme.mono(10, .semibold)).tracking(2)
                            .foregroundColor(isOpen ? Theme.ink : Theme.inkDim)
                        Spacer()
                        if let trailing {
                            Text(trailing.uppercased())
                                .font(Theme.mono(9, .semibold)).tracking(1.5)
                                .foregroundColor(Theme.glow)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.glow.opacity(0.14)))
                        }
                    }
                    .contentShape(Rectangle())    // the whole row is the target, not just the text
                }
                .buttonStyle(.plain)

                // Fade rather than slide: the section below is already moving to make room, and
                // two things travelling at once for one click is one too many.
                if isOpen { content().transition(.opacity) }
            }
        }
    }

    private func sectionLabel(_ text: String, trailing: String?) -> some View {
        HStack {
            Text(text.uppercased())
                .font(Theme.mono(10, .semibold)).tracking(2).foregroundColor(Theme.inkDim)
            Spacer()
            if let trailing {
                Text(trailing.uppercased())
                    .font(Theme.mono(9, .semibold)).tracking(1.5)
                    .foregroundColor(Theme.glow)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.glow.opacity(0.14)))
            }
        }
    }

    private var batchSheet: some View {
        VStack(spacing: 18) {
            Text("Batch complete").font(Theme.ui(18, .semibold)).foregroundColor(Theme.ink)
            if let outcome = appState.batchOutcome {
                // THREE numbers, because Outcome has three and this showed two — with the wrong
                // word on one of them. `failed` (a decode, render or write that threw) was printed
                // under the label "skipped" in a calm blue, and `skippedCount` (a collision, where
                // the existing file was deliberately left alone) was never shown at all. A batch
                // that threw on forty frames told the photographer forty were skipped.
                HStack(spacing: 28) {
                    stat("\(outcome.succeeded)", "applied", Theme.glow)
                    if outcome.skippedCount > 0 {
                        stat("\(outcome.skippedCount)", "skipped", Theme.inkDim)
                    }
                    stat("\(outcome.failed)", "failed", outcome.failed > 0 ? Theme.warn : Theme.inkFaint)
                }
            }
            Button(action: { appState.showBatchSheet = false }) { toolbarLabel("Done", filled: true) }
                .buttonStyle(.plain)
        }
        .padding(32).frame(width: 320).background(Theme.surface)
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(Theme.mono(30, .medium)).foregroundColor(color)
            Text(label.uppercased()).font(Theme.mono(9)).tracking(1.5).foregroundColor(Theme.inkDim)
        }
    }

    // MARK: File panels

    private func openExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .png]
        // Suggest a name that says what the photo IS — still fully editable in the panel.
        panel.nameFieldStringValue = appState.suggestedExportName(ext: appState.exportFormat.fileExtension)
        // The one thing about an export that is not visible in the file you get back.
        //
        // In the panel rather than in the sidebar, because it is a property of THIS export and the
        // moment you are deciding it is the moment you are choosing where the file goes. It also
        // covers the batch, which writes hundreds of files from the same setting — so the checkbox
        // that says what travels has to be somewhere you meet before either.
        panel.accessoryView = PanelAccessories.exportOptions(appState)
        if panel.runModal() == .OK, let url = panel.url {
            Task { await appState.exportFullResolution(to: url) }
        }
    }

    /// Where the edited photographs go.
    ///
    /// A save panel rather than a folder chooser, so the destination arrives PRE-NAMED and visible:
    /// it opens on the shoot's own folder with "Edited" already typed. The principle is that nothing
    /// is ever written somewhere the user has not seen named — but they should not have to type it
    /// either, and the answer is the same nine times in ten.
    ///
    /// Writing into the shoot's own folder is refused downstream by `Destination.prepare`, which
    /// compares filesystem identity; a subfolder is safe and the originals cannot be touched.
    private func openExportEditedPanel() {
        let panel = NSSavePanel()
        panel.title = "Export edited photos"
        panel.message = "Choose a folder for the edited copies. Your originals are never modified."
        panel.nameFieldLabel = "Folder:"
        panel.nameFieldStringValue = "Edited"
        panel.canCreateDirectories = true
        if let folder = appState.imageURL?.deletingLastPathComponent() {
            panel.directoryURL = folder
        }
        panel.accessoryView = PanelAccessories.exportOptions(appState, showScope: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        Task { await appState.exportEdited(to: target) }
    }

    private func openBatchPanel() {
        // The look is checked BEFORE any panel opens. The old order let someone choose two
        // folders and only then learn nothing would happen — the guard inside runBatchApply
        // even complained about it in a comment, while still being the only guard.
        guard let styleId = appState.selectedCandidateId,
              let style = CandidateStyle.all.first(where: { $0.id == styleId }) else {
            appState.statusMessage = "Pick a look first — Batch apply adapts the one you have chosen"
            return
        }

        // A shoot is already open, so it IS the input — asking someone to re-choose the folder
        // they are looking at reads as a different feature. One panel: where the copies go.
        if appState.folderPhotos.count > 1 {
            let output = NSOpenPanel()
            output.title = "Batch apply \(style.label)"
            output.message = "Each of the \(appState.folderPhotos.count) photos in this shoot is read "
                + "and corrected on its own — \(style.label) and your tweaks are adapted per frame, "
                + "not copied. Choose where the edited copies go; your originals are never touched."
            output.prompt = "Apply \(style.label)"
            output.canChooseDirectories = true; output.canChooseFiles = false
            output.canCreateDirectories = true
            output.accessoryView = PanelAccessories.batchOptions(appState)
            output.isAccessoryViewDisclosed = true
            guard output.runModal() == .OK, let outputDir = output.url else { return }
            let files = appState.batchTargets(keepersOnly: appState.batchKeepersOnly)
            Task { await appState.runBatchApply(files: files, outputDir: outputDir) }
            return
        }

        // No shoot open: the original two-panel flow, which now says what each panel is for.
        let input = NSOpenPanel()
        input.title = "Batch apply \(style.label) — choose the shoot folder"
        input.message = "Every photo in the folder you choose is read and corrected on its own, "
            + "with \(style.label) and your tweaks adapted to each frame."
        input.prompt = "Choose shoot"
        input.canChooseDirectories = true; input.canChooseFiles = false
        guard input.runModal() == .OK, let inputDir = input.url else { return }
        let output = NSOpenPanel()
        output.title = "Choose where to write the edited copies"
        output.message = "Copies land here; the originals in the shoot folder are never touched."
        output.prompt = "Apply \(style.label)"
        output.canChooseDirectories = true; output.canChooseFiles = false; output.canCreateDirectories = true
        guard output.runModal() == .OK, let outputDir = output.url else { return }
        Task { await appState.runBatchApply(inputDir: inputDir, outputDir: outputDir) }
    }
}

// MARK: - Candidate row

struct CandidateRow: View {
    let candidate: CandidateViewModel
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var temp: Double? { candidate.baseRecipe.global.temperatureK }

    /// What makes THIS candidate different from the others, in at most three numbers.
    ///
    /// The row used to show exposure and nothing else, which made four genuinely different options
    /// describe themselves identically: `RecipeEngine.exposure` deliberately returns exactly zero for
    /// any frame whose median luma sits between 0.30 and 0.60 — "leave a reasonably-exposed frame
    /// alone" — and that band covers most competently exposed photographs. So the picker was
    /// reporting the one value designed not to move, while the contrast and vibrance that actually
    /// separate Natural from Dramatic went unmentioned.
    ///
    /// Ordered by how much a photographer would notice, not by magnitude: exposure first when it is
    /// doing anything, then contrast, then colour. Empty means this candidate really is a no-op,
    /// which is worth saying out loud rather than dressing up as "+0.00 EV".
    private var signature: String {
        let g = candidate.baseRecipe.global
        var parts: [String] = []
        if abs(g.exposureEV) >= 0.01 { parts.append(String(format: "%+.2f EV", g.exposureEV)) }
        if abs(g.contrast) >= 1 { parts.append(String(format: "%+.0f contrast", g.contrast)) }
        if abs(g.vibrance) >= 1 { parts.append(String(format: "%+.0f vibrance", g.vibrance)) }
        else if abs(g.saturation) >= 1 { parts.append(String(format: "%+.0f saturation", g.saturation)) }
        if parts.isEmpty, abs(g.highlights) >= 1 {
            parts.append(String(format: "%+.0f highlights", g.highlights))
        }
        return parts.isEmpty ? "as shot" : parts.prefix(3).joined(separator: " · ")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(nsImage: candidate.previewImage)
                    .resizable().scaledToFill()
                    .frame(width: 62, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    Text(candidate.label)
                        .font(Theme.ui(14, .semibold))
                        .foregroundColor(isSelected ? Theme.ink : Theme.inkDim)
                    Text(signature)
                        .font(Theme.mono(10)).foregroundColor(Theme.inkFaint)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Circle().fill(temp.map(KelvinScale.color) ?? Theme.inkFaint)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
                    Text(temp.map { "\(Int($0))K" } ?? "as-shot")
                        .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                }
            }
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.surface2 : Theme.surface.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(isSelected ? Theme.glow : Theme.hairline.opacity(0.6),
                                lineWidth: isSelected ? 1.5 : 1))
            )
        }
        .buttonStyle(.plain)
        // Picking a candidate is the one act this whole app is built around, and the selection
        // moves between rows — so the border and fill hand over rather than cutting. Colour and
        // stroke width only: no scale, no shadow, nothing that would make a row jump at the eye
        // while it is being compared against the photograph.
        .animation(Motion.gated(Motion.quick, reduceMotion), value: isSelected)
    }
}

// MARK: - Histogram (live tonal distribution + clipping)

struct HistogramView: View {
    let image: CIImage?

    var body: some View {
        Canvas { ctx, size in
            guard let bins = Self.luma(image), let peak = bins.max(), peak > 0 else { return }
            let n = bins.count
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in bins.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(n - 1)
                let y = size.height * (1 - CGFloat(min(1, v / peak * 1.05)))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.55), .white.opacity(0.12)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            // Clipping flags: a dab at each end when pixels pile at pure black / white.
            if (bins.first ?? 0) / peak > 0.5 {
                ctx.fill(Path(CGRect(x: 0, y: 0, width: 4, height: size.height)), with: .color(.blue.opacity(0.6)))
            }
            if (bins.last ?? 0) / peak > 0.5 {
                ctx.fill(Path(CGRect(x: size.width - 4, y: 0, width: 4, height: size.height)), with: .color(.red.opacity(0.6)))
            }
        }
        .frame(height: 54)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)))
    }

    /// 64-bin luma histogram sampled from the rendered proxy.
    ///
    /// The comment here used to say "Cheap (100×100 sample)" and it was not: `rgba8Sampled`
    /// rasterises the image at its FULL extent and only then downsamples, so asking for 100×100
    /// rendered all 1200 px of the proxy first. That happened inside a `Canvas` draw closure — the
    /// main thread — on every render, which means on every tick of every slider drag.
    ///
    /// Scaling the CIImage down BEFORE the raster makes the claim true. Done here rather than in
    /// `rgba8Sampled` because a dozen measurement paths depend on that function's exact resampling,
    /// and this is a histogram: a few bins of difference are invisible, whereas silently moving
    /// `FaceSkin` or `SubjectMask` numbers is how a calibrated threshold stops meaning what it did.
    static func luma(_ image: CIImage?) -> [Double]? {
        guard let image else { return nil }
        let small = PerceptionProxy.downsample(image, maxEdge: 100)
        guard let data = try? ImageWriter.rgba8Sampled(small, width: 100, height: 100) else { return nil }
        var bins = [Double](repeating: 0, count: 64)
        data.withUnsafeBytes { rp in
            let px = rp.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) {
                let l = 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
                bins[min(63, Int(l / 256 * 64))] += 1
            }
        }
        return bins
    }
}

// MARK: - Tone slider (instrument readout)

/// What a control *does*, said in colour and light. Every slider used to be the same orange track,
/// so Temp and Contrast were the same object with different words on top; the rail under the knob
/// makes the action legible before the label is read.
///
/// The identity describes the ACTION, never the value — the value stays in the knob position and
/// the monospaced readout, so nothing here is the only way to read the control.
enum ToneIdentity {
    /// Geometry, softness, feather: no honest reading in light. Left exactly as it was — a rail
    /// that says nothing is decoration, and decoration in a darkroom panel costs attention the
    /// photograph should be getting.
    case plain
    case temperature
    case tint
    case exposure
    case contrast
    /// Highlights and Shadows both brighten to the right, as the knob does. What separates them is
    /// which end of the scale they work in, so that — not direction — is what the rails show.
    case highlights
    case shadows
    /// Chroma rising left to right. `hue` nil means every hue at once, i.e. the global pair.
    case saturation(hue: Double?)
    /// The mixer rotating one band: the rail is that band and the neighbours it can reach.
    case hueShift(center: Double)
    /// The whole hue circle as a selection axis (the colour-range mask picks a point on it).
    case spectrum
    /// Haze → definition. The quietest of the family on purpose: clarity and texture are small
    /// effects, and a loud rail would oversell them.
    case presence

    /// Hue angles for the mixer's eight bands. Deliberately not derived from `bandColor` — that
    /// vends system colours for the swatches, and a rail has to interpolate toward a band's
    /// neighbours, which needs an angle rather than a swatch.
    static func bandHue(_ band: String) -> Double {
        switch band {
        case "red":    return 0
        case "orange": return 30
        case "yellow": return 55
        case "green":  return 120
        case "aqua":   return 185
        case "blue":   return 225
        case "purple": return 280
        default:       return 320   // magenta
        }
    }

    /// The mask panel builds its sliders from `maskAdjustmentSpecs`, so it identifies them by key
    /// rather than at the call site.
    static func adjustment(_ key: String) -> ToneIdentity {
        switch key {
        case "exposure_ev":            return .exposure
        case "highlights":             return .highlights
        case "shadows":                return .shadows
        case "contrast":               return .contrast
        case "saturation", "vibrance": return .saturation(hue: nil)
        default:                       return .plain
        }
    }
}

/// The axis a slider's knob travels along, drawn as light.
///
/// It sits below the native track rather than behind it, for two reasons: the knob keeps its own
/// contrast against the system track no matter how dark the rail gets, and the gradient reads as a
/// scale the knob moves along instead of as a second value indicator. Everything is muted to
/// roughly the temperature rail's weight — the sidebar sits next to a photograph and must not
/// compete with it.
struct ToneRail: View {
    let identity: ToneIdentity

    private static let thickness: CGFloat = 4

    // A quiet, slightly desaturated palette: full-strength hues next to a near-black panel read as
    // toy UI, and the greys need more alpha than the colours to register at all.
    private static let greenTint   = Color(hex: 0x6FB98A)
    private static let neutralTint = Color(hex: 0xB6BCC5)
    private static let magentaTint = Color(hex: 0xC182B4)
    private static let ashDark     = Color(hex: 0x1C1F26)
    private static let ashMid      = Color(hex: 0x707783)
    private static let ashLight    = Color(hex: 0xE6E9EE)
    private static let flatGrey    = Color(hex: 0x7A8089)

    var body: some View {
        switch identity {
        case .plain:
            EmptyView()

        // The app's own Kelvin scale, oriented as the signature rail orients it: low K (amber) at
        // the left, high K (blue) at the right. Reusing it keeps one colour-temperature ramp in
        // the product rather than two that drift apart.
        case .temperature:
            bar(KelvinScale.gradient, opacity: 0.55)

        case .tint:
            bar(gradient([Self.greenTint, Self.neutralTint, Self.magentaTint]), opacity: 0.5)

        case .exposure:
            bar(gradient([Self.ashDark, Self.ashMid, Self.ashLight]), opacity: 0.7)

        // Contrast is the one control whose action is a *spread*, so the rail splits: flat and
        // identical at the left, opening toward black and white as the knob moves right.
        case .contrast:
            VStack(spacing: 1) {
                halfBar([Self.flatGrey, Color(hex: 0xA8AFB9), Color(hex: 0xF3F5F8)])
                halfBar([Self.flatGrey, Color(hex: 0x555B65), Color(hex: 0x0E1014)])
            }
            .accessibilityHidden(true)

        case .highlights:
            bar(gradient([Color(hex: 0x5C626C), Color(hex: 0xA9B0BA), Color(hex: 0xF1F3F6)]), opacity: 0.7)

        case .shadows:
            bar(gradient([Color(hex: 0x171A20), Color(hex: 0x4A5058), Color(hex: 0x9AA1AB)]), opacity: 0.7)

        // Constant brightness, rising chroma: grey at the left, colour at the right, which is the
        // whole of what the control does. Brightness is held flat on purpose so it cannot be
        // mistaken for one of the tonal rails.
        case .saturation(let hue):
            bar(Self.chromaRamp(hue: hue), opacity: 0.6)

        case .hueShift(let center):
            bar(gradient([Self.muted(center - 55), Self.muted(center), Self.muted(center + 55)]), opacity: 0.5)

        case .spectrum:
            bar(Self.spectrum, opacity: 0.45)

        // Stops bunched to the right: flat and hazy across most of the travel, separating only as
        // the effect starts to bite. Cool and stopping short of white, so it reads as atmosphere
        // clearing rather than as one more brightness ramp.
        case .presence:
            bar(LinearGradient(stops: [
                .init(color: Color(hex: 0x36404E), location: 0),
                .init(color: Color(hex: 0x414C5B), location: 0.55),
                .init(color: Color(hex: 0xA3B2C4), location: 1)
            ], startPoint: .leading, endPoint: .trailing), opacity: 0.6)
        }
    }

    private func bar(_ fill: some ShapeStyle, opacity: Double) -> some View {
        Capsule().fill(fill)
            .frame(height: Self.thickness)
            .opacity(opacity)
            .accessibilityHidden(true)
    }

    private func halfBar(_ colors: [Color]) -> some View {
        Capsule().fill(gradient(colors))
            .frame(height: (Self.thickness - 1) / 2)
            .opacity(0.85)
    }

    private func gradient(_ colors: [Color]) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }

    /// A hue at instrument strength rather than screen-primary strength.
    private static func muted(_ degrees: Double) -> Color {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return Color(hue: (wrapped < 0 ? wrapped + 360 : wrapped) / 360, saturation: 0.58, brightness: 0.88)
    }

    private static let spectrum = LinearGradient(
        colors: stride(from: 0.0, through: 360.0, by: 60.0).map { muted($0) },
        startPoint: .leading, endPoint: .trailing)

    /// Grey → colour at a fixed brightness. `hue` nil walks the whole circle, which is what the
    /// global pair actually touches; a single hue is the mixer working on one band.
    private static func chromaRamp(hue: Double?) -> LinearGradient {
        let stops = (0...8).map { i -> Color in
            let t = Double(i) / 8
            return Color(hue: hue.map { $0 / 360 } ?? t, saturation: 0.62 * t, brightness: 0.74)
        }
        return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
    }
}

struct ToneSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let onChange: () -> Void
    /// Defaults to `.plain` so a control only claims a meaning when someone decided it has one.
    var identity: ToneIdentity = .plain
    /// Bumped by the double-click reset, and the ONLY thing the readout animates on.
    ///
    /// The obvious move — animating `value` back to neutral — is not available: `value` is bound
    /// straight to the render, so easing it would push a stream of intermediate recipes through
    /// the pipeline and put intermediate states into the undo history. The number therefore snaps,
    /// as does the knob, and only the readout's colour acknowledges the reset. Keying on a counter
    /// rather than on `value` also guarantees this can never fire mid-drag.
    /// Called with true when a drag starts and false when it ends. Used to hide the mask overlay
    /// for the duration, so the photograph is visible while it is being judged.
    var onDragging: (Bool) -> Void = { _ in }
    /// Where double-click sends this control. Defaults to zero for the signed ±100 scales, and is
    /// given explicitly by the ones whose neutral is elsewhere.
    var neutral: Double = 0
    @State private var resetTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(Theme.ui(12)).foregroundColor(Theme.inkDim)
                Spacer()
                Text(readout)
                    .font(Theme.mono(11, value == neutral ? .regular : .semibold))
                    .foregroundColor(value == neutral ? Theme.inkFaint : Theme.glow)
                    .animation(Motion.gated(Motion.quick, reduceMotion), value: resetTick)
            }
            VStack(spacing: 3) {
                // `onEditingChanged` brackets the DRAG — true when the thumb is grabbed, false
                // when it is let go. The overlay-suppression flag was being driven from the value
                // setter and `onChange` instead, which meant it went true, then false, and only
                // THEN was a render built: never true when it was read, so the feature was dead on
                // arrival. A gesture's begin and end are the only honest place to bracket a
                // gesture.
                Slider(value: $value, in: range, step: step, onEditingChanged: onDragging)
                    // The accent stays the same on every slider: it is the language of "where the
                    // value is", and the rail below is the language of "what this does". Making
                    // both vary at once would leave neither reliable.
                    .tint(Theme.glow)
                    .controlSize(.small)
                    // Live: re-render on every value change during the drag, not just on release.
                    .onChange(of: value) { onChange() }
                ToneRail(identity: identity)
            }
        }
        // Double-click the row to reset this control to its neutral value.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // Reset to this control's OWN neutral, not to literal zero. Guarding on
            // `range.contains(0)` made the gesture silently dead on every slider whose scale does
            // not straddle zero — Temp (2500…9500), radial Size, Brush size, Skin tolerance and
            // the three 0.01…0.5 Range sliders. Seven controls where double-click did nothing and
            // nothing said why.
            value = neutral
            onChange()
            resetTick += 1
        }
    }

    private var readout: String {
        let sign = value > 0 ? "+" : ""
        return step < 1
            ? String(format: "%@%.2f%@", sign, value, unit)
            : String(format: "%@%.0f%@", sign, value, unit)
    }
}

// MARK: - Hand-drawn gradient mask (view-model + editor)

/// A hand-added parametric mask — a radial/linear gradient or a brushed region — all plain values
/// so SwiftUI binds to it directly. Converts to the engine's `Mask` at render time.
/// A snapshot of the full manual-edit state, for undo/redo.
struct EditSnapshot: Equatable {
    var edit: GlobalAdjustments
    var userMasks: [UserMaskVM]
    var maskEnabled: [String: Bool]
    var maskStrength: [String: Double]
    var straighten: Double
    var hsl: [String: HSLAdjustment]
}

struct UserMaskVM: Identifiable, Equatable, Codable {
    enum Kind: String, Codable {
        case radial, linear, brush, colorRange, luminance, skin, background, subject, instance
    }
    var id = UUID()
    var kind: Kind
    var cx = 0.5, cy = 0.5, radius = 0.35, angle = 0.0, softness = 0.35
    var stamps: [BrushStamp] = []                       // brush only
    var selCenter = 0.0, selRange = 0.1, selSoftness = 0.1   // colour / luminance / skin selection
    /// The local adjustments this mask carries. Keys and ranges live in
    /// `AppState.maskAdjustmentSpecs`, and the editor builds its sliders from that list, so a
    /// hand-drawn mask and an auto mask can never again offer different controls.
    ///
    /// It used to be exposure/contrast/saturation and nothing else, while the renderer honoured
    /// six — so `shadows`, `highlights` and `vibrance` were unreachable on every mask a user
    /// drew: radial, graduated, brush, colour, luminance, skin, background, subject, instance.
    /// All nine. The two auto masks got the full set. The sharpest version of the gap is that
    /// `RecipeEngine.subjectMask` reaches for `shadows` deliberately — "detail recovery weighted
    /// over raw exposure, kinder to skin at any tone" — and someone painting a mask over that
    /// same face could not.
    ///
    /// Optional-with-default so a sidecar written before these existed still decodes.
    var exposure = 0.0, contrast = 0.0, saturation = 0.0
    var shadows = 0.0, highlights = 0.0, vibrance = 0.0
    var tightness = 0.0
    var feather = 0.0
    var invert = false
    /// `.instance` only: which detected subject this mask is for. The renderer looks the bitmap up
    /// under this id, and the export path matches it back to a fresh full-resolution detection —
    /// see `SubjectInstances.reidentify`, because the id is a per-pass index and means nothing on
    /// its own. Optional (and absent from older sidecars) so decoding an edit saved before
    /// per-subject masks existed still works.
    var instanceId: String?
    /// The label as it was when the mask was made ("Person 2", "Cat"). Stored rather than looked
    /// up so an edit reopened after a detection that came back slightly differently still says
    /// what the photographer thought they were editing.
    var instanceLabel: String?
    /// WHERE the subject was, normalised, when the mask was made — the part of its identity that
    /// survives a sidecar. The id does not: reopen the photo and the segmentation runs again with
    /// fresh per-pass indices, so a saved mask keyed only by id comes back pointing at nobody. The
    /// box is what `rekeyInstanceMasks` matches on to find the same subject again.
    var instanceBox: CGRect?
    /// Kind at the time, for the same reason — it tie-breaks the match.
    var instanceKind: SubjectInstances.Kind?
    /// What the photographer calls this mask. Nil falls back to the kind's name, which is how it
    /// was: three radial masks were all called "Radial", in a list, with nothing to tell them
    /// apart. Fine with one mask and useless with four.
    var name: String?
    /// THE UNIVERSAL MODIFIER. Narrows whatever region this mask defines to pixels that also fall
    /// in a colour or luminance range — "the skin within this person", "the highlights inside this
    /// graduated filter", "the reds in the bottom half".
    ///
    /// `.skin` used to be the only mask that could do this, because the intersection was written
    /// into the renderer as a special case for one type. It is available on every mask now, which
    /// is the whole point of collapsing the kinds into one primitive.
    enum Refinement: String, Codable, CaseIterable { case none, colour, luminance }
    var refinement: Refinement = .none
    var refineCenter = 0.06, refineRange = 0.12, refineSoftness = 0.06

    /// The subject this mask is bound to, when it is bound to one — `.instance` always, `.skin`
    /// when scoped to a single person. Every site that re-identifies subjects (export at full
    /// resolution, re-keying after a fresh detection) must use THIS rather than testing the kind,
    /// so a new instance-bound kind cannot be silently left out of re-identification again.
    var boundInstanceId: String? {
        (kind == .instance || kind == .skin) ? instanceId : nil
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, cx, cy, radius, angle, softness, stamps, selCenter, selRange, selSoftness
        case exposure, contrast, saturation, instanceId, instanceLabel, instanceBox, instanceKind
        case tightness, feather, invert
        // EVERY STORED PROPERTY MUST BE LISTED HERE. With an explicit `CodingKeys`, the synthesised
        // encoder writes only what this enum names — so a property added above and forgotten here
        // is not a smaller file, it is silent data loss. `init(from:)` decodes these with
        // defaults, which is exactly what made it invisible: the values came back looking like
        // untouched defaults rather than like something that failed to save.
        //
        // Lost this way until now: the three adjustments hand-drawn masks had just gained
        // (shadows, highlights, vibrance), every mask's name, and the whole refine feature. All of
        // it survived switching photos, because that path keeps objects in memory, and vanished on
        // relaunch.
        case shadows, highlights, vibrance, name
        case refinement, refineCenter, refineRange, refineSoftness
    }

    init(id: UUID = UUID(), kind: Kind, cx: Double = 0.5, cy: Double = 0.5, radius: Double = 0.35, angle: Double = 0.0, softness: Double = 0.35, stamps: [BrushStamp] = [], selCenter: Double = 0.0, selRange: Double = 0.1, selSoftness: Double = 0.1, exposure: Double = 0.0, contrast: Double = 0.0, saturation: Double = 0.0, instanceId: String? = nil, instanceLabel: String? = nil, instanceBox: CGRect? = nil, instanceKind: SubjectInstances.Kind? = nil, tightness: Double = 0.0, feather: Double = 0.0, invert: Bool = false) {
        self.id = id; self.kind = kind; self.cx = cx; self.cy = cy; self.radius = radius; self.angle = angle; self.softness = softness
        self.stamps = stamps; self.selCenter = selCenter; self.selRange = selRange; self.selSoftness = selSoftness
        self.exposure = exposure; self.contrast = contrast; self.saturation = saturation
        self.instanceId = instanceId; self.instanceLabel = instanceLabel; self.instanceBox = instanceBox; self.instanceKind = instanceKind
        self.tightness = tightness; self.feather = feather; self.invert = invert
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        cx = try c.decodeIfPresent(Double.self, forKey: .cx) ?? 0.5
        cy = try c.decodeIfPresent(Double.self, forKey: .cy) ?? 0.5
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? 0.35
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0.0
        softness = try c.decodeIfPresent(Double.self, forKey: .softness) ?? 0.35
        stamps = try c.decodeIfPresent([BrushStamp].self, forKey: .stamps) ?? []
        selCenter = try c.decodeIfPresent(Double.self, forKey: .selCenter) ?? 0.0
        selRange = try c.decodeIfPresent(Double.self, forKey: .selRange) ?? 0.1
        selSoftness = try c.decodeIfPresent(Double.self, forKey: .selSoftness) ?? 0.1
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0.0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0.0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0.0
        instanceId = try c.decodeIfPresent(String.self, forKey: .instanceId)
        instanceLabel = try c.decodeIfPresent(String.self, forKey: .instanceLabel)
        instanceBox = try c.decodeIfPresent(CGRect.self, forKey: .instanceBox)
        instanceKind = try c.decodeIfPresent(SubjectInstances.Kind.self, forKey: .instanceKind)
        tightness = try c.decodeIfPresent(Double.self, forKey: .tightness) ?? 0.0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0.0
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        // The decoder is HAND-WRITTEN, so adding a key to `CodingKeys` fixes encoding and leaves
        // decoding still ignoring it — the file grows the field and nothing reads it back. Both
        // halves or neither.
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0.0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0.0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0.0
        name = try c.decodeIfPresent(String.self, forKey: .name)
        refinement = try c.decodeIfPresent(Refinement.self, forKey: .refinement) ?? .none
        refineCenter = try c.decodeIfPresent(Double.self, forKey: .refineCenter) ?? 0.06
        refineRange = try c.decodeIfPresent(Double.self, forKey: .refineRange) ?? 0.12
        refineSoftness = try c.decodeIfPresent(Double.self, forKey: .refineSoftness) ?? 0.06
    }

    var label: String {
        switch kind {
        case .radial: return "Radial"; case .linear: return "Graduated"; case .brush: return "Brush"
        case .colorRange: return "Colour range"; case .luminance: return "Luminance"; case .skin: return "Skin"
        case .background: return "Background"
        case .subject: return "Subject"
        case .instance: return instanceLabel ?? "Subject"
        }
    }

    /// The name shown in the panel: what it was renamed to, or what kind it is.
    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? label : trimmed
    }
    var hasCanvasHandles: Bool { kind == .radial || kind == .linear }

    /// Adjustments addressed by the same key the renderer and `maskAdjustmentSpecs` use, so the
    /// editor can be built from that list rather than from a hand-written set of sliders that
    /// silently fell behind it.
    subscript(adjustment key: String) -> Double {
        get {
            switch key {
            case "exposure_ev": return exposure
            case "contrast":    return contrast
            case "saturation":  return saturation
            case "shadows":     return shadows
            case "highlights":  return highlights
            case "vibrance":    return vibrance
            default:            return 0
            }
        }
        set {
            switch key {
            case "exposure_ev": exposure = newValue
            case "contrast":    contrast = newValue
            case "saturation":  saturation = newValue
            case "shadows":     shadows = newValue
            case "highlights":  highlights = newValue
            case "vibrance":    vibrance = newValue
            default:            break
            }
        }
    }

    func toMask() -> Mask {
        var adj: [String: Double] = [:]
        if exposure != 0 { adj["exposure_ev"] = exposure }
        if contrast != 0 { adj["contrast"] = contrast }
        if saturation != 0 { adj["saturation"] = saturation }
        if shadows != 0 { adj["shadows"] = shadows }
        if highlights != 0 { adj["highlights"] = highlights }
        if vibrance != 0 { adj["vibrance"] = vibrance }
        let f = feather
        let t = tightness
        let inv = invert
        // Applied to whatever region the source below produces. `.skin` still constructs its own
        // refinement from the legacy fields, so an existing skin mask is untouched by this.
        let ref: MaskSelection? = {
            switch refinement {
            case .none: return nil
            case .colour: return MaskSelection(kind: .color, center: refineCenter,
                                               range: refineRange, softness: refineSoftness)
            case .luminance: return MaskSelection(kind: .luminance, center: refineCenter,
                                                  range: refineRange, softness: refineSoftness)
            }
        }()
        switch kind {
        case .brush:
            return Mask(id: id.uuidString, type: "brush", source: "brush", invert: inv,
                        feather: f, opacity: 1, adjustments: adj, stamps: stamps, tightness: t,
                        refine: ref)
        case .radial, .linear:
            let sk: MaskShape.Kind = kind == .radial ? .radial : .linear
            return Mask(id: id.uuidString, type: sk.rawValue, source: "gradient", invert: inv,
                        feather: f, opacity: 1, adjustments: adj,
                        shape: MaskShape(kind: sk, cx: cx, cy: cy, radius: radius, angle: angle, softness: softness), tightness: t,
                        refine: ref)
        case .colorRange, .luminance:
            let k: MaskSelection.Kind = kind == .colorRange ? .color : .luminance
            return Mask(id: id.uuidString, type: k.rawValue, source: "selection", invert: inv,
                        feather: f, opacity: 1, adjustments: adj,
                        selection: MaskSelection(kind: k, center: selCenter, range: selRange, softness: selSoftness), tightness: t,
                        refine: ref)
        case .skin:
            // NOT a kind any more — a region narrowed to skin hues. Identical pixels to the old
            // bespoke path; it is just said in the general vocabulary now.
            //
            // `ref` wins when the user has set one. The editor shows the REFINE picker on every
            // kind, and this case used to ignore it and build a colour selection from the legacy
            // skin fields regardless — so choosing "Light" on a skin mask silently gave you a
            // colour narrowing instead. Worse than a dead control: the picture changed, just not
            // in the way that was asked for.
            let skinRef = ref ?? MaskSelection(kind: .color, center: selCenter,
                                               range: selRange, softness: selSoftness)
            if let inst = instanceId {
                // ONE person's skin: that subject's region, narrowed the same way. The mask's id
                // IS the instance id — the same contract as `.instance`, which is how the
                // renderer finds the bitmap and how export re-identifies the person at full
                // resolution. On a frame with three people, brightening the bride's skin must
                // not also brighten the groom's.
                return Mask(id: inst, type: "instance", source: "segmentation", invert: inv,
                            feather: f != 0 ? f : 30, opacity: 1, adjustments: adj, tightness: t,
                            refine: skinRef)
            }
            return Mask(id: id.uuidString, type: "subject", source: "segmentation", invert: inv,
                        feather: f, opacity: 1, adjustments: adj, tightness: t, refine: skinRef)
        case .background:
            // Also not a kind: the subject region, inverted. `invert` was always the modifier
            // doing the work — this case existed only to set it for you.
            let finalInvert = inv ? false : true
            let finalFeather = f != 0 ? f : 20
            return Mask(id: id.uuidString, type: "subject", source: "segmentation", invert: finalInvert,
                        feather: finalFeather, opacity: 1, adjustments: adj, tightness: t,
                        refine: ref)
        case .subject:
            let finalFeather = f != 0 ? f : 30
            return Mask(id: id.uuidString, type: "subject", source: "segmentation", invert: inv,
                        feather: finalFeather, opacity: 1, adjustments: adj, tightness: t,
                        refine: ref)
        case .instance:
            let finalFeather = f != 0 ? f : 30
            return Mask(id: instanceId ?? id.uuidString, type: "instance", source: "segmentation",
                        invert: inv, feather: finalFeather, opacity: 1, adjustments: adj, tightness: t,
                        refine: ref)
        }
    }
}

struct UserMaskEditor: View {
    @Binding var mask: UserMaskVM
    let onChange: () -> Void
    let onDelete: () -> Void
    var isSelected = false
    var onSelect: () -> Void = {}
    /// Select-or-deselect, for the eye in the header. Separate from `onSelect` on purpose: the card
    /// tap must only ever select, so that clicking around inside a card cannot put its selection
    /// down by accident.
    var onToggleSelected: () -> Void = {}
    var isPainting = false
    var togglePaint: () -> Void = {}
    var clearStrokes: () -> Void = {}
    var brushRadius: Binding<Double> = .constant(0.09)
    var hasPerson = true
    /// The detected people on this frame, for the skin mask's "whose skin" choice. Empty means
    /// no choice to offer.
    var people: [SubjectInstances.Instance] = []
    /// Bracket a tone drag so the overlay steps aside while the photograph is being judged —
    /// otherwise you are grading 60% red and the slider appears to do nothing useful.
    var onAdjustBegin: () -> Void = {}
    var onAdjustEnd: () -> Void = {}
    var canMoveUp = false
    var canMoveDown = false
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}

    /// Skin and Background are built from the person segmentation — flag it when there isn't one,
    /// so the mask isn't just quietly inert.
    private var needsPersonButHasNone: Bool {
        (mask.kind == .skin || mask.kind == .background || mask.kind == .subject) && !hasPerson
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(mask.label, text: Binding(
                    get: { mask.name ?? "" },
                    set: { mask.name = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12, .semibold)).foregroundColor(Theme.ink)
                    .onSubmit(onChange)
                    .help("Rename this mask")
                if isSelected && mask.kind != .brush {
                    Text("editing on canvas").font(Theme.mono(9)).foregroundColor(Theme.glow)
                }
                Spacer()
                // The off switch, next to the trash rather than instead of it. Same glyph, same
                // help text and same behaviour as the auto masks' eye: click to show where this
                // mask falls, click again to put it away. Tapping the card selects but never
                // deselects — a click that lands on the card's padding should not silently undo
                // your selection — so the deliberate "put it down" gesture needs its own button,
                // and it needs to be the thing you find when you are reaching for the trash.
                Button(action: onToggleSelected) {
                    Image(systemName: isSelected ? "eye.fill" : "eye")
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? Theme.glow : Theme.inkFaint)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Stop showing this mask on the photo (keeps its edits)"
                                 : "Show where this mask falls")
                // Which mask sits on top of which. Composites in array order, so this changes the
                // picture, not just the list.
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold))
                        .foregroundColor(canMoveUp ? Theme.inkDim : Theme.inkFaint.opacity(0.4))
                }
                .buttonStyle(.plain).disabled(!canMoveUp)
                .help("Move this mask up the stack")
                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .foregroundColor(canMoveDown ? Theme.inkDim : Theme.inkFaint.opacity(0.4))
                }
                .buttonStyle(.plain).disabled(!canMoveDown)
                .help("Move this mask down the stack")
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundColor(Theme.inkDim)
                }.buttonStyle(.plain)
            }

            if needsPersonButHasNone {
                // Same glyph and colour as the craft flags under the preview — one visual language
                // for "look at this", wherever it turns up.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9)).foregroundColor(Theme.warn)
                    Text("No person detected in this photo — this mask has nothing to act on.")
                        .font(Theme.mono(9)).foregroundColor(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            switch mask.kind {
            case .brush:
                HStack(spacing: 8) {
                    Button(action: togglePaint) {
                        Text(isPainting ? "Painting…" : "Paint")
                            .font(Theme.ui(11, .semibold)).foregroundColor(isPainting ? Theme.base : Theme.ink)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(isPainting ? Theme.glow : Theme.surface2)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)))
                    }.buttonStyle(.plain)
                    Button(action: clearStrokes) {
                        Text("Clear").font(Theme.ui(11, .semibold)).foregroundColor(Theme.inkDim)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.surface2)
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1)))
                    }.buttonStyle(.plain)
                }
                ToneSlider(label: "Brush size", value: brushRadius, range: 0.02...0.35, step: 0.01, unit: "", onChange: {}, neutral: 0.09)
            case .radial:
                ToneSlider(label: "Center X", value: $mask.cx, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Center Y", value: $mask.cy, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Size", value: $mask.radius, range: 0.05...1.2, step: 0.01, unit: "", onChange: onChange, neutral: 0.35)
                ToneSlider(label: "Softness", value: $mask.softness, range: 0...1, step: 0.01, unit: "", onChange: onChange)
            case .linear:
                ToneSlider(label: "Center X", value: $mask.cx, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Center Y", value: $mask.cy, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Angle", value: $mask.angle, range: 0...360, step: 1, unit: "°", onChange: onChange)
                ToneSlider(label: "Softness", value: $mask.softness, range: 0...1, step: 0.01, unit: "", onChange: onChange)
            case .colorRange:
                // Hue picker (0…1 → the colour wheel) + how wide a band + edge softness.
                ToneSlider(label: "Hue", value: $mask.selCenter, range: 0...1, step: 0.005, unit: "", onChange: onChange, identity: .spectrum)
                ToneSlider(label: "Range", value: $mask.selRange, range: 0.01...0.5, step: 0.005, unit: "", onChange: onChange, neutral: 0.1)
                ToneSlider(label: "Softness", value: $mask.selSoftness, range: 0...0.3, step: 0.005, unit: "", onChange: onChange)
            case .luminance:
                ToneSlider(label: "Brightness", value: $mask.selCenter, range: 0...1, step: 0.01, unit: "", onChange: onChange, identity: .exposure)
                ToneSlider(label: "Range", value: $mask.selRange, range: 0.01...0.5, step: 0.005, unit: "", onChange: onChange, neutral: 0.1)
                ToneSlider(label: "Softness", value: $mask.selSoftness, range: 0...0.3, step: 0.005, unit: "", onChange: onChange)
            case .skin:
                Text(mask.instanceId == nil
                     ? "Skin tones within the detected person, fair across complexions."
                     : "Skin tones within \(mask.instanceLabel ?? "this person") only — nobody else's.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                // WHOSE skin, when the frame offers a choice. On a frame with three people a
                // skin edit lands on all of them unless it is told otherwise, and brightening
                // the bride must not also brighten the groom. Hidden with one person — a picker
                // with one real answer is furniture.
                if people.count > 1 {
                    HStack {
                        Text("Whose skin").font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { mask.instanceId ?? "" },
                            set: { chosen in
                                if let person = people.first(where: { $0.id == chosen }) {
                                    mask.instanceId = person.id
                                    mask.instanceLabel = person.label
                                    mask.instanceBox = person.boundingBox
                                    mask.instanceKind = person.kind
                                    if mask.name == nil || mask.name?.hasPrefix("Skin") == true {
                                        mask.name = "Skin — \(person.label)"
                                    }
                                } else {
                                    mask.instanceId = nil; mask.instanceLabel = nil
                                    mask.instanceBox = nil; mask.instanceKind = nil
                                    if mask.name?.hasPrefix("Skin") == true { mask.name = nil }
                                }
                                onChange()
                            })) {
                            Text("Everyone").tag("")
                            ForEach(people, id: \.id) { person in
                                Text(person.label).tag(person.id)
                            }
                        }
                        .pickerStyle(.menu).labelsHidden().frame(maxWidth: 170)
                    }
                }
                ToneSlider(label: "Tolerance", value: $mask.selRange, range: 0.02...0.18, step: 0.005, unit: "", onChange: onChange, neutral: 0.06)
            case .background:
                Text("Everything except the detected subject — darken or desaturate it to make the subject pop.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            case .subject:
                Text("The detected person — lift, model, or recover them without touching the scene.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            case .instance:
                Text("Just this one — everything else in the frame is untouched.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)

            // MODIFIERS — the same two on every mask, whatever defines its region. `.skin` and
            // `.background` used to be separate mask kinds, which is what made these unavailable
            // everywhere else: "the highlights within this person" or "everything except the
            // reds" had no way to be said.
            Toggle(isOn: $mask.invert) {
                Text("Invert — adjust everything else")
                    .font(Theme.ui(11)).foregroundColor(Theme.inkDim)
            }
            .toggleStyle(.switch).tint(Theme.glow)
            .onChange(of: mask.invert) { onChange() }

            HStack(spacing: 6) {
                Text("REFINE").font(Theme.mono(9)).tracking(1.2).foregroundColor(Theme.inkFaint)
                Spacer()
                Picker("", selection: $mask.refinement) {
                    Text("Off").tag(UserMaskVM.Refinement.none)
                    Text("Colour").tag(UserMaskVM.Refinement.colour)
                    Text("Light").tag(UserMaskVM.Refinement.luminance)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170).controlSize(.small)
                .onChange(of: mask.refinement) { onChange() }
            }
            .help("Narrow this mask to pixels that are also a certain colour or brightness")

            if mask.refinement != .none {
                ToneSlider(label: mask.refinement == .colour ? "Hue" : "Brightness",
                           value: $mask.refineCenter, range: 0...1, step: 0.005, unit: "",
                           onChange: onChange,
                           identity: mask.refinement == .colour ? .spectrum : .exposure)
                ToneSlider(label: "Range", value: $mask.refineRange, range: 0.01...0.5,
                           step: 0.005, unit: "", onChange: onChange, neutral: 0.12)
                ToneSlider(label: "Softness", value: $mask.refineSoftness, range: 0...0.3,
                           step: 0.005, unit: "", onChange: onChange)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
            // Built from the SAME list the auto-mask panel uses, rather than a hand-written
            // subset. These two editors had drifted: the auto masks offered six adjustments and
            // hand-drawn ones offered three, so half the renderer's local capability was
            // unreachable on the masks people actually draw. Driving both from
            // `maskAdjustmentSpecs` is what stops that happening again — add a control there and
            // it appears in both places, with the same range and the same label.
            ForEach(AppState.maskAdjustmentSpecs, id: \.key) { spec in
                ToneSlider(label: spec.label,
                           value: Binding(get: { mask[adjustment: spec.key] },
                                          set: { mask[adjustment: spec.key] = $0 }),
                           range: spec.range,
                           step: spec.key == "exposure_ev" ? 0.05 : 1,
                           unit: spec.unit,
                           onChange: onChange,
                           identity: ToneIdentity.adjustment(spec.key),
                           onDragging: { $0 ? onAdjustBegin() : onAdjustEnd() })
            }
            ToneSlider(label: "Tightness", value: $mask.tightness, range: 0...100, step: 1, unit: "", onChange: onChange)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke((isPainting || isSelected) ? Theme.glow : Theme.glow.opacity(0.4),
                            lineWidth: (isPainting || isSelected) ? 1.5 : 1))
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

// MARK: - Mask control (toggle + strength for an auto-mask)

struct MaskControl: View {
    let name: String
    @Binding var isOn: Bool
    @Binding var strength: Double
    let onChange: () -> Void
    /// The full local adjustment set for this mask. Optional so the control still works for
    /// callers that only want the toggle.
    var maskId: String? = nil
    var adjustment: ((String) -> Binding<Double>)? = nil
    var feather: Binding<Double>? = nil
    var tightness: Binding<Double>? = nil
    var invert: Binding<Bool>? = nil
    var onReset: (() -> Void)? = nil
    /// Whether this mask is the one the overlay is showing, and how to say "show me this one".
    /// Clicking a selected mask again clears the selection, which is what puts the red away.
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    /// Bracket a tone drag so the overlay can step aside while the picture is being judged.
    var onAdjustBegin: () -> Void = {}
    var onAdjustEnd: () -> Void = {}
    /// Folded by default. A subject mask usually needs nothing beyond the strength Kelvin chose,
    /// and six sliders per mask unfolded would rebuild the wall of controls the sidebar just lost.
    @State private var showAdjustments = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: $isOn) {
                    Text(name).font(Theme.ui(13, .medium)).foregroundColor(Theme.ink)
                }
                .toggleStyle(.switch).tint(Theme.glow)
                .onChange(of: isOn) { onChange() }
                Spacer()
                // Show-me-this-one, and click again to put it away. The auto masks previously had
                // no way to say either: the overlay picked one on its own and the panel offered
                // nothing to change or clear that choice.
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "eye.fill" : "eye")
                        .font(.system(size: 10))
                        .foregroundColor(isSelected ? Theme.glow : Theme.inkFaint)
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Hide this mask's overlay" : "Show where this mask falls")
            }

            if isOn {
                HStack {
                    Text("Strength").font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                    Spacer()
                    Text("\(Int(strength))%").font(Theme.mono(10)).foregroundColor(Theme.glow)
                }
                // Live, like every `ToneSlider`. Commit-on-release here alone made the one control
                // in the panel that does not preview read as a control that does not work.
                Slider(value: $strength, in: 0...100, step: 1)
                    .onChange(of: strength) { onChange() }
                    .tint(Theme.glow).controlSize(.small)

                if let adjustment {
                    Button {
                        withAnimation(Motion.gated(Motion.quick, reduceMotion)) { showAdjustments.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7, weight: .bold))
                                .rotationEffect(.degrees(showAdjustments ? 90 : 0))
                            Text("Adjust").font(Theme.mono(9, .semibold)).tracking(1)
                            Spacer()
                            if onReset != nil && showAdjustments {
                                Button("Reset") { onReset?() }
                                    .buttonStyle(.plain)
                                    .font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
                            }
                        }
                        .foregroundColor(Theme.inkDim)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showAdjustments {
                        VStack(spacing: 10) {
                            ForEach(AppState.maskAdjustmentSpecs, id: \.key) { spec in
                                ToneSlider(label: spec.label,
                                           value: adjustment(spec.key),
                                           range: spec.range,
                                           step: spec.key == "exposure_ev" ? 0.05 : 1,
                                           unit: spec.unit,
                                           onChange: onChange,
                                           identity: ToneIdentity.adjustment(spec.key),
                                           onDragging: { $0 ? onAdjustBegin() : onAdjustEnd() })
                            }
                            if let feather {
                                ToneSlider(label: "Feather", value: feather, range: 0...100,
                                           step: 1, unit: "", onChange: onChange)
                            }
                            if let tightness {
                                ToneSlider(label: "Tightness", value: tightness, range: 0...100,
                                           step: 1, unit: "", onChange: onChange)
                            }
                            if let invert {
                                Toggle(isOn: invert) {
                                    Text("Invert — adjust everything else")
                                        .font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                                }
                                .toggleStyle(.switch).tint(Theme.glow)
                                .onChange(of: invert.wrappedValue) { onChange() }
                            }
                        }
                        .padding(.top, 2)
                        .transition(.opacity)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Theme.glow.opacity(0.6) : Theme.hairline.opacity(0.6),
                            lineWidth: isSelected ? 1.5 : 1))
        )
    }
}

// MARK: - Keyboard Shortcuts Sheet

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let shortcuts: [(key: String, description: String)] = [
        ("P", "Flag photo as Keep & advance to next"),
        ("X", "Flag photo as Reject & advance to next"),
        ("O", "Toggle Mask Overlay red visualization"),
        ("[ / ]", "Decrease / Increase brush size"),
        ("1 – 4", "Select Candidate Edit 1, 2, 3, or 4"),
        ("Hold", "Press & hold 'Hold to compare' for original"),
        ("⌘Z", "Undo edit"),
        ("⌘Shift Z", "Redo edit"),
        ("⌘O", "Open another photo or folder"),
        ("← / →", "Navigate to previous / next photo in strip"),
        ("⌘/", "Show this list")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("KEYBOARD SHORTCUTS")
                    .font(Theme.mono(11, .semibold)).tracking(1.4).foregroundColor(Theme.ink)
                Spacer()
                Button("Done") { dismiss() }
                    .font(Theme.ui(12, .semibold)).foregroundColor(Theme.glow)
                    .buttonStyle(.plain)
            }
            Divider().overlay(Theme.hairline)

            VStack(spacing: 9) {
                ForEach(shortcuts, id: \.key) { item in
                    HStack(spacing: 12) {
                        Text(item.key)
                            .font(Theme.mono(10, .semibold))
                            .foregroundColor(Theme.base)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.glow))
                            .frame(width: 76, alignment: .leading)
                        Text(item.description)
                            .font(Theme.ui(12)).foregroundColor(Theme.ink)
                        Spacer()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(Theme.surface)
    }
}
