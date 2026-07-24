import SwiftUI
import CoreImage
import CryptoKit
import UniformTypeIdentifiers
import KelvinCore

struct CandidateViewModel: Identifiable {
    let id: String
    let label: String
    let recipe: Recipe
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
    @Published var activePreviewImage: NSImage?
    @Published var isProcessing: Bool = false
    @Published var statusMessage: String = "Drop a photo (RAW, JPEG, PNG) to begin."

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
            // 1. Decode full-resolution CIImage
            let fullRes = try ImageDecoder.decode(url: url)
            self.fullResCI = fullRes

            // 2. Compute SHA256 of source file data
            let fileData = try Data(contentsOf: url)
            let hash = SHA256.hash(data: fileData)
            self.imageId = "sha256:" + hash.compactMap { String(format: "%02x", $0) }.joined()

            // 3. Proxy-first downsample (768px max edge)
            statusMessage = "Generating perception proxy..."
            let proxy = PerceptionProxy.downsample(fullRes)
            self.proxyCI = proxy

            // 4. Perception read (StaticPerceptionProvider stub for M7 shell)
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
            statusMessage = "Measuring histogram & color statistics..."
            let sampleBytes = try ImageMetrics.sample(proxy)
            let stats = ImageStatistics.compute(from: sampleBytes)

            // 6. Generate 4 candidate recipes (natural, vivid, soft, dramatic)
            statusMessage = "Generating candidate recipes..."
            let recipes = RecipeEngine.candidates(perception: perceptionRead, statistics: stats)

            // 7. Render candidate previews on proxy
            var models: [CandidateViewModel] = []
            for recipe in recipes {
                let renderedCI = Renderer.render(proxy, with: recipe)
                if let nsImage = ciToNSImage(renderedCI) {
                    let label = recipe.label ?? recipe.id ?? "Candidate"
                    models.append(CandidateViewModel(
                        id: recipe.id ?? UUID().uuidString,
                        label: label,
                        recipe: recipe,
                        previewImage: nsImage
                    ))
                }
            }

            self.candidates = models
            if let first = models.first {
                selectCandidate(id: first.id)
            }

            statusMessage = "\(Branding.displayName) ready — 4 candidates generated."
        } catch {
            statusMessage = "Error loading image: \(error.localizedDescription)"
        }

        isProcessing = false
    }

    func selectCandidate(id: String) {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return }
        selectedCandidateId = id
        activePreviewImage = candidate.previewImage

        // Task 4: Wire pick -> store (RECIPE-SCHEMA.md Stage 3)
        let shownIds = candidates.map { $0.id }
        let perceptionHash = candidate.recipe.provenance?.perceptionHash
        let pick = PreferencePick(
            imageId: imageId,
            perceptionHash: perceptionHash,
            shown: shownIds,
            chosen: id
        )

        Task {
            try? await store.record(pick: pick)
        }
    }

    func exportFullResolution(to exportURL: URL) async {
        guard let fullRes = fullResCI,
              let selectedId = selectedCandidateId,
              let candidate = candidates.first(where: { $0.id == selectedId }) else { return }

        isProcessing = true
        statusMessage = "Rendering full-resolution export..."

        do {
            let renderedFullCI = Renderer.render(fullRes, with: candidate.recipe)
            if let cgImage = context.createCGImage(renderedFullCI, from: renderedFullCI.extent) {
                let nsImage = NSImage(cgImage: cgImage, size: NSZeroSize)
                if let tiffData = nsImage.tiffRepresentation,
                   let bitmapRep = NSBitmapImageRep(data: tiffData),
                   let jpegData = bitmapRep.representation(using: .jpeg, properties: [:]) {
                    try jpegData.write(to: exportURL)
                    statusMessage = "Exported successfully to \(exportURL.lastPathComponent)"
                }
            }
        } catch {
            statusMessage = "Export error: \(error.localizedDescription)"
        }

        isProcessing = false
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
                // Main Workspace
                HSplitView {
                    // Left: Selected Active Preview
                    VStack {
                        Image(nsImage: activeImage)
                            .resizable()
                            .scaledToFit()
                            .padding()
                        HStack {
                            Text("Active Preview (\(selectedId.capitalized))")
                                .font(.headline)
                            Spacer()
                            Button("Export Full Resolution...") {
                                openExportPanel()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding([.horizontal, .bottom])
                    }
                    .frame(minWidth: 450)

                    // Right: Candidate Picker Grid
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Candidate Edits")
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

                        Spacer()
                    }
                    .frame(width: 380)
                    .padding(.vertical)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            } else {
                // Empty Drop Target State
                VStack(spacing: 20) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 64))
                        .foregroundColor(isTargetedForDrop ? .accentColor : .secondary)

                    Text("Drop Photo Here")
                        .font(.title)
                        .bold()

                    Text("Supports RAW, JPEG, and PNG. Perception and candidate previews will generate automatically.")
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
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "edited_photo.jpg"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await appState.exportFullResolution(to: url)
            }
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
