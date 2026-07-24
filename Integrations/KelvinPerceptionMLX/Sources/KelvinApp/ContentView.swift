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

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
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
    @Published var activePreviewImage: NSImage?
    /// The untouched original (proxy), for the press-and-hold before/after compare.
    @Published var originalPreviewImage: NSImage?
    @Published var showingOriginal = false
    /// Objective craft flags on the current edit (clipping, skin, cast) — empty when clean.
    @Published var activeCraftIssues: [AestheticEvaluator.Issue] = []

    /// The full editable global adjustment set (absolute values, Lightroom-style). Sliders bind
    /// straight to its fields; it starts from the chosen candidate and the user takes it from there.
    @Published var edit = GlobalAdjustments.neutral
    /// The candidate's values as generated — the baseline manual edits are measured against (for
    /// the "carry my tweaks to the batch" and preference logging), and what Reset returns to.
    private var editBaseline = GlobalAdjustments.neutral
    /// Manual straighten angle (degrees); auto-crops the corners. Per-photo framing.
    @Published var straighten = 0.0
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
    /// Hand-added parametric gradient masks (radial / linear) — the user's own local edits.
    @Published var userMasks: [UserMaskVM] = []

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
    @Published var learnedProfile: PreferenceProfile = .empty
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

    /// The other photos sitting in the folder you opened from, for the filmstrip.
    @Published var folderPhotos: [URL] = []
    /// Photos whose edit differs from the candidate Kelvin generated (drives the strip's dot).
    @Published var editedURLs: Set<URL> = []
    /// Full editing state per photo, so switching away and back is instant and lossless — no
    /// re-running the model. Bounded, because each entry pins decoded images.
    private var sessions: [URL: PhotoSession] = [:]
    private var sessionOrder: [URL] = []
    private static let maxSessions = 8
    private var thumbnails: [URL: NSImage] = [:]

    func thumbnail(for url: URL) -> NSImage? {
        if let hit = thumbnails[url] { return hit }
        let t = PhotoBrowser.thumbnail(for: url)
        if let t { thumbnails[url] = t }
        return t
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
        maskEnabled = saved.maskEnabled
        maskStrength = saved.maskStrength
        straighten = saved.straighten
        hsl = saved.hsl
        removeDust = saved.removeDust
        brushCache = [:]
        updateActiveRecipe()
        resetHistory()
    }

    /// Capture the current photo's state before leaving it.
    private func stashCurrentSession() {
        guard let url = imageURL, let full = fullResCI, let proxy = proxyCI else { return }
        let session = PhotoSession(
            url: url, imageId: imageId, fullResCI: full, proxyCI: proxy,
            originalPreviewImage: originalPreviewImage, perception: perception,
            candidates: candidates, proxyMaskBitmaps: proxyMaskBitmaps,
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
        fullResCI = s.fullResCI; proxyCI = s.proxyCI
        originalPreviewImage = s.originalPreviewImage
        perception = s.perception; candidates = s.candidates
        proxyMaskBitmaps = s.proxyMaskBitmaps
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
        imageURL = nil
        fullResCI = nil; proxyCI = nil
        candidates = []; selectedCandidateId = nil
        activeRecipe = nil; activePreviewImage = nil; originalPreviewImage = nil
        lastRenderedCI = nil; activeCraftIssues = []
        userMasks = []; paintingMaskId = nil; selectedUserMaskId = nil
        brushCache = [:]
        proxyMaskBitmaps = [:]; healSpots = []; detectedSpotCount = 0
        zoom = 1; pan = .zero; showingOriginal = false
        statusMessage = "Drop a photo to read the light."
    }

    /// Remove a photo from the strip for this session, and forget any edit it had. The file itself
    /// is never touched — this is about clearing the working set, not deleting someone's work.
    func dismiss(_ url: URL) {
        EditStore.remove(for: url)
        editedURLs.remove(url)
        sessions.removeValue(forKey: url)
        sessionOrder.removeAll { $0 == url }
        folderPhotos.removeAll { $0 == url }
        if url == imageURL {
            if let next = folderPhotos.first {
                Task { await openPhoto(next) }
            } else {
                closeCurrentPhoto()
            }
        }
    }

    /// Switch photos from the filmstrip: stash what you were doing, then restore or load fresh.
    func openPhoto(_ url: URL) async {
        guard url != imageURL else { return }
        stashCurrentSession()
        if let cached = sessions[url] {
            restore(cached)
            sessionOrder.removeAll { $0 == url }; sessionOrder.append(url)
            return
        }
        await loadPhoto(from: url)
    }

    func loadPhoto(from url: URL) async {
        isProcessing = true
        statusMessage = "Decoding…"
        // Keep whatever you were working on before this photo takes over.
        if imageURL != nil, imageURL != url { stashCurrentSession() }
        imageURL = url
        folderPhotos = PhotoBrowser.siblings(of: url)
        // Photos edited in an earlier session already carry a dot.
        editedURLs.formUnion(EditStore.edited(among: folderPhotos))
        userMasks = []; paintingMaskId = nil; selectedUserMaskId = nil   // hand-drawn masks are per-photo
        zoom = 1; pan = .zero
        do {
            let fullRes = try ImageDecoder.decode(url: url)
            self.fullResCI = fullRes

            let fileData = try Data(contentsOf: url)
            let hash = SHA256.hash(data: fileData)
            self.imageId = "sha256:" + hash.compactMap { String(format: "%02x", $0) }.joined()

            statusMessage = "Building proxy…"
            // The model wants a small 768px proxy (non-negotiable #4); the EDIT proxy is a bit
            // larger so zooming shows more detail, but not so large that live rendering slows down
            // (1200px balances zoom detail against snappy sliders). Masks build from it, so they
            // stay aligned when zoomed.
            let perceptionProxy = PerceptionProxy.downsample(fullRes)
            let proxy = PerceptionProxy.downsample(fullRes, maxEdge: 1200)
            self.proxyCI = proxy
            // The untouched original, for the before/after compare.
            self.originalPreviewImage = ciToNSImage(proxy)

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
            self.perception = perceptionRead

            statusMessage = "Measuring…"
            let sampleBytes = try ImageMetrics.sample(proxy)
            let stats = ImageStatistics.compute(from: sampleBytes)

            // Subject + sky masks (for local edits). Generated on the proxy for fast previews; the
            // measured region brightness tells the engine whether to lift the subject or defog the sky.
            let measured = LocalMasks.measure(in: proxy)
            self.proxyMaskBitmaps = measured.bitmaps
            self.subjectLuma = measured.subjectLuma
            self.skyLuma = measured.skyLuma
            let proxyMasks = measured.bitmaps

            // Scan for sensor dust once (normalised coords reused everywhere). Conservative — a
            // clean frame yields none. Off until the user opts in.
            self.healSpots = DustDetector.detect(in: proxy)
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
            var scored: [CandidateCurator.Scored] = []
            var previews: [String: NSImage] = [:]
            for recipe in recipes {
                let renderedCI = Renderer.render(proxy, with: recipe, maskBitmaps: proxyMasks)
                guard let nsImage = ciToNSImage(renderedCI),
                      let score = AestheticEvaluator.score(rendered: renderedCI) else { continue }
                let key = recipe.id ?? UUID().uuidString
                previews[key] = nsImage
                scored.append(.init(recipe: recipe, score: score))
            }
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
        updateActiveRecipe()
    }

    func onEdit() { updateActiveRecipe(); scheduleCommit() }

    /// The fix currently being worked on, and how many nudges it has taken.
    private var fixInProgress: AestheticEvaluator.Issue?
    private var fixAttempts = 0
    private static let maxFixAttempts = 5

    /// Apply a targeted correction for a flagged craft issue — the "Fix" the warning offers.
    ///
    /// One nudge often isn't enough: a badly over-saturated frame needs more than −16 saturation,
    /// so the flag would still be there afterwards and you'd have to keep clicking. Now a single
    /// click keeps nudging until the evaluator stops complaining (or gives up after a few rounds,
    /// rather than fighting a photo that can't be fixed this way).
    func applyFix(_ issue: AestheticEvaluator.Issue) {
        fixInProgress = issue
        fixAttempts = 0
        nudge(for: issue)
    }

    /// Called once the craft check has re-run: if the issue survived, go again.
    private func continueFixIfNeeded() {
        guard let issue = fixInProgress else { return }
        guard activeCraftIssues.contains(issue), fixAttempts < Self.maxFixAttempts else {
            fixInProgress = nil
            return
        }
        fixAttempts += 1
        nudge(for: issue)
    }

    private func nudge(for issue: AestheticEvaluator.Issue) {
        func c(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(r.upperBound, max(r.lowerBound, v)) }
        switch issue {
        case .skinOverSaturated:
            edit.saturation = c(edit.saturation - 16, -100...100)
            edit.vibrance = c(edit.vibrance - 12, -100...100)
        case .skinAshy:
            edit.vibrance = c(edit.vibrance + 12, -100...100)
        case .skinHue:
            edit.saturation = c(edit.saturation - 10, -100...100)  // ease the push that skewed the hue
            edit.tint = c(edit.tint - 4, -100...100)
        case .crushedShadows:
            edit.shadows = c(edit.shadows + 22, -100...100)
            edit.blacks = c(edit.blacks + 10, -100...100)
            edit.contrast = c(edit.contrast - 8, -100...100)
        case .blownHighlights:
            edit.highlights = c(edit.highlights - 26, -100...100)
            edit.whites = c(edit.whites - 8, -100...100)
        case .flat:
            edit.contrast = c(edit.contrast + 16, -100...100)
            edit.whites = c(edit.whites + 6, -100...100)
            edit.blacks = c(edit.blacks - 6, -100...100)
        case .colorCast:
            edit.temperatureK = 5500; edit.tint = 0            // neutralise white balance
        }
        onEdit()
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
    func resetHistory() { undoStack = []; redoStack = []; committed = snapshot(); refreshUndoState() }

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
            self.continueFixIfNeeded()
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
        userMasks.append(m)
        selectedUserMaskId = m.id                      // show its canvas handles
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
            return m
        }
        ms += userMasks.map { $0.toMask() }
        return ms.isEmpty ? nil : ms
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
        Task.detached(priority: .userInitiated) {
            let rendered = Renderer.render(input.proxy, with: input.recipe, maskBitmaps: input.bitmaps)
            let cg = ctx.createCGImage(rendered, from: rendered.extent)
            let out = RenderOutput(ci: rendered, cg: cg)
            await MainActor.run {
                self.lastRenderedCI = out.ci
                if let cg = out.cg { self.activePreviewImage = NSImage(cgImage: cg, size: .zero) }
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
            self.activeCraftIssues = AestheticEvaluator.score(rendered: r)?.issues ?? []
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

    func exportFullResolution(to exportURL: URL) async {
        guard let fullRes = fullResCI, let recipe = activeRecipe else { return }
        isProcessing = true
        statusMessage = "Rendering full resolution…"
        do {
            // Regenerate masks at full resolution so the local edits are crisp on export.
            let masks = (recipe.masks?.isEmpty == false) ? LocalMasks.measure(in: fullRes).bitmaps : [:]
            try ImageWriter.write(Renderer.render(fullRes, with: recipe, maskBitmaps: masks), to: exportURL)
            statusMessage = "Exported \(exportURL.lastPathComponent)"
            recordCurrentPick()   // exporting a look IS the deliberate choice worth learning from
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
                    let out = outputDir.appendingPathComponent(file.deletingPathExtension().lastPathComponent)
                        .appendingPathExtension("jpg")
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

    private func ciToNSImage(_ ciImage: CIImage) -> NSImage? {
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
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
    @StateObject private var appState = AppState()
    @State private var isTargeted = false
    @State private var panStart = CGSize.zero
    @State private var zoomStart = 1.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            if appState.selectedCandidateId != nil, appState.activePreviewImage != nil {
                workspace
            } else {
                emptyState
            }
        }
        .background(Theme.base)
        .preferredColorScheme(.dark)
        .task { await appState.loadDemoIfRequested() }
        .sheet(isPresented: $appState.showBatchSheet) { batchSheet }
    }

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
            HStack(spacing: 8) {
                if appState.isProcessing {
                    ProgressView().controlSize(.small).tint(Theme.glow)
                } else {
                    Circle().fill(Theme.glow).frame(width: 5, height: 5)
                }
                Text(appState.statusMessage)
                    .font(Theme.mono(11))
                    .foregroundColor(Theme.inkDim)
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
                    Text("Drop a photo. Kelvin reads the scene and hands you four finished looks — pick one, and it learns.")
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

                Button(action: openFileImporter) {
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
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url { Task { @MainActor in await appState.loadPhoto(from: url) } }
            }
            return true
        }
    }

    // MARK: Workspace

    private var workspace: some View {
        HSplitView {
            // Preview + the active look's white balance on the rail
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack {
                        if let img = (appState.showingOriginal ? appState.originalPreviewImage : appState.activePreviewImage) ?? appState.activePreviewImage {
                            Image(nsImage: img)
                                .resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(24)
                                .scaleEffect(appState.zoom, anchor: .center)
                                .offset(appState.pan)
                        }
                    }
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
                    // Double-click to fit.
                    .onTapGesture(count: 2) { appState.resetZoom(); zoomStart = 1 }
                }
                previewFooter
                if appState.folderPhotos.count > 1 {
                    FilmstripView(photos: appState.folderPhotos,
                                  current: appState.imageURL,
                                  editedURLs: appState.editedURLs,
                                  thumbnail: appState.thumbnail(for:),
                                  onSelect: { url in Task { await appState.openPhoto(url) } },
                                  onDismiss: { appState.dismiss($0) })
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
            case .brush, .colorRange, .luminance, .skin, .background:
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
            if !appState.activeCraftIssues.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(appState.activeCraftIssues, id: \.self) { issue in
                        HStack(spacing: 8) {
                            Text("⚠").font(Theme.ui(10))
                            Text(issue.message).font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                            Spacer(minLength: 4)
                            Button(action: { appState.applyFix(issue) }) {
                                Text("Fix").font(Theme.ui(10, .semibold)).foregroundColor(Theme.base)
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.glow))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
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
        .help(look.blurb)
    }

    private func editToolLabel(_ text: String, enabled: Bool) -> some View {
        Text(text)
            .font(Theme.ui(11, .semibold))
            .foregroundColor(enabled ? Theme.ink : Theme.inkFaint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(Theme.surface2.opacity(enabled ? 1 : 0.4))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
            )
    }

    private func addMaskLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(11, .semibold)).foregroundColor(Theme.ink)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Theme.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline, lineWidth: 1))
            )
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HistogramView(image: appState.lastRenderedCI)

                HStack(spacing: 8) {
                    Button(action: appState.undo) { editToolLabel("Undo", enabled: appState.canUndo) }
                        .buttonStyle(.plain).disabled(!appState.canUndo)
                        .keyboardShortcut("z", modifiers: .command)
                    Button(action: appState.redo) { editToolLabel("Redo", enabled: appState.canRedo) }
                        .buttonStyle(.plain).disabled(!appState.canRedo)
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                    Spacer()
                    Button(action: appState.resetToCandidate) { editToolLabel("Reset all", enabled: true) }
                        .buttonStyle(.plain)
                }

                sectionLabel("Candidates", trailing: nil)
                VStack(spacing: 8) {
                    ForEach(appState.candidates) { candidate in
                        CandidateRow(candidate: candidate,
                                     isSelected: candidate.id == appState.selectedCandidateId) {
                            appState.selectCandidate(id: candidate.id)
                        }
                    }
                }

                let ch = appState.onEdit   // re-render on any slider change

                sectionLabel("Looks", trailing: appState.activeLookId == nil ? nil : "On")
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

                sectionLabel("White balance", trailing: nil)
                VStack(spacing: 14) {
                    ToneSlider(label: "Temp", value: appState.temperatureBinding, range: 2500...9500, step: 10, unit: " K", onChange: ch)
                    ToneSlider(label: "Tint", value: $appState.edit.tint, range: -100...100, step: 1, unit: "", onChange: ch)
                }

                sectionLabel("Tone", trailing: nil)
                VStack(spacing: 14) {
                    ToneSlider(label: "Exposure", value: $appState.edit.exposureEV, range: -5...5, step: 0.05, unit: " EV", onChange: ch)
                    ToneSlider(label: "Contrast", value: $appState.edit.contrast, range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Highlights", value: $appState.edit.highlights, range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Shadows", value: $appState.edit.shadows, range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Whites", value: $appState.edit.whites, range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Blacks", value: $appState.edit.blacks, range: -100...100, step: 1, unit: "", onChange: ch)
                }

                sectionLabel("Presence", trailing: nil)
                VStack(spacing: 14) {
                    ToneSlider(label: "Texture", value: $appState.edit.texture, range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Clarity", value: $appState.edit.clarity, range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Dehaze", value: $appState.edit.dehaze, range: 0...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Fusion", value: $appState.edit.fusion, range: 0...100, step: 1, unit: "", onChange: ch)
                }

                sectionLabel("Color", trailing: nil)
                VStack(spacing: 14) {
                    ToneSlider(label: "Vibrance", value: $appState.edit.vibrance, range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Saturation", value: $appState.edit.saturation, range: -100...100, step: 1, unit: "", onChange: ch)
                }

                sectionLabel("Color mixer", trailing: nil)
                VStack(spacing: 12) {
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
                    ToneSlider(label: "Hue", value: appState.hslBinding(\.h), range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Saturation", value: appState.hslBinding(\.s), range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Luminance", value: appState.hslBinding(\.l), range: -100...100, step: 1, unit: "", onChange: ch)
                }

                sectionLabel("Geometry", trailing: nil)
                VStack(spacing: 12) {
                    ToneSlider(label: "Straighten", value: $appState.straighten, range: -15...15, step: 0.1, unit: "°", onChange: ch)
                    Button(action: appState.autoStraighten) { addMaskLabel("Auto-level horizon") }
                        .buttonStyle(.plain)
                }

                sectionLabel("Masks", trailing: nil)
                VStack(spacing: 12) {
                    // Auto-detected masks (subject / sky): toggle + strength.
                    ForEach(appState.baseMaskIds, id: \.self) { mid in
                        MaskControl(
                            name: mid.capitalized,
                            isOn: Binding(get: { appState.maskEnabled[mid] ?? true },
                                          set: { appState.maskEnabled[mid] = $0 }),
                            strength: Binding(get: { appState.maskStrength[mid] ?? 100 },
                                              set: { appState.maskStrength[mid] = $0 }),
                            onChange: appState.onEdit)
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
                    VStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.radial) }) { addMaskLabel("+ Radial") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.linear) }) { addMaskLabel("+ Grad") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.brush) }) { addMaskLabel("+ Brush") }.buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.colorRange) }) { addMaskLabel("+ Colour") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.luminance) }) { addMaskLabel("+ Luma") }.buttonStyle(.plain)
                            Button(action: { appState.addUserMask(.skin) }) { addMaskLabel("+ Skin") }.buttonStyle(.plain)
                        }
                        HStack(spacing: 6) {
                            Button(action: { appState.addUserMask(.background) }) { addMaskLabel("+ Background") }.buttonStyle(.plain)
                            Color.clear.frame(maxWidth: .infinity)
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }

                sectionLabel("Repair", trailing: appState.detectedSpotCount > 0 ? "\(appState.detectedSpotCount) spots" : nil)
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
            .padding(20)
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

    private func openFileImporter() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await appState.loadPhoto(from: url) }
        }
    }

    private func openExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = "kelvin-edit.jpg"
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

struct ToneSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(Theme.ui(12)).foregroundColor(Theme.inkDim)
                Spacer()
                Text(readout)
                    .font(Theme.mono(11, value == 0 ? .regular : .semibold))
                    .foregroundColor(value == 0 ? Theme.inkFaint : Theme.glow)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Theme.glow)
                .controlSize(.small)
                // Live: re-render on every value change during the drag, not just on release.
                .onChange(of: value) { _ in onChange() }
        }
        // Double-click the row to reset this control to its neutral value.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if range.contains(0) { value = 0; onChange() }
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
        case radial, linear, brush, colorRange, luminance, skin, background
    }
    var id = UUID()
    var kind: Kind
    var cx = 0.5, cy = 0.5, radius = 0.35, angle = 0.0, softness = 0.35
    var stamps: [BrushStamp] = []                       // brush only
    var selCenter = 0.0, selRange = 0.1, selSoftness = 0.1   // colour / luminance / skin selection
    var exposure = 0.0, contrast = 0.0, saturation = 0.0

    var label: String {
        switch kind {
        case .radial: return "Radial"; case .linear: return "Graduated"; case .brush: return "Brush"
        case .colorRange: return "Colour range"; case .luminance: return "Luminance"; case .skin: return "Skin"
        case .background: return "Background"
        }
    }
    var hasCanvasHandles: Bool { kind == .radial || kind == .linear }

    func toMask() -> Mask {
        var adj: [String: Double] = [:]
        if exposure != 0 { adj["exposure_ev"] = exposure }
        if contrast != 0 { adj["contrast"] = contrast }
        if saturation != 0 { adj["saturation"] = saturation }
        switch kind {
        case .brush:
            return Mask(id: id.uuidString, type: "brush", source: "brush", invert: false,
                        feather: 0, opacity: 1, adjustments: adj, stamps: stamps)
        case .radial, .linear:
            let sk: MaskShape.Kind = kind == .radial ? .radial : .linear
            return Mask(id: id.uuidString, type: sk.rawValue, source: "gradient", invert: false,
                        feather: 0, opacity: 1, adjustments: adj,
                        shape: MaskShape(kind: sk, cx: cx, cy: cy, radius: radius, angle: angle, softness: softness))
        case .colorRange, .luminance:
            let k: MaskSelection.Kind = kind == .colorRange ? .color : .luminance
            return Mask(id: id.uuidString, type: k.rawValue, source: "selection", invert: false,
                        feather: 0, opacity: 1, adjustments: adj,
                        selection: MaskSelection(kind: k, center: selCenter, range: selRange, softness: selSoftness))
        case .skin:
            return Mask(id: id.uuidString, type: "skin", source: "skin", invert: false,
                        feather: 0, opacity: 1, adjustments: adj,
                        selection: MaskSelection(kind: .color, center: selCenter, range: selRange, softness: selSoftness))
        case .background:
            // type "subject" so the renderer finds the person bitmap; invert → everything else.
            return Mask(id: id.uuidString, type: "subject", source: "segmentation", invert: true,
                        feather: 20, opacity: 1, adjustments: adj)
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
        (mask.kind == .skin || mask.kind == .background) && !hasPerson
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
                Text("⚠ No person detected in this photo — this mask has nothing to act on.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim)
                    .fixedSize(horizontal: false, vertical: true)
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
                ToneSlider(label: "Hue", value: $mask.selCenter, range: 0...1, step: 0.005, unit: "", onChange: onChange)
                ToneSlider(label: "Range", value: $mask.selRange, range: 0.01...0.5, step: 0.005, unit: "", onChange: onChange)
                ToneSlider(label: "Softness", value: $mask.selSoftness, range: 0...0.3, step: 0.005, unit: "", onChange: onChange)
            case .luminance:
                ToneSlider(label: "Brightness", value: $mask.selCenter, range: 0...1, step: 0.01, unit: "", onChange: onChange)
                ToneSlider(label: "Range", value: $mask.selRange, range: 0.01...0.5, step: 0.005, unit: "", onChange: onChange)
                ToneSlider(label: "Softness", value: $mask.selSoftness, range: 0...0.3, step: 0.005, unit: "", onChange: onChange)
            case .skin:
                Text("Skin tones within the detected person, fair across complexions.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
                ToneSlider(label: "Tolerance", value: $mask.selRange, range: 0.02...0.18, step: 0.005, unit: "", onChange: onChange)
            case .background:
                Text("Everything except the detected subject — darken or blur it to make the subject pop.")
                    .font(Theme.mono(9)).foregroundColor(Theme.inkDim).fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(Theme.hairline).frame(height: 1)
            ToneSlider(label: "Exposure", value: $mask.exposure, range: -3...3, step: 0.05, unit: " EV", onChange: onChange)
            ToneSlider(label: "Contrast", value: $mask.contrast, range: -100...100, step: 1, unit: "", onChange: onChange)
            ToneSlider(label: "Saturation", value: $mask.saturation, range: -100...100, step: 1, unit: "", onChange: onChange)
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
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline.opacity(0.6), lineWidth: 1))
        )
    }
}
