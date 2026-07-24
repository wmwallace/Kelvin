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

    @Published var deltaExposure = 0.0
    @Published var deltaContrast = 0.0
    @Published var deltaHighlights = 0.0
    @Published var deltaShadows = 0.0
    @Published var deltaVibrance = 0.0
    @Published var deltaSaturation = 0.0

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
        do {
            let fullRes = try ImageDecoder.decode(url: url)
            self.fullResCI = fullRes

            let fileData = try Data(contentsOf: url)
            let hash = SHA256.hash(data: fileData)
            self.imageId = "sha256:" + hash.compactMap { String(format: "%02x", $0) }.joined()

            statusMessage = "Building proxy…"
            let proxy = PerceptionProxy.downsample(fullRes)
            self.proxyCI = proxy

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
        guard candidates.contains(where: { $0.id == id }) else { return }
        selectedCandidateId = id
        deltaExposure = 0; deltaContrast = 0; deltaHighlights = 0
        deltaShadows = 0; deltaVibrance = 0; deltaSaturation = 0
        updateActiveRecipe()
        // NOTE: selecting/browsing candidates does NOT record a pick — only a deliberate
        // choice (export) does. Recording on every selection floods the store with fake
        // preferences and corrupts the learned profile.
    }

    func updateSliderDeltas() { updateActiveRecipe() }

    private func updateActiveRecipe() {
        guard let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }),
              let proxy = proxyCI else { return }
        var g = candidate.baseRecipe.global
        g.exposureEV = clampStep(g.exposureEV + deltaExposure, -5...5, 0.05)
        g.contrast = clampStep(g.contrast + deltaContrast, -100...100, 1)
        g.highlights = clampStep(g.highlights + deltaHighlights, -100...100, 1)
        g.shadows = clampStep(g.shadows + deltaShadows, -100...100, 1)
        g.vibrance = clampStep(g.vibrance + deltaVibrance, -100...100, 1)
        g.saturation = clampStep(g.saturation + deltaSaturation, -100...100, 1)
        var finalRecipe = candidate.baseRecipe
        finalRecipe.global = g
        finalRecipe.heal = removeDust && !healSpots.isEmpty ? healSpots : nil
        self.activeRecipe = finalRecipe
        self.activePreviewImage = ciToNSImage(Renderer.render(proxy, with: finalRecipe, maskBitmaps: proxyMaskBitmaps))
    }

    func recordCurrentPick() {
        guard let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }) else { return }
        var edits: [String: Double] = [:]
        if abs(deltaExposure) > 0.01 { edits["exposure_ev"] = (deltaExposure * 100).rounded() / 100 }
        if abs(deltaContrast) > 0.1 { edits["contrast"] = deltaContrast.rounded() }
        if abs(deltaHighlights) > 0.1 { edits["highlights"] = deltaHighlights.rounded() }
        if abs(deltaShadows) > 0.1 { edits["shadows"] = deltaShadows.rounded() }
        if abs(deltaVibrance) > 0.1 { edits["vibrance"] = deltaVibrance.rounded() }
        if abs(deltaSaturation) > 0.1 { edits["saturation"] = deltaSaturation.rounded() }
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

    /// The reference photo's manual slider tweaks, to carry onto every batch photo.
    private func manualTweaks() -> [String: Double] {
        ["exposure_ev": deltaExposure, "contrast": deltaContrast, "highlights": deltaHighlights,
         "shadows": deltaShadows, "vibrance": deltaVibrance, "saturation": deltaSaturation]
    }

    private func applyTweaks(_ t: [String: Double], to g: inout GlobalAdjustments) {
        g.exposureEV = clampStep(g.exposureEV + (t["exposure_ev"] ?? 0), -5...5, 0.05)
        g.contrast = clampStep(g.contrast + (t["contrast"] ?? 0), -100...100, 1)
        g.highlights = clampStep(g.highlights + (t["highlights"] ?? 0), -100...100, 1)
        g.shadows = clampStep(g.shadows + (t["shadows"] ?? 0), -100...100, 1)
        g.vibrance = clampStep(g.vibrance + (t["vibrance"] ?? 0), -100...100, 1)
        g.saturation = clampStep(g.saturation + (t["saturation"] ?? 0), -100...100, 1)
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
                if let img = appState.activePreviewImage {
                    Image(nsImage: img)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(24)
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
            HStack(spacing: 10) {
                Button(action: openBatchPanel) { toolbarLabel("Batch apply", filled: false) }
                    .buttonStyle(.plain)
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

                sectionLabel("Fine-tune", trailing: nil)
                VStack(spacing: 14) {
                    ToneSlider(label: "Exposure", value: $appState.deltaExposure, range: -2...2, step: 0.05, unit: " EV", onChange: appState.updateSliderDeltas)
                    ToneSlider(label: "Contrast", value: $appState.deltaContrast, range: -30...30, step: 1, unit: "", onChange: appState.updateSliderDeltas)
                    ToneSlider(label: "Highlights", value: $appState.deltaHighlights, range: -50...50, step: 1, unit: "", onChange: appState.updateSliderDeltas)
                    ToneSlider(label: "Shadows", value: $appState.deltaShadows, range: -50...50, step: 1, unit: "", onChange: appState.updateSliderDeltas)
                    ToneSlider(label: "Vibrance", value: $appState.deltaVibrance, range: -30...30, step: 1, unit: "", onChange: appState.updateSliderDeltas)
                    ToneSlider(label: "Saturation", value: $appState.deltaSaturation, range: -30...30, step: 1, unit: "", onChange: appState.updateSliderDeltas)
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
