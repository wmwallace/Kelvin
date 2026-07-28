import Foundation
import CryptoKit
import os

/// What the model saw in a photograph, kept between launches.
///
/// **Measured: perception is 96% of the cost of exporting a shoot** — 6.43s of a 6.72s frame, with
/// decode, statistics, masks, engine, render and write together accounting for the rest. And it was
/// recomputed every single time, because the only cache was `AppState.perceptionBySignature`: 32
/// entries, in memory, gone on quit. Exporting 400 frames re-read 400 photographs the model had
/// often already read minutes earlier. That is 45 minutes of a shoot's export spent answering a
/// question that was already answered.
///
/// A read is a **pure function of the photograph's pixels**, so it is safe to keep forever: the same
/// file put through the same model gives the same answer. That makes this an ordinary cache — it can
/// be deleted at any time and the only cost is doing the work again.
///
/// Written beside the edits, in the app's own directory, for the reason recorded on `EditStore`:
/// Kelvin does not create files inside anybody's photography library.
///
/// Reproduce the measurement with `kelvin-perceive bench-export --in-dir <shoot>`.
///
/// Lives in Core rather than beside `EditStore` in the app, because the headless tools want it too:
/// `kelvin-perceive label` builds the evaluation corpus one read at a time and had its own ad-hoc
/// resumability (skip if the output JSON exists). One cache, shared, means labelling a corpus warms
/// the app and the app warms the corpus.
public struct CachedPerception: Codable {
    public var version: Int = 1
    /// The model that produced this read. A different model is a different answer, so a cache
    /// written by one must never be served to another — this is what makes `KELVIN_MODEL=…` A/B
    /// comparisons honest rather than silently served from the previous model's cache.
    public var modelId: String
    public var perception: Perception
    public var readAt: String
    /// Size and modification date, so a file replaced under us is re-read. Deliberately NOT a
    /// content hash: SHA-256 over a folder of 60 MP RAWs is exactly the cost this cache exists to
    /// avoid, and it would be paid on every lookup rather than every read.
    public var contentHint: String?
}

public enum PerceptionStore {

    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "PerceptionStore")

    /// Beside the edits, under the app's own Application Support folder. Resolved here rather
    /// than borrowed from `EditStore` because Core must not depend on the app — the headless tools
    /// have no app bundle and still need to find the same directory.
    public static let directory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let base = appSupport
            .appendingPathComponent(Branding.displayName)
            .appendingPathComponent("perception")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static func key(for photo: URL) -> String {
        let digest = SHA256.hash(data: Data(photo.standardizedFileURL.path.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    public static func url(for photo: URL) -> URL {
        directory.appendingPathComponent(key(for: photo)).appendingPathExtension("json")
    }

    /// Size + modification date. One `stat`, no bytes touched.
    ///
    /// Deliberately `FileManager.attributesOfItem` and NOT `URL.resourceValues`. Foundation caches
    /// resource values **on the URL object**, and this app passes the same `URL` around for the
    /// whole time a photograph is open — so a file replaced under us kept reporting its old size and
    /// the stale read was served as though it were current. Caught by
    /// `testAChangedFileInvalidatesItsRead`, which is the one test here that matters most.
    public static func contentHint(for photo: URL) -> String? {
        guard let attributes = try? FileManager.default
            .attributesOfItem(atPath: photo.standardizedFileURL.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size.int64Value)-\(Int(modified))"
    }

    /// The stored read for this photograph, or nil if there is none, it came from another model, or
    /// the file has changed since.
    ///
    /// Staleness is a MISS, not an error: the caller re-reads and overwrites. That is the whole
    /// contract of a cache, and it is what lets the model be swapped without a migration.
    public static func load(for photo: URL, modelId: String) -> Perception? {
        guard let data = try? Data(contentsOf: url(for: photo)),
              let cached = try? JSONDecoder().decode(CachedPerception.self, from: data),
              cached.modelId == modelId
        else { return nil }
        if let hint = cached.contentHint, let now = contentHint(for: photo), hint != now { return nil }
        return cached.perception
    }

    public static func save(_ perception: Perception, for photo: URL, modelId: String) {
        let record = CachedPerception(
            modelId: modelId,
            perception: perception,
            readAt: ISO8601DateFormatter().string(from: Date()),
            contentHint: contentHint(for: photo))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(record).write(to: url(for: photo), options: .atomic)
        } catch {
            // A failure here costs time, never work — the next read simply recomputes. Logged
            // rather than surfaced, and the filename stays redacted because the log must not leak
            // what the app promises not to.
            log.error("Failed to cache perception: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Which of these photographs have a usable read already — a cheap existence check per file, so
    /// a shoot can say how much of itself has been read without decoding anything.
    ///
    /// Existence only: it does NOT open each file to check the model or the content hint, because
    /// this drives a progress count over hundreds of frames. A stale entry is caught on `load`.
    public static func read(among photos: [URL]) -> Set<URL> {
        let fm = FileManager.default
        return Set(photos.filter { fm.fileExists(atPath: url(for: $0).path) })
    }

    public static func remove(for photo: URL) {
        try? FileManager.default.removeItem(at: url(for: photo))
    }

    /// Forget every cached read. For the day the model changes underneath a large library and
    /// someone would rather reclaim the space than let it age out one stale entry at a time.
    public static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        _ = directory      // recreate
    }
}
