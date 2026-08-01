import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoreLocation
import CryptoKit
import KelvinCore
import os

/// Derived data about a photograph that is expensive to read and cheap to keep: its filmstrip
/// thumbnail, its content hash, what the camera recorded in its header, and what the triage scan
/// measured.
///
/// **This exists because of network volumes.** Everything Kelvin knows about a photograph it learns
/// by reading the file, and until this landed it learned it again on every launch. On a local SSD
/// that is invisible. On a NAS it is the whole experience: opening a 437-frame shoot meant 437
/// thumbnail reads and 437 EXIF header reads over SMB, and then the same 874 reads the next morning.
/// A thumbnail that took 4 ms from an internal disk takes a round trip plus a partial file read from
/// a share, and the strip scrolls at the speed of the slowest one.
///
/// **In `~/Library/Caches`, not Application Support** — and that distinction is the point rather
/// than housekeeping. `EditStore` and `PerceptionStore` hold work that cannot be recomputed (an
/// afternoon of edits) or that costs fifteen seconds a frame to recompute (a model read), so they
/// live in Application Support where macOS will not touch them. Everything in here can be rebuilt
/// from the original file in milliseconds-to-seconds, so it belongs somewhere the system is allowed
/// to reclaim under disk pressure. Deleting this directory is always safe.
///
/// Reading is best-effort throughout: a miss, a corrupt entry and an unreadable directory are all
/// the same thing to a caller, which is "do the work". Nothing here can make Kelvin wrong, only
/// slow — with the single exception noted on `thumbnailCG`, which is why that one is lossless.
///
/// A struct with a `shared` instance rather than an `enum` of statics, so the directory can be
/// injected. Every other store in this codebase is an enum with a hardcoded path, and every one of
/// them is therefore tested against the developer's real Application Support folder or not at all.
/// A cache is the wrong place to continue that: its whole contract is "the second answer equals the
/// first", which cannot be tested without controlling where entries land and being able to throw
/// them away afterwards.
struct MediaCache: Sendable {

    /// The one the app uses.
    static let shared = MediaCache(directory: defaultDirectory)

    /// Where entries land. `shared` puts this in `~/Library/Caches`; tests point it at a temporary
    /// directory and delete it afterwards.
    let directory: URL

    private static let log = Logger(subsystem: Branding.bundleIdentifier, category: "MediaCache")

    /// How much disk this is allowed to occupy before `trim` starts evicting. 512 MB holds the
    /// thumbnails and headers for a few tens of thousands of frames, which is more shoots than
    /// anyone revisits — and it is a cache, so being wrong costs a re-read and nothing else.
    static let byteBudget: Int64 = 512 * 1024 * 1024

    static let defaultDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        // Under the bundle identifier rather than the display name: this is the convention macOS
        // itself uses for a cache directory, and unlike Application Support (which is user-visible
        // and named for a human) nobody reads this path.
        return caches
            .appendingPathComponent(Branding.bundleIdentifier)
            .appendingPathComponent("media")
    }()

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The cache key: **file name + size + modification date**, plus a variant tag, and deliberately
    /// NOT the path.
    ///
    /// This is `PerceptionStore.key`'s scheme on purpose — see the long note there for why. The
    /// short version: keying on a path means a cache silently emptied by an afternoon of tidying,
    /// measured on a real library at 19 of 23 entries orphaned, and reorganising a photography
    /// library is a thing photographers do. Name + size + mtime survives a move, a rename of any
    /// parent folder, and being filed into a different shoot.
    ///
    /// It inherits that scheme's known trade too: two photographs sharing a name, a byte count AND
    /// a modification second would be served each other's entry. Across bodies `_DSC6390.ARW` is a
    /// name that genuinely repeats, so this is not zero — the cost is one wrong thumbnail in a strip
    /// until something touches the file, and no wrong pixels anywhere, because nothing in the edit
    /// or export path reads this cache.
    ///
    /// `variant` separates the kinds of derived data, and for thumbnails it carries the pixel size —
    /// a 160 px entry must never be served to a caller that asked for 320.
    private func key(for photo: URL, variant: String) -> String? {
        // No hint means no `stat`, which means the file is gone or unreadable. Refusing to cache is
        // right here rather than falling back to the path as `PerceptionStore` does: that fallback
        // exists so a model read worth six seconds is not thrown away, and nothing in here is worth
        // an entry that cannot be invalidated.
        guard let hint = PerceptionStore.contentHint(for: photo) else { return nil }
        let identity = "\(photo.lastPathComponent)-\(hint)-\(variant)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func entry(for photo: URL, variant: String, ext: String) -> URL? {
        key(for: photo, variant: variant).map {
            directory.appendingPathComponent($0).appendingPathExtension(ext)
        }
    }

    // MARK: - Thumbnails

    /// The filmstrip thumbnail for `url`, from disk if it is there and from the original if not.
    ///
    /// **Stored as PNG, and the losslessness is load-bearing.** A 160 px JPEG would be a quarter of
    /// the size and it would be the wrong call. Today the strip's thumbnail is display-only —
    /// `AppState.signature(for:)` fingerprints frames for near-duplicate detection off a separate
    /// `PerceptionProxy.measurementProxy`, not off this — so a lossy round trip would be invisible
    /// and harmless. That is exactly what makes it a trap: the day something measures a thumbnail,
    /// the cache would start feeding it different pixels from the ones a cold read produces, and the
    /// symptom would be a measurement that changes depending on whether you had opened the folder
    /// before. This codebase has already been bitten once by two proxy sizes giving one photograph
    /// two different candidate sets (see the note on `measureOn` in `loadPhoto`); a cache that
    /// perturbs pixels is the same bug with a worse reproduction rate. PNG at this size costs tens
    /// of kilobytes and removes the whole category.
    ///
    /// **What "lossless" does and does not promise here.** The pixel values survive exactly; the
    /// in-memory layout does not. ImageIO returns a JPEG thumbnail as `noneSkipFirst` (XRGB) and the
    /// same image decoded back from PNG as `noneSkipLast` (RGBX) — same sRGB space, same 8 bits per
    /// component, same values, channels in a different order. Measured on a 160×120 thumbnail: 76,623
    /// of 76,800 bytes differ and not one pixel does. So anything comparing two of these must draw
    /// them into a common context first, and nothing may assume a byte layout from a `CGImage` that
    /// came out of here. Every consumer already goes through CIImage or a CGContext, both of which
    /// normalise on the way in, so this is a note for the next person rather than a live hazard.
    func thumbnailCG(for url: URL, maxPixel: Int = 160) -> CGImage? {
        let entry = entry(for: url, variant: "thumb\(maxPixel)", ext: "png")
        if let entry, let cached = readImage(at: entry) { return cached }
        guard let fresh = PhotoBrowser.decodeThumbnailCG(for: url, maxPixel: maxPixel) else {
            return nil
        }
        if let entry { writeImage(fresh, to: entry) }
        return fresh
    }

    private func readImage(at entry: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(entry as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return image
    }

    private func writeImage(_ image: CGImage, to entry: URL) {
        // Via a temporary file in the same directory, then an atomic move. Thumbnails are decoded
        // from several detached tasks at once and a reader can arrive mid-write; a half-written PNG
        // would be a permanent miss that looks like a corrupt thumbnail, because the key does not
        // change until the original does.
        let temp = directory.appendingPathComponent("tmp-" + UUID().uuidString)
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: temp)
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(entry, withItemAt: temp)
        } catch {
            // Losing the race to another task that cached the same frame is the ordinary case here,
            // not a failure — the entry exists either way.
            try? FileManager.default.removeItem(at: temp)
        }
    }

    // MARK: - Content hash

    /// The `sha256:…` identity Kelvin stamps into preference records and saved edits.
    ///
    /// **The most expensive single thing a photograph costs over a network, and the least urgent.**
    /// Hashing means reading every byte: a 60 MB RAW is a 60 MB transfer, where the proxy that
    /// actually goes on screen is a fraction of that. It bought a provenance string used in two
    /// places (`SavedEdit.contentHint` and `PreferencePick.imageId`) and nothing on the path to
    /// showing anybody a picture.
    ///
    /// Cached, so a shoot pays it once ever rather than once per launch. `AppState.loadPhoto` also
    /// no longer waits for it — see the deferred hash there.
    ///
    /// Streamed in chunks rather than `Data(contentsOf:)`, which used to hold the entire file in
    /// memory at once alongside the decoded full-resolution image and its proxies.
    func imageId(for url: URL) -> String? {
        let entry = entry(for: url, variant: "sha256", ext: "txt")
        if let entry, let cached = try? String(contentsOf: entry, encoding: .utf8),
           cached.hasPrefix("sha256:") {
            return cached
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        // 4 MB at a time: large enough that a network share sees sequential reads rather than a
        // syscall storm, small enough to be invisible in memory.
        let chunkSize = 4 * 1024 * 1024
        while true {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let id = "sha256:" + hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
        if let entry { try? Data(id.utf8).write(to: entry, options: .atomic) }
        return id
    }

    // MARK: - Capture info

    /// What the camera recorded, from disk if it is there.
    ///
    /// One header read per file is cheap locally and is the folder-wide cost that dominates opening
    /// a shoot from a share: `PhotoOrder.captureIndex` walks every frame to build the strip's
    /// capture-time order and its place grouping, and every one of those is a file open across the
    /// network.
    func captureInfo(for url: URL) -> CaptureInfo {
        let entry = entry(for: url, variant: "capture", ext: "json")
        if let entry, let data = try? Data(contentsOf: entry),
           let stored = try? JSONDecoder().decode(StoredCaptureInfo.self, from: data),
           stored.version == StoredCaptureInfo.currentVersion {
            return stored.captureInfo
        }
        let fresh = CaptureInfoReader.read(url: url)
        if let entry, let data = try? JSONEncoder().encode(StoredCaptureInfo(fresh)) {
            try? data.write(to: entry, options: .atomic)
        }
        return fresh
    }

    /// The capture index for a whole folder, served from the cache per frame.
    ///
    /// Mirrors `PhotoOrder.captureIndex(for:)` rather than calling it, because the saving is
    /// per-file and that function reads every file unconditionally. The ordering rules stay in
    /// `PhotoOrder` where they are tested; this only changes where the headers come from.
    func captureIndex(for urls: [URL]) -> PhotoOrder.CaptureIndex {
        var index = PhotoOrder.CaptureIndex()
        index.dates.reserveCapacity(urls.count)
        for url in urls {
            if Task.isCancelled { return index }
            let info = captureInfo(for: url)
            if let captured = info.captured { index.dates[url] = captured }
            if let location = info.location { index.locations[url] = location }
        }
        return index
    }

    /// `CaptureInfo` is not `Codable` and should not become so for this — it carries a
    /// `CLLocationCoordinate2D`, which would need a custom conformance in Core to serve a cache in
    /// the app. A DTO here keeps that decision local and versioned.
    private struct StoredCaptureInfo: Codable {
        static let currentVersion = 1
        var version = currentVersion
        var camera: String?
        var lens: String?
        var focalLength: Double?
        var aperture: Double?
        var shutterSeconds: Double?
        var iso: Double?
        var exposureBias: Double?
        var captured: Date?
        var latitude: Double?
        var longitude: Double?
        var altitude: Double?
        var positionStatus: String
        var pixelWidth: Int?
        var pixelHeight: Int?

        init(_ info: CaptureInfo) {
            camera = info.camera
            lens = info.lens
            focalLength = info.focalLength
            aperture = info.aperture
            shutterSeconds = info.shutterSeconds
            iso = info.iso
            exposureBias = info.exposureBias
            captured = info.captured
            latitude = info.coordinate?.latitude
            longitude = info.coordinate?.longitude
            altitude = info.altitude
            positionStatus = info.positionStatus.rawValue
            pixelWidth = info.pixelWidth
            pixelHeight = info.pixelHeight
        }

        var captureInfo: CaptureInfo {
            var info = CaptureInfo()
            info.camera = camera
            info.lens = lens
            info.focalLength = focalLength
            info.aperture = aperture
            info.shutterSeconds = shutterSeconds
            info.iso = iso
            info.exposureBias = exposureBias
            info.captured = captured
            if let latitude, let longitude {
                info.coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            info.altitude = altitude
            info.positionStatus = CaptureInfo.PositionStatus(rawValue: positionStatus) ?? .absent
            info.pixelWidth = pixelWidth
            info.pixelHeight = pixelHeight
            return info
        }
    }

    // MARK: - Triage verdicts

    /// The Best/Focus/Flagged measuring pass for one frame, from disk if it is there.
    ///
    /// Safe to cache because a verdict is a pure function of the file's bytes: every sample grid
    /// comes off the deterministic software raster (`ImageWriter.rgba8Sampled`, whose determinism
    /// is documented and tested), so the second answer equalling the first — the property this
    /// whole cache rests on — holds by construction. What used to happen instead: `AppState`
    /// held verdicts only in memory, so reopening a shoot re-measured all of it; over SMB that is
    /// the difference between one `stat` per frame and a preview read per frame.
    ///
    /// What is stored is the RAW READINGS only — never the derived concerns. Thresholds move
    /// (`PhotoTriage` deleted four of its own seven concerns after measuring 836 real frames), and
    /// an entry that stored conclusions would keep showing yesterday's flags on today's rules.
    /// Concerns are re-derived from the current thresholds on every load.
    func verdict(for url: URL, fastRAW: Bool = true) -> PhotoTriage.Verdict? {
        if let cached = storedVerdict(for: url, fastRAW: fastRAW) { return cached }
        guard let fresh = PhotoTriage.readTracingPath(url: url, fastRAW: fastRAW)
        else { return nil }
        // A fallback reading is never cached. The fast path can fail transiently (a network
        // volume mid-hiccup) while the full decode then succeeds, and the two paths can rasterise
        // differently — stored under the fast variant, that one frame's acuity would answer for
        // the wrong decode until the file next changed, quietly mis-ranking its burst. Uncached,
        // it self-heals on the next scan exactly as it did before the cache existed.
        if !fresh.viaFallback { storeVerdict(fresh.verdict, for: url, fastRAW: fastRAW) }
        return fresh.verdict
    }

    /// The stored verdict alone, never measuring. Split from `verdict(for:)` because nothing else
    /// can tell "served from the cache" from "re-measured quickly", and that distinction is what
    /// the invalidation tests exist to prove.
    func storedVerdict(for url: URL, fastRAW: Bool = true) -> PhotoTriage.Verdict? {
        guard let entry = entry(for: url, variant: Self.verdictVariant(fastRAW: fastRAW),
                                ext: "json"),
              let data = try? Data(contentsOf: entry),
              let stored = try? JSONDecoder().decode(StoredVerdict.self, from: data),
              stored.version == StoredVerdict.currentVersion
        else { return nil }
        return stored.verdict
    }

    func storeVerdict(_ verdict: PhotoTriage.Verdict, for url: URL, fastRAW: Bool = true) {
        guard let entry = entry(for: url, variant: Self.verdictVariant(fastRAW: fastRAW),
                                ext: "json"),
              let data = try? JSONEncoder().encode(StoredVerdict(verdict))
        else { return }
        try? data.write(to: entry, options: .atomic)
    }

    /// The variant carries the whole measurement geometry plus the decode path, and both come from
    /// the code rather than from literals here: `PhotoTriage.measurementGeometry` is built out of
    /// the same constants the pass measures through, so changing any of them — the 1200 px proxy,
    /// the 384 px focus grid, the 96 px histogram sample, the 9×8×8 hash — strands every existing
    /// entry instead of silently serving it for a measurement nobody takes any more. `fast` and
    /// `full` are separate entries because the two decode paths can rasterise differently, and
    /// `triage-compare` exists precisely because that difference is worth measuring.
    private static func verdictVariant(fastRAW: Bool) -> String {
        "verdict-\(PhotoTriage.measurementGeometry)-\(fastRAW ? "fast" : "full")"
    }

    /// `Verdict` is not `Codable` and should not become so — Core keeps its measurement types free
    /// of serialisation decisions, the same call `StoredCaptureInfo` records for `CaptureInfo`. A
    /// DTO here keeps that decision local and versioned.
    ///
    /// Raw readings only; no `concerns` field, by design — see `verdict(for:)`.
    private struct StoredVerdict: Codable {
        static let currentVersion = 1
        var version = currentVersion

        // FocusMeasure.Reading
        var acuity: Double
        var measurable: Bool

        // PhotoTriage.Signature
        var signatureBits: UInt64
        var signatureContrast: Double

        // ImageStatistics — every stored property except `dynamicRange`, which its initialiser
        // derives from the white and black points exactly as `compute` originally did.
        var meanLuma: Double
        var medianLuma: Double
        var blackPoint: Double
        var shadowLevel: Double
        var highlightLevel: Double
        var whitePoint: Double
        var highlightClip: Double
        var shadowClip: Double
        var shadowMass: Double
        var shadowRegion: Double
        var saturationClip: Double
        var chromaA: Double
        var chromaB: Double
        var neutralChromaA: Double
        var neutralChromaB: Double
        var edgeChromaA: Double
        var edgeChromaB: Double

        init(_ verdict: PhotoTriage.Verdict) {
            acuity = verdict.focus.acuity
            measurable = verdict.focus.measurable
            signatureBits = verdict.signature.bits
            signatureContrast = verdict.signature.contrast
            let s = verdict.statistics
            meanLuma = s.meanLuma
            medianLuma = s.medianLuma
            blackPoint = s.blackPoint
            shadowLevel = s.shadowLevel
            highlightLevel = s.highlightLevel
            whitePoint = s.whitePoint
            highlightClip = s.highlightClip
            shadowClip = s.shadowClip
            shadowMass = s.shadowMass
            shadowRegion = s.shadowRegion
            saturationClip = s.saturationClip
            chromaA = s.chromaA
            chromaB = s.chromaB
            neutralChromaA = s.neutralChromaA
            neutralChromaB = s.neutralChromaB
            edgeChromaA = s.edgeChromaA
            edgeChromaB = s.edgeChromaB
        }

        var verdict: PhotoTriage.Verdict {
            let statistics = ImageStatistics(
                meanLuma: meanLuma, medianLuma: medianLuma, blackPoint: blackPoint,
                shadowLevel: shadowLevel, highlightLevel: highlightLevel, whitePoint: whitePoint,
                highlightClip: highlightClip, shadowClip: shadowClip,
                chromaA: chromaA, chromaB: chromaB,
                shadowMass: shadowMass, shadowRegion: shadowRegion,
                saturationClip: saturationClip,
                neutralChromaA: neutralChromaA, neutralChromaB: neutralChromaB,
                edgeChromaA: edgeChromaA, edgeChromaB: edgeChromaB)
            let focus = FocusMeasure.Reading(acuity: acuity, measurable: measurable)
            let signature = PhotoTriage.Signature(bits: signatureBits,
                                                  contrast: signatureContrast)
            // Concerns come from the CURRENT thresholds, never from the entry.
            return PhotoTriage.Verdict(
                concerns: PhotoTriage.concerns(for: statistics, focus: focus),
                focus: focus, statistics: statistics, signature: signature)
        }
    }

    // MARK: - Housekeeping

    private static let sizeKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey
    ]

    /// Total bytes on disk, for the settings pane.
    func totalBytes() -> Int64 {
        contents().reduce(0) { $0 + $1.bytes }
    }

    private func contents() -> [(url: URL, bytes: Int64, modified: Date)] {
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Self.sizeKeys, options: .skipsHiddenFiles)
        else { return [] }
        return names.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(Self.sizeKeys)) else { return nil }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            return (url, bytes, values.contentModificationDate ?? .distantPast)
        }
    }

    /// Evict oldest-first until the cache fits its budget.
    ///
    /// By modification date rather than access date: a cache entry is written once and then only
    /// read, and macOS does not promise to update access times on every filesystem. So this evicts
    /// the frames cached longest ago rather than the ones least recently looked at — a worse
    /// heuristic that always works, over a better one that silently degrades to random.
    ///
    /// Called on a background task at launch. It never runs on the path that reads an entry, so a
    /// large cache can never make opening a photograph slower.
    func trim(toBytes budget: Int64 = MediaCache.byteBudget) {
        let entries = contents()
        var total = entries.reduce(0) { $0 + $1.bytes }
        guard total > budget else { return }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > budget else { break }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.bytes
        }
        Self.log.info("Trimmed the media cache to \(total / (1024 * 1024)) MB")
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
