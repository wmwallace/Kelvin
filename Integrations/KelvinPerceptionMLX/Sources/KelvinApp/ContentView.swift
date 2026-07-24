import SwiftUI
import CoreImage
import CryptoKit
import UniformTypeIdentifiers
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
    @Published var activeCraftNotes: [String] = []

    /// The full editable global adjustment set (absolute values, Lightroom-style). Sliders bind
    /// straight to its fields; it starts from the chosen candidate and the user takes it from there.
    @Published var edit = GlobalAdjustments.neutral
    /// The candidate's values as generated — the baseline manual edits are measured against (for
    /// the "carry my tweaks to the batch" and preference logging), and what Reset returns to.
    private var editBaseline = GlobalAdjustments.neutral
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
    private let context = CIContext()
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

    func loadPhoto(from url: URL) async {
        isProcessing = true
        statusMessage = "Decoding…"
        imageURL = url
        userMasks = []          // hand-drawn masks are per-photo
        do {
            let fullRes = try ImageDecoder.decode(url: url)
            self.fullResCI = fullRes

            let fileData = try Data(contentsOf: url)
            let hash = SHA256.hash(data: fileData)
            self.imageId = "sha256:" + hash.compactMap { String(format: "%02x", $0) }.joined()

            statusMessage = "Building proxy…"
            let proxy = PerceptionProxy.downsample(fullRes)
            self.proxyCI = proxy
            // The untouched original, for the before/after compare.
            self.originalPreviewImage = ciToNSImage(proxy)

            statusMessage = "Reading the scene…"
            // Real perception: Qwen2.5-VL reads the proxy. First call loads the model (a few
            // seconds once cached); if it can't run, fall back to a conservative read so the
            // app still produces candidates from the measured statistics.
            let perceptionRead: Perception
            do {
                perceptionRead = try await perceptionProvider.perceive(proxy)
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

            var models: [CandidateViewModel] = []
            for recipe in recipes {
                let renderedCI = Renderer.render(proxy, with: recipe, maskBitmaps: proxyMasks)
                if let nsImage = ciToNSImage(renderedCI) {
                    models.append(CandidateViewModel(
                        id: recipe.id ?? UUID().uuidString,
                        label: recipe.label ?? recipe.id ?? "Candidate",
                        baseRecipe: recipe,
                        previewImage: nsImage))
                }
            }
            self.candidates = models
            if let first = models.first { selectCandidate(id: first.id) }

            statusMessage = "Ready · pick a look, or Batch apply it to a folder"
        } catch {
            statusMessage = "Couldn't read that photo — \(error.localizedDescription)"
        }
        isProcessing = false
    }

    func selectCandidate(id: String) {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return }
        selectedCandidateId = id
        // Load the candidate's actual values into the editable set — the user edits from here.
        edit = candidate.baseRecipe.global
        editBaseline = candidate.baseRecipe.global
        baseMasks = candidate.baseRecipe.masks ?? []
        maskEnabled = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, true) })
        maskStrength = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, $0.opacity * 100) })
        updateActiveRecipe()
        // NOTE: selecting/browsing candidates does NOT record a pick — only a deliberate
        // choice (export) does. Recording on every selection floods the store with fake
        // preferences and corrupts the learned profile.
    }

    /// Revert every manual edit back to the candidate as Kelvin generated it.
    func resetToCandidate() {
        edit = editBaseline
        maskEnabled = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, true) })
        maskStrength = Dictionary(uniqueKeysWithValues: baseMasks.map { ($0.id, $0.opacity * 100) })
        updateActiveRecipe()
    }

    func onEdit() { updateActiveRecipe() }

    /// Add a hand-drawn gradient mask, centred, with a gentle starting darken so the user sees it.
    func addUserMask(_ kind: MaskShape.Kind) {
        var m = UserMaskVM(kind: kind)
        m.exposure = -0.6
        userMasks.append(m)
        onEdit()
    }

    func removeUserMask(_ id: UUID) { userMasks.removeAll { $0.id == id }; onEdit() }

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

    private func updateActiveRecipe() {
        guard let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }),
              let proxy = proxyCI else { return }
        var finalRecipe = candidate.baseRecipe
        finalRecipe.global = edit                       // absolute manual values
        finalRecipe.masks = activeMasks()
        finalRecipe.heal = removeDust && !healSpots.isEmpty ? healSpots : nil
        self.activeRecipe = finalRecipe
        let rendered = Renderer.render(proxy, with: finalRecipe, maskBitmaps: proxyMaskBitmaps)
        self.activePreviewImage = ciToNSImage(rendered)
        // Objective craft self-check on the edit the user is looking at — surfaces clipping,
        // skin, or cast problems. Not a taste verdict; just "did this edit break something".
        self.activeCraftNotes = AestheticEvaluator.score(rendered: rendered)?.notes ?? []
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
                    // Sensor dust sits at the same normalised position on every frame of a shoot,
                    // so the spots found on the reference photo heal the whole batch.
                    recipe.heal = (removeDust && !healSpots.isEmpty) ? healSpots : nil
                    let masks = (recipe.masks?.isEmpty == false) ? LocalMasks.measure(in: image).bitmaps : [:]
                    let out = outputDir.appendingPathComponent(file.deletingPathExtension().lastPathComponent)
                        .appendingPathExtension("jpg")
                    try ImageWriter.write(Renderer.render(image, with: recipe, maskBitmaps: masks),
                                          to: out, format: .jpeg(quality: 0.92))
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
        g.tint = clampStep(g.tint + (t["tint"] ?? 0), -100...100, 1)
        if let dt = t["temperatureK"] { g.temperatureK = (g.temperatureK ?? 5500) + dt }
    }

    /// The ids of the auto-masks on the current candidate (e.g. "subject", "sky"), for the UI.
    var baseMaskIds: [String] { baseMasks.map { $0.id } }

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
                if let img = (appState.showingOriginal ? appState.originalPreviewImage : appState.activePreviewImage) ?? appState.activePreviewImage {
                    Image(nsImage: img)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
                        .overlay(alignment: .topLeading) {
                            if appState.showingOriginal {
                                Text("BEFORE")
                                    .font(Theme.mono(11, .semibold)).tracking(2)
                                    .foregroundColor(Theme.base)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Capsule().fill(Theme.ink.opacity(0.75)))
                                    .padding(30)
                            }
                        }
                }
                previewFooter
            }
            .frame(minWidth: 460)
            .background(Theme.base)

            sidebar
                .frame(width: 360)
                .background(Theme.surface)
        }
    }

    private var previewFooter: some View {
        let temp = appState.activeTemperature
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(appState.selectedCandidateId?.capitalized ?? "—")
                    .font(Theme.ui(16, .semibold)).foregroundColor(Theme.ink)
                Spacer()
                Text(temp.map { "\(Int($0)) K" } ?? "as-shot")
                    .font(Theme.mono(12))
                    .foregroundColor(temp.map(KelvinScale.color) ?? Theme.inkDim)
            }
            TemperatureRail(marks: temp.map { [($0, true)] } ?? [])
            // Craft self-check: flag any objective problems (clipping, skin, cast) in this edit.
            if !appState.activeCraftNotes.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("⚠").font(Theme.ui(11))
                    Text(appState.activeCraftNotes.joined(separator: " · "))
                        .font(Theme.mono(10)).foregroundColor(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            HStack(spacing: 10) {
                Button(action: openBatchPanel) { toolbarLabel("Batch apply", filled: false) }
                    .buttonStyle(.plain)
                // Press and hold to see the untouched original.
                toolbarLabel("Hold to compare", filled: false)
                    .opacity(appState.showingOriginal ? 0.55 : 1)
                    .onLongPressGesture(minimumDuration: 0.01, maximumDistance: 40, pressing: { pressing in
                        appState.showingOriginal = pressing
                    }, perform: {})
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

                sectionLabel("White balance", trailing: "Reset")
                    .onTapGesture { appState.resetToCandidate() }
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
                }

                sectionLabel("Color", trailing: nil)
                VStack(spacing: 14) {
                    ToneSlider(label: "Vibrance", value: $appState.edit.vibrance, range: -100...100, step: 1, unit: "", onChange: ch)
                    ToneSlider(label: "Saturation", value: $appState.edit.saturation, range: -100...100, step: 1, unit: "", onChange: ch)
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
                    // Hand-drawn gradient masks: full geometry + local adjustments.
                    ForEach($appState.userMasks) { $m in
                        UserMaskEditor(mask: $m, onChange: appState.onEdit,
                                       onDelete: { appState.removeUserMask(m.id) })
                    }
                    HStack(spacing: 8) {
                        Button(action: { appState.addUserMask(.radial) }) { addMaskLabel("+ Radial") }
                            .buttonStyle(.plain)
                        Button(action: { appState.addUserMask(.linear) }) { addMaskLabel("+ Graduated") }
                            .buttonStyle(.plain)
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
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { onChange() }
            }
            .tint(Theme.glow)
            .controlSize(.small)
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

/// A hand-added parametric gradient mask, all plain values so SwiftUI binds to it directly.
/// Converts to the engine's `Mask` (with a `MaskShape`) at render time.
struct UserMaskVM: Identifiable {
    let id = UUID()
    var kind: MaskShape.Kind
    var cx = 0.5, cy = 0.5, radius = 0.35, angle = 0.0, softness = 0.35
    var exposure = 0.0, contrast = 0.0, saturation = 0.0

    func toMask() -> Mask {
        var adj: [String: Double] = [:]
        if exposure != 0 { adj["exposure_ev"] = exposure }
        if contrast != 0 { adj["contrast"] = contrast }
        if saturation != 0 { adj["saturation"] = saturation }
        return Mask(id: id.uuidString, type: kind.rawValue, source: "gradient", invert: false,
                    feather: 0, opacity: 1, adjustments: adj,
                    shape: MaskShape(kind: kind, cx: cx, cy: cy, radius: radius,
                                     angle: angle, softness: softness))
    }
}

struct UserMaskEditor: View {
    @Binding var mask: UserMaskVM
    let onChange: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(mask.kind == .radial ? "Radial" : "Graduated")
                    .font(Theme.ui(12, .semibold)).foregroundColor(Theme.ink)
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundColor(Theme.inkDim)
                }.buttonStyle(.plain)
            }
            ToneSlider(label: "Center X", value: $mask.cx, range: 0...1, step: 0.01, unit: "", onChange: onChange)
            ToneSlider(label: "Center Y", value: $mask.cy, range: 0...1, step: 0.01, unit: "", onChange: onChange)
            if mask.kind == .radial {
                ToneSlider(label: "Size", value: $mask.radius, range: 0.05...1.2, step: 0.01, unit: "", onChange: onChange)
            } else {
                ToneSlider(label: "Angle", value: $mask.angle, range: 0...360, step: 1, unit: "°", onChange: onChange)
            }
            ToneSlider(label: "Softness", value: $mask.softness, range: 0...1, step: 0.01, unit: "", onChange: onChange)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ToneSlider(label: "Exposure", value: $mask.exposure, range: -3...3, step: 0.05, unit: " EV", onChange: onChange)
            ToneSlider(label: "Contrast", value: $mask.contrast, range: -100...100, step: 1, unit: "", onChange: onChange)
            ToneSlider(label: "Saturation", value: $mask.saturation, range: -100...100, step: 1, unit: "", onChange: onChange)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.surface.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.glow.opacity(0.4), lineWidth: 1))
        )
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
