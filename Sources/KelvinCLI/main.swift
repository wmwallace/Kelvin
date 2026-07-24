import Foundation
import KelvinCore

// Headless entry point. This is a first-class target — it is how the eval harness will run
// (ARCHITECTURE.md), not a debug affordance. Milestone 1 ships one subcommand: `render`.
//
// Arg parsing is hand-rolled to keep M1 dependency-free and buildable offline. It is
// deliberately small; swift-argument-parser is the intended replacement once a second
// subcommand (`eval`) exists and the flag surface grows.

let tool = Branding.displayName.lowercased() + "-cli"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func printUsage() {
    print("""
    \(Branding.displayName) CLI

    Usage:
      \(tool) render --in <image> --recipe <recipe.json> --out <output>
      \(tool) engine --in <image> --perception <perception.json> --out <recipe.json>
      \(tool) candidates --in <image> --perception <perception.json> --out-dir <dir>
      \(tool) batch --in-dir <dir> --recipe <recipe.json> --out-dir <dir> [--format png|jpg]
      \(tool) corpus-init --root <dir> --references <a,b,c> [--source <dir>] [--perception <dir>]
      \(tool) corpus-degrade --in-dir <good-photos> --out-dir <corpus>
      \(tool) eval --corpus <dir> [--out <report.json>] [--engine-version <v>]

    render options:
      --in       Path to the source image (RAW, JPEG, or PNG). Required.
      --recipe   Path to a recipe JSON sidecar. Required.
      --out      Output path. Extension picks the format (.png or .jpg). Required.

    engine options:
      --in          Path to the source image (RAW, JPEG, or PNG). Required.
      --perception  Path to a hand-labelled perception JSON (Stage 1). Required.
      --out         Where to write the generated recipe JSON. Required.

    candidates options:
      --in          Path to the source image (RAW, JPEG, or PNG). Required.
      --perception  Path to a hand-labelled perception JSON (Stage 1). Required.
      --out-dir     Directory to write one <style>.json per candidate. Required.

    batch options:
      --in-dir      Directory of source images to propagate the recipe across. Required.
      --recipe      Path to a recipe JSON sidecar. Required.
      --out-dir     Directory to write rendered outputs (originals untouched). Required.
      --format      png (default) or jpg.

    corpus-init options:
      --root        Dataset root containing the source and expert folders. Required.
      --references  Comma-separated expert subfolders (e.g. target_a,target_b,target_c). Required.
      --source      Source-image subfolder. Default "source".
      --perception  Optional subfolder of per-image perception JSON (<id>.json).
      --camera      Optional subfolder of manufacturer JPEGs (<id>.jpg).
      --out         Where to write manifest.json. Default <root>/manifest.json.

    corpus-degrade options (commercial-clean: good photos → degraded sources + originals):
      --in-dir      Folder of good photographs you own (references). Required.
      --out-dir     Where to write reference/, source/, and manifest.json. Required.

    eval options:
      --corpus          Directory containing a manifest.json. Required.
      --out             Where to write report.json. Optional; table always prints.
      --engine-version  Label recorded in the report. Default 0.1.0.

    Other:
      -h, --help  Show this help.
    """)
}

/// Minimal `--flag value` extractor. Returns the value following `flag`, or nil.
func value(for flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard let subcommand = arguments.first else {
    printUsage()
    exit(0)
}

if subcommand == "-h" || subcommand == "--help" {
    printUsage()
    exit(0)
}

switch subcommand {
case "render":
    let rest = Array(arguments.dropFirst())

    guard let inPath = value(for: "--in", in: rest) else { fail("render requires --in") }
    guard let recipePath = value(for: "--recipe", in: rest) else { fail("render requires --recipe") }
    guard let outPath = value(for: "--out", in: rest) else { fail("render requires --out") }

    let inURL = URL(fileURLWithPath: inPath)
    let recipeURL = URL(fileURLWithPath: recipePath)
    let outURL = URL(fileURLWithPath: outPath)

    do {
        let image = try ImageDecoder.decode(url: inURL)
        let recipe = try RecipeIO.load(from: recipeURL)   // clamps on decode
        let rendered = Renderer.render(image, with: recipe)
        try ImageWriter.write(rendered, to: outURL)
        print("Wrote \(outURL.path)")
    } catch {
        fail("\(error)")
    }

case "engine":
    let rest = Array(arguments.dropFirst())

    guard let inPath = value(for: "--in", in: rest) else { fail("engine requires --in") }
    guard let perceptionPath = value(for: "--perception", in: rest) else { fail("engine requires --perception") }
    guard let outPath = value(for: "--out", in: rest) else { fail("engine requires --out") }

    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let stats = try ImageStatistics.compute(image)
        let perception = try PerceptionIO.load(from: URL(fileURLWithPath: perceptionPath))
        let recipe = RecipeEngine.recipe(
            perception: perception,
            statistics: stats,
            perceptionHash: PerceptionIO.hash(perception),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try RecipeIO.save(recipe, to: URL(fileURLWithPath: outPath))
        print("Wrote \(outPath) [\(recipe.label ?? "recipe")]")
    } catch {
        fail("\(error)")
    }

case "candidates":
    let rest = Array(arguments.dropFirst())

    guard let inPath = value(for: "--in", in: rest) else { fail("candidates requires --in") }
    guard let perceptionPath = value(for: "--perception", in: rest) else { fail("candidates requires --perception") }
    guard let outDirPath = value(for: "--out-dir", in: rest) else { fail("candidates requires --out-dir") }

    let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)

    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let stats = try ImageStatistics.compute(image)
        let perception = try PerceptionIO.load(from: URL(fileURLWithPath: perceptionPath))
        // One perception, one statistics pass → N recipes (parameter swaps, no re-perception).
        let recipes = RecipeEngine.candidates(
            perception: perception,
            statistics: stats,
            perceptionHash: PerceptionIO.hash(perception),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        for recipe in recipes {
            let name = (recipe.id ?? recipe.label ?? "candidate") + ".json"
            try RecipeIO.save(recipe, to: outDir.appendingPathComponent(name))
        }
        let labels = recipes.map { $0.label ?? "?" }.joined(separator: ", ")
        print("Wrote \(recipes.count) candidates to \(outDir.path) [\(labels)]")
    } catch {
        fail("\(error)")
    }

case "batch":
    let rest = Array(arguments.dropFirst())

    guard let inDirPath = value(for: "--in-dir", in: rest) else { fail("batch requires --in-dir") }
    guard let recipePath = value(for: "--recipe", in: rest) else { fail("batch requires --recipe") }
    guard let outDirPath = value(for: "--out-dir", in: rest) else { fail("batch requires --out-dir") }

    let format: ImageWriter.Format
    switch value(for: "--format", in: rest)?.lowercased() {
    case "jpg", "jpeg": format = .jpeg(quality: 0.92)
    case "png", nil: format = .png
    case let other?: fail("unknown --format '\(other)' (use png or jpg)")
    }

    do {
        let recipe = try RecipeIO.load(from: URL(fileURLWithPath: recipePath))
        let outcome = try BatchApply.run(
            inputDir: URL(fileURLWithPath: inDirPath, isDirectory: true),
            recipe: recipe,
            outputDir: URL(fileURLWithPath: outDirPath, isDirectory: true),
            format: format
        )
        print("Applied recipe to \(outcome.succeeded) image(s), \(outcome.failed) failed.")
        for failure in outcome.failures {
            FileHandle.standardError.write(Data("  skipped \(failure.source.lastPathComponent): \(failure.message)\n".utf8))
        }
    } catch {
        fail("\(error)")
    }

case "corpus-init":
    let rest = Array(arguments.dropFirst())

    guard let rootPath = value(for: "--root", in: rest) else { fail("corpus-init requires --root") }
    guard let refsArg = value(for: "--references", in: rest) else { fail("corpus-init requires --references") }
    let references = refsArg.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
    guard !references.isEmpty else { fail("--references must list at least one folder") }

    let root = URL(fileURLWithPath: rootPath, isDirectory: true)
    let options = CorpusBuilder.Options(
        sourceDir: value(for: "--source", in: rest) ?? "source",
        referenceDirs: references,
        perceptionDir: value(for: "--perception", in: rest),
        cameraJpegDir: value(for: "--camera", in: rest)
    )

    do {
        let outURL = value(for: "--out", in: rest).map { URL(fileURLWithPath: $0) }
        let manifest = try CorpusBuilder.write(root: root, options: options, to: outURL)
        let labelled = manifest.entries.filter { $0.perception != nil }.count
        print("Wrote manifest with \(manifest.entries.count) entries "
            + "(\(references.count) experts each, \(labelled) with perception labels) to "
            + (outURL?.path ?? root.appendingPathComponent("manifest.json").path))
    } catch {
        fail("\(error)")
    }

case "corpus-degrade":
    let rest = Array(arguments.dropFirst())

    guard let inDir = value(for: "--in-dir", in: rest) else { fail("corpus-degrade requires --in-dir") }
    guard let outDir = value(for: "--out-dir", in: rest) else { fail("corpus-degrade requires --out-dir") }

    do {
        let photos = try BatchApply.imageFiles(in: URL(fileURLWithPath: inDir, isDirectory: true))
        guard !photos.isEmpty else { fail("no images in \(inDir)") }
        let manifest = try DegradationCorpus.build(
            goodPhotos: photos,
            outputDir: URL(fileURLWithPath: outDir, isDirectory: true)
        )
        let photoCount = Set(manifest.entries.map { $0.id.components(separatedBy: "__").first ?? $0.id }).count
        print("Built degradation corpus: \(photoCount) photo(s) × \(DegradationCorpus.standard.count) "
            + "degradations = \(manifest.entries.count) entries in \(outDir)")
        print("Next: kelvin-perceive label --in-dir \(outDir)/source --out-dir \(outDir)/perception")
        print("Then: \(tool) eval --corpus \(outDir)")
    } catch {
        fail("\(error)")
    }

case "mask":
    // Debug/inspection: segment the subject and preview a local lift through the mask.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("mask requires --in") }
    guard let outDirPath = value(for: "--out-dir", in: rest) else { fail("mask requires --out-dir") }
    let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        guard let mask = SubjectMask.person(in: image) else { fail("no person found in \(inPath)") }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try ImageWriter.write(mask, to: outDir.appendingPathComponent("mask.png"), format: .png)
        if let luma = SubjectMask.maskedMeanLuma(image: image, mask: mask) {
            print(String(format: "subject mean luma: %.3f", luma))
        }
        let subjectMask = Mask(id: "subject", type: "subject", source: "segmentation",
                               invert: false, feather: 15, opacity: 1.0,
                               adjustments: ["exposure_ev": 0.7, "shadows": 25])
        var recipe = Recipe.neutral
        recipe.masks = [subjectMask]
        let lifted = Renderer.render(image, with: recipe, maskBitmaps: ["subject": mask])
        try ImageWriter.write(lifted, to: outDir.appendingPathComponent("lifted.png"), format: .png)
        print("Wrote mask.png + lifted.png to \(outDir.path)")
    } catch {
        fail("\(error)")
    }

case "eval":
    let rest = Array(arguments.dropFirst())

    guard let corpusPath = value(for: "--corpus", in: rest) else { fail("eval requires --corpus") }
    let corpusURL = URL(fileURLWithPath: corpusPath)
    let engineVersion = value(for: "--engine-version", in: rest) ?? "0.1.0"

    do {
        let corpus = try Corpus.load(root: corpusURL)
        let report = try Evaluator.run(corpus: corpus, engineVersion: engineVersion)

        print(report.renderTable())

        if let outPath = value(for: "--out", in: rest) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            try data.write(to: URL(fileURLWithPath: outPath))
            print("Wrote \(outPath)")
        }

        // Surface the no-op invariant as a non-zero exit so CI can gate on it.
        if !report.noOpFidelityOK {
            fail("no-op fidelity failed: a neutral recipe altered pixels")
        }
    } catch {
        fail("\(error)")
    }

default:
    fail("unknown subcommand '\(subcommand)'. Try `\(tool) --help`.")
}
