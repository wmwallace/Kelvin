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
// First run downloads ~2.9 GB (the 4-bit model) from Hugging Face; then inference is seconds.

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

if first == "label" {
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
        note(String(format: "Perceived in %.1fs\n", Date().timeIntervalSince(started)))

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
