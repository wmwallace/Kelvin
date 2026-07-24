import SwiftUI
import CoreImage
import CryptoKit
import UniformTypeIdentifiers
import KelvinCore

struct CandidateViewModel: Identifiable {
    let id: String
    let label: String
    let baseRecipe: Recipe
    let previewImage: NSImage
}

@MainActor
final class AppState: ObservableObject {
    @Published var imageURL: URL?
    @Published var fullResCI: CIImage?
    @Published var proxyCI: CIImage?
    @Published var imageId: String = ""
    @Published var perception: Perception?
    @Published var candidates: [CandidateViewModel] = []
    @Published var selectedCandidateId: String?
    @Published var activeRecipe: Recipe?
    @Published var activePreviewImage: NSImage?

    // Interactive slider deltas over selected candidate
    @Published var deltaExposure: Double = 0.0
    @Published var deltaContrast: Double = 0.0
    @Published var deltaHighlights: Double = 0.0
    @Published var deltaShadows: Double = 0.0
    @Published var deltaVibrance: Double = 0.0
    @Published var deltaSaturation: Double = 0.0

    // Batch Apply & Processing State
    @Published var isProcessing: Bool = false
    @Published var statusMessage: String = "Drop a photo (RAW, JPEG, PNG) to begin."
    @Published var learnedProfile: PreferenceProfile = .empty
    @Published var batchOutcome: BatchApply.Outcome?
    @Published var showBatchSheet: Bool = false

    private let store: PreferenceStore
    private let context = CIContext()

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Branding.displayName)
        let logURL = appSupport.appendingPathComponent("preferences.jsonl")
        self.store = PreferenceStore(logFileURL: logURL)
    }

    func loadPhoto(from url: URL) async {
        isProcessing = true
        statusMessage = "Decoding image..."
        imageURL = url

        do {
            // Task 1: Load picks & compute learned profile (cold-start safe)
            let picks = (try? await store.loadAll()) ?? []
            let profile = PreferenceLearner.learn(from: picks)
            self.learnedProfile = profile

            // 1. Decode full-resolution CIImage
            let fullRes = try ImageDecoder.decode(url: url)
            self.fullResCI = fullRes

            // 2. Compute SHA256 of source file bytes
            let fileData = try Data(contentsOf: url)
            let hash = SHA256.hash(data: fileData)
            self.imageId = "sha256:" + hash.compactMap { String(format: "%02x", $0) }.joined()

            // 3. Proxy-first downsample (768px max edge)
            statusMessage = "Generating perception proxy..."
            let proxy = PerceptionProxy.downsample(fullRes)
            self.proxyCI = proxy

            // 4. Perception read (StaticPerceptionProvider default for shell)
            statusMessage = "Analyzing scene..."
            let defaultPerception = Perception(
                scene: .landscape,
                subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
                lighting: Perception.Lighting(condition: .harshSun, direction: .front, contrastRange: .high),
                problems: [.underexposedSubject],
                intent: .natural,
                confidence: 0.85
            )
            let provider = StaticPerceptionProvider(defaultPerception)
            let perceptionRead = try await provider.perceive(proxy)
            self.perception = perceptionRead

            // 5. Measured statistics from proxy
            statusMessage = "Measuring statistics..."
            let sampleBytes = try ImageMetrics.sample(proxy)
            let stats = ImageStatistics.compute(from: sampleBytes)

            // 6. Generate candidates through the learning loop
            statusMessage = "Generating candidates with preference profile..."
            let recipes = RecipeEngine.candidates(perception: perceptionRead, statistics: stats, profile: profile)

            // 7. Render candidate previews on proxy
            var models: [CandidateViewModel] = []
            for recipe in recipes {
                let renderedCI = Renderer.render(proxy, with: recipe)
                if let nsImage = ciToNSImage(renderedCI) {
                    let label = recipe.label ?? recipe.id ?? "Candidate"
                    models.append(CandidateViewModel(
                        id: recipe.id ?? UUID().uuidString,
                        label: label,
                        baseRecipe: recipe,
                        previewImage: nsImage
                    ))
                }
            }

            self.candidates = models
            if let first = models.first {
                selectCandidate(id: first.id)
            }

            let profileInfo = profile.sampleCount >= PreferenceLearner.minSamples
                ? " (learned from \(profile.sampleCount) picks)"
                : " (hand-tuned baseline)"
            statusMessage = "\(Branding.displayName) ready — 4 candidates generated\(profileInfo)."
        } catch {
            statusMessage = "Error loading image: \(error.localizedDescription)"
        }

        isProcessing = false
    }

    func selectCandidate(id: String) {
        guard candidates.contains(where: { $0.id == id }) else { return }
        selectedCandidateId = id
        
        // Reset manual slider deltas on new candidate selection
        deltaExposure = 0.0
        deltaContrast = 0.0
        deltaHighlights = 0.0
        deltaShadows = 0.0
        deltaVibrance = 0.0
        deltaSaturation = 0.0

        updateActiveRecipe()
        recordCurrentPick()
    }

    func updateSliderDeltas() {
        updateActiveRecipe()
    }

    private func updateActiveRecipe() {
        guard let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }),
              let proxy = proxyCI else { return }

        var g = candidate.baseRecipe.global
        g.exposureEV = roundedClamp(g.exposureEV + deltaExposure, to: -5.0...5.0, step: 0.05)
        g.contrast = roundedClamp(g.contrast + deltaContrast, to: -100...100, step: 1)
        g.highlights = roundedClamp(g.highlights + deltaHighlights, to: -100...100, step: 1)
        g.shadows = roundedClamp(g.shadows + deltaShadows, to: -100...100, step: 1)
        g.vibrance = roundedClamp(g.vibrance + deltaVibrance, to: -100...100, step: 1)
        g.saturation = roundedClamp(g.saturation + deltaSaturation, to: -100...100, step: 1)

        var finalRecipe = candidate.baseRecipe
        finalRecipe.global = g
        self.activeRecipe = finalRecipe

        // Instant proxy preview render (<50ms target)
        let renderedCI = Renderer.render(proxy, with: finalRecipe)
        self.activePreviewImage = ciToNSImage(renderedCI)
    }

    // Task 2: Record pick with subsequent_manual_edits
    func recordCurrentPick() {
        guard let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }) else { return }

        var manualEdits: [String: Double] = [:]
        if abs(deltaExposure) > 0.01 { manualEdits["exposure_ev"] = (deltaExposure * 100).rounded() / 100 }
        if abs(deltaContrast) > 0.1 { manualEdits["contrast"] = deltaContrast.rounded() }
        if abs(deltaHighlights) > 0.1 { manualEdits["highlights"] = deltaHighlights.rounded() }
        if abs(deltaShadows) > 0.1 { manualEdits["shadows"] = deltaShadows.rounded() }
        if abs(deltaVibrance) > 0.1 { manualEdits["vibrance"] = deltaVibrance.rounded() }
        if abs(deltaSaturation) > 0.1 { manualEdits["saturation"] = deltaSaturation.rounded() }

        let shownIds = candidates.map { $0.id }
        let perceptionHash = candidate.baseRecipe.provenance?.perceptionHash

        let pick = PreferencePick(
            imageId: imageId,
            perceptionHash: perceptionHash,
            shown: shownIds,
            chosen: selectedId,
            subsequentManualEdits: manualEdits.isEmpty ? nil : manualEdits
        )

        Task {
            try? await store.record(pick: pick)
        }
    }

    // Task 4: Full-resolution export using ImageWriter
    func exportFullResolution(to exportURL: URL) async {
        guard let fullRes = fullResCI,
              let recipe = activeRecipe else { return }

        isProcessing = true
        statusMessage = "Rendering full-resolution export..."

        do {
            let renderedFullCI = Renderer.render(fullRes, with: recipe)
            try ImageWriter.write(renderedFullCI, to: exportURL)
            statusMessage = "Exported successfully to \(exportURL.lastPathComponent)"
        } catch {
            statusMessage = "Export error: \(error.localizedDescription)"
        }

        isProcessing = false
    }

    // Task 5: Batch-apply UI using BatchApply.run
    func runBatchApply(inputDir: URL, outputDir: URL) async {
        guard let recipe = activeRecipe else { return }

        isProcessing = true
        statusMessage = "Running batch apply across folder..."

        do {
            let inputFiles = try BatchApply.imageFiles(in: inputDir)
            let outcome = try BatchApply.run(inputs: inputFiles, recipe: recipe, outputDir: outputDir)
            self.batchOutcome = outcome
            self.showBatchSheet = true
            statusMessage = "Batch apply complete: \(outcome.succeeded) succeeded, \(outcome.failed) failed."
        } catch {
            statusMessage = "Batch apply error: \(error.localizedDescription)"
        }

        isProcessing = false
    }

    private func roundedClamp(_ val: Double, to range: ClosedRange<Double>, step: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, val))
        return (clamped / step).rounded() * step
    }

    private func ciToNSImage(_ ciImage: CIImage) -> NSImage? {
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSZeroSize)
    }
}

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var isTargetedForDrop = false

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                Text(Branding.displayName)
                    .font(.title2)
                    .bold()
                Spacer()
                Text(appState.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if appState.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if let selectedId = appState.selectedCandidateId,
               let activeImage = appState.activePreviewImage {
                // Main Interactive Workspace
                HSplitView {
                    // Left Column: Active Preview + Export / Batch Toolbar
                    VStack(spacing: 12) {
                        Image(nsImage: activeImage)
                            .resizable()
                            .scaledToFit()
                            .padding()

                        HStack {
                            Text("Active Look: \(selectedId.capitalized)")
                                .font(.headline)
                            Spacer()
                            Button("Batch Apply Shoot...") {
                                openBatchPanel()
                            }
                            .buttonStyle(.bordered)

                            Button("Export Full-Res...") {
                                openExportPanel()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding([.horizontal, .bottom])
                    }
                    .frame(minWidth: 450)

                    // Right Column: Candidate Picker + Manual Edit Adjustments
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("1. Pick Candidate")
                                .font(.headline)
                                .padding(.horizontal)

                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(appState.candidates) { candidate in
                                    CandidateCard(
                                        candidate: candidate,
                                        isSelected: candidate.id == appState.selectedCandidateId
                                    ) {
                                        appState.selectCandidate(id: candidate.id)
                                    }
                                }
                            }
                            .padding(.horizontal)

                            Divider()
                                .padding(.vertical, 4)

                            // Task 2: Fine-tuning sliders to capture subsequent_manual_edits
                            Text("2. Fine-Tune Adjustments")
                                .font(.headline)
                                .padding(.horizontal)

                            VStack(spacing: 10) {
                                SliderRow(label: "Exposure", value: $appState.deltaExposure, range: -2.0...2.0, step: 0.05, unit: "EV") {
                                    appState.updateSliderDeltas()
                                }
                                SliderRow(label: "Contrast", value: $appState.deltaContrast, range: -30...30, step: 1, unit: "") {
                                    appState.updateSliderDeltas()
                                }
                                SliderRow(label: "Highlights", value: $appState.deltaHighlights, range: -50...50, step: 1, unit: "") {
                                    appState.updateSliderDeltas()
                                }
                                SliderRow(label: "Shadows", value: $appState.deltaShadows, range: -50...50, step: 1, unit: "") {
                                    appState.updateSliderDeltas()
                                }
                                SliderRow(label: "Vibrance", value: $appState.deltaVibrance, range: -30...30, step: 1, unit: "") {
                                    appState.updateSliderDeltas()
                                }
                                SliderRow(label: "Saturation", value: $appState.deltaSaturation, range: -30...30, step: 1, unit: "") {
                                    appState.updateSliderDeltas()
                                }
                            }
                            .padding(.horizontal)

                            HStack {
                                Spacer()
                                Button("Save Tweak as Pick") {
                                    appState.recordCurrentPick()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical)
                    }
                    .frame(width: 380)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            } else {
                // Empty Drop State
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundColor(isTargetedForDrop ? .accentColor : .secondary)

                    Text("Drop Photo into \(Branding.displayName)")
                        .font(.title)
                        .bold()

                    Text("Supports RAW, JPEG, and PNG. Candidate generation and preference learning run automatically.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button("Select Photo...") {
                        openFileImporter()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isTargetedForDrop ? Color.accentColor.opacity(0.1) : Color.clear)
                .onDrop(of: [.fileURL], isTargeted: $isTargetedForDrop) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url = url {
                            Task { @MainActor in
                                await appState.loadPhoto(from: url)
                            }
                        }
                    }
                    return true
                }
            }
        }
        .navigationTitle(Branding.displayName)
        .sheet(isPresented: $appState.showBatchSheet) {
            if let outcome = appState.batchOutcome {
                VStack(spacing: 16) {
                    Text("Batch Apply Complete")
                        .font(.title2)
                        .bold()

                    HStack(spacing: 24) {
                        VStack {
                            Text("\(outcome.succeeded)")
                                .font(.title)
                                .foregroundColor(.green)
                            Text("Succeeded")
                                .font(.caption)
                        }
                        VStack {
                            Text("\(outcome.failed)")
                                .font(.title)
                                .foregroundColor(outcome.failed > 0 ? .red : .secondary)
                            Text("Failed")
                                .font(.caption)
                        }
                    }

                    Button("Done") {
                        appState.showBatchSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(32)
                .frame(width: 360)
            }
        }
    }

    private func openFileImporter() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .rawImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.loadPhoto(from: url)
            }
        }
    }

    private func openExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = "edited_photo.jpg"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.exportFullResolution(to: url)
            }
        }
    }

    private func openBatchPanel() {
        let inputPanel = NSOpenPanel()
        inputPanel.title = "Select Input Shoot Folder"
        inputPanel.canChooseDirectories = true
        inputPanel.canChooseFiles = false
        inputPanel.allowsMultipleSelection = false

        guard inputPanel.runModal() == .OK, let inputDir = inputPanel.url else { return }

        let outputPanel = NSOpenPanel()
        outputPanel.title = "Select Output Folder"
        outputPanel.canChooseDirectories = true
        outputPanel.canChooseFiles = false
        outputPanel.canCreateDirectories = true
        outputPanel.allowsMultipleSelection = false

        guard outputPanel.runModal() == .OK, let outputDir = outputPanel.url else { return }

        Task {
            await appState.runBatchApply(inputDir: inputDir, outputDir: outputDir)
        }
    }
}

struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text(formatValue(value))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            Slider(value: $value, in: range, step: step) {
                Text(label)
            } onEditingChanged: { editing in
                if !editing { onChange() }
            }
        }
    }

    private func formatValue(_ val: Double) -> String {
        let sign = val > 0 ? "+" : ""
        if step < 1.0 {
            return String(format: "%@%.2f%@", sign, val, unit)
        } else {
            return String(format: "%@%.0f%@", sign, val, unit)
        }
    }
}

struct CandidateCard: View {
    let candidate: CandidateViewModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: candidate.previewImage)
                .resizable()
                .scaledToFit()
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                )

            Text(candidate.label)
                .font(.caption)
                .bold()
                .foregroundColor(isSelected ? .accentColor : .primary)
        }
        .padding(8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
        .onTapGesture {
            onSelect()
        }
    }
}
