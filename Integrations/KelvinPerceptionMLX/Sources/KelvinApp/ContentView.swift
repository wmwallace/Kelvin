import SwiftUI
import CoreImage
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

    /// Every local adjustment the renderer honours inside a mask, in the order a photographer
    /// works: light first, then colour. Keys must match `Renderer.applyMaskedAdjustments`.
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
        let saved = userMasks.enumerated().filter { $0.element.kind == .instance }
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
        if let existing = userMasks.first(where: { $0.instanceId == instance.id }) {
            selectedUserMaskId = existing.id
            showMaskOverlay = true
            onEdit()
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
        showMaskOverlay = true
        onEdit()
    }

    func adjustBrushRadius(by delta: Double) {
        brushRadius = min(0.35, max(0.02, brushRadius + delta))
    }

    /// Sensor dust/spots detected once on load (normalised → resolution-independent, so the same
    /// set heals the proxy preview, the full-res export, and every frame of a batch — dust sits at
    /// a fixed sensor position across a whole shoot).
    private var healSpots: [HealSpot] = []
    @Published var detectedSpotCount = 0
    /// Opt-in: dust removal is off by default so a clean frame is never touched, and the user
    /// decides when a spot is dust versus real detail.
    @Published var removeDust = false { didSet { updateActiveRecipe() } }

    @Published var isProcessing = false
    @Published var statusMessage = "Drop a photo to read the light."
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
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

    /// `DateTimeOriginal` per photo for the folder named by `captureDatesFolder`. Empty until the
    /// background read lands, which `PhotoOrder.sorted` treats as "nothing is dated" — so the
    /// strip shows filename order in the meantime rather than an empty or jumping list.
    private var captureDates: [URL: Date] = [:]
    /// Which directory `captureDates` describes. One folder at a time, which is how a shoot is
    /// worked: opening every frame of a 437-shot folder must not re-read 437 EXIF headers each
    /// time. Leaving for another folder and coming back costs one re-read, which is the price of
    /// not carrying an unbounded cache of dates for folders nobody is looking at.
    private var captureDatesFolder: URL?
    private var captureDateTask: Task<Void, Never>?
    /// True while the read is in flight, so the strip's sort control can say the order is not
    /// settled yet instead of appearing to have sorted wrongly.
    @Published private(set) var captureDatesPending = false

    /// Whether the order on screen is still provisional. Only true under capture-time sort — the
    /// read also runs when you are sorting by name (so switching later is instant), but a name
    /// sort is not waiting on it and must not display as though it were.
    var sortOrderPending: Bool { captureDatesPending && photoSort == .captureTime }

    /// Put `folderPhotos` back in the order the controls currently ask for. Cheap — a sort of a
    /// few hundred URLs against an in-memory dictionary, no file access.
    private func reorderFolderPhotos() {
        folderPhotos = PhotoOrder.sorted(folderPhotos, by: photoSort,
                                         reversed: photoSortReversed, captureDates: captureDates)
    }

    /// Read the capture times for a folder, **off the main thread**, and re-sort when they arrive.
    ///
    /// An EXIF read is a header read, not a decode, so it is cheap per file — but 437 files is 437
    /// file opens, and this codebase has twice put the window on the floor by doing per-file work
    /// on the main thread (thumbnails once decoded whole RAWs during view layout and the window
    /// never appeared). So: never on the main thread, never blocking the open, and the strip is
    /// usable in filename order throughout.
    private func loadCaptureDates(for folder: URL, photos: [URL]) {
        guard captureDatesFolder != folder else { return }      // already have this folder
        captureDateTask?.cancel()
        captureDatesFolder = folder
        captureDates = [:]
        captureDatesPending = true
        captureDateTask = Task { [weak self] in
            let dates = await Task.detached(priority: .utility) {
                PhotoOrder.captureDates(for: photos)
            }.value
            guard !Task.isCancelled, let self else { return }
            // Guard against a folder switch that started while this read was running — a late
            // result must not re-sort the strip you are looking at now using another folder's
            // dates.
            guard self.captureDatesFolder == folder else { return }
            self.captureDates = dates
            self.captureDatesPending = false
            self.reorderFolderPhotos()
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
        case all = "All", keepers = "Keepers", undecided = "Undecided", soft = "Focus"
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
            // Review, not a verdict: this is the list to LOOK at, so the false positives are
            // the point of it rather than something hidden by it.
            case .soft:      return focus[url]?.isSoft == true
            }
        }
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

    var softCount: Int { folderPhotos.filter { focus[$0]?.isSoft == true }.count }

    /// Measure every frame in the folder, newest results published as they arrive so the strip
    /// fills in progressively rather than freezing until the end.
    func scanFocus() {
        guard focusScanProgress == nil else { return }      // already running
        let photos = folderPhotos
        guard !photos.isEmpty else { return }
        focusScanProgress = 0

        Task { [weak self] in
            var done = 0
            for url in photos {
                guard let self else { return }
                if self.focus[url] == nil {
                    // Measured on the same 1200px proxy the thresholds were calibrated against —
                    // a different scale would silently invalidate them.
                    let reading = await Task.detached(priority: .utility) { () -> FocusMeasure.Reading? in
                        guard let full = try? ImageDecoder.decode(url: url) else { return nil }
                        let proxy = AppState.materialiseShared(
                            PerceptionProxy.downsample(full, maxEdge: 1200))
                        return FocusMeasure.read(proxy)
                    }.value
                    if let reading { self.focus[url] = reading }
                }
                done += 1
                self.focusScanProgress = Double(done) / Double(photos.count)
                // Yield so the UI keeps drawing and the scan can be interrupted by simply working.
                await Task.yield()
            }
            self?.focusScanProgress = nil
        }
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
            let image = await Task.detached(priority: .utility) {
                PhotoBrowser.thumbnail(for: url)
            }.value
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
        guard let url = imageURL else { return "kelvin-edit." + ext }
        let look = activeLookId.flatMap { LookPreset.named($0)?.name }
            ?? candidates.first { $0.id == selectedCandidateId }?.label
        return ExportNaming.filename(for: url, perception: perception, look: look, ext: ext)
    }

    /// "12 Mar, 14:03" from an ISO timestamp — a restored edit should say *when*, not show a
    /// machine string.
    static func friendlyDate(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "an earlier session" }
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: date)
    }

    /// The current edit, in the form that goes to disk.
    private func currentSavedEdit() -> SavedEdit {
        SavedEdit(styleId: selectedCandidateId, global: edit, userMasks: userMasks,
                  maskEnabled: maskEnabled, maskStrength: maskStrength,
                  straighten: straighten, hsl: hsl, blackAndWhite: activeRecipe?.blackAndWhite,
                  removeDust: removeDust,
                  savedAt: ISO8601DateFormatter().string(from: Date()), contentHint: imageId)
    }

    /// Write the edit for `url` if it differs from what Kelvin generated, or clear it if the user
    /// has reset back to the candidate — otherwise a stale file would keep resurrecting an edit
    /// they undid.
    private func persistEdit(for url: URL) {
        let touched = edit != editBaseline || !userMasks.isEmpty || straighten != 0
            || !hsl.isEmpty || removeDust
        if touched { EditStore.save(currentSavedEdit(), for: url) }
        else { EditStore.remove(for: url) }
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
        selectedCandidateId = s.selectedCandidateId
        edit = s.edit; editBaseline = s.editBaseline
        baseMasks = s.baseMasks; maskEnabled = s.maskEnabled; maskStrength = s.maskStrength
        userMasks = s.userMasks; straighten = s.straighten; hsl = s.hsl; removeDust = s.removeDust
        brushCache = [:]; selectedUserMaskId = nil; paintingMaskId = nil
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
        fullResCI = nil; proxyCI = nil
        candidates = []; selectedCandidateId = nil
        activeRecipe = nil; active = nil; original = nil
        lastRenderedCI = nil; activeCraftIssues = []; lastCraftReading = nil; exhaustedFixes = []
        userMasks = []; paintingMaskId = nil; selectedUserMaskId = nil
        subjectInstances = []; highlightedInstanceId = nil
        brushCache = [:]
        proxyMaskBitmaps = [:]; healSpots = []; detectedSpotCount = 0
        zoom = 1; pan = .zero; showingOriginal = false
        statusMessage = "Drop a photo to read the light."
    }

    /// Remove a photo from the strip for this session, and forget any edit it had. The file itself
    /// is never touched — this is about clearing the working set, not deleting someone's work.
    func dismiss(_ url: URL) {
        dismissedURLs.insert(url)      // survives the folder re-scan that happens on every open
        EditStore.remove(for: url)
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
                statusMessage = "No photos Kelvin can read in \(url.lastPathComponent)."
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
            statusMessage = "Kelvin can't read .\(url.pathExtension) files."
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
        if panel.runModal() == .OK, let url = panel.url {
            Task { await open(url) }
        }
    }

    func loadPhoto(from url: URL) async {
        isProcessing = true
        statusMessage = "Decoding…"
        // Keep whatever you were working on before this photo takes over.
        if loadedURL != nil, loadedURL != url { stashCurrentSession() }
        imageURL = url
        let siblings = PhotoBrowser.siblings(of: url).filter { !dismissedURLs.contains($0) || $0 == url }
        // Kick the EXIF pass off first: it clears the cache synchronously when the folder has
        // changed, so the sort below can never use the previous folder's dates.
        loadCaptureDates(for: url.deletingLastPathComponent(), photos: siblings)
        // Sorted with whatever dates are already cached — none on the first open of a folder,
        // which `PhotoOrder` resolves to filename order. The pass above fills them in and re-sorts;
        // the strip is never blocked waiting for it.
        folderPhotos = PhotoOrder.sorted(siblings, by: photoSort,
                                         reversed: photoSortReversed, captureDates: captureDates)
        // Photos edited in an earlier session already carry a dot.
        editedURLs.formUnion(EditStore.edited(among: folderPhotos))
        flags = FlagStore.flags(among: folderPhotos)
        capture = CaptureInfoReader.read(url: url)
        userMasks = []; paintingMaskId = nil; selectedUserMaskId = nil   // hand-drawn masks are per-photo
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
                let perceptionProxy = PerceptionProxy.downsample(fullRes)
                // MATERIALISE the edit proxy. `downsample` returns a *lazy* CIImage — a filter
                // graph over the full-resolution original — so every later measurement (mask
                // coverage, subject luma, dust scan, histogram) silently re-renders all 60
                // megapixels again. Rendering once here means everything downstream works on real
                // 1200 px pixels.
                let proxy = Self.materialiseShared(PerceptionProxy.downsample(fullRes, maxEdge: 1200))
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

            statusMessage = "Reading the scene…"
            // Real perception: Qwen2.5-VL reads the 768px proxy. First call loads the model (a few
            // seconds once cached); if it can't run, fall back to a conservative read so the
            // app still produces candidates from the measured statistics.
            let perceptionRead: Perception
            do {
                perceptionRead = try await perceptionProvider.perceive(perceptionProxy)
            } catch {
                perceptionRead = Self.conservativeRead
                statusMessage = "Model unavailable — conservative read"
            }
            guard imageURL == url else { return }
            self.perception = perceptionRead

            statusMessage = "Measuring…"
            // Also off the main thread: the statistics pass, Vision's person/sky segmentation and
            // the dust scan each render the proxy, and together they were the second-biggest block
            // on the main thread after decode.
            let measurement = try await Task.detached(priority: .userInitiated) { () throws -> MeasuredPhoto in
                let sampleBytes = try ImageMetrics.sample(proxy)
                let stats = ImageStatistics.compute(from: sampleBytes)
                // Subject + sky masks (for local edits). Generated on the proxy for fast previews;
                // the measured region brightness tells the engine whether to lift the subject or
                // defog the sky.
                let measured = LocalMasks.measure(in: proxy)
                // Scan for sensor dust once (normalised coords reused everywhere). Conservative —
                // a clean frame yields none. Off until the user opts in.
                return MeasuredPhoto(stats: stats, masks: measured,
                                     dust: DustDetector.detect(in: proxy),
                                     focus: FocusMeasure.read(proxy),
                                     // Every separable subject, individually. `LocalMasks` above
                                     // fuses them into one "subject" for the engine's own decisions
                                     // (lift the person, defog the sky), which is right for a
                                     // global judgement and wrong for editing: two people at
                                     // different distances from the light want different amounts,
                                     // and the merged mask can only give them the average.
                                     instances: SubjectInstances.detect(in: proxy))
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
                statusMessage = "Ready · restored your edit from \(Self.friendlyDate(saved.savedAt))"
            } else {
                statusMessage = "Ready · pick a look, or Batch apply it to a folder"
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
                self.fixInProgress = false
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
            return "Fixed \(run.resolved.count) of \(total) · \(run.remaining.count) left alone — "
                + "they pull against what was fixed"
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
            statusMessage = "No subject Kelvin can isolate in this frame — that one needs a mask you draw"
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
            hsl = look.hsl ?? [:]
        } else {
            hsl = [:]
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
        guard let proxy = proxyCI, let deg = HorizonDetector.levelingAngle(in: proxy) else { return }
        straighten = min(15, max(-15, deg))
        onEdit()
    }

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
                let touched = self.edit != self.editBaseline || !self.userMasks.isEmpty
                    || self.straighten != 0 || !self.hsl.isEmpty || self.removeDust
                if touched { self.editedURLs.insert(url) } else { self.editedURLs.remove(url) }
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
    @Published var selectedUserMaskId: UUID?

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
        let framed = framedExtent, source = proxyCI?.extent ?? framed
        let frac = distPx / min(rect.width, rect.height)
        let scale = min(source.width, source.height) > 0
            ? min(framed.width, framed.height) / min(source.width, source.height) : 1
        withMask(id) { $0.radius = min(1.2, max(0.05, Double(frac) * Double(scale))) }
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
        showMaskOverlay = true                         // auto-show mask overlay when adding a mask
        if kind == .brush { paintingMaskId = m.id }    // brush: start painting right away
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
        // Throttle: skip if the last stamp is closer than ~⅓ of the brush radius. Scale by zoom so
        // the stroke stays smooth when zoomed in (a screen-inch covers less of the image).
        let minStep = brushRadius * 0.33 / max(1, zoom)
        if let last = userMasks[idx].stamps.last {
            let dx = last.x - nx, dy = last.y - ny
            if (dx * dx + dy * dy).squareRoot() < minStep { return }
        }
        // Round to 4 decimals: sub-pixel even on a 9504 px export, and it keeps the sidecar (and
        // every undo snapshot) compact — stamps are the one recipe field that grows with use.
        func r4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
        userMasks[idx].stamps.append(
            BrushStamp(x: r4(nx), y: r4(ny), radius: r4(brushRadius), hardness: 0.6))
        onEdit()
    }

    /// The masks to render: the candidate's masks (minus any switched off, scaled to strength),
    /// plus the user's hand-drawn gradient masks.
    private func activeMasks() -> [Mask]? {
        var ms = baseMasks.compactMap { m -> Mask? in
            guard maskEnabled[m.id] ?? true else { return nil }
            var m = m
            m.opacity = clampStep((maskStrength[m.id] ?? m.opacity * 100) / 100, 0...1, 0.01)
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
                    "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!
                ]).cropped(to: extent)
            } else {
                bitmap = bitmaps[maskStruct.id] ?? bitmaps[maskStruct.type]
            }
            if let b = bitmap {
                return (b, maskStruct.invert, maskStruct.feather, maskStruct.tightness ?? 0)
            }
        }
        if let firstBase = baseMaskIds.first(where: { maskEnabled[$0] ?? true }) {
            if let b = proxyMaskBitmaps[firstBase] {
                let invert = maskInvert[firstBase] ?? false
                let feather = maskFeather[firstBase] ?? 0
                let tightness = maskTightness[firstBase] ?? 0
                return (b, invert, feather, tightness)
            }
        }
        if let firstUser = userMasks.first {
            let maskStruct = firstUser.toMask()
            if let b = bitmaps[maskStruct.id] ?? bitmaps[maskStruct.type] {
                return (b, maskStruct.invert, maskStruct.feather, maskStruct.tightness ?? 0)
            }
        }
        return nil
    }

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
            guard let composited = Renderer.brushMask(m.stamps, extent: extent),
                  let cg = context.createCGImage(composited, from: extent) else { continue }
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
        let ctx = context
        // Which photo these pixels are of. A render started before a photo switch can still land
        // after it; tagged, that frame is ignored instead of being shown under the new photo's name.
        let renderedURL = loadedURL
        let showOverlay = showMaskOverlay
        let overlayTarget = showOverlay ? activeSelectedMaskBitmap(extent: proxy.extent) : nil
        Task.detached(priority: .userInitiated) {
            var rendered = Renderer.render(input.proxy, with: input.recipe, maskBitmaps: input.bitmaps)
            if let ov = overlayTarget {
                rendered = Renderer.renderMaskOverlay(rendered, maskBitmap: ov.bitmap, invert: ov.invert, feather: ov.feather, tightness: ov.tightness, opacity: 0.6)
            }
            let cg = ctx.createCGImage(rendered, from: rendered.extent)
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
            let reading = CraftFix.Reading(stats: stats, face: FaceSkin.read(in: r))
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
        let wanted = Set(userMasks.compactMap { $0.kind == .instance ? $0.instanceId : nil })
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

    func exportFullResolution(to exportURL: URL) async {
        guard let fullRes = fullResCI, let recipe = activeRecipe else { return }
        isProcessing = true
        statusMessage = "Rendering full resolution…"
        do {
            // Regenerate masks at full resolution so the local edits are crisp on export.
            let masks = (recipe.masks?.isEmpty == false)
                ? fullResolutionMaskBitmaps(for: fullRes) : [:]
            try ImageWriter.write(Renderer.render(fullRes, with: recipe, maskBitmaps: masks), to: exportURL)
            statusMessage = "Exported \(exportURL.lastPathComponent)"
            // Exporting is the one unambiguous signal of preference, so it's logged. NOTE: nothing
            // currently reads this back — candidates are generated fresh per photo, by design (the
            // way to reuse an edit is Batch apply, not a cross-image average). The log exists so
            // that decision can be revisited with real data; it is not a live learning loop, and
            // the UI must not claim otherwise.
            recordCurrentPick()
        } catch {
            statusMessage = "Export failed — \(error.localizedDescription)"
        }
        isProcessing = false
    }

    /// Apply the chosen *look* across a folder with per-photo intelligence: the style is held
    /// constant, but every photo is re-perceived and re-measured so its own corrective baseline
    /// (exposure / white balance / tone) is derived fresh. A shoot's frames differ in exposure
    /// and scene — copying identical slider values would wreck half of them. The manual tweaks
    /// you made on the reference photo ride along on top of each adapted recipe.
    func runBatchApply(inputDir: URL, outputDir: URL) async {
        guard let styleId = selectedCandidateId,
              let style = CandidateStyle.all.first(where: { $0.id == styleId }) else { return }
        let tweaks = manualTweaks()
        isProcessing = true
        do {
            let files = try BatchApply.imageFiles(in: inputDir)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            var written: [URL] = []
            var failures: [BatchApply.Failure] = []
            for (i, file) in files.enumerated() {
                statusMessage = "Adapting \(style.label) to photo \(i + 1) of \(files.count)…"
                do {
                    let image = try ImageDecoder.decode(url: file)
                    let proxy = PerceptionProxy.downsample(image)
                    let perception = try await perceptionProvider.perceive(proxy)
                    let stats = try ImageStatistics.compute(proxy)
                    // Per-photo subject + sky masks — each frame gets its own local decisions.
                    let m = LocalMasks.measure(in: proxy)
                    var recipe = RecipeEngine.candidate(perception: perception, statistics: stats,
                                                        style: style, subjectLuma: m.subjectLuma,
                                                        skyLuma: m.skyLuma, iso: ExifReader.iso(url: file))
                    applyTweaks(tweaks, to: &recipe.global)
                    applyLookBeyondGlobals(to: &recipe)
                    // Sensor dust sits at the same normalised position on every frame of a shoot,
                    // so the spots found on the reference photo heal the whole batch.
                    recipe.heal = (removeDust && !healSpots.isEmpty) ? healSpots : nil
                    let masks = (recipe.masks?.isEmpty == false) ? LocalMasks.measure(in: image).bitmaps : [:]
                    // Name each output from what the model read about THAT frame, so a batch
                    // comes out searchable rather than as a wall of camera serial numbers.
                    let stem = ExportNaming.stem(for: file, perception: perception, look: style.label)
                    let out = ExportNaming.uniqueURL(in: outputDir, stem: stem, ext: "jpg")
                    try ImageWriter.write(Renderer.render(image, with: recipe, maskBitmaps: masks),
                                          to: out, format: .jpeg(quality: 0.97))
                    written.append(out)
                } catch {
                    failures.append(BatchApply.Failure(source: file, message: "\(error)"))
                }
            }
            self.batchOutcome = BatchApply.Outcome(written: written, failures: failures)
            self.showBatchSheet = true
            statusMessage = "Batch done · \(written.count) edited as \(style.label), \(failures.count) skipped"
        } catch {
            statusMessage = "Batch failed — \(error.localizedDescription)"
        }
        isProcessing = false
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

    private func applyTweaks(_ t: [String: Double], to g: inout GlobalAdjustments) {
        g.exposureEV = clampStep(g.exposureEV + (t["exposure_ev"] ?? 0), -5...5, 0.05)
        g.contrast = clampStep(g.contrast + (t["contrast"] ?? 0), -100...100, 1)
        g.highlights = clampStep(g.highlights + (t["highlights"] ?? 0), -100...100, 1)
        g.shadows = clampStep(g.shadows + (t["shadows"] ?? 0), -100...100, 1)
        g.whites = clampStep(g.whites + (t["whites"] ?? 0), -100...100, 1)
        g.blacks = clampStep(g.blacks + (t["blacks"] ?? 0), -100...100, 1)
        g.vibrance = clampStep(g.vibrance + (t["vibrance"] ?? 0), -100...100, 1)
        g.saturation = clampStep(g.saturation + (t["saturation"] ?? 0), -100...100, 1)
        g.clarity = clampStep(g.clarity + (t["clarity"] ?? 0), -100...100, 1)
        g.texture = clampStep(g.texture + (t["texture"] ?? 0), -100...100, 1)
        g.dehaze = clampStep(g.dehaze + (t["dehaze"] ?? 0), 0...100, 1)
        g.fusion = clampStep(g.fusion + (t["fusion"] ?? 0), 0...100, 1)
        g.tint = clampStep(g.tint + (t["tint"] ?? 0), -100...100, 1)
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

    private func clampStep(_ v: Double, _ r: ClosedRange<Double>, _ step: Double) -> Double {
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
                    Text("Drop a photo. Kelvin reads the scene on-device and offers a few finished looks — pick one, tune it, then apply it across the shoot.")
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
                    Text("Choose a photo")
                        .font(Theme.ui(13, .semibold))
                        .foregroundColor(Theme.base)
                        .padding(.horizontal, 22).padding(.vertical, 11)
                        .background(Capsule().fill(Theme.glow))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Text("RAW · JPEG · PNG   —   on-device, nothing leaves your Mac")
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
                                  sortKey: $appState.photoSort,
                                  sortReversed: $appState.photoSortReversed,
                                  sortPending: appState.sortOrderPending)
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
            SubjectHighlight(instance: instance, imageFrame: appState.imageRect(in: container))
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
                let rPx = m.radius * min(rect.width, rect.height)
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
            case .instance:
                // No handles — the shape is the subject's, not something to drag. But show WHICH
                // subject: the sliders below say "Exposure", and on a frame with three people
                // there is otherwise nothing on screen saying whose.
                if let instance = appState.subjectInstances.first(where: { $0.id == m.instanceId }) {
                    SubjectHighlight(instance: instance, imageFrame: rect)
                }
            case .brush, .colorRange, .luminance, .skin, .background, .subject:
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
                                .font(Theme.ui(10, appState.showMaskOverlay ? .semibold : .regular))
                        }
                        .foregroundColor(appState.showMaskOverlay ? Theme.glow : Theme.inkDim)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(
                            Capsule().fill(appState.showMaskOverlay ? Theme.glow.opacity(0.15) : Theme.surface2)
                                .overlay(Capsule().stroke(appState.showMaskOverlay ? Theme.glow.opacity(0.6) : Theme.hairline, lineWidth: 1))
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
                            .help("Work through every flag in one step, worst damage first — "
                                  + "clipping, then tone, then colour and skin")
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
                                    .help("Kelvin's automatic correction for this is already as far "
                                          + "as it goes — from here it's a manual adjustment")
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
                // Clickable: coordinates are only useful if you can get to a map from them.
                if let url = c.mapURL {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.and.ellipse").font(.system(size: 9))
                            Text(location).font(Theme.mono(9))
                        }.foregroundColor(Theme.glow)
                    }
                } else {
                    Text(location).font(Theme.mono(9)).foregroundColor(Theme.inkFaint)
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
                    Button(action: appState.resetToCandidate) { editToolLabel("Reset all", enabled: true, icon: "arrow.counterclockwise") }
                        .buttonStyle(.plain)
                }

                Group {
                CollapsibleSection("Candidates", icon: "rectangle.stack", defaultOpen: true) {
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
                    ToneSlider(label: "Temp", value: appState.temperatureBinding, range: 2500...9500, step: 10, unit: " K", onChange: ch, identity: .temperature)
                    ToneSlider(label: "Tint", value: $appState.edit.tint, range: -100...100, step: 1, unit: "", onChange: ch, identity: .tint)
                    Divider().overlay(Theme.hairline).padding(.vertical, 2)
                    ToneSlider(label: "Exposure", value: $appState.edit.exposureEV, range: -5...5, step: 0.05, unit: " EV", onChange: ch, identity: .exposure)
                    ToneSlider(label: "Contrast", value: $appState.edit.contrast, range: -100...100, step: 1, unit: "", onChange: ch, identity: .contrast)
                    ToneSlider(label: "Highlights", value: $appState.edit.highlights, range: -100...100, step: 1, unit: "", onChange: ch, identity: .highlights)
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
                            onReset: { appState.resetMask(mid) })
                    }
                    // Hand-drawn masks: gradient geometry or brush strokes + local adjustments.
                    ForEach($appState.userMasks) { $m in
                        UserMaskEditor(
                            mask: $m, onChange: appState.onEdit,
                            onDelete: { appState.removeUserMask(m.id) },
                            isSelected: appState.selectedUserMaskId == m.id,
                            onSelect: { appState.selectedUserMaskId = m.id },
                            isPainting: appState.paintingMaskId == m.id,
                            togglePaint: { appState.paintingMaskId = (appState.paintingMaskId == m.id) ? nil : m.id },
                            clearStrokes: { appState.clearStrokes(m.id) },
                            brushRadius: Binding(get: { appState.brushRadius },
                                                 set: { appState.brushRadius = $0 }),
                            hasPerson: appState.hasPerson)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        // The "+" used to be repeated on all eight buttons. Said once over the
                        // grid it costs a line and buys every button back the width its glyph
                        // needs — and the row stops reading as a list of things called "+ Luma".
                        Text("ADD A MASK")
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
                }

                // Last: a record of the photograph, not a control reached for mid-edit.
                if appState.capture.camera != nil || appState.capture.summaryText != nil {
                    CollapsibleSection("Capture", icon: "camera") { capturePanel }
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
                HStack(spacing: 28) {
                    stat("\(outcome.succeeded)", "applied", Theme.glow)
                    stat("\(outcome.failed)", "skipped", outcome.failed > 0 ? Theme.cool : Theme.inkFaint)
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
        panel.nameFieldStringValue = appState.suggestedExportName()
        if panel.runModal() == .OK, let url = panel.url {
            Task { await appState.exportFullResolution(to: url) }
        }
    }

    private func openBatchPanel() {
        let input = NSOpenPanel()
        input.title = "Choose the shoot folder"
        input.canChooseDirectories = true; input.canChooseFiles = false
        guard input.runModal() == .OK, let inputDir = input.url else { return }
        let output = NSOpenPanel()
        output.title = "Choose where to write edits"
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
    private var exposure: Double { candidate.baseRecipe.global.exposureEV }

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
                    Text(String(format: "%+.2f EV", exposure))
                        .font(Theme.mono(10)).foregroundColor(Theme.inkFaint)
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

    /// 64-bin luma histogram sampled from the rendered proxy. Cheap (100×100 sample).
    static func luma(_ image: CIImage?) -> [Double]? {
        guard let image, let data = try? ImageWriter.rgba8Sampled(image, width: 100, height: 100) else { return nil }
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
    @State private var resetTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(Theme.ui(12)).foregroundColor(Theme.inkDim)
                Spacer()
                Text(readout)
                    .font(Theme.mono(11, value == 0 ? .regular : .semibold))
                    .foregroundColor(value == 0 ? Theme.inkFaint : Theme.glow)
                    .animation(Motion.gated(Motion.quick, reduceMotion), value: resetTick)
            }
            VStack(spacing: 3) {
                Slider(value: $value, in: range, step: step)
                    // The accent stays the same on every slider: it is the language of "where the
                    // value is", and the rail below is the language of "what this does". Making
                    // both vary at once would leave neither reliable.
                    .tint(Theme.glow)
                    .controlSize(.small)
                    // Live: re-render on every value change during the drag, not just on release.
                    .onChange(of: value) { _ in onChange() }
                ToneRail(identity: identity)
            }
        }
        // Double-click the row to reset this control to its neutral value.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if range.contains(0) { value = 0; onChange(); resetTick += 1 }
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
    var exposure = 0.0, contrast = 0.0, saturation = 0.0
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

    enum CodingKeys: String, CodingKey {
        case id, kind, cx, cy, radius, angle, softness, stamps, selCenter, selRange, selSoftness
        case exposure, contrast, saturation, instanceId, instanceLabel, instanceBox, instanceKind
        case tightness, feather, invert
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
    var hasCanvasHandles: Bool { kind == .radial || kind == .linear }

    func toMask() -> Mask {
        var adj: [String: Double] = [:]
        if exposure != 0 { adj["exposure_ev"] = exposure }
        if contrast != 0 { adj["contrast"] = contrast }
        if saturation != 0 { adj["saturation"] = saturation }
        let f = feather
        let t = tightness
        let inv = invert
        switch kind {
        case .brush:
            return Mask(id: id.uuidString, type: "brush", source: "brush", invert: inv,
                        feather: f, opacity: 1, adjustments: adj, stamps: stamps, tightness: t)
        case .radial, .linear:
            let sk: MaskShape.Kind = kind == .radial ? .radial : .linear
            return Mask(id: id.uuidString, type: sk.rawValue, source: "gradient", invert: inv,
                        feather: f, opacity: 1, adjustments: adj,
                        shape: MaskShape(kind: sk, cx: cx, cy: cy, radius: radius, angle: angle, softness: softness), tightness: t)
        case .colorRange, .luminance:
            let k: MaskSelection.Kind = kind == .colorRange ? .color : .luminance
            return Mask(id: id.uuidString, type: k.rawValue, source: "selection", invert: inv,
                        feather: f, opacity: 1, adjustments: adj,
                        selection: MaskSelection(kind: k, center: selCenter, range: selRange, softness: selSoftness), tightness: t)
        case .skin:
            return Mask(id: id.uuidString, type: "skin", source: "skin", invert: inv,
                        feather: f, opacity: 1, adjustments: adj,
                        selection: MaskSelection(kind: .color, center: selCenter, range: selRange, softness: selSoftness), tightness: t)
        case .background:
            let finalInvert = inv ? false : true
            let finalFeather = f != 0 ? f : 20
            return Mask(id: id.uuidString, type: "subject", source: "segmentation", invert: finalInvert,
                        feather: finalFeather, opacity: 1, adjustments: adj, tightness: t)
        case .subject:
            let finalFeather = f != 0 ? f : 30
            return Mask(id: id.uuidString, type: "subject", source: "segmentation", invert: inv,
                        feather: finalFeather, opacity: 1, adjustments: adj, tightness: t)
        case .instance:
            let finalFeather = f != 0 ? f : 30
            return Mask(id: instanceId ?? id.uuidString, type: "instance", source: "segmentation",
                        invert: inv, feather: finalFeather, opacity: 1, adjustments: adj, tightness: t)
        }
    }
}

struct UserMaskEditor: View {
    @Binding var mask: UserMaskVM
    let onChange: () -> Void
    let onDelete: () -> Void
    var isSelected = false
    var onSelect: () -> Void = {}
    var isPainting = false
    var togglePaint: () -> Void = {}
    var clearStrokes: () -> Void = {}
    var brushRadius: Binding<Double> = .constant(0.09)
    var hasPerson = true

    /// Skin and Background are built from the person segmentation — flag it when there isn't one,
    /// so the mask isn't just quietly inert.
    private var needsPersonButHasNone: Bool {
        (mask.kind == .skin || mask.kind == .background || mask.kind == .subject) && !hasPerson
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(mask.label).font(Theme.ui(12, .semibold)).foregroundColor(Theme.ink)
                if isSelected && mask.kind != .brush {
                    Text("editing on canvas").font(Theme.mono(9)).foregroundColor(Theme.glow)
                }
                Spacer()
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
                ToneSlider(label: "Brush size", value: brushRadius, range: 0.02...0.35, step: 0.01, unit: "", onChange: {})
            case .radial:
                ToneSlider(label: "Center X", value: $mask.cx, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Center Y", value: $mask.cy, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Size", value: $mask.radius, range: 0.05...1.2, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Softness", value: $mask.softness, range: 0...1, step: 0.01, unit: "", onChange: onChange)
            case .linear:
                ToneSlider(label: "Center X", value: $mask.cx, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Center Y", value: $mask.cy, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Angle", value: $mask.angle, range: 0...360, step: 1, unit: "°", onChange: onChange)
                ToneSlider(label: "Softness", value: $mask.softness, range: 0...1, step: 0.01, unit: "", onChange: onChange)
            case .colorRange:
                // Hue picker (0…1 → the colour wheel) + how wide a band + edge softness.
                ToneSlider(label: "Hue", value: $mask.selCenter, range: 0...1, step: 0.005, unit: "", onChange: onChange, identity: .spectrum)
                ToneSlider(label: "Range", value: $mask.selRange, range: 0.01...0.5, step: 0.005, unit: "", onChange: onChange)
                ToneSlider(label: "Softness", value: $mask.selSoftness, range: 0...0.3, step: 0.005, unit: "", onChange: onChange)
            case .luminance:
                ToneSlider(label: "Brightness", value: $mask.selCenter, range: 0...1, step: 0.01, unit: "", onChange: onChange, identity: .exposure)
                ToneSlider(label: "Range", value: $mask.selRange, range: 0.01...0.5, step: 0.005, unit: "", onChange: onChange)
                ToneSlider(label: "Softness", value: $mask.selSoftness, range: 0...0.3, step: 0.005, unit: "", onChange: onChange)
            case .skin:
                Text("Skin tones within the detected person, fair across complexions.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                ToneSlider(label: "Tolerance", value: $mask.selRange, range: 0.02...0.18, step: 0.005, unit: "", onChange: onChange)
            case .background:
                Text("Everything except the detected subject — darken or blur it to make the subject pop.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            case .subject:
                Text("The detected person — lift, model, or recover them without touching the scene.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            case .instance:
                Text("Just this one — everything else in the frame is untouched.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
            ToneSlider(label: "Exposure", value: $mask.exposure, range: -3...3, step: 0.05, unit: " EV", onChange: onChange, identity: .exposure)
            ToneSlider(label: "Contrast", value: $mask.contrast, range: -100...100, step: 1, unit: "", onChange: onChange, identity: .contrast)
            ToneSlider(label: "Saturation", value: $mask.saturation, range: -100...100, step: 1, unit: "", onChange: onChange, identity: .saturation(hue: nil))
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
    /// Folded by default. A subject mask usually needs nothing beyond the strength Kelvin chose,
    /// and six sliders per mask unfolded would rebuild the wall of controls the sidebar just lost.
    @State private var showAdjustments = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isOn) {
                Text(name).font(Theme.ui(13, .medium)).foregroundColor(Theme.ink)
            }
            .toggleStyle(.switch).tint(Theme.glow)
            .onChange(of: isOn) { _ in onChange() }

            if isOn {
                HStack {
                    Text("Strength").font(Theme.ui(11)).foregroundColor(Theme.inkDim)
                    Spacer()
                    Text("\(Int(strength))%").font(Theme.mono(10)).foregroundColor(Theme.glow)
                }
                Slider(value: $strength, in: 0...100, step: 1) { editing in if !editing { onChange() } }
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
                                           identity: ToneIdentity.adjustment(spec.key))
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
                                .onChange(of: invert.wrappedValue) { _ in onChange() }
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
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline.opacity(0.6), lineWidth: 1))
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
