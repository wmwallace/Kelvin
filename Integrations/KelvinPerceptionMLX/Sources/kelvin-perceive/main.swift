import Foundation
import CoreImage
import KelvinCore
import KelvinPerceptionMLX

// Proves the on-device loop end to end: a real photo → Qwen2.5-VL perception (categorical
// judgments only) → the deterministic engine's candidate recipes → rendered outputs.
//
//   swift run kelvin-perceive <image> [render-out-dir]
//
// First run downloads ~2–3 GB (the 4-bit model) from Hugging Face.

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}
func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: kelvin-perceive <image> [render-out-dir]") }

do {
    let imageURL = URL(fileURLWithPath: args[1])
    let image = try ImageDecoder.decode(url: imageURL)
    note("Image: \(imageURL.lastPathComponent)  \(Int(image.extent.width))×\(Int(image.extent.height))")
    note("Loading Qwen2.5-VL-3B-Instruct-4bit (first run downloads ~2–3 GB)…")

    let provider = MLXPerceptionProvider()
    let started = Date()
    let perception = try await provider.perceive(image)
    note(String(format: "Perceived in %.1fs\n", Date().timeIntervalSince(started)))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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

    if args.count >= 3 {
        let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for recipe in candidates {
            let rendered = Renderer.render(image, with: recipe)
            let name = (recipe.id ?? "candidate") + ".jpg"
            try ImageWriter.write(rendered, to: outDir.appendingPathComponent(name),
                                  format: .jpeg(quality: 0.9))
        }
        print("\nWrote \(candidates.count) rendered candidates to \(outDir.path)")
    }
} catch {
    die("\(error)")
}
