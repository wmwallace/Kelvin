import SwiftUI
import PhotosUI
import Photos
import CoreTransferable
import UniformTypeIdentifiers
import KelvinCore

/// One photograph being chosen for. The whole of the iPhone app's state.
///
/// Deliberately small. The Mac's `AppState` is six thousand lines because it grew a shoot browser,
/// masks, heals, batch export and undo; the phone's first job is the product's one sentence and
/// nothing else — read one photograph, offer looks large enough to choose between, keep the one
/// chosen. Every rule it applies is a call into KelvinCore (`ShippedCandidates`, the same
/// composition the eval harness scores), so there is no fourth copy of candidate generation here to
/// drift from the other three.
@MainActor
@Observable
final class EditSession {

    enum Phase {
        case empty
        case working(String)
        case ready(Composed)
        case failed(String)
    }

    private(set) var phase: Phase = .empty
    var selectedID: String?
    var showingOriginal = false
    /// A short confirmation after saving, or the reason it failed.
    private(set) var notice: String?
    private(set) var isSaving = false
    var shareItem: ShareItem?
    /// Offsets on top of whichever look is chosen — see `Adjustments`. They follow the photograph
    /// across a change of look, the way someone asking for "a bit brighter" means the photo.
    var adjustments = Adjustments()
    /// The chosen look re-rendered with `adjustments`, for the canvas. Nil when there are none.
    private(set) var adjustedPreview: CGImage?
    private var adjustToken = 0
    /// Which photograph the choices are filed under — the Photos identifier, or the file's path for
    /// a photo opened some other way. Nil until a photo is open.
    private(set) var photoKey: String?

    /// True when the open photograph came back with a choice made on an earlier visit, so the canvas
    /// can say so instead of looking like the engine's own pick.
    private(set) var restoredEdit = false

    /// File the current choice under the open photograph. Choosing the engine's own opener with no
    /// adjustments is not an edit, and removes any saved one — the next visit opens fresh.
    func persistChoice() {
        guard let photoKey, let composed, let id = selectedID else { return }
        if id == composed.openingID && adjustments.isNeutral {
            PhoneEditStore.remove(for: photoKey)
        } else {
            PhoneEditStore.save(PhoneEdit(styleId: id, adjustments: adjustments), for: photoKey)
        }
    }

    /// The recipe that will be saved: the chosen look, with the adjustments on it.
    var selectedRecipe: Recipe? { selectedLook.map { adjustments.applied(to: $0.recipe) } }

    /// Re-render the chosen look with the current adjustments. Latest request wins: a drag makes
    /// many, and only the last one's pixels are shown.
    func refreshAdjustedPreview() async {
        adjustToken += 1
        let mine = adjustToken
        guard let composed, let recipe = selectedRecipe, !adjustments.isNeutral else {
            adjustedPreview = nil
            return
        }
        let image = try? await Pipeline.renderAdjusted(recipe, in: composed)
        guard mine == adjustToken else { return }
        adjustedPreview = image
    }

    struct ShareItem: Identifiable { let id = UUID(); let url: URL }

    /// The request being served. A photo picked while another is still being read wins, and the
    /// earlier one's result is dropped on arrival rather than painted over the newer choice.
    private var request = 0

    var composed: Composed? { if case .ready(let c) = phase { c } else { nil } }

    var selectedLook: Composed.Look? {
        guard let c = composed else { return nil }
        return c.looks.first { $0.id == selectedID } ?? c.looks.first
    }

    // MARK: Opening

    func open(_ item: PhotosPickerItem) async {
        await open(key: item.itemIdentifier) { () async throws -> URL in
            guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else {
                throw OpenError.unreadable
            }
            return picked.url
        }
    }

    /// Open a file directly. Debug builds take `-open <path>` at launch so the simulator can be
    /// driven — and screenshotted — without a finger on the photo picker.
    func open(file url: URL) async {
        await open(key: url.path) { url }
    }

    private func open(key: String?, _ resolve: () async throws -> URL) async {
        request += 1
        let mine = request
        notice = nil
        phase = .working("Opening")
        do {
            let url = try await resolve()
            let result = try await Pipeline.compose(url) { [weak self] stage in
                guard let self, self.request == mine else { return }
                self.phase = .working(stage)
            }
            guard request == mine else { return }
            showingOriginal = false
            adjustedPreview = nil
            photoKey = key
            // What was chosen last time, if this photograph was opened before and that look is
            // still among the ones offered; otherwise the engine's own opener, fresh.
            if let key, let saved = PhoneEditStore.load(for: key),
               result.looks.contains(where: { $0.id == saved.styleId }) {
                selectedID = saved.styleId
                adjustments = saved.adjustments
                restoredEdit = true
            } else {
                selectedID = result.openingID
                adjustments = Adjustments()
                restoredEdit = false
            }
            phase = .ready(result)
        } catch {
            guard request == mine else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Keeping it

    func saveToPhotos() async {
        guard let look = selectedLook, let recipe = selectedRecipe, let source = composed?.source,
              !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        notice = nil
        do {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                notice = "To save, allow \(Branding.displayName) to add photos in Settings"
                return
            }
            let file = try await Pipeline.export(recipe, from: source)
            try await Self.addToLibrary(file)
            try? FileManager.default.removeItem(at: file)
            notice = "Saved to Photos as \(look.name)"
        } catch {
            notice = "Couldn't save. \(error.localizedDescription)"
        }
    }

    func share() async {
        guard let recipe = selectedRecipe, let source = composed?.source, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            shareItem = ShareItem(url: try await Pipeline.export(recipe, from: source))
        } catch {
            notice = "Couldn't prepare the photo. \(error.localizedDescription)"
        }
    }

    // MARK: Carrying the look across the shoot

    /// Progress of an apply, for the caption. Nil when none is running.
    private(set) var batch: (done: Int, total: Int)?
    private var batchTask: Task<Void, Never>?

    /// The chosen look, carried to other photographs — the second half of the product's sentence.
    ///
    /// Each photo is resolved on its own (`Pipeline.resolve`): the look is the same, the exposure and
    /// white balance under it are that frame's, so a frame shot into the sun and the next one shot
    /// away from it both come out as "Soft" rather than as copies of the first frame's sliders. The
    /// adjustments ride on top as offsets, as they do on the photo you chose them on. Each result is
    /// saved to Photos as a new photo; originals are never touched.
    func apply(to items: [PhotosPickerItem]) {
        guard let look = selectedLook, !items.isEmpty, batch == nil else { return }
        let style = look.id, adjustments = self.adjustments, name = look.name
        batchTask = Task { [weak self] in
            guard let self else { return }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                self.notice = "To save, allow \(Branding.displayName) to add photos in Settings"
                return
            }
            self.batch = (0, items.count)
            var saved = 0, failed = 0
            for (i, item) in items.enumerated() {
                if Task.isCancelled { break }
                do {
                    guard let picked = try await item.loadTransferable(type: PickedPhoto.self) else {
                        throw OpenError.unreadable
                    }
                    let recipe = adjustments.applied(to: try await Pipeline.resolve(style: style, on: picked.url))
                    let file = try await Pipeline.export(recipe, from: picked.url)
                    try await Self.addToLibrary(file)
                    try? FileManager.default.removeItem(at: file)
                    try? FileManager.default.removeItem(at: picked.url)
                    if let key = item.itemIdentifier {
                        PhoneEditStore.save(PhoneEdit(styleId: style, adjustments: adjustments), for: key)
                    }
                    saved += 1
                } catch {
                    failed += 1
                }
                self.batch = (i + 1, items.count)
            }
            self.batch = nil
            self.notice = Task.isCancelled
                ? "Stopped — \(saved) saved to Photos as \(name)"
                : "\(saved) saved to Photos as \(name)" + (failed > 0 ? " · \(failed) couldn't be read" : "")
        }
    }

    func stopApplying() { batchTask?.cancel() }

    /// Add a written file to the library as a new photo. `@Sendable` and `nonisolated` because Photos
    /// runs the change block on its own queue — the older Swift CI builds with says so out loud.
    nonisolated private static func addToLibrary(_ file: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges { @Sendable in
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
        }
    }

    enum OpenError: LocalizedError {
        case unreadable
        var errorDescription: String? { "That photo couldn't be opened." }
    }
}

/// A photograph from the picker, as a file Kelvin can decode — RAW included, which is why this is a
/// file and not `Data`: `ImageDecoder` routes RAW through Apple's decoder by type, and a copy on disk
/// keeps a 48 MP ProRAW out of memory until it is decoded.
///
/// The copy is Kelvin's own, in its temporary directory; the library's original is never written.
struct PickedPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let ext = received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-" + UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedPhoto(url: dest)
        }
    }
}
