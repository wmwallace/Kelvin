import Foundation
// @preconcurrency for the reason SubjectInstances gives: CIImage is Sendable on the macOS 27 SDK
// and not on the one CI builds against.
@preconcurrency import CoreImage
#if compiler(>=6.4)
import Vision
#endif

/// Tap-to-segment: the object under a click, from Apple's iterative segmentation request (Vision,
/// macOS 27 / iOS 27, `GenerateIterativeSegmentationRequest`). The pixels behind `Mask.segment`.
///
/// **Compiled only by a Swift 6.4 toolchain (Xcode 27), and live only on macOS 27 / iOS 27.** CI
/// builds with Xcode 16, whose SDK has no such request; every reference to it sits inside
/// `#if compiler(>=6.4)` and `#available`, and everywhere else `isSupported` is false and `mask`
/// returns nil — the feature is absent, never half-present.
///
/// **Blocking, by design, and for D21's sake.** The request is async-only, and measured with the
/// cooperative pool held to one thread (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`), it parks the pool
/// thread it runs on for the whole of each perform — 0.13–0.4 s warm, ~9–15 s the first time a
/// process loads the model — whatever executor it is called from: pinned to a dispatch-backed
/// `TaskExecutor`, the pool still went silent. It cannot be kept off the pool, so it is kept to ONE
/// at a time instead: these functions block their caller until Vision answers, and the app calls
/// them only from the serial Vision lane (the MLX token loop was the same bargain, D21). Never call
/// them from a Swift concurrency context; that would hold two pool threads, not one.
public enum ObjectSegmentation {

    /// Whether this build, on this OS, can select objects at all. False on anything older than
    /// macOS 27 / iOS 27 and in any build made without the macOS 27 SDK.
    public static var isSupported: Bool {
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) { return true }
        #endif
        return false
    }

    /// Where Vision's point for a tap lies. Taps are stored top-left like every point in a recipe;
    /// Vision's normalised space is bottom-left, and mixing the two is a bug this codebase has
    /// already had once (see `RegionSeed`). Verified on a real frame: a cormorant 30 px tall is
    /// found by this conversion and missed by the unconverted point.
    public static func visionPoint(_ tap: SegmentSeed.Point) -> CGPoint {
        CGPoint(x: tap.x, y: 1 - tap.y)
    }

    public enum Readiness: Equatable, Sendable {
        /// Needs macOS 27 (or a build made with its SDK).
        case unsupported
        case ready
        /// Apple's model has to be fetched or loaded first — `prepare()`.
        case needsPreparing
        case failed(String)
    }

    /// What `prepare()` would have to do. Blocking (see the type). A fresh process reports
    /// `needsPreparing` even when the model is already on disk — `prepare()` then returns at once.
    public static func readiness() -> Readiness {
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            do {
                return try waitFor { () async -> Readiness in
                    switch await GenerateIterativeSegmentationRequest(
                        seedPoint: NormalizedPoint(x: 0.5, y: 0.5)).assetStatus {
                    case .ready: return .ready
                    case .notReady, .downloading: return .needsPreparing
                    case .error(let error): return .failed(error.localizedDescription)
                    @unknown default: return .needsPreparing
                    }
                }
            } catch { return .failed(error.localizedDescription) }
        }
        #endif
        return .unsupported
    }

    /// Fetch Apple's model if this Mac does not have it yet (a one-time download, ~6 s measured),
    /// then load it by segmenting a tiny grey frame, so the first real tap is not the one that pays
    /// the process's model load. Blocking; the download is network time, so the app runs this on
    /// its fetch lane. Throws when the model cannot be had.
    public static func prepare() throws {
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            try waitFor {
                let request = GenerateIterativeSegmentationRequest(
                    seedPoint: NormalizedPoint(x: 0.5, y: 0.5))
                try await request.downloadAssets()
                // A warm-up failing is not the model being missing — the real tap will say so.
                let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
                    .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
                _ = try? await request.perform(on: grey, orientation: nil)
            }
            return
        }
        #endif
        throw Unavailable()
    }

    /// The object the taps describe, as a white-where-selected mask over `image`'s extent — or nil
    /// when there is no include tap, the OS cannot do it, or Vision found nothing. Blocking.
    ///
    /// Always regenerated from the taps on the image it will be rendered over: the canvas proxy for
    /// the canvas, the export's measurement image for the file. Measured on `_DSC6390` with a seed,
    /// an exclusion and an addition, the same taps at 768 and 2400 px disagree on 0.04% of pixels,
    /// so the file matches the canvas without a bitmap ever being stored (RECIPE-SCHEMA #6).
    public static func mask(for seed: SegmentSeed, in image: CIImage) -> CIImage? {
        guard !seed.include.isEmpty, !image.extent.isInfinite, !image.extent.isEmpty else { return nil }
        #if compiler(>=6.4)
        if #available(macOS 27, iOS 27, *) {
            guard let cg = try? waitFor({ try await segment(seed, in: image) }) else { return nil }
            return LocalMasks.scale(CIImage(cgImage: cg), to: image.extent)
        }
        #endif
        return nil
    }

    /// Every object mask in `masks`, segmented on `image` and placed over `extent` — what an export
    /// adds to the bitmaps it measures. `failed` names the masks with taps that came back empty, so
    /// the export can say which edit is missing from the file rather than write it as nothing.
    public static func bitmaps(for masks: [Mask], in image: CIImage,
                               placedOver extent: CGRect) -> (bitmaps: [String: CIImage], failed: [String]) {
        var out: [String: CIImage] = [:]
        var failed: [String] = []
        for mask in masks {
            guard let seed = mask.segment, !seed.include.isEmpty else { continue }
            if let m = self.mask(for: seed, in: image) {
                out[mask.id] = LocalMasks.scale(m, to: extent)
            } else {
                failed.append(mask.id)
            }
        }
        return (out, failed)
    }

    struct Unavailable: LocalizedError {
        var errorDescription: String? { "Selecting objects needs macOS 27." }
    }

    #if compiler(>=6.4)
    /// The request, replayed from the taps. The seed must be performed alone first — measured, adding
    /// a point before the first perform fails inside Vision ("getBestMask failed with status 14") —
    /// and every further tap then goes in at once, which gives the same mask as one perform per tap.
    @available(macOS 27, iOS 27, *)
    private static func segment(_ seed: SegmentSeed, in image: CIImage) async throws -> CGImage? {
        guard let first = seed.include.first else { return nil }
        func point(_ tap: SegmentSeed.Point) -> NormalizedPoint {
            let p = visionPoint(tap)
            return NormalizedPoint(x: p.x, y: p.y)
        }
        let request = GenerateIterativeSegmentationRequest(seedPoint: point(first))
        // A no-op when the model is here (0.02 s measured); a download when it is not.
        try await request.downloadAssets()
        var observation = try await request.perform(on: image, orientation: nil)
        let more = seed.include.dropFirst()
        if !more.isEmpty || !seed.exclude.isEmpty {
            for tap in more { try request.addIncludedPoint(point(tap)) }
            for tap in seed.exclude { try request.addExcludedPoint(point(tap)) }
            observation = try await request.perform(on: image, orientation: nil)
        }
        return try observation?.cgImage
    }
    #endif

    /// Run async work to completion from synchronous code. DETACHED, because a plain `Task` started
    /// from the command line's top-level code inherits the main actor — which is the thread waiting
    /// here, so it would never run.
    private static func waitFor<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        guard let result = box.result else { throw CancellationError() }
        return try result.get()
    }

    /// Written once by the detached task and read after the semaphore says it has been.
    private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }
}
