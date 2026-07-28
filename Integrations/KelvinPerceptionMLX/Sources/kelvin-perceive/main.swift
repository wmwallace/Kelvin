import Foundation
import CoreImage
import KelvinCore
import KelvinPerceptionMLX

// The on-device perception driver. Two modes:
//
//   kelvin-perceive <image> [render-out-dir]
//       Perceive one photo → print perception JSON + engine candidates (and optionally
//       render them). Proves the full loop.
//
//   kelvin-perceive label --in-dir <sources> --out-dir <labels>
//       Perceive every image in a folder and write <stem>.json per image — the corpus
//       labelling step that feeds `kelvin-cli eval`. Resumable (skips already-labelled),
//       and the model loads once (the provider is an actor that caches it).
//
//   kelvin-perceive bench-export --in-dir <shoot> [--out-dir <dir>] [--limit N]
//                                 [--style natural] [--no-cache] [--lanes N]
//       Time the ADAPTED EXPORT path — the one a shoot carrying an applied look takes —
//       stage by stage, and say what it costs at shoot scale.
//
//       This exists because `docs/ARCHITECTURE.md` carries a budget row for exporting
//       look-carried frames and nothing could measure it. The stages below are the same
//       sequence, in the same order, as `AppState.adaptedRecipe` followed by the render
//       and write in `exportEdited`: decode → proxy → perceive → statistics → local masks
//       → engine → full-res masks → render → write. If that path changes, change this.
//
// First run downloads ~1.6 GB (the 4-bit model) from Hugging Face; then inference is seconds.
// Measured, not estimated — and avoidable entirely with `make stage-model` plus KELVIN_MODEL_PATH.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}
func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
func flag(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

let args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first else {
    die("usage:\n  kelvin-perceive <image> [render-out-dir]\n  kelvin-perceive label --in-dir <dir> --out-dir <dir>")
}

let provider = MLXPerceptionProvider()

/// A render waiting to be written. `CIImage` crosses to the task group here deliberately: it is a
/// filter graph, and forcing it is exactly the work being parallelised.
struct WriteJob: @unchecked Sendable {
    let image: CIImage
    let out: URL
}

/// One frame's stage timings, in seconds.
struct FrameTiming {
    var decode = 0.0, proxy = 0.0, perceive = 0.0, statistics = 0.0
    var proxyMasks = 0.0, engine = 0.0, curate = 0.0, fullResMasks = 0.0, render = 0.0, write = 0.0
    var total: Double {
        decode + proxy + perceive + statistics + proxyMasks + engine + curate
            + fullResMasks + render + write
    }
}

/// Materialise a lazy CIImage so later measurements do not silently re-render the full frame.
/// The same trick `AppState` uses; duplicated here because that one lives in the app target.
///
/// Inside an enum rather than at file scope, and this is not style: **top-level `let`s in a
/// `main.swift` are implicitly main-actor isolated**, so a nonisolated function reading one does not
/// compile. It did compile on the author's SDK and failed on CI's — the second time this exact
/// divergence has bitten in this change alone (see `HistogramTests`). Static members of a type carry
/// no such isolation, which makes this the boring, portable spelling.
enum Bench {
    /// `nonisolated(unsafe)` because `CIContext` is `Sendable` on the macOS 27 SDK and NOT on the
    /// one CI builds against — so this line warns "unnecessary" here and is required there. The
    /// same trap, with the same annotation and the same reason, is on `AppState.sharedContext`;
    /// that comment is the canonical one. Do not delete this to silence the local warning.
    nonisolated(unsafe) static let context: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: true])
        }
        return CIContext()
    }()

    static func materialise(_ image: CIImage) -> CIImage {
        guard let cg = context.createCGImage(image, from: image.extent) else { return image }
        return CIImage(cgImage: cg)
    }
}
func clock<T>(_ into: inout Double, _ body: () throws -> T) rethrows -> T {
    let t = Date(); defer { into = Date().timeIntervalSince(t) }
    return try body()
}

if first == "bench-export" {
    guard let inDir = flag("--in-dir", in: args) else { die("bench-export requires --in-dir") }
    let outDir = flag("--out-dir", in: args)
        ?? NSTemporaryDirectory() + "kelvin-bench-\(UUID().uuidString)"
    let limit = flag("--limit", in: args).flatMap(Int.init)
    let styleId = flag("--style", in: args) ?? "natural"
    let noCache = args.contains("--no-cache")
    // Mirrors the app's export: plan sequentially, then render N frames at once. 1 is the old
    // strictly-sequential behaviour, for measuring against.
    let lanes = max(1, flag("--lanes", in: args).flatMap(Int.init) ?? 3)
    // Export size, so the cost of writing full-resolution frames can be measured against a
    // delivery-sized one. 0 means full resolution.
    let longEdge = flag("--long-edge", in: args).flatMap(Int.init) ?? 0
    let exportSize: ImageWriter.Size = longEdge > 0 ? .longEdge(longEdge) : .fullResolution
    guard let style = CandidateStyle.all.first(where: { $0.id == styleId }) else {
        die("unknown style '\(styleId)'")
    }
    let outURL = URL(fileURLWithPath: outDir, isDirectory: true)

    do {
        var images = try BatchApply.imageFiles(in: URL(fileURLWithPath: inDir, isDirectory: true))
        guard !images.isEmpty else { die("no images in \(inDir)") }
        if let limit { images = Array(images.prefix(limit)) }
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

        note("Export benchmark — \(images.count) frame(s), style \(style.label)")
        note("Model \(provider.activeModelID); size \(longEdge > 0 ? "\(longEdge) px" : "full"); writing to \(outURL.path)\n")

        var timings: [FrameTiming] = []
        var pending: [WriteJob] = []
        var cacheHits = 0
        let wallStart = Date()
        for (i, url) in images.enumerated() {
            var t = FrameTiming()
            let full = try clock(&t.decode) { try ImageDecoder.decode(url: url) }
            let proxy = clock(&t.proxy) { Bench.materialise(PerceptionProxy.downsample(full)) }

            // The same cache the app uses, hit in the same order — so this measures shipped
            // behaviour rather than a benchmark's idea of it. Run twice on one shoot to see the
            // difference the cache makes; `--no-cache` measures the cold path deliberately.
            let perceiveStart = Date()
            let perception: Perception
            if !noCache, let cached = PerceptionStore.load(for: url, modelId: provider.activeModelID) {
                perception = cached
                cacheHits += 1
            } else {
                perception = try await provider.perceive(proxy)
                PerceptionStore.save(perception, for: url, modelId: provider.activeModelID)
            }
            t.perceive = Date().timeIntervalSince(perceiveStart)

            let stats = try clock(&t.statistics) { try ImageStatistics.compute(proxy) }
            let measured = clock(&t.proxyMasks) { LocalMasks.measure(in: proxy) }
            // THE WHOLE CANDIDATE SET, then curate — because that is what the app's export does.
            //
            // This used to build the requested style alone, which is exactly the divergence that
            // made the app's export disagree with its own canvas: the curator drops styles that are
            // wrong for a frame, and a benchmark that skips the curator measures a path nobody
            // ships. `curate` is timed separately so the cost of getting it right is visible rather
            // than buried in `engine`.
            let iso = ExifReader.iso(url: url)
            let generated = clock(&t.engine) {
                RecipeEngine.candidates(perception: perception, statistics: stats,
                                        subjectLuma: measured.subjectLuma,
                                        skyLuma: measured.skyLuma, iso: iso)
            }
            let recipe = clock(&t.curate) { () -> Recipe in
                var scored: [CandidateCurator.Scored] = []
                for candidate in generated {
                    let preview = Renderer.render(proxy, with: candidate, maskBitmaps: measured.bitmaps)
                    guard let score = AestheticEvaluator.score(rendered: preview) else { continue }
                    scored.append(.init(recipe: candidate, score: score))
                }
                if let chosen = CandidateCurator.resolve(from: scored, requested: style.id).chosen {
                    return chosen.recipe
                }
                return RecipeEngine.candidate(perception: perception, statistics: stats, style: style,
                                              subjectLuma: measured.subjectLuma,
                                              skyLuma: measured.skyLuma, iso: iso)
            }
            // Full-resolution masks only when the recipe actually carries masks — same condition
            // the export loop uses, and it is a large part of the cost when it fires.
            let bitmaps = clock(&t.fullResMasks) {
                (recipe.masks?.isEmpty == false) ? LocalMasks.measure(in: full).bitmaps : [:]
            }
            let rendered = clock(&t.render) { Renderer.render(full, with: recipe, maskBitmaps: bitmaps) }
            let out = outURL.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jpg")
            if lanes <= 1 {
                try clock(&t.write) {
                    try ImageWriter.write(rendered, to: out, format: .jpeg(quality: 0.97),
                                      size: exportSize)
                }
                note(String(format: "  %2d/%d  %-24@ %5.2fs", i + 1, images.count,
                            url.lastPathComponent as NSString, t.total))
            } else {
                pending.append(WriteJob(image: rendered, out: out))
            }
            timings.append(t)
        }
        // The concurrent half: the writes (which force the render) run N at a time. Per-stage
        // timings above stay sequential and honest; WALL time is what this flag measures.
        if lanes > 1 {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < pending.count else { return }
                    let job = pending[next]; next += 1
                    group.addTask {
                        try? ImageWriter.write(job.image, to: job.out, format: .jpeg(quality: 0.97))
                    }
                }
                for _ in 0..<min(lanes, pending.count) { add() }
                while await group.next() != nil { add() }
            }
        }
        let wall = Date().timeIntervalSince(wallStart)

        func stat(_ pick: (FrameTiming) -> Double) -> (mean: Double, share: Double) {
            let values = timings.map(pick)
            let mean = values.reduce(0, +) / Double(values.count)
            let totalMean = timings.map(\.total).reduce(0, +) / Double(timings.count)
            return (mean, totalMean > 0 ? mean / totalMean * 100 : 0)
        }
        let stages: [(String, (FrameTiming) -> Double)] = [
            ("decode", \.decode), ("proxy", \.proxy), ("perceive", \.perceive),
            ("statistics", \.statistics), ("masks (proxy)", \.proxyMasks), ("engine", \.engine),
            ("curate", \.curate),
            ("masks (full-res)", \.fullResMasks), ("render", \.render), ("write", \.write),
        ]
        print("\n── per-frame cost ──")
        for (name, pick) in stages {
            let s = stat(pick)
            print(String(format: "  %-18@ %6.2fs  %5.1f%%", name as NSString, s.mean, s.share))
        }
        let totals = timings.map(\.total).sorted()
        let mean = totals.reduce(0, +) / Double(totals.count)
        print(String(format: "  %-18@ %6.2fs", "TOTAL" as NSString, mean))
        print(String(format: "\n  min %.2fs · median %.2fs · max %.2fs · wall %.1fs for %d frames",
                     totals.first ?? 0, totals[totals.count / 2], totals.last ?? 0, wall, timings.count))
        print("  perception: \(cacheHits) served from cache, \(timings.count - cacheHits) read fresh")

        print("\n── at shoot scale (sequential, as the app runs it today) ──")
        for n in [100, 400, 1000] {
            let seconds = mean * Double(n)
            print(String(format: "  %4d frames  %6.1f min", n, seconds / 60))
        }
    } catch {
        die("\(error)")
    }
} else if first == "compare-measure-edge" {
    // ---- Does measurement resolution change the edit? ----
    //
    // THE CANVAS AND THE EXPORT MEASURE AT DIFFERENT SIZES. `AppState.loadPhoto` computes
    // statistics, local masks and candidate scores on the 1200 px EDIT proxy;
    // `AppState.adaptedRecipe` computes all three on the 768 px PERCEPTION proxy. They apply the
    // same curation rule to different measurements, so they can still disagree — and the recipe's
    // own numbers can differ — for the same photograph.
    //
    // Fixing that means changing what one of them measures, which changes the pixels of every
    // existing shoot look. CLAUDE.md says that wants eval-harness evidence rather than a
    // judgement call, and this is the evidence: run both arms over real frames and report what
    // actually differs. Perception is held FIXED (it is read at 768 in both paths already, and
    // served from cache here), so measurement resolution is the only variable.
    //
    //   kelvin-perceive compare-measure-edge --in-dir <shoot> [--limit N] [--style natural]
    //                                        [--a 768] [--b 1200]
    guard let inDir = flag("--in-dir", in: args) else {
        die("compare-measure-edge requires --in-dir")
    }
    let limit = flag("--limit", in: args).flatMap(Int.init)
    let styleId = flag("--style", in: args) ?? "natural"
    let edgeA = flag("--a", in: args).flatMap(Int.init) ?? PerceptionProxy.defaultMaxEdge
    let edgeB = flag("--b", in: args).flatMap(Int.init) ?? 1200
    guard let style = CandidateStyle.all.first(where: { $0.id == styleId }) else {
        die("unknown style '\(styleId)'")
    }

    /// One arm: measure at `edge`, generate, score, curate, and resolve the requested style —
    /// the same sequence both shipped paths run, differing only in the size they measure at.
    func resolve(_ full: CIImage, at edge: Int, perception: Perception,
                 iso: Double?) throws -> (recipe: Recipe, honoured: Bool, curated: [String],
                                          faces: Int, requestedScore: Double?, subjectLuma: Double?) {
        let proxy = Bench.materialise(PerceptionProxy.downsample(full, maxEdge: edge))
        let stats = try ImageStatistics.compute(proxy)
        let masks = LocalMasks.measure(in: proxy)
        let generated = RecipeEngine.candidates(perception: perception, statistics: stats,
                                                subjectLuma: masks.subjectLuma,
                                                skyLuma: masks.skyLuma, iso: iso)
        var scored: [CandidateCurator.Scored] = []
        for candidate in generated {
            let preview = Renderer.render(proxy, with: candidate, maskBitmaps: masks.bitmaps)
            guard let score = AestheticEvaluator.score(rendered: preview) else { continue }
            scored.append(.init(recipe: candidate, score: score))
        }
        let r = CandidateCurator.resolve(from: scored, requested: style.id)
        let fallback = RecipeEngine.candidate(perception: perception, statistics: stats,
                                              style: style, subjectLuma: masks.subjectLuma,
                                              skyLuma: masks.skyLuma, iso: iso)
        // WHY a frame flips, not just that it did. `AestheticEvaluator.score(rendered:)` is
        // statistics — which are sampled to 96x96 and so barely care about resolution — PLUS
        // `FaceSkin.read`, which is Vision. If the two arms disagree it is almost certainly Vision
        // seeing a different number of faces at a different input size, and that swings the skin
        // term, which swings the quality floor, which decides curation. Reporting the face count
        // and the requested style's score says whether that is what happened.
        let faces = FaceSkin.read(in: proxy).faceCount
        let requestedScore = scored.first { $0.recipe.id == style.id }?.score.overall
        return (r.chosen?.recipe ?? fallback, r.honouredRequest,
                r.curated.map { $0.recipe.id ?? "?" }, faces, requestedScore, masks.subjectLuma)
    }

    do {
        var images = try BatchApply.imageFiles(in: URL(fileURLWithPath: inDir, isDirectory: true))
        images = PhotoOrder.sorted(images, by: .filename)
        guard !images.isEmpty else { die("no images in \(inDir)") }
        if let limit { images = Array(images.prefix(limit)) }

        note("Measurement-resolution A/B — \(images.count) frame(s), style \(style.label)")
        note("  A = \(edgeA) px (what export measures at) · B = \(edgeB) px (what the canvas does)")
        note("  perception held fixed, from cache\n")

        var deltaEs: [Double] = []
        var curationFlips = 0, chosenFlips = 0, recipeDiffs = 0
        var fresh = 0
        var worst: (name: String, de: Double) = ("", 0)

        for (i, url) in images.enumerated() {
            let full = try ImageDecoder.decode(url: url)
            // Perception is the CONTROL, not a variable: both shipped paths read it at 768 px, so
            // both arms share one read. Cached where possible, read and kept where not — a shoot
            // nobody has opened would otherwise be un-measurable.
            let perception: Perception
            if let cached = PerceptionStore.load(for: url, modelId: provider.activeModelID) {
                perception = cached
            } else {
                let readProxy = Bench.materialise(PerceptionProxy.downsample(full))
                perception = try await provider.perceive(readProxy)
                PerceptionStore.save(perception, for: url, modelId: provider.activeModelID)
                fresh += 1
            }
            let iso = ExifReader.iso(url: url)
            let a = try resolve(full, at: edgeA, perception: perception, iso: iso)
            let b = try resolve(full, at: edgeB, perception: perception, iso: iso)

            // The measurement that decides it: render the FULL frame under each arm's recipe and
            // compare the pixels. Recipe-field deltas say something changed; ΔE says whether a
            // photographer could tell.
            //
            // WITH the full-resolution mask bitmaps, and that is not a detail. `Renderer` skips any
            // recipe mask it is handed no bitmap for, so rendering without them compares the global
            // half of two recipes and silently discards the local half — which is precisely where
            // this experiment's variable lands, since `subjectLuma` and `skyLuma` are two of the
            // measurements that differ between the arms. The bitmaps themselves come off the full
            // frame and are shared, exactly as export builds them; what differs is the strength
            // each arm's recipe asks for.
            let fullMasks = LocalMasks.measure(in: full).bitmaps
            let sampleA = try ImageMetrics.sample(
                Renderer.render(full, with: a.recipe, maskBitmaps: fullMasks))
            let sampleB = try ImageMetrics.sample(
                Renderer.render(full, with: b.recipe, maskBitmaps: fullMasks))
            let de = ImageMetrics.meanDeltaE2000(sampleA, sampleB)
            deltaEs.append(de)
            if de > worst.de { worst = (url.lastPathComponent, de) }

            if a.curated != b.curated { curationFlips += 1 }
            if a.recipe.id != b.recipe.id { chosenFlips += 1 }
            let sameNumbers = a.recipe.global == b.recipe.global
            if !sameNumbers { recipeDiffs += 1 }

            let mark = a.recipe.id != b.recipe.id ? "  ← CHOSE A DIFFERENT LOOK"
                : (a.curated != b.curated ? "  ← curated set differs" : "")
            note(String(format: "  %2d/%d  %-22@ ΔE %5.2f  %@ vs %@%@",
                        i + 1, images.count, url.lastPathComponent as NSString, de,
                        (a.recipe.id ?? "?") as NSString, (b.recipe.id ?? "?") as NSString,
                        mark as NSString))
            // Explain any frame the two arms did not agree on, because WHICH ARM IS RIGHT decides
            // which way to unify them, and "they differ" does not answer that.
            if a.recipe.id != b.recipe.id || a.curated != b.curated {
                func fmt(_ d: Double?) -> String { d.map { String(format: "%.3f", $0) } ?? "—" }
                note("          faces \(a.faces) vs \(b.faces) · "
                     + "\(style.id) score \(fmt(a.requestedScore)) vs \(fmt(b.requestedScore)) · "
                     + "subjectLuma \(fmt(a.subjectLuma)) vs \(fmt(b.subjectLuma))")
                note("          offered A: \(a.curated.joined(separator: ","))")
                note("          offered B: \(b.curated.joined(separator: ","))")
            }
        }

        guard !deltaEs.isEmpty else {
            die("no frames could be measured")
        }
        let sorted = deltaEs.sorted()
        let mean = deltaEs.reduce(0, +) / Double(deltaEs.count)
        let n = deltaEs.count

        print("\n── measuring at \(edgeA) px vs \(edgeB) px, \(n) frame(s) ──")
        print(String(format: "  ΔE2000 between the two renders   mean %.2f · median %.2f · max %.2f",
                     mean, sorted[n / 2], sorted.last ?? 0))
        print("  worst frame                      \(worst.name) at ΔE \(String(format: "%.2f", worst.de))")
        print("  recipes with different numbers   \(recipeDiffs) of \(n)")
        print("  frames offering a different set  \(curationFlips) of \(n)")
        print("  frames OPENING IN A DIFFERENT LOOK  \(chosenFlips) of \(n)")
        if fresh > 0 { print("  perception read fresh            \(fresh) of \(n)") }
        print("""

          ΔE2000 below 1.0 is generally taken as imperceptible to the average eye; below 2.0,
          perceptible only on close inspection. A different CHOSEN LOOK is not a small
          difference at any ΔE — it is the canvas and the export disagreeing about which
          candidate the photograph is.
        """)
    } catch {
        die("\(error)")
    }
} else if first == "label" {
    // ---- Batch corpus labelling ----
    guard let inDir = flag("--in-dir", in: args) else { die("label requires --in-dir") }
    guard let outDir = flag("--out-dir", in: args) else { die("label requires --out-dir") }
    let inURL = URL(fileURLWithPath: inDir, isDirectory: true)
    let outURL = URL(fileURLWithPath: outDir, isDirectory: true)

    do {
        let images = try BatchApply.imageFiles(in: inURL)
        guard !images.isEmpty else { die("no images in \(inDir)") }
        try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
        note("Labelling \(images.count) image(s) with \(provider.activeModelID) (first run downloads the weights)…")

        var done = 0, skipped = 0, failed = 0
        for (i, image) in images.enumerated() {
            let stem = image.deletingPathExtension().lastPathComponent
            let jsonURL = outURL.appendingPathComponent(stem).appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: jsonURL.path) { skipped += 1; continue }
            do {
                let decoded = try ImageDecoder.decode(url: image)
                let perception = try await provider.perceive(decoded)
                try encoder.encode(perception).write(to: jsonURL)
                done += 1
                if done % 25 == 0 || i == images.count - 1 {
                    note("  \(done + skipped)/\(images.count) (\(skipped) skipped, \(failed) failed)")
                }
            } catch {
                failed += 1
                note("  ✗ \(stem): \(error)")
            }
        }
        note("Done: \(done) labelled, \(skipped) already present, \(failed) failed.")
    } catch {
        die("\(error)")
    }
} else {
    // ---- Single image ----
    do {
        let imageURL = URL(fileURLWithPath: first)
        let image = try ImageDecoder.decode(url: imageURL)
        note("Image: \(imageURL.lastPathComponent)  \(Int(image.extent.width))×\(Int(image.extent.height))")
        // The model actually in use, not the default. This said "Qwen2.5-VL-3B-Instruct-4bit"
        // unconditionally, so `KELVIN_MODEL=…` — which exists precisely so two models can be
        // compared on real photos — reported the wrong one the whole time it was being A/B'd.
        note("Loading \(provider.activeModelID) (first run downloads the weights)…")

        let started = Date()
        let perception = try await provider.perceive(image)
        note(String(format: "Perceived in %.1fs", Date().timeIntervalSince(started)))
        // The breakdown, because "4.5 seconds" does not say whether to shrink the image or the
        // answer — and both of those trade accuracy, so the trade should be aimed.
        note("  " + (await provider.lastTiming).summary + "\n")

        print("── perception (VLM output — categorical only) ──")
        print(String(data: try encoder.encode(perception), encoding: .utf8) ?? "{}")

        let stats = try ImageStatistics.compute(image)

        // Local masks (subject + sky) and their metered brightness → the engine's local
        // decisions. One pass produces the bitmaps and the lumas (skin-aware for the subject).
        let measured = LocalMasks.measure(in: image)
        if let luma = measured.subjectLuma { note(String(format: "subject present, metered luma %.3f", luma)) }
        if let luma = measured.skyLuma { note(String(format: "sky present, mean luma %.3f", luma)) }
        let maskBitmaps = measured.bitmaps

        let iso = ExifReader.iso(url: imageURL)
        if let iso { note(String(format: "ISO %.0f → noise-reduction sized from sensor gain", iso)) }
        let candidates = RecipeEngine.candidates(
            perception: perception, statistics: stats,
            subjectLuma: measured.subjectLuma, skyLuma: measured.skyLuma, iso: iso,
            perceptionHash: PerceptionIO.hash(perception),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )

        print("\n── candidates (engine output — deterministic numbers, aesthetic score) ──")
        var scored: [(recipe: Recipe, score: Double)] = []
        var scoredForCuration: [CandidateCurator.Scored] = []
        for recipe in candidates {
            let g = recipe.global
            let label = (recipe.label ?? "?").padding(toLength: 9, withPad: " ", startingAt: 0)
            let wb = g.temperatureK.map { String(format: "%.0fK", $0) } ?? "as-shot"
            // Score the *rendered* candidate against the craft floors (tonal range, clipping,
            // skin plausibility, cast) — objective quality, not taste.
            let rendered = Renderer.render(image, with: recipe, maskBitmaps: maskBitmaps)
            let aesthetic = AestheticEvaluator.score(rendered: rendered)
            scored.append((recipe, aesthetic?.overall ?? 0))
            if let aesthetic { scoredForCuration.append(.init(recipe: recipe, score: aesthetic)) }
            let scoreStr = aesthetic.map { String(format: "%.2f", $0.overall) } ?? "  – "
            let flags = aesthetic?.notes.isEmpty == false ? "  ⚠ " + (aesthetic!.notes.joined(separator: "; ")) : ""
            print("  \(label)  " + String(format: "exp %+.2f  contrast %+3.0f  vibrance %+3.0f  wb %-7@  score %@",
                                          g.exposureEV, g.contrast, g.vibrance, wb as NSString, scoreStr as NSString) + flags)
        }
        // What the app would actually SHOW: generate widely, then curate.
        let curated = CandidateCurator.select(from: scoredForCuration, count: 4)
        print("\n── curated (what the picker shows) ──")
        for item in curated {
            print(String(format: "  %-9@ score %.2f",
                         (item.recipe.label ?? "?") as NSString, item.score.overall))
        }
        let droppedNames = candidates.compactMap { $0.label }
            .filter { name in !curated.contains { $0.recipe.label == name } }
        if !droppedNames.isEmpty {
            print("  dropped: " + droppedNames.joined(separator: ", "))
        }

        if let best = curated.first {
            print("\n── suggested export name ──")
            print("  " + ExportNaming.filename(for: imageURL, perception: perception,
                                               look: best.recipe.label))
        }

        if let cleanest = scored.max(by: { $0.score < $1.score }) {
            // "Cleanest" = fewest craft defects, NOT "best look" (that's the user's taste). The
            // score is a guardrail: it flags clipping / bad skin / casts, it doesn't pick a mood.
            print("  → cleanest (fewest craft defects): \(cleanest.recipe.label ?? "?") "
                  + "(\(String(format: "%.2f", cleanest.score)))")
        }

        if args.count >= 2 {
            let dir = URL(fileURLWithPath: args[1], isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for recipe in candidates {
                let rendered = Renderer.render(image, with: recipe, maskBitmaps: maskBitmaps)
                try ImageWriter.write(rendered, to: dir.appendingPathComponent((recipe.id ?? "candidate") + ".jpg"),
                                      format: .jpeg(quality: 0.9))
            }
            print("\nWrote \(candidates.count) rendered candidates to \(dir.path)")
        }
    } catch {
        die("\(error)")
    }
}
