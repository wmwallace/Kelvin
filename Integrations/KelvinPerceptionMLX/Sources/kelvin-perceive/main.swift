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
        note("Labelling \(images.count) image(s) with Qwen2.5-VL (first run downloads ~2.9 GB)…")

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
        note("Loading Qwen2.5-VL-3B-Instruct-4bit (first run downloads ~2.9 GB)…")

        let started = Date()
        let perception = try await provider.perceive(image)
        note(String(format: "Perceived in %.1fs\n", Date().timeIntervalSince(started)))

        print("── perception (VLM output — categorical only) ──")
        print(String(data: try encoder.encode(perception), encoding: .utf8) ?? "{}")

        let stats = try ImageStatistics.compute(image)
        let candidates = RecipeEngine.candidates(
            perception: perception, statistics: stats,
            perceptionHash: PerceptionIO.hash(perception),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )

        print("\n── candidates (engine output — deterministic numbers) ──")
        for recipe in candidates {
            let g = recipe.global
            let label = (recipe.label ?? "?").padding(toLength: 9, withPad: " ", startingAt: 0)
            let wb = g.temperatureK.map { String(format: "%.0fK", $0) } ?? "as-shot"
            print("  \(label)  " + String(format: "exp %+.2f  contrast %+3.0f  vibrance %+3.0f  wb %@",
                                          g.exposureEV, g.contrast, g.vibrance, wb as NSString))
        }

        if args.count >= 2 {
            let dir = URL(fileURLWithPath: args[1], isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for recipe in candidates {
                let rendered = Renderer.render(image, with: recipe)
                try ImageWriter.write(rendered, to: dir.appendingPathComponent((recipe.id ?? "candidate") + ".jpg"),
                                      format: .jpeg(quality: 0.9))
            }
            print("\nWrote \(candidates.count) rendered candidates to \(dir.path)")
        }
    } catch {
        die("\(error)")
    }
}
