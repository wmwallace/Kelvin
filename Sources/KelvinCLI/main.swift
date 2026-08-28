import Foundation
import CoreImage
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
                    [--on-collision unique|skip|overwrite]
      \(tool) corpus-init --root <dir> --references <a,b,c> [--source <dir>] [--perception <dir>]
      \(tool) corpus-degrade --in-dir <good-photos> --out-dir <corpus>
      \(tool) eval --corpus <dir> [--out <report.json>] [--engine-version <v>]
      \(tool) triage-compare --in-dir <dir> [--limit <n>]
      \(tool) sky-metrics --in-dir <dir> [--limit <n>] [--perception <p.json>] [--dump-dir <dir>]
      \(tool) corpus-pairs --root <shoots> --out-dir <dir> [--long-edge <n>]
      \(tool) faces --in-dir <dir>
      \(tool) mask-coverage --in-dir <dir> [--out-dir <dir>]
      \(tool) endpoint-probe --in-dir <dir> [--reference-dir <dir>] [--perception-dir <dir>]
      \(tool) exposure-probe --in-dir <dir> --reference-dir <dir> [--perception-dir <dir>]
                     [--recipe-dir <dir>]
      \(tool) bg-probe --in-dir <dir> --reference-dir <dir> [--perception-dir <dir>]
      \(tool) bench-focus --in-dir <dir> [--mode old|new]
      \(tool) wb-probe --in-dir <dir> [--reference-dir <dir>] [--cost]
      \(tool) instances --in <image>
      \(tool) grow --in <image> --at <x,y> [--tolerance <t>] [--softness <s>] [--out-dir <dir>]
      \(tool) pick-probe --report <report.json> --corpus <dir> [--pair a,b] [--min-margin <dE>]
      \(tool) opener-probe --report <report.json> --corpus <dir> [--style <id>]
                     [--regions <r,r,…>] [--masses <m,m,…>]

    wb-probe options (docs/EVALUATION.md, "Which illuminant estimate is right"):
      --in / --in-dir  One photograph, or a folder of them. Required.
      --reference-dir  The corpus's untouched originals. Adds the TRUE cast — the mean-chroma
                       difference between a degraded frame and the original it came from — and
                       `recovery`, the share of it each estimator would remove. 1.00 is exact;
                       negative means the correction points the wrong way.
      --cost           Render each estimator's correction and report how far it moved the frame.
                       Point this at FINISHED photographs, where the right answer is zero.

      Both halves are needed to choose an estimator and neither is a corpus ΔE: the corpus is all
      degraded frames, so correcting is always right there and it cannot see the cost of firing on
      work that was already finished. `edge` wins the corpus and is the wrong pick for exactly
      that reason.

    grow options (the magic wand — RegionGrow, on a real photograph):
      --in         One photograph. Required.
      --at         Seed point, normalised 0…1, TOP-LEFT origin. Required. e.g. --at 0.18,0.62
      --tolerance  One tolerance instead of the default sweep.
      --softness   Fraction of the tolerance the edge fades over (default 0.25).
      --out-dir    Write grow-mask.png and grow-preview.png (the region pulled down 1.5 EV, so the
                   selection can be seen on the picture rather than inferred from a number).

      The sweep is the point: coverage per tolerance shows a flat run while the fill is still
      inside one object and a jump once it bursts out into the sky. Ship a number from the flat
      part. LOOK at the preview before believing the table — the same warning `sky-metrics
      --dump-dir` carries, and for the same reason.

    mask-coverage options:
      --in-dir   Directory of photographs to measure. Required.
      --out-dir  Write, per frame, the subject/sky/background masks painted onto the picture
                 (<stem>-subject.png etc.) and <stem>-bg-dim.png — the frame with its background
                 pulled down 0.5 EV through the derived mask, so a background treatment can be
                 SEEN rather than inferred from a coverage column.

    bg-probe options:
      --in-dir          The corpus's captures. Required.
      --reference-dir   The photographer's exports of the same frames. Required.
      --perception-dir  Per-frame perception JSON (<stem>.json). Adds the ENGINE's subject and
                        background ΔEV beside the photographer's: the default candidate — the one
                        every frame opens in — composed through the app's own path
                        (ShippedCandidates.compose) and measured under the same masks. Frames
                        without a label keep their photographer columns and are counted on a
                        "no label" line, so a partially labelled corpus is fine.

    bench-focus options:
      --in-dir  Folder of photographs to scan. Required.
      --mode    new (default): the app's cold-scan arrangement — PhotoTriage.read(url:), the
                embedded-preview fast path, several frames at once. old: sequential full decode,
                kept as the before picture.

      The figure is the app's COLD scan only. The warm path — MediaCache's verdict cache — is
      app-layer and cannot be measured from this CLI.

    triage-compare options:
      --in-dir   Directory of photographs to measure. Required.
      --limit    Stop after this many frames (default 25).

      Measures every frame twice — once from the camera's embedded preview, once from a full
      decode — and reports the acuity difference and the time saved. The fast path is what the
      folder scan uses; this says whether it moves the soft/unusable verdicts your thresholds
      were calibrated for. Run it on a RAW shoot before trusting either.

    sky-metrics options (docs/EVALUATION.md, "Measuring a sky"):
      --in / --in-dir  One photograph, or a folder of them. Required.
      --limit          Stop after this many frames (default 12).
      --perception     Hand-labelled perception JSON. Adds a per-style table and the pairwise
                       sky-versus-frame divergence, which is what a sky lever is calibrated on.
      --dump-dir       Write the proxy, the reference region and the sky mask as PNGs.

    render options:
      --in       Path to the source image (RAW, JPEG, or PNG). Required.
      --recipe   Path to a recipe JSON sidecar. Required.
      --out      Output path. Extension picks the format (.png or .jpg). Required.
      --look     Compose a look preset onto the recipe before rendering
                 (LookPreset.applied(to:)). A look id, or "all" to write the base render
                 plus one <out-stem>-<look-id> file per library look.

    engine options:
      --in          Path to the source image (RAW, JPEG, or PNG). Required.
      --perception  Path to a hand-labelled perception JSON (Stage 1). Required.
      --out         Where to write the generated recipe JSON. Required.

    candidates options:
      --in          Path to the source image (RAW, JPEG, or PNG). Required.
      --perception  Path to a hand-labelled perception JSON (Stage 1). Required.
      --out-dir     Directory to write one <style>.json per candidate. Required.

    batch options:
      --in-dir       Directory of source images to propagate the recipe across. Required.
      --recipe       Path to a recipe JSON sidecar. Required.
      --out-dir      Directory to write edited copies. Created if missing. Must not be --in-dir;
                     the originals are never written to. Required.
      --format       png (default) or jpg.
      --on-collision What to do when an output name already exists in --out-dir:
                     unique (default, writes name-2), skip (keep what's there),
                     overwrite (replace it — destroys the previous export).

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
      --long-edge   Cap the long edge of references and sources. Recommended: eval renders
                    every style on every entry, so a full-resolution corpus is not per-commit.

    eval options:
      --corpus          Directory containing a manifest.json. Required.
      --out             Where to write report.json. Optional; table always prints.
      --engine-version  Label recorded in the report. Default 0.1.0.

    ablate options (which lever is the error — rank a recipe's levers by the damage each does):
      --in          The frame the recipe was built for. Required.
      --reference   The finished photograph to measure distance to. Required.
      --recipe      Recipe JSON under test. Required.

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
        // Supply subject/sky bitmaps so any local masks the recipe references are applied; the
        // renderer ignores masks it has no bitmap for, so measuring unconditionally is safe.
        let measured = LocalMasks.measure(in: image)
        func render(_ r: Recipe, to url: URL) throws {
            let rendered = Renderer.render(image, with: r, maskBitmaps: measured.bitmaps)
            try ImageWriter.write(rendered, to: url)
            print("Wrote \(url.path)")
        }
        switch value(for: "--look", in: rest) {
        case nil:
            try render(recipe, to: outURL)
        case "all":
            // The audition set: the recipe as picked, then every library look composed on it —
            // one file per look, named <out-stem>-<look-id>.<ext>.
            try render(recipe, to: outURL)
            let stem = outURL.deletingPathExtension()
            let ext = outURL.pathExtension.isEmpty ? "png" : outURL.pathExtension
            for look in LookPreset.library {
                let url = URL(fileURLWithPath: stem.path + "-\(look.id)")
                    .appendingPathExtension(ext)
                try render(look.applied(to: recipe), to: url)
            }
        case let id?:
            guard let look = LookPreset.named(id) else {
                fail("unknown look '\(id)'. known: "
                     + LookPreset.library.map(\.id).joined(separator: ", ") + ", all")
            }
            try render(look.applied(to: recipe), to: outURL)
        }
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
        let measured = LocalMasks.measure(in: image)
        let recipe = RecipeEngine.recipe(
            perception: perception,
            statistics: stats,
            subjectLuma: measured.subjectLuma,
            skyLuma: measured.skyLuma,
            subjectOrigin: measured.subjectOrigin,
            iso: ExifReader.iso(url: URL(fileURLWithPath: inPath)),
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
        let perception = try PerceptionIO.load(from: URL(fileURLWithPath: perceptionPath))

        // One perception, one statistics pass → N recipes (parameter swaps, no re-perception),
        // scored and curated. Composed through `ShippedCandidates` so this command reports and
        // writes the app's decision rather than a second implementation of it — and so the recipes
        // on disk are measured on the same image the "curated" line below was decided from. They
        // were not: this generated from the full frame and then curated from the proxy, which is
        // precisely the two-measurement disagreement that once put a different recipe on the canvas
        // than in the exported file.
        let composed = try ShippedCandidates.compose(
            for: image,
            perception: perception,
            iso: ExifReader.iso(url: URL(fileURLWithPath: inPath)),
            perceptionHash: PerceptionIO.hash(perception),
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // Optional: --render also writes a preview PNG per candidate, rendered the way export
        // renders it — full-resolution pixels with masks measured at that resolution.
        let alsoRender = rest.contains("--render")
        let fullMasks = alsoRender ? LocalMasks.measure(in: image).bitmaps : [:]
        for candidate in composed.all {
            let base = candidate.recipe.id ?? candidate.recipe.label ?? "candidate"
            try RecipeIO.save(candidate.recipe, to: outDir.appendingPathComponent(base + ".json"))
            if alsoRender {
                let rendered = ShippedCandidates.deliver(candidate.recipe, on: image,
                                                         masks: fullMasks)
                try ImageWriter.write(rendered, to: outDir.appendingPathComponent(base + ".png"),
                                      format: .png)
            }
        }

        print("curated: " + composed.curated.map {
            String(format: "%@ %.2f", $0.recipe.label ?? "?", $0.score.overall)
        }.joined(separator: ", "))
        if !composed.droppedStyleIDs.isEmpty {
            print("dropped: " + composed.droppedStyleIDs.joined(separator: ", "))
        }
        print("opens in: " + (composed.chosen?.recipe.label ?? "nothing"))

        let labels = composed.all.map { $0.recipe.label ?? "?" }.joined(separator: ", ")
        let sky = composed.masks.skyLuma.map { String(format: "sky luma %.2f", $0) } ?? "no sky"
        print("Wrote \(composed.all.count) candidates to \(outDir.path) [\(labels)] (\(sky))")
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

    // Default: never clobber. `overwrite` has to be typed out, because a batch that silently
    // replaces a previous export is how a photographer loses a morning's work.
    let onCollision: BatchApply.Destination.OnCollision
    switch value(for: "--on-collision", in: rest)?.lowercased() {
    case "unique", "unique-suffix", nil: onCollision = .uniqueSuffix
    case "skip": onCollision = .skip
    case "overwrite": onCollision = .overwrite
    case let other?: fail("unknown --on-collision '\(other)' (use unique, skip or overwrite)")
    }

    do {
        let recipe = try RecipeIO.load(from: URL(fileURLWithPath: recipePath))
        let outcome = try BatchApply.run(
            inputDir: URL(fileURLWithPath: inDirPath, isDirectory: true),
            recipe: recipe,
            destination: BatchApply.Destination(
                directory: URL(fileURLWithPath: outDirPath, isDirectory: true),
                onCollision: onCollision,
                format: format
            )
        )
        print("Applied recipe to \(outcome.succeeded) image(s), "
            + "\(outcome.skippedCount) skipped, \(outcome.failed) failed.")
        // Per-file, not just counts: a run that half-worked has to say which half.
        for item in outcome.items {
            switch item.result {
            case .written: break
            case .skipped(let existing):
                print("  skipped \(item.source.lastPathComponent): "
                    + "\(existing.lastPathComponent) already exists")
            case .failed(let message):
                FileHandle.standardError.write(
                    Data("  failed \(item.source.lastPathComponent): \(message)\n".utf8))
            }
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
        let longEdge = value(for: "--long-edge", in: rest).flatMap(Int.init)
        let manifest = try DegradationCorpus.build(
            goodPhotos: photos,
            outputDir: URL(fileURLWithPath: outDir, isDirectory: true),
            longEdge: longEdge
        )
        if longEdge == nil {
            print("NOTE: built at full resolution. `eval` renders every style on every entry, so a "
                + "corpus of\n      large frames will not run per commit — pass --long-edge 1600 "
                + "unless you need\n      full-resolution pixels.")
        }
        let photoCount = Set(manifest.entries.map { $0.id.components(separatedBy: "__").first ?? $0.id }).count
        print("Built degradation corpus: \(photoCount) photo(s) × \(DegradationCorpus.standard.count) "
            + "degradations = \(manifest.entries.count) entries in \(outDir)")
        print("Next: kelvin-perceive label --in-dir \(outDir)/source --out-dir \(outDir)/perception")
        print("Then: \(tool) eval --corpus \(outDir)")
    } catch {
        fail("\(error)")
    }

case "corpus-pairs":
    // A corpus whose reference is what the photographer ACTUALLY WANTED, not the untouched
    // original. See `PairedCorpus` for why this had to exist and what it still cannot settle.
    do {
        let rest = Array(arguments.dropFirst())
        guard let root = value(for: "--root", in: rest) else {
            fail("corpus-pairs requires --root (a folder of shoots)")
        }
        guard let outDir = value(for: "--out-dir", in: rest) else {
            fail("corpus-pairs requires --out-dir")
        }
        let longEdge = value(for: "--long-edge", in: rest).flatMap(Int.init)
        let pairs = PairedCorpus.discover(root: URL(fileURLWithPath: root, isDirectory: true))
        guard !pairs.isEmpty else {
            fail("no pairs under \(root) — expected an `edited/` folder beside the captures, "
                 + "holding exports whose filenames match them")
        }
        print("Found \(pairs.count) candidate pair(s).")

        var skipped = 0
        let manifest = try PairedCorpus.build(
            pairs: pairs,
            outputDir: URL(fileURLWithPath: outDir, isDirectory: true),
            longEdge: longEdge,
            onSkip: { url, why in
                skipped += 1
                print("  skipped \(url.lastPathComponent): \(why)")
            }
        )
        if longEdge == nil {
            print("NOTE: built at full resolution — pass --long-edge 1600 unless you need "
                + "full-resolution pixels.")
        }
        print("Built paired corpus: \(manifest.entries.count) entries "
            + "(\(skipped) skipped) in \(outDir)")
        print("Next: cd Integrations/KelvinPerceptionMLX && swift run kelvin-perceive label "
            + "--in-dir \(outDir)/source --out-dir \(outDir)/perception")
        print("Then: \(tool) eval --corpus \(outDir)")
        print("⚠️  Read it ALONGSIDE the degradation corpus, never instead of it: this one "
            + "penalises under-editing exactly where that one rewards it.")
    } catch {
        fail("\(error)")
    }

case "cast":
    // Debug/inspection: the colour-cast measurement behind the "strong colour cast" warning,
    // split into its direction so a warm scene can be told from a white-balance error.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inPath = value(for: "--in", in: rest) else { fail("cast requires --in") }
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let s = try ImageStatistics.compute(image)
        let mag = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
        print(String(format: "  a*=%+6.2f (green-/red+)  b*=%+6.2f (blue-/yellow+)  magnitude=%5.2f%@",
                     s.chromaA, s.chromaB, mag, mag > 22 ? "  FLAGGED" : ""))
    } catch { fail("\(error)") }

case "similar-map":
    // What the strip's `Similar` grouping and the `Best` filter are both built on: which frames
    // `PhotoTriage` thinks are near-duplicates of each other. Reported as group sizes, because
    // "Best does not filter anything" and "this shoot has no near-duplicates in it" look identical
    // from the outside and are completely different problems.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inDir = value(for: "--in-dir", in: rest) else { fail("similar-map requires --in-dir") }
        let limit = value(for: "--limit", in: rest).flatMap(Int.init) ?? 40
        var images = try BatchApply.imageFiles(in: URL(fileURLWithPath: inDir, isDirectory: true))
        guard !images.isEmpty else { fail("no images in \(inDir)") }
        images = Array(images.prefix(limit))

        var frames: [PhotoTriage.Frame] = []
        var unreadable = 0, unmeasurable = 0
        for url in images {
            guard let verdict = PhotoTriage.read(url: url) else { unreadable += 1; continue }
            if !verdict.signature.isMeasurable { unmeasurable += 1 }
            frames.append(PhotoTriage.Frame(url: url, signature: verdict.signature,
                                            captured: CaptureInfoReader.read(url: url).captured))
        }
        let groups = PhotoTriage.groups(frames)
        let multi = groups.filter { $0.count > 1 }
        print("\(images.count) frame(s): \(frames.count) read, \(unreadable) unreadable, "
              + "\(unmeasurable) with no signal in the fingerprint")
        print("near-duplicate distance \(PhotoTriage.nearDuplicateDistance), "
              + "burst distance \(PhotoTriage.burstDistance)")
        print("\(groups.count) group(s), \(multi.count) with more than one frame")
        for g in groups where g.count > 1 {
            print("  \(g.count): " + g.map { $0.lastPathComponent }.joined(separator: " "))
        }
        if multi.isEmpty {
            print("→ every frame is its own group, so `Best` can only return all of them.")
        }
    } catch { fail("\(error)") }

case "instances":
    // Debug/inspection: what SubjectInstances finds, and what it decided to call each one.
    // The naming is Vision's classifier over a crop, gated on precision and confidence, so when a
    // row reads "Subject" it means the gate rejected everything — this prints what it rejected.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inPath = value(for: "--in", in: rest) else { fail("instances requires --in") }
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let found = SubjectInstances.detect(in: image)
        print("instances: \(found.count)")
        for i in found {
            let sure = i.nameConfidence.map { String(format: "guess %.2f", $0) } ?? "certain"
            print(String(format: "  %@  label=%@ (%@)  kind=%@  coverage=%.3f",
                         i.id, i.label, sure, String(describing: i.kind), i.coverage))
        }
    } catch { fail("\(error)") }

case "grow":
    // The magic wand, on a real photograph, before any of it reaches the UI.
    //
    // `SubjectInstances` returns the MOST salient thing and stops: on `_DSC6390` it hands back
    // Haystack Rock with its silhouette intact and neither of the two smaller sea stacks beside it.
    // Those stacks are the case `RegionGrow` exists for, and the only question that matters about it
    // is what tolerance picks one out — a number nobody can guess from the code and which is
    // different for a rock against sky than for a mountain shading into a hillside.
    //
    // So the default is a SWEEP rather than a single answer. Coverage per tolerance is the reading:
    // a stack against sky shows a long flat run (the object, insensitive to the exact number) and
    // then a jump to most of the frame (the fill has burst into the sky). The tolerance to ship is
    // in the flat part, and where the jump lands is the whole risk of this approach.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inPath = value(for: "--in", in: rest) else { fail("grow requires --in") }
        guard let at = value(for: "--at", in: rest) else {
            fail("grow requires --at <x,y> — normalised 0…1, TOP-LEFT origin, e.g. --at 0.18,0.62")
        }
        let parts = at.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { fail("--at must be two numbers, e.g. --at 0.18,0.62") }
        let seed = CGPoint(x: parts[0], y: parts[1])
        let softness = value(for: "--softness", in: rest).flatMap(Double.init) ?? 0.25
        let single = value(for: "--tolerance", in: rest).flatMap(Double.init)

        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        print(String(format: "%@  %.0f×%.0f  seed %.3f,%.3f (top-left origin)",
                     URL(fileURLWithPath: inPath).lastPathComponent as NSString,
                     image.extent.width, image.extent.height, seed.x, seed.y))

        /// What fraction of the frame a mask actually selects. Sampled small — the same sanity
        /// check `SubjectMask` makes, reimplemented here because that one is not public.
        func coverage(of mask: CIImage) -> Double {
            guard let data = try? ImageWriter.rgba8Sampled(mask, width: 128, height: 128) else { return 0 }
            var sum = 0.0, n = 0.0
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: data.count, by: 4) { sum += Double(p[i]) / 255; n += 1 }
            }
            return n > 0 ? sum / n : 0
        }

        let outDir = value(for: "--out-dir", in: rest).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outDir { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }

        let tolerances = single.map { [$0] } ?? [0.04, 0.06, 0.08, 0.10, 0.12, 0.15, 0.20, 0.25, 0.30, 0.40]
        print("tolerance  coverage  verdict")
        for t in tolerances {
            guard let mask = RegionGrow.mask(in: image, seed: seed, tolerance: t, softness: softness) else {
                print(String(format: "  %.2f       —       below minimum coverage (%.4f) — a miss",
                             t, RegionGrow.minimumCoverage))
                continue
            }
            let c = coverage(of: mask)
            // Past about half the frame the fill has plainly escaped whatever was clicked. Said in
            // words because a coverage column alone reads as a measurement rather than a warning.
            let verdict = c > 0.5 ? "ESCAPED — this is most of the picture"
                        : c > 0.25 ? "large — check it is still one object"
                        : "plausible"
            print(String(format: "  %.2f     %6.3f    %@", t, c, verdict as NSString))

            guard let outDir else { continue }
            // ONE PAIR PER TOLERANCE, deliberately — an earlier version picked a single tolerance to
            // write and there is no non-arbitrary way to choose one. The coverage column cannot tell
            // a region that grew into the next object from one that grew to fit the object it is in:
            // on `_DSC6390`'s left sea stack the fill escapes along the surf line into Haystack Rock
            // at EVERY tolerance that looks flat and plausible in the table. Only the picture says so.
            let tag = String(format: "%.2f", t)
            try ImageWriter.write(mask, to: outDir.appendingPathComponent("grow-\(tag)-mask.png"),
                                  format: .png)
            var recipe = Recipe.neutral
            recipe.masks = [Mask(id: "grow", type: "subject", source: "region-grow",
                                 invert: false, feather: 8, opacity: 1.0,
                                 adjustments: ["exposure_ev": -1.5])]
            let preview = Renderer.render(image, with: recipe, maskBitmaps: ["grow": mask])
            try ImageWriter.write(preview, to: outDir.appendingPathComponent("grow-\(tag)-preview.png"),
                                  format: .png)
        }
        if let outDir { print("wrote a mask and a preview per tolerance to \(outDir.path)") }
    } catch { fail("\(error)") }

case "mask":
    // Debug/inspection: segment the subject and preview a local lift through the mask.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("mask requires --in") }
    guard let outDirPath = value(for: "--out-dir", in: rest) else { fail("mask requires --out-dir") }
    let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let personMask = SubjectMask.person(in: image)
        guard let mask = personMask ?? SubjectMask.foreground(in: image) else {
            fail("no subject found in \(inPath)")
        }
        print(personMask != nil ? "source: person segmentation" : "source: foreground instance (no person)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try ImageWriter.write(mask, to: outDir.appendingPathComponent("mask.png"), format: .png)
        if let luma = SubjectMask.maskedMeanLuma(image: image, mask: mask) {
            print(String(format: "subject mean luma: %.3f", luma))
        }
        let skin = FaceSkin.read(in: image)
        if let luma = skin.skinLuma {
            print(String(format: "faces: %d, skin luma: %.3f, hue: %.0f°, saturation: %.2f",
                         skin.faceCount, luma, skin.skinHueDegrees ?? -1, skin.skinSaturation ?? -1))
        } else { print("faces: \(skin.faceCount) (no skin metered)") }
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

case "triage-compare":
    // MEASURE, DO NOT GUESS. The folder scan reads a RAW file's embedded preview rather than
    // paying ~1170 ms for a full decode, which is the difference between six minutes and thirty
    // seconds on a real shoot. The catch is that a camera preview carries in-camera sharpening and
    // JPEG artefacts, both of which push acuity UP relative to the proxy the soft/unusable
    // thresholds were calibrated against. This prints that difference on real frames instead of
    // leaving it to be discovered by a photographer wondering why nothing is flagged any more.
    let rest = Array(arguments.dropFirst())
    guard let dir = value(for: "--in-dir", in: rest) else {
        FileHandle.standardError.write(Data("triage-compare: --in-dir is required\n".utf8))
        exit(2)
    }
    let limit = value(for: "--limit", in: rest).flatMap(Int.init) ?? 25
    let files = Array((try? BatchApply.imageFiles(in: URL(fileURLWithPath: dir))) ?? []).prefix(limit)
    guard !files.isEmpty else {
        FileHandle.standardError.write(Data("triage-compare: no readable images in \(dir)\n".utf8))
        exit(1)
    }

    print("frame                          fast    full    delta   fast(ms)  full(ms)")
    var deltas: [Double] = []
    var verdictChanges = 0
    var fastTotal = 0.0, fullTotal = 0.0
    for file in files {
        let t0 = Date()
        let fast = PhotoTriage.read(url: file, fastRAW: true)
        let fastMs = Date().timeIntervalSince(t0) * 1000
        let t1 = Date()
        let full = PhotoTriage.read(url: file, fastRAW: false)
        let fullMs = Date().timeIntervalSince(t1) * 1000
        guard let fast, let full else { continue }
        let delta = fast.focus.acuity - full.focus.acuity
        deltas.append(delta)
        fastTotal += fastMs; fullTotal += fullMs
        // The number that actually matters: not whether the reading moved, but whether the VERDICT
        // moved. A shifted acuity nobody acts on is arithmetic; a flipped soft flag is a behaviour
        // change for the person using it.
        let flipped = fast.focus.isSoft != full.focus.isSoft
        if flipped { verdictChanges += 1 }
        let name = file.lastPathComponent
        let padded = name.count < 28 ? name + String(repeating: " ", count: 28 - name.count) : name
        print(String(format: "%@ %6.2f  %6.2f  %+6.2f  %8.0f  %8.0f%@",
                     padded,
                     fast.focus.acuity, full.focus.acuity, delta, fastMs, fullMs,
                     flipped ? "   ← SOFT FLAG FLIPPED" : ""))
    }
    if !deltas.isEmpty {
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let worst = deltas.map(abs).max() ?? 0
        print("")
        print(String(format: "%d frames · mean acuity delta %+.3f · largest %.3f · soft-flag changes %d",
                     deltas.count, mean, worst, verdictChanges))
        print(String(format: "time: fast %.1fs, full %.1fs — %.1fx faster",
                     fastTotal / 1000, fullTotal / 1000, fullTotal / max(fastTotal, 0.001)))
        if verdictChanges > 0 {
            print("Soft verdicts moved. Recalibrate FocusMeasure's thresholds for the fast path, or")
            print("set fastRAW: false in the scan, before trusting the speed-up.")
        }
    }

case "bench":
    // Where does interactive render time actually go? Measures the proxy render + read-back for
    // each stage, so optimisation targets are chosen from data rather than guesswork.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("bench requires --in") }
    do {
        let full = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let proxy = PerceptionProxy.downsample(full, maxEdge: 1200)
        let ctx = CIContext(options: [.cacheIntermediates: true])
        _ = ctx.createCGImage(proxy, from: proxy.extent)     // warm up

        func bench(_ label: String, _ recipe: Recipe, _ n: Int = 11) {
            var times: [Double] = []
            for _ in 0..<n {
                let start = Date()
                let out = Renderer.render(proxy, with: recipe, maskBitmaps: [:])
                _ = ctx.createCGImage(out, from: out.extent)
                times.append(Date().timeIntervalSince(start) * 1000)
            }
            times.sort()
            print(String(format: "  %-32@ median %6.1f ms", label as NSString, times[n / 2]))
        }

        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.3; g.contrast = 12; g.vibrance = 8; g.shadows = 15; g.highlights = -20
        func recipe(_ mutate: (inout Recipe) -> Void = { _ in }) -> Recipe {
            var r = Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil, global: g,
                           curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
            mutate(&r); return r
        }
        print("Interactive render benchmark — proxy \(Int(proxy.extent.width))×\(Int(proxy.extent.height))")
        bench("globals only", recipe())
        bench("+ HSL cube (colour mixer)", recipe { $0.hsl = ["blue": HSLAdjustment(h: 5, s: 20, l: -10)] })
        bench("+ colour-selection mask", recipe {
            $0.masks = [Mask(id: "c", type: "color", source: "selection", invert: false, feather: 0,
                             opacity: 1, adjustments: ["exposure_ev": -1],
                             selection: MaskSelection(kind: .color, center: 0.33, range: 0.1, softness: 0.08))]
        })
        bench("+ straighten 4°", recipe { $0.geometry = Geometry(rotateDeg: 4, crop: nil, lensCorrection: false) })
        bench("+ clarity (halo-suppressed)", recipe { $0.global.clarity = 40 })
        for count in [25, 250, 1200] {
            let stamps = (0..<count).map { i in
                BrushStamp(x: 0.2 + Double(i) * 0.002, y: 0.5, radius: 0.06, hardness: 0.6)
            }
            let brush = recipe {
                $0.masks = [Mask(id: "b", type: "brush", source: "brush", invert: false, feather: 0,
                                 opacity: 1, adjustments: ["exposure_ev": -0.8], stamps: stamps)]
            }
            bench("+ brush \(count) stamps (composited)", brush, 5)
            // The app bakes the stroke once and reuses it; this is what a frame then costs.
            if let composited = Renderer.brushMask(stamps, extent: proxy.extent),
               let cg = ctx.createCGImage(composited, from: proxy.extent) {
                let flat = CIImage(cgImage: cg)
                var times: [Double] = []
                for _ in 0..<5 {
                    let start = Date()
                    let out = Renderer.render(proxy, with: brush, maskBitmaps: ["b": flat])
                    _ = ctx.createCGImage(out, from: out.extent)
                    times.append(Date().timeIntervalSince(start) * 1000)
                }
                times.sort()
                print(String(format: "  %-32@ median %6.1f ms",
                             "+ brush \(count) stamps (baked)" as NSString, times[2]))
            }
        }
    } catch { fail("\(error)") }

case "bench-ui":
    // What ELSE does an interactive frame cost, on the thread that draws the window?
    //
    // `bench` measures the render, which the app already runs off the main actor. But a frame is not
    // only its render: the histogram redraws from the new pixels inside a SwiftUI `Canvas` closure,
    // and the craft self-check re-measures them 200 ms after the last edit. Both of those read the
    // rendered proxy, and both run where SwiftUI runs. Whatever they cost is time the panel is not
    // scrolling and the slider is not tracking, and none of it appears in `bench`.
    //
    // Same discipline as the other two: the release notes admit "the edit panel can stutter while a
    // render or scene read is in flight", and the fix has to be aimed at a number rather than at the
    // most suspicious-looking code.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inPath = value(for: "--in", in: rest) else { fail("bench-ui requires --in") }
        let full = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let proxy = PerceptionProxy.downsample(full, maxEdge: 1200)
        let ctx = CIContext(options: [.cacheIntermediates: true])
        // What the app actually holds after a render: a concrete bitmap, not a filter chain.
        var g = GlobalAdjustments.neutral
        g.exposureEV = 0.3; g.contrast = 12; g.vibrance = 8; g.shadows = 15; g.highlights = -20
        let recipe = Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil, global: g,
                            curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
        let rendered = Renderer.render(proxy, with: recipe, maskBitmaps: [:])
        guard let cg = ctx.createCGImage(rendered, from: rendered.extent) else { fail("render failed") }
        let frame = CIImage(cgImage: cg)

        func bench(_ label: String, _ n: Int = 11, _ body: () -> Void) {
            body()                                   // warm up; first call pays for lazy setup
            var times: [Double] = []
            for _ in 0..<n {
                let start = Date()
                body()
                times.append(Date().timeIntervalSince(start) * 1000)
            }
            times.sort()
            print(String(format: "  %-38@ median %7.1f ms", label as NSString, times[n / 2]))
        }

        print("Main-thread work per frame — proxy \(Int(proxy.extent.width))×\(Int(proxy.extent.height))")
        // The histogram, as HistogramView.luma does it: downsample first, then rasterise 100×100.
        bench("histogram (Canvas draw closure)") {
            let small = PerceptionProxy.downsample(frame, maxEdge: 100)
            _ = try? ImageWriter.rgba8Sampled(small, width: 100, height: 100)
        }
        // The craft check, split into its two halves, because they are not remotely the same size.
        bench("craft: ImageStatistics.compute") { _ = try? ImageStatistics.compute(frame) }
        bench("craft: FaceSkin.read (Vision)", 5) { _ = FaceSkin.read(in: frame) }
        if let stats = try? ImageStatistics.compute(frame) {
            bench("craft: issues from the reading") {
                _ = CraftFix.Reading(stats: stats, face: FaceSkin.read(in: frame), condition: nil).issues
            }
        }
        print("  A frame at 60 Hz is 16.7 ms. Anything above that here is a dropped frame, on the")
        print("  thread that scrolls the panel.")

        // AND AGAIN WITH THE GPU BUSY, which is the case the release notes actually describe. Every
        // measurement above goes through a CIContext, and a CIContext hands work to the GPU: it is
        // thread-safe, not free of contention. When something else is already saturating the device
        // — a full-resolution export, or the perception model generating tokens — the same call on
        // the main thread waits for the device rather than for its own arithmetic.
        //
        // The load here is a Core Image render rather than MLX, because this executable is
        // deliberately MLX-free. It is the same mechanism and a smaller hammer: whatever ratio shows
        // up here is a floor for what a 2 B-parameter model does to the same numbers.
        let busy = DispatchQueue(label: "gpu-load", qos: .userInitiated)
        // A semaphore as a stop flag: signalled once, and the loop's non-blocking wait succeeds
        // exactly once. Avoids hand-rolling a lock around a Bool for a benchmark.
        let stop = DispatchSemaphore(value: 0)
        busy.async {
            var heavy = GlobalAdjustments.neutral
            heavy.clarity = 60; heavy.texture = 40; heavy.dehaze = 30
            let r = Recipe(schemaVersion: 1, id: nil, label: nil, provenance: nil, global: heavy,
                           curve: nil, hsl: nil, masks: nil, detail: nil, geometry: nil)
            while stop.wait(timeout: .now()) == .timedOut {
                let out = Renderer.render(full, with: r, maskBitmaps: [:])
                _ = ctx.createCGImage(out, from: out.extent)
            }
        }
        print("\nThe same work, with a full-resolution render looping on another thread:")
        bench("histogram (Canvas draw closure)") {
            let small = PerceptionProxy.downsample(frame, maxEdge: 100)
            _ = try? ImageWriter.rgba8Sampled(small, width: 100, height: 100)
        }
        bench("craft: ImageStatistics.compute") { _ = try? ImageStatistics.compute(frame) }
        bench("craft: FaceSkin.read (Vision)", 5) { _ = FaceSkin.read(in: frame) }
        stop.signal()
    } catch { fail("\(error)") }

case "bench-load":
    // Where does the time between "I picked a photo" and "here are your candidates" actually go?
    //
    // `bench` above measures an interactive frame, which is the cost of DRAGGING a slider. This
    // measures the cost of OPENING a photo, which is the wait a user actually complains about, and
    // it is a different pipeline: decode, proxy, statistics, four independent Vision/Core Image
    // passes, then eight candidate renders each scored.
    //
    // Written because a performance proposal arrived with per-subsystem speedup figures and no
    // measurements. Every real performance problem this app has had was work happening in the wrong
    // PLACE (full RAW decodes during view layout; decode on the MainActor), not work being too
    // slow — so the useful question is which stages dominate and which are independent of each
    // other, not which could be rewritten in Metal.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inPath = value(for: "--in", in: rest) else { fail("bench-load requires --in") }
        let url = URL(fileURLWithPath: inPath)

        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let out = try body()
            print(String(format: "  %-30@ %7.1f ms", label as NSString,
                         Date().timeIntervalSince(start) * 1000))
            return out
        }

        print("Load-path profile — \(url.lastPathComponent)")
        let full = try time("decode") { try ImageDecoder.decode(url: url) }
        print(String(format: "    (%.0f×%.0f)", full.extent.width, full.extent.height))

        // `ImageDecoder.decode` returns a LAZY CIImage — it reads the header and builds a recipe
        // for producing pixels, it does not produce them. So the "decode" figure above is setup,
        // and whichever stage first asks for pixels pays for the real decode. Forcing it here
        // separates "the file is slow to decode" from "downsampling is slow", which are different
        // problems with different fixes.
        let ctx = CIContext(options: [.cacheIntermediates: true])
        _ = time("first pixels (real decode)") {
            ctx.createCGImage(full, from: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let proxy = time("proxy 1200px (materialised)") { () -> CIImage in
            let lazy = PerceptionProxy.downsample(full, maxEdge: 1200)
            guard let cg = ctx.createCGImage(lazy, from: lazy.extent) else { return lazy }
            return CIImage(cgImage: cg)
        }
        _ = time("proxy 768px (perception)") { () -> CIImage in
            let lazy = PerceptionProxy.downsample(full, maxEdge: 768)
            guard let cg = ctx.createCGImage(lazy, from: lazy.extent) else { return lazy }
            return CIImage(cgImage: cg)
        }

        // The alternative: ask ImageIO to decode STRAIGHT to the size we want. A JPEG can be
        // scaled during entropy decoding, so this never materialises the full frame at all —
        // where `downsample` renders every full-resolution pixel and then throws almost all of
        // them away. The filmstrip already loads thumbnails this way.
        _ = time("proxy via ImageIO subsampled") { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200,
                kCGImageSourceCreateThumbnailWithTransform: true
            ] as CFDictionary)
        }

        if rest.contains("--sweep-width") {
            for w in [7000.0, 8000.0, 8192.0, 8193.0, 8500.0, 9000.0, full.extent.width]
            where w <= full.extent.width {
                let crop = full.cropped(to: CGRect(x: 0, y: 0, width: w, height: full.extent.height))
                _ = time("  width \(Int(w)) -> 1200px") { () -> CGImage? in
                    let p = PerceptionProxy.downsample(crop, maxEdge: 1200)
                    return ctx.createCGImage(p, from: p.extent)
                }
            }
        }

        // The focus thresholds were calibrated against the Lanczos-downsampled 1200 px proxy, and a
        // focus measure reads exactly the high-frequency content a different resampling filter
        // would change. So before letting the fast proxy anywhere near the focus scan, check the
        // two agree about the photograph.
        if let fast = PerceptionProxy.fromFile(url, maxEdge: 1200) {
            let a = FocusMeasure.read(proxy), b = FocusMeasure.read(fast)
            print(String(format: "  focus: lanczos acuity %.3f (soft %@)  imageio %.3f (soft %@)",
                         a.acuity, a.isSoft ? "yes" : "no", b.acuity, b.isSoft ? "yes" : "no"))
        }

        let stats = try time("statistics") { try ImageStatistics.compute(proxy) }

        // What the white-balance estimator sees, and what it does about it. Whole-frame mean chroma
        // is a grey-world assumption: it reads a photograph full of warm content — skin, wood,
        // autumn leaves — as an illuminant error, and the stronger the correction the more that
        // matters.
        if rest.contains("--wb") {
            let mag = (stats.chromaA * stats.chromaA + stats.chromaB * stats.chromaB).squareRoot()
            print(String(format: "  cast: a %+.1f  b %+.1f  magnitude %.1f",
                         stats.chromaA, stats.chromaB, mag))
            let neutralising = RecipeEngine.neutralisingWhiteBalance(for: stats)
            print(String(format: "  neutralising: %.0f K  tint %+.0f",
                         neutralising.temperatureK, neutralising.tint))
            let before = FaceSkin.read(in: proxy)
            for strength in [0.0, 0.4, 0.7, 1.0] {
                var g = GlobalAdjustments.neutral
                g.temperatureK = RecipeEngine.temperature(correctingChromaB: stats.chromaB,
                                                          strength: strength)
                g.tint = stats.chromaA * 1.8 * strength
                var r = Recipe.neutral; r.global = g
                let out = Renderer.render(proxy, with: r)
                let s = try ImageStatistics.compute(out)
                let skin = FaceSkin.read(in: out)
                let residual = (s.chromaA * s.chromaA + s.chromaB * s.chromaB).squareRoot()
                print(String(format: "    strength %.1f -> %.0f K  residual cast %5.1f  skin hue %5.1f°%@",
                             strength, g.temperatureK ?? 6500, residual,
                             skin.skinHueDegrees ?? -1,
                             (skin.skinHueDegrees.map { $0 < 6 || $0 > 32 } ?? false) ? "  OFF-NATURAL" : ""))
            }
            _ = before
        }
        // None of these four reads another's output, which is the whole point of measuring them
        // one at a time and then together.
        //
        // MEASURED IN SEPARATE PROCESSES (`--only seq` / `--only par`), because running both in
        // one run flatters whichever goes second: Vision loads its models on first use and Core
        // Image caches the proxy, so the second block is timed against a machine the first block
        // warmed up. Measured that way the concurrent block came out at 141 ms against a 1163 ms
        // sequential sum, an "8× win" that was mostly just being second.
        let only = value(for: "--only", in: rest)
        if only != "par" {
            _ = time("  masks (subject + sky)") { LocalMasks.measure(in: proxy) }
            _ = time("  subject instances") { SubjectInstances.detect(in: proxy) }
            _ = time("  focus measure") { FocusMeasure.read(proxy) }
            _ = time("  face skin") { FaceSkin.read(in: proxy) }
        }
        if only != "seq" {
        // The arrangement the app actually uses — NOT all four at once. All four crashes:
        // EXC_BAD_ACCESS in `objc_release` inside Vision's
        // `VNGenerateSemanticSegmentationCompoundRequest detectorTypeForSemanticSegmentationRequest`
        // when two person-segmentation requests resolve their detector concurrently. Reproduced
        // here at 2 crashes in 6 runs. `--only par-unsafe` still does it, because a race you can
        // reproduce on demand is worth being able to reproduce again.
        let unsafeAll = only == "par-unsafe"
        let visionSerial = { _ = LocalMasks.measure(in: proxy); _ = SubjectInstances.detect(in: proxy) }
        let jobs: [() -> Void] = unsafeAll
            ? [{ _ = LocalMasks.measure(in: proxy) }, { _ = SubjectInstances.detect(in: proxy) },
               { _ = FocusMeasure.read(proxy) }]
            : [visionSerial, { _ = FocusMeasure.read(proxy) }]
        let group = DispatchGroup()
        let lock = NSLock()
        var done = 0
        time(unsafeAll ? "  ALL FOUR concurrently (UNSAFE)" : "  concurrent (Vision serialised)") {
            for work in jobs {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    work()
                    lock.lock(); done += 1; lock.unlock()
                    group.leave()
                }
            }
            group.wait()
        }
        }

        let recipes = time("candidate recipes (engine)") {
            // The app's conservative fallback read — the perception content does not matter for a
            // timing measurement, only that the engine runs its full path.
            let perception = Perception(
                scene: .other,
                subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
                lighting: Perception.Lighting(condition: .indoorDaylight, direction: .diffuse,
                                              contrastRange: .normal),
                problems: [], intent: .natural, confidence: 0.3)
            return RecipeEngine.candidates(perception: perception, statistics: stats,
                                    subjectLuma: nil, skyLuma: nil, iso: ExifReader.iso(url: url),
                                    focus: FocusMeasure.engineReading(for: proxy))
        }
        print("    (\(recipes.count) candidates)")
        // Serial, as this stage used to be — kept so the arrangement below has something to be
        // measured against rather than asserted about.
        _ = time("candidates: serial") { () -> Int in
            var kept = 0
            for r in recipes {
                let out = Renderer.render(proxy, with: r, maskBitmaps: [:])
                if AestheticEvaluator.score(rendered: out) != nil { kept += 1 }
            }
            return kept
        }

        // The arrangement the app now uses: render + statistics concurrently, Vision serially.
        //
        // The split is not an optimisation detail, it is the whole design. `AestheticEvaluator`'s
        // convenience entry point runs `FaceSkin.read`, which is Vision, and concurrent Vision is
        // what crashed this app before (see the measurement block in the app's `loadPhoto`). Core
        // Image and `ImageStatistics` are safe together and are the expensive half; the face read
        // stays on one thread behind them.
        _ = time("candidates: render ‖, Vision serial") { () -> Int in
            let group = DispatchGroup()
            let lock = NSLock()
            var prepared: [(Int, CIImage, ImageStatistics)] = []
            for (i, r) in recipes.enumerated() {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let out = Renderer.render(proxy, with: r, maskBitmaps: [:])
                    if let stats = try? ImageStatistics.compute(out) {
                        lock.lock(); prepared.append((i, out, stats)); lock.unlock()
                    }
                    group.leave()
                }
            }
            group.wait()
            prepared.sort { $0.0 < $1.0 }
            // One detection for the whole set — eight candidates are eight gradings of one frame,
            // so this was finding the same faces eight times. Metering stays per candidate because
            // that is the part that must differ.
            let faces = FaceSkin.detect(in: proxy)
            var kept = 0
            for (_, image, stats) in prepared {
                _ = AestheticEvaluator.score(stats: stats,
                                             face: FaceSkin.meter(in: image, faces: faces))
                kept += 1
            }
            return kept
        }
        // How much of the stage is the Vision face read. Scoring only consults `face` for skin
        // plausibility, and `AestheticEvaluator` documents that as applying "only when a face is
        // present" — so on a frame with nobody in it, eight Vision passes buy one constant.
        //
        // NOT a change anyone should make from this number alone: perception's `subject.present`
        // and Vision's face detector can disagree, and skipping the read on the model's word would
        // let a missed face through to a skin score of 1.0. It is measured here so the size of the
        // prize is known before anyone decides whether it is worth an eval-harness run.
        _ = time("candidates: no face read (floor)") { () -> Int in
            var kept = 0
            for r in recipes {
                let out = Renderer.render(proxy, with: r, maskBitmaps: [:])
                if let stats = try? ImageStatistics.compute(out) {
                    _ = AestheticEvaluator.score(stats: stats, face: nil); kept += 1
                }
            }
            return kept
        }
        _ = time("EXIF header read") { ExifReader.iso(url: url) }
    } catch { fail("\(error)") }

case "ablate":
    // WHICH LEVER IS THE ERROR? A ΔE for a whole recipe says a frame came out 9.4 from the finished
    // photograph and nothing about why — and three guesses made without this in one session were all
    // wrong. The first run of it ranked white balance as 100 ΔE of damage over 54 corpus entries,
    // five times the next lever. See `RecipeAblation`.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("ablate requires --in") }
    guard let refPath = value(for: "--reference", in: rest) else { fail("ablate requires --reference") }
    guard let recipePath = value(for: "--recipe", in: rest) else { fail("ablate requires --recipe") }

    do {
        let source = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let reference = try ImageDecoder.decode(url: URL(fileURLWithPath: refPath))
        let recipe = try RecipeIO.load(from: URL(fileURLWithPath: recipePath))
        let result = try RecipeAblation.run(source: source, reference: reference, recipe: recipe)
        print("\(URL(fileURLWithPath: inPath).lastPathComponent) vs "
              + "\(URL(fileURLWithPath: refPath).lastPathComponent) [\(recipe.label ?? recipe.id ?? "recipe")]")
        print(result.renderTable())
    } catch {
        fail("\(error)")
    }

case "wb-probe":
    // EVERY ILLUMINANT ESTIMATE ON ONE FRAME, side by side, and — when a reference is supplied —
    // the cast that is actually there.
    //
    // White balance is the engine's largest single error (`ablate`: 100 ΔE over 54 corpus entries
    // before `3cf9c8d`, 54.9 after), and the two questions it fails at are different: does the
    // estimate FIRE on a finished photograph it should leave alone, and does it recover the RIGHT
    // MAGNITUDE on a frame that genuinely is cast. A corpus ΔE answers neither directly — it mixes
    // them with every other lever. This prints the estimates themselves.
    //
    // With `--reference`, the true cast is measured as the whole-frame mean-chroma difference
    // between this frame and the untouched original it was degraded from, which is the one place a
    // ground-truth cast exists. `recovery` is the share of that the estimator would take out.
    do {
        let rest = Array(arguments.dropFirst())
        var paths: [String] = []
        if let dir = value(for: "--in-dir", in: rest) {
            paths = try FileManager.default
                .contentsOfDirectory(atPath: dir)
                .filter { !$0.hasPrefix(".") }
                .sorted()
                .map { (dir as NSString).appendingPathComponent($0) }
        } else if let one = value(for: "--in", in: rest) {
            paths = [one]
        } else {
            fail("wb-probe requires --in or --in-dir")
        }
        let referenceDir = value(for: "--reference-dir", in: rest)
        let wantCost = rest.contains("--cost")
        let estimatorsUnderTest: [RecipeEngine.WhiteBalanceEstimator] =
            [.mean, .neutral, .edge, .hybrid]

        print("frame                        "
              + estimatorsUnderTest.map { "  " + $0.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0) }.joined()
              + (wantCost ? "| ΔE moved (0 = left alone)" : "| true cast    recovery"))
        var totals: [String: (Double, Double)] = [:]
        var costs: [String: (Double, Double)] = [:]
        var fires: [String: Int] = [:]
        var n = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let image = try? ImageDecoder.decode(url: url) else { continue }
            let s = try ImageStatistics.compute(image)

            func fmt(_ a: Double, _ b: Double) -> String {
                String(format: "%+5.1f/%+5.1f", a, b)
            }
            // Driven through the engine's own accessors rather than reimplemented here, so that
            // `hybrid` — whose whole point is that its gate and its magnitude disagree — is measured
            // as the engine would apply it and not as a guess about what it does.
            let estimates: [(String, Double, Double)] = estimatorsUnderTest.map {
                let cast = RecipeEngine.castChroma(s, $0)
                return ($0.rawValue, cast.a, cast.b)
            }

            // The truth, when there is one: how far this frame's colour was moved from the original.
            var truth: (a: Double, b: Double)?
            if let referenceDir {
                // corpus-degrade names a degraded frame "<reference>__<degradation>.<ext>"; the
                // reference keeps the bare name.
                let stem = url.deletingPathExtension().lastPathComponent
                let base = stem.components(separatedBy: "__").first ?? stem
                for candidate in [base, stem] where truth == nil {
                    for ext in ["jpg", "png", "jpeg"] {
                        let refURL = URL(fileURLWithPath: referenceDir)
                            .appendingPathComponent(candidate).appendingPathExtension(ext)
                        guard FileManager.default.fileExists(atPath: refURL.path),
                              let refImage = try? ImageDecoder.decode(url: refURL),
                              let refStats = try? ImageStatistics.compute(refImage) else { continue }
                        truth = (s.chromaA - refStats.chromaA, s.chromaB - refStats.chromaB)
                        break
                    }
                }
            }

            // NOT `padding(toLength:)`, which truncates when the string is longer than the field —
            // it silently clipped ".png" off every corpus filename, and a truncated name is worse
            // than a ragged column because it can no longer be matched back to the file.
            let name28 = url.lastPathComponent
            var line = name28 + String(repeating: " ", count: max(1, 30 - name28.count))
            for (_, a, b) in estimates { line += "  " + fmt(a, b) }

            // THE COST OF FIRING ON A PHOTOGRAPH THAT IS ALREADY FINISHED. Restraint measured as a
            // count — "leaves 82% alone" — says nothing about the size of the mistakes it does make,
            // and an estimator that fires often but gently can easily beat one that fires rarely and
            // hard. This renders each estimate's correction and measures how far it moved a frame
            // that, being the photographer's own finished work, should not have moved at all.
            if wantCost {
                let sourceSample = try ImageMetrics.sample(image)
                for (est, (name, a, b)) in zip(estimatorsUnderTest, estimates) {
                    // The GATE is the estimator's own, which for `hybrid` is not the estimate the
                    // correction is sized from — that separation is the thing being measured.
                    let gate = RecipeEngine.gateChroma(s, est)
                    let magnitude = (gate.a * gate.a + gate.b * gate.b).squareRoot()
                    costs[name, default: (0, 0)].1 += 1
                    guard magnitude > RecipeEngine.castDeadband else {
                        line += "  \(name)= ----"
                        continue
                    }
                    fires[name, default: 0] += 1
                    var recipe = Recipe.neutral
                    let wb = RecipeEngine.whiteBalanceCorrecting(chromaA: a, chromaB: b)
                    recipe.global.temperatureK = wb.temperatureK
                    recipe.global.tint = wb.tint
                    let rendered = try Renderer.render(image, with: recipe)
                    let moved = ImageMetrics.meanDeltaE2000(
                        try ImageMetrics.sample(rendered), sourceSample
                    )
                    line += String(format: "  %@=%5.2f", name, moved)
                    costs[name, default: (0, 0)].0 += moved
                }
            }
            if let truth {
                let trueMag = (truth.a * truth.a + truth.b * truth.b).squareRoot()
                line += "  | " + fmt(truth.a, truth.b) + " "
                for (name, a, b) in estimates {
                    // How much of the true cast this estimate would remove: the projection of the
                    // estimate onto the true cast direction. 1.0 is exact, <1 under-reads, and a
                    // negative number is a correction pointing the wrong way.
                    let recovery = trueMag > 0.5
                        ? (a * truth.a + b * truth.b) / (trueMag * trueMag) : 0
                    line += String(format: " %@=%+.2f", name, recovery)
                    var acc = totals[name] ?? (0, 0)
                    acc.0 += recovery; acc.1 += 1
                    totals[name] = acc
                }
            }
            print(line)
            n += 1
        }
        if !totals.isEmpty {
            print("\nmean recovery over \(n) frames (1.00 = exact, <1 under-reads):")
            for name in estimatorsUnderTest.map(\.rawValue) {
                guard let (sum, count) = totals[name], count > 0 else { continue }
                print("  " + name.padding(toLength: 8, withPad: " ", startingAt: 0)
                      + String(format: " %+.3f", sum / count))
            }
        }
        if !costs.isEmpty {
            // The fire count is reported here rather than left to be derived from the columns above,
            // because those print the MAGNITUDE estimate and the gate is a different one under
            // `hybrid` — deriving it from the columns reads hybrid's restraint as edge's, which is
            // the opposite of the property it was chosen for.
            print("\nfired on / left alone, at deadband \(RecipeEngine.castDeadband) — the GATE:")
            for name in estimatorsUnderTest.map(\.rawValue) {
                guard let (_, count) = costs[name], count > 0 else { continue }
                let fired = fires[name] ?? 0
                print("  " + name.padding(toLength: 8, withPad: " ", startingAt: 0)
                      + String(format: " fired on %2d of %2.0f — left %3.0f%% alone",
                               fired, count, 100 * (count - Double(fired)) / count))
            }
            print("\nmean ΔE moved over \(n) frames — lower is more restrained:")
            for name in estimatorsUnderTest.map(\.rawValue) {
                guard let (sum, count) = costs[name], count > 0 else { continue }
                print("  " + name.padding(toLength: 8, withPad: " ", startingAt: 0)
                      + String(format: " %.3f", sum / count))
            }
        }
    } catch {
        fail("\(error)")
    }

case "mask-coverage":
    // WHICH MASKS ACTUALLY FIRE, AND ON HOW MUCH OF THE FRAME?
    //
    // The mask layer is the most valuable thing the engine does — ablated over 77 real before/after
    // pairs it EARNS 24.6 ΔE against 3.5 of damage, a net −21.1 and six times the next lever. No
    // corpus of global degradations could have shown that, because none of them asks for a local
    // edit. So the highest-value question left is not which global constant to tune; it is where
    // the local layer is absent.
    //
    // This says, per frame: did a subject mask appear, did a sky mask appear, what fraction of the
    // frame does each cover, and — the number that decides what to build next — **how much of the
    // picture no mask touches at all**.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inDir = value(for: "--in-dir", in: rest) else {
            fail("mask-coverage requires --in-dir")
        }
        let paths = try BatchApply.imageFiles(in: URL(fileURLWithPath: inDir, isDirectory: true))
        guard !paths.isEmpty else { fail("no images in \(inDir)") }
        let outDir = value(for: "--out-dir", in: rest).map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let outDir { try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }

        print("frame                                 subject          sky   background   unmasked")
        var haveSubject = 0, havePerson = 0, haveSky = 0, haveNeither = 0, total = 0
        var unmasked: [Double] = []
        var backgrounds: [Double] = []
        var worstDrift = 0.0
        for url in paths {
            // One pool per frame: with --out-dir each iteration renders and writes four images,
            // and without a drain that is the same slow climb `BatchApply` measured at 60 GB
            // over a 400-frame batch.
            try autoreleasepool {
                guard let image = try? ImageDecoder.decode(url: url) else { return }
                // Measure on the perception proxy, which is where the app decides.
                let proxy = PerceptionProxy.downsample(image, maxEdge: 768)
                let m = LocalMasks.measure(in: proxy)
                total += 1

                func coverage(_ key: String) -> Double {
                    guard let mask = m.bitmaps[key],
                          let stats = try? ImageStatistics.compute(mask) else { return 0 }
                    // A mask is white where it applies; its mean luma IS its coverage fraction.
                    return stats.meanLuma
                }
                let subject = coverage("subject"), sky = coverage("sky")
                let background = coverage("background")
                // The masks are disjoint by construction — `LocalMasks` subtracts the subject from
                // the sky and derives background as the complement of both — so the covered
                // fraction is their sum rather than a union that needs computing.
                let covered = min(1.0, subject + sky)
                unmasked.append(1 - covered)
                backgrounds.append(background)

                // VERIFY the partition — in linear mask units, which is where it actually holds.
                // The columns above read sRGB-encoded bytes (their historical unit), and a soft
                // mask — the sky is a confidence map, mostly midtones — encodes brighter in sRGB
                // than it blends, so the three COLUMNS legitimately sum past 100% on a soft sky.
                // Linearised, subject + sky + background = 1 pointwise by construction, and a
                // drift here means the derivation or the disjointness broke upstream.
                func linearCoverage(_ key: String) -> Double {
                    guard let mask = m.bitmaps[key],
                          let data = try? ImageWriter.rgba8Sampled(mask, width: 96, height: 96)
                    else { return 0 }
                    var sum = 0.0, n = 0.0
                    data.withUnsafeBytes { rp in
                        let px = rp.bindMemory(to: UInt8.self)
                        for i in stride(from: 0, to: data.count, by: 4) {
                            let c = Double(px[i]) / 255.0
                            sum += c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
                            n += 1
                        }
                    }
                    return n > 0 ? sum / n : 0
                }
                let linearSum = linearCoverage("subject") + linearCoverage("sky")
                              + linearCoverage("background")
                worstDrift = max(worstDrift, abs(linearSum - 1))

                if m.bitmaps["subject"] != nil { haveSubject += 1 }
                if m.subjectOrigin == .person { havePerson += 1 }
                if m.bitmaps["sky"] != nil { haveSky += 1 }
                // "Neither" means no SEGMENTED mask — the derived background always exists, so an
                // emptiness check on `bitmaps` would never fire again.
                if m.bitmaps["subject"] == nil && m.bitmaps["sky"] == nil { haveNeither += 1 }

                let name = url.deletingPathExtension().lastPathComponent
                let shown = name.count > 34 ? String(name.suffix(34)) : name
                // No `%s` here: it takes a C string, and handing it a Swift String passes a pointer
                // into a temporary that is already gone. It does not warn, it segfaults — and with the
                // output redirected that reads as a command that produced nothing.
                let origin = m.subjectOrigin.map { $0 == .person ? "(person) " : "(salient)" } ?? "         "
                print(shown + String(repeating: " ", count: max(1, 36 - shown.count))
                      + String(format: "%5.1f%% ", subject * 100) + origin
                      + String(format: " %5.1f%%      %5.1f%%      %5.1f%%",
                               sky * 100, background * 100, (1 - covered) * 100))

                guard let outDir else { return }
                // The audition: the three masks painted onto the frame, and — the picture that
                // decides whether a background treatment is worth building rules for — the frame
                // with its background pulled down half a stop through the derived mask.
                //
                // The output stem keeps the source EXTENSION: a RAW+JPEG shoot has `_DSC0001.ARW`
                // and `_DSC0001.JPG` in one folder, both get table rows, and stem-only filenames
                // would silently leave only whichever wrote second — a table that no longer
                // matches its own pictures.
                let outStem = "\(name).\(url.pathExtension.lowercased())"
                for key in ["subject", "sky", "background"] {
                    guard let mask = m.bitmaps[key] else { continue }
                    let overlay = Renderer.renderMaskOverlay(proxy, maskBitmap: mask)
                    try ImageWriter.write(overlay, to: outDir.appendingPathComponent("\(outStem)-\(key).png"),
                                          format: .png)
                }
                var recipe = Recipe.neutral
                recipe.masks = [Mask(id: "bg", type: "background", source: "segmentation",
                                     invert: false, feather: 20, opacity: 1.0,
                                     adjustments: ["exposure_ev": -0.5])]
                let dimmed = Renderer.render(proxy, with: recipe, maskBitmaps: m.bitmaps)
                try ImageWriter.write(dimmed, to: outDir.appendingPathComponent("\(outStem)-bg-dim.png"),
                                      format: .png)
            }
        }
        guard total > 0 else { fail("nothing decodable") }
        func pct(_ n: Int) -> String { String(format: "%3.0f%%", 100.0 * Double(n) / Double(total)) }
        print("\n\(total) frames:")
        print("  subject mask: \(haveSubject) (\(pct(haveSubject))) — of which person-segmented: "
              + "\(havePerson), salient-object fallback: \(haveSubject - havePerson)")
        print("  sky mask:     \(haveSky) (\(pct(haveSky)))")
        print("  NEITHER:      \(haveNeither) (\(pct(haveNeither))) — background is the whole frame there")
        let sorted = unmasked.sorted()
        if let best = sorted.first, let worst = sorted.last {
            print(String(format: "  fraction of the frame no mask touches: median %.0f%%, "
                         + "best %.0f%%, worst %.0f%%",
                         sorted[sorted.count / 2] * 100, best * 100, worst * 100))
        }
        let bgSorted = backgrounds.sorted()
        print(String(format: "  measured background coverage: median %.0f%% — "
                     + "worst partition drift (linear |s+k+b − 1|): %.1f points",
                     bgSorted[bgSorted.count / 2] * 100, worstDrift * 100))
        if worstDrift > 0.05 {
            print("  WARNING: subject + sky + background should sum to 1 everywhere; a drift this "
                  + "size means the masks no longer partition the frame")
        }
        if let outDir { print("wrote per-frame mask overlays and a bg-dim preview to \(outDir.path)") }
    } catch {
        fail("\(error)")
    }

case "exposure-probe":
    // DOES THE ENGINE AGREE WITH THE PHOTOGRAPHER ABOUT HOW BRIGHT A FRAME SHOULD BE?
    //
    // `exposure_ev` is the engine's largest net error against real edits (+11.0 ΔE over 77 pairs)
    // and it has been parked twice as "the owner's call", because the question underneath it is a
    // product one — may a photograph be dark because the photographer wanted it dark? — and no
    // instrument could answer it. A degradation corpus cannot: its reference is the untouched
    // original, so it only ever says "put it back".
    //
    // A corpus of real before/after pairs can, because for every frame the photographer has already
    // decided how bright the result should be. This prints their decision next to the engine's.
    //
    // The photographer's implied EV is log2(reference median / source median) — how many stops they
    // actually moved the frame. Compared against `exposure_ev`, the sign is the interesting part:
    // disagreeing about magnitude is a constant to calibrate, but moving a frame the OPPOSITE way
    // from its photographer is a rule that has misread the intent.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inDir = value(for: "--in-dir", in: rest) else {
            fail("exposure-probe requires --in-dir")
        }
        guard let referenceDir = value(for: "--reference-dir", in: rest) else {
            fail("exposure-probe requires --reference-dir")
        }
        let perceptionDir = value(for: "--perception-dir", in: rest)
        let recipeDir = value(for: "--recipe-dir", in: rest)
        let paths = try FileManager.default.contentsOfDirectory(atPath: inDir)
            .filter { !$0.hasPrefix(".") }.sorted()
            .map { (inDir as NSString).appendingPathComponent($0) }

        print("frame                                  src    ref | photographer  "
              + (recipeDir == nil ? "engine" : "render") + "   error")
        var errors: [Double] = [], wrongWay = 0, scored = 0
        var engineEVs: [Double] = [], theirEVs: [Double] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let stem = url.deletingPathExtension().lastPathComponent
            guard let image = try? ImageDecoder.decode(url: url),
                  let s = try? ImageStatistics.compute(image) else { continue }

            var refStats: ImageStatistics?
            for ext in ["png", "jpg", "jpeg"] where refStats == nil {
                let refURL = URL(fileURLWithPath: referenceDir)
                    .appendingPathComponent(stem).appendingPathExtension(ext)
                if FileManager.default.fileExists(atPath: refURL.path),
                   let refImage = try? ImageDecoder.decode(url: refURL) {
                    refStats = try? ImageStatistics.compute(refImage)
                }
            }
            guard let ref = refStats, s.medianLuma > 0.001, ref.medianLuma > 0.001 else { continue }

            var p = Perception(
                scene: .landscape,
                subject: Perception.Subject(present: false, type: .none, count: .none,
                                            placement: .center),
                lighting: Perception.Lighting(condition: .overcast, direction: .diffuse,
                                              contrastRange: .normal),
                problems: [], intent: .natural, confidence: 0.9)
            if let perceptionDir {
                let pURL = URL(fileURLWithPath: perceptionDir)
                    .appendingPathComponent(stem).appendingPathExtension("json")
                if let loaded = try? PerceptionIO.load(from: pURL) { p = loaded }
            }

            let theirs = log2(ref.medianLuma / s.medianLuma)
            // With `--recipe-dir`, "engine" is where the WHOLE recipe lands rather than what the
            // exposure rule alone asked for. The two answer different questions and the gap between
            // them is the point: `exposure_ev` can be well calibrated in isolation while the render
            // still overshoots, because `whites`, `shadows` and `fusion` brighten too and nothing
            // reconciles them. An ablation says a lever is doing damage; only this says whether the
            // damage is that lever's own aim or the sum of everything pulling the same way.
            var ours = RecipeEngine.exposure(p, s)
            if let recipeDir {
                let recipeURL = URL(fileURLWithPath: recipeDir)
                    .appendingPathComponent(stem).appendingPathComponent("natural.json")
                guard let recipe = try? RecipeIO.load(from: recipeURL),
                      let rendered = try? ImageStatistics.compute(
                          try Renderer.render(image, with: recipe)),
                      rendered.medianLuma > 0.001 else { continue }
                ours = log2(rendered.medianLuma / s.medianLuma)
            }
            let error = ours - theirs
            let opposite = theirs * ours < 0 && abs(theirs) > 0.1 && abs(ours) > 0.1
            if opposite { wrongWay += 1 }
            errors.append(error); engineEVs.append(ours); theirEVs.append(theirs); scored += 1

            let name = stem.count > 36 ? String(stem.suffix(36)) : stem
            print(name + String(repeating: " ", count: max(1, 38 - name.count))
                  + String(format: "%.3f  %.3f |   %+6.2f    %+6.2f  %+6.2f%@",
                           s.medianLuma, ref.medianLuma, theirs, ours, error,
                           opposite ? "  OPPOSITE" : ""))
        }
        guard scored > 0 else { fail("no scorable pairs") }
        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        func median(_ xs: [Double]) -> Double { let v = xs.sorted(); return v[v.count / 2] }
        print(String(format:
            "\n%d pairs. Photographer moved a frame by median %+.2f EV; the engine by %+.2f.",
            scored, median(theirEVs), median(engineEVs)))
        print(String(format:
            "error (engine − photographer): mean %+.2f EV, median %+.2f, |error| > 0.5 EV on %d",
            mean(errors), median(errors), errors.filter { abs($0) > 0.5 }.count))
        print("moved the frame the OPPOSITE way from its photographer: \(wrongWay) of \(scored)")
    } catch {
        fail("\(error)")
    }

case "bg-probe":
    // DOES THE PHOTOGRAPHER TREAT THE BACKGROUND DIFFERENTLY FROM THE SUBJECT?
    //
    // `LocalMasks` now derives a background mask on every frame, which makes a default background
    // treatment *possible* — and nothing yet says whether it is justified. That is not a taste
    // guess: for every paired frame the photographer has already decided how bright each region of
    // the finished photograph is. This measures that decision region by region.
    //
    // Mean luma is measured under the CAPTURE's own subject/sky/background masks — once on the
    // capture, once on the photographer's export of the same frame — and each region's move is
    // expressed in EV. One segmentation per pair: crops are excluded at corpus build, so the
    // capture's geometry is the export's geometry, and segmenting the export separately would only
    // add a second source of mask noise.
    //
    // The column that answers the question is the DIFFERENTIAL, backgroundΔEV − subjectΔEV: zero
    // means the background simply rode the global edit; negative means the photographer settles
    // the background relative to the subject, which is the evidence a default treatment would
    // rest on.
    //
    // With --perception-dir the probe also answers the follow-on question: does the ENGINE lift
    // the subject as much as the photographer does? A labelled frame's default candidate — the one
    // every frame opens in, the only look whose quality is unconditionally the photographer's
    // experience — is composed through `ShippedCandidates.compose`, because that is the one path
    // the app ships (measure on the perception proxy, generate, render WITH bitmaps, score,
    // curate). The eval harness once measured `RecipeEngine.recipe()`, which nothing in the app
    // calls, and it hid months of drift; any bespoke render path here would reopen that hole.
    // Labels arrive incrementally from a separate process, so a missing one skips the engine
    // columns for that frame only — the photographer columns never depend on a label.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inDir = value(for: "--in-dir", in: rest) else {
            fail("bg-probe requires --in-dir")
        }
        guard let referenceDir = value(for: "--reference-dir", in: rest) else {
            fail("bg-probe requires --reference-dir")
        }
        let perceptionDir = value(for: "--perception-dir", in: rest)
        let paths = try FileManager.default.contentsOfDirectory(atPath: inDir)
            .filter { !$0.hasPrefix(".") }.sorted()
            .map { (inDir as NSString).appendingPathComponent($0) }

        struct Row {
            let origin: SubjectMask.Origin?
            let skyPresent: Bool
            let subjectEV: Double?
            let skyEV: Double?
            let backgroundEV: Double?
            /// backgroundΔEV − subjectΔEV. Negative: the background was settled relative to the
            /// subject.
            let differential: Double?
            let backgroundSatDelta: Double?
            /// The default candidate's move on the same regions, under the same masks. Nil when
            /// the frame has no label, or when composition could not produce a default.
            let engineSubjectEV: Double?
            let engineBackgroundEV: Double?
        }

        print("frame                                 subjΔEV   skyΔEV    bgΔEV | bg−subj  bgΔsat"
              + (perceptionDir == nil ? "" : " |engSubj    engBg"))
        var rows: [Row] = []
        var noReference = 0, unreadable = 0, misaligned = 0
        var noLabel = 0, engineUnmeasurable = 0
        for path in paths {
            // One pool per frame: each iteration decodes two frames and runs a segmentation, and
            // without a drain that is the same slow climb `BatchApply` measured at 60 GB over a
            // 400-frame batch.
            autoreleasepool {
                let url = URL(fileURLWithPath: path)
                let stem = url.deletingPathExtension().lastPathComponent
                // `ImageDecoder.decode` does NOT apply the EXIF orientation of a non-RAW file
                // (`CIImage(contentsOf:)` without `.applyOrientationProperty` — see
                // `PerceptionProxy.fromFile`'s doc, which declines to assume it). The corpus's own
                // PNGs are baked upright, but this command accepts any two folders, and a
                // tag-rotated JPEG capture would either sample the reference's ground with the
                // capture's sky mask or be dropped as misaligned. Orient here, so the aspect gate
                // below compares what the masks will actually see.
                func decodeUpright(_ u: URL) -> CIImage? {
                    if ImageDecoder.rawExtensions.contains(u.pathExtension.lowercased()) {
                        return try? ImageDecoder.decode(url: u)
                    }
                    return CIImage(contentsOf: u, options: [.applyOrientationProperty: true])
                }
                guard let capture = decodeUpright(url) else {
                    unreadable += 1; return
                }
                var refImage: CIImage?
                for ext in ["png", "jpg", "jpeg"] where refImage == nil {
                    let refURL = URL(fileURLWithPath: referenceDir)
                        .appendingPathComponent(stem).appendingPathExtension(ext)
                    if FileManager.default.fileExists(atPath: refURL.path) {
                        refImage = decodeUpright(refURL)
                    }
                }
                guard let reference = refImage else { noReference += 1; return }

                // With orientation applied above, an alignable pair has the SAME aspect, not
                // merely the same long/short ratio. A pair that still disagrees cannot share
                // one mask honestly; skip it and say so in the summary.
                let (cw, ch) = (capture.extent.width, capture.extent.height)
                let (rw, rh) = (reference.extent.width, reference.extent.height)
                guard ch > 0, rh > 0, abs(cw / ch - rw / rh) / (rw / rh) <= 0.02 else {
                    misaligned += 1; return
                }

                // Measure on the 768 px perception proxy, which is where the app decides.
                let captureProxy = PerceptionProxy.downsample(capture, maxEdge: 768)
                let referenceProxy = PerceptionProxy.downsample(reference, maxEdge: 768)

                // A labelled frame composes the shipped candidate set once, and its masks and
                // proxy serve the photographer columns too — one segmentation per pair, so the
                // engine and the photographer are measured under the SAME masks. An unlabelled
                // frame (or one whose composition fails) still gets photographer columns from a
                // direct measurement.
                var composition: ShippedCandidates.Composition?
                if let perceptionDir {
                    let pURL = URL(fileURLWithPath: perceptionDir)
                        .appendingPathComponent(stem).appendingPathExtension("json")
                    if let perception = try? PerceptionIO.load(from: pURL) {
                        composition = try? ShippedCandidates.compose(
                            for: capture, perception: perception,
                            iso: ExifReader.iso(url: url))
                        if composition == nil { engineUnmeasurable += 1 }
                    } else {
                        noLabel += 1
                    }
                }
                let m = composition?.masks ?? LocalMasks.measure(in: captureProxy)
                let measureBase = composition?.measuredOn ?? captureProxy

                /// Mean HSV saturation of the pixels the mask covers — the same sampled reduction
                /// as `SubjectMask.maskedMeanLuma`, for the one extra channel this probe reports.
                /// Local to the probe: luma is the primary question, and nothing else needs this
                /// yet.
                func maskedMeanSaturation(image: CIImage, mask: CIImage) -> Double? {
                    guard let imgData = try? ImageWriter.rgba8Sampled(image, width: 96, height: 96),
                          let maskData = try? ImageWriter.rgba8Sampled(mask, width: 96, height: 96)
                    else { return nil }
                    var satSum = 0.0, weight = 0.0
                    imgData.withUnsafeBytes { ip in
                        maskData.withUnsafeBytes { mp in
                            let img = ip.bindMemory(to: UInt8.self)
                            let msk = mp.bindMemory(to: UInt8.self)
                            for i in stride(from: 0, to: imgData.count, by: 4) {
                                let m = Double(msk[i]) / 255.0
                                guard m > 0.4 else { continue }
                                let r = Double(img[i]) / 255.0, g = Double(img[i + 1]) / 255.0
                                let b = Double(img[i + 2]) / 255.0
                                let hi = max(r, g, b), lo = min(r, g, b)
                                satSum += (hi > 0 ? (hi - lo) / hi : 0) * m
                                weight += m
                            }
                        }
                    }
                    guard weight > 4 else { return nil }
                    return satSum / weight
                }

                /// How many stops the photographer moved a region. Nil when either side is
                /// unmeasurable (no mask, mask too small to carry a mean, or a luma too near zero
                /// for a log to mean anything).
                func evDelta(_ src: Double?, _ ref: Double?) -> Double? {
                    guard let src, let ref, src > 0.001, ref > 0.001 else { return nil }
                    return log2(ref / src)
                }

                func regionEV(_ key: String) -> Double? {
                    guard let mask = m.bitmaps[key] else { return nil }
                    return evDelta(SubjectMask.maskedMeanLuma(image: measureBase, mask: mask),
                                   SubjectMask.maskedMeanLuma(image: referenceProxy, mask: mask))
                }
                let subjectEV = regionEV("subject")
                let skyEV = regionEV("sky")
                let backgroundEV = regionEV("background")
                var differential: Double?
                if let backgroundEV, let subjectEV { differential = backgroundEV - subjectEV }
                var backgroundSatDelta: Double?
                if let bg = m.bitmaps["background"],
                   let srcSat = maskedMeanSaturation(image: measureBase, mask: bg),
                   let refSat = maskedMeanSaturation(image: referenceProxy, mask: bg) {
                    backgroundSatDelta = refSat - srcSat
                }

                // The DEFAULT candidate's render, at measurement resolution, masks applied — what
                // a photographer actually opens on. `chosen` nil means curation produced nothing
                // to open in, which for an instrument is a fact worth counting, not hiding.
                var engineSubjectEV: Double?, engineBackgroundEV: Double?
                if let composition {
                    if let chosen = composition.chosen,
                       let preview = composition.candidate(styleID: chosen.recipe.id ?? "")?
                           .preview {
                        func engineEV(_ key: String) -> Double? {
                            guard let mask = m.bitmaps[key] else { return nil }
                            return evDelta(
                                SubjectMask.maskedMeanLuma(image: measureBase, mask: mask),
                                SubjectMask.maskedMeanLuma(image: preview, mask: mask))
                        }
                        engineSubjectEV = engineEV("subject")
                        engineBackgroundEV = engineEV("background")
                    } else {
                        engineUnmeasurable += 1
                    }
                }

                rows.append(Row(origin: m.subjectOrigin, skyPresent: m.bitmaps["sky"] != nil,
                                subjectEV: subjectEV, skyEV: skyEV, backgroundEV: backgroundEV,
                                differential: differential,
                                backgroundSatDelta: backgroundSatDelta,
                                engineSubjectEV: engineSubjectEV,
                                engineBackgroundEV: engineBackgroundEV))

                func cell(_ x: Double?) -> String {
                    x.map { String(format: "%+7.2f", $0) } ?? "      —"
                }
                let name = stem.count > 36 ? String(stem.suffix(36)) : stem
                var line = name + String(repeating: " ", count: max(1, 38 - name.count))
                    + cell(subjectEV) + "  " + cell(skyEV) + "  " + cell(backgroundEV)
                    + " |" + cell(differential) + "  " + cell(backgroundSatDelta)
                if perceptionDir != nil {
                    line += " |" + cell(engineSubjectEV) + "  " + cell(engineBackgroundEV)
                }
                print(line)
            }
        }
        guard !rows.isEmpty else { fail("no scorable pairs") }

        func quartiles(_ xs: [Double]) -> (p25: Double, median: Double, p75: Double)? {
            guard !xs.isEmpty else { return nil }
            let v = xs.sorted()
            func q(_ f: Double) -> Double { v[Int((Double(v.count - 1) * f).rounded())] }
            return (q(0.25), q(0.5), q(0.75))
        }
        func summarise(_ label: String, _ xs: [Double]) {
            guard let q = quartiles(xs) else {
                print("  " + label + "   (no measurable pairs)"); return
            }
            print(String(format: "  %@  n=%3d   p25 %+6.2f   median %+6.2f   p75 %+6.2f",
                         label, xs.count, q.p25, q.median, q.p75))
        }

        print("\n\(rows.count) pairs scored"
              + " (skipped: \(noReference) without a reference, \(unreadable) unreadable, "
              + "\(misaligned) that could not be aligned).")
        print("\nΔEV per region (photographer's export vs capture, EV = log2(ref/src)):")
        summarise("subject   ", rows.compactMap(\.subjectEV))
        summarise("sky       ", rows.compactMap(\.skyEV))
        summarise("background", rows.compactMap(\.backgroundEV))

        let diffs = rows.compactMap(\.differential)
        print("\ndifferential (backgroundΔEV − subjectΔEV; negative = background settled"
              + " relative to the subject):")
        summarise("all pairs ", diffs)
        summarise("  person  ", rows.filter { $0.origin == .person }.compactMap(\.differential))
        summarise("  salient ", rows.filter { $0.origin == .foreground }.compactMap(\.differential))
        summarise("  sky     ", rows.filter(\.skyPresent).compactMap(\.differential))
        summarise("  no sky  ", rows.filter { !$0.skyPresent }.compactMap(\.differential))
        let darker = diffs.filter { $0 < -0.15 }.count
        let brighter = diffs.filter { $0 > 0.15 }.count
        print("  |differential| > 0.15 EV on \(darker + brighter) of \(diffs.count) pairs — "
              + "background darker on \(darker), brighter on \(brighter)")
        print("\nbackground saturation (mean HSV sat under the background mask, ref − src):")
        summarise("background", rows.compactMap(\.backgroundSatDelta))

        if perceptionDir != nil {
            // Engine vs photographer is only meaningful over the SAME pairs, so the
            // photographer's quartiles are restated here restricted to the frames the engine
            // could be measured on — the section above keeps the full corpus.
            let subjPairs = rows.compactMap { r -> (their: Double, engine: Double,
                                                    origin: SubjectMask.Origin?)? in
                guard let t = r.subjectEV, let e = r.engineSubjectEV else { return nil }
                return (t, e, r.origin)
            }
            let bgGaps = rows.compactMap { r -> Double? in
                guard let t = r.backgroundEV, let e = r.engineBackgroundEV else { return nil }
                return t - e
            }
            print("\nengine (default candidate via ShippedCandidates.compose) vs photographer,"
                  + " subject ΔEV, same pairs:")
            summarise("photogr.  ", subjPairs.map(\.their))
            summarise("engine    ", subjPairs.map(\.engine))
            print("\ngap (photographer − engine; positive = the engine lifts the subject less"
                  + " than the photographer did):")
            summarise("subject   ", subjPairs.map { $0.their - $0.engine })
            summarise("  person  ", subjPairs.filter { $0.origin == .person }
                                             .map { $0.their - $0.engine })
            summarise("  salient ", subjPairs.filter { $0.origin == .foreground }
                                             .map { $0.their - $0.engine })
            summarise("background", bgGaps)
            print("no label: \(noLabel)"
                  + (engineUnmeasurable > 0
                     ? " · engine unmeasurable (composition failed or nothing survived "
                       + "curation): \(engineUnmeasurable)"
                     : ""))
        }
    } catch {
        fail("\(error)")
    }

case "faces":
    // COUNT THE FACES IN A CORPUS. `docs/EVALUATION.md` tells you to run this before trusting a
    // corpus to cover skin, so it should not require writing a script.
    //
    // The first real corpus was believed to cover skin because three of its nine photographs came
    // from a folder called `Studio Portraits`. Counted, only 2 of the 9 had a face at all and the
    // "portraits" were shoreline landscapes — the folder name was not the content, and the skin half
    // of the engine went unmeasured for months. A folder name is not evidence.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inDir = value(for: "--in-dir", in: rest) else { fail("faces requires --in-dir") }
        let urls = try BatchApply.imageFiles(in: URL(fileURLWithPath: inDir, isDirectory: true))
        guard !urls.isEmpty else { fail("no images in \(inDir)") }

        var withFaces = 0, total = 0
        var histogram: [Int: Int] = [:]
        for url in urls {
            guard let image = try? ImageDecoder.decode(url: url) else { continue }
            // Detect on the same proxy the engine meters on, so the count is the one the engine
            // would actually see rather than a more generous full-resolution one.
            let count = FaceSkin.detect(in: PerceptionProxy.downsample(image, maxEdge: 768)).count
            total += 1
            histogram[count, default: 0] += 1
            if count > 0 { withFaces += 1 }
            print("  " + url.lastPathComponent.padding(toLength: 44, withPad: " ", startingAt: 0)
                  + (count == 0 ? "—" : "\(count) face\(count == 1 ? "" : "s")"))
        }
        guard total > 0 else { fail("nothing decodable in \(inDir)") }
        print("\n\(withFaces) of \(total) frames have a face "
              + "(\(Int(100.0 * Double(withFaces) / Double(total)))%)")
        for (n, c) in histogram.sorted(by: { $0.key < $1.key }) {
            print("  \(n) face\(n == 1 ? "" : "s"): \(c) frame\(c == 1 ? "" : "s")")
        }
        if withFaces * 4 < total {
            print("⚠️  Under a quarter of this corpus has a face in it. The skin half of the engine "
                  + "is effectively unmeasured here — see docs/EVALUATION.md.")
        }
    } catch {
        fail("\(error)")
    }

case "endpoint-probe":
    // DOES THE ENDPOINT RULE OVERSHOOT? `whites` is the engine's largest single error since white
    // balance was fixed — 20.7 ΔE over 54 corpus entries, concentrated on `dull` (6.1) and `flat`
    // (5.0) and **zero** on the one genuinely underexposed row.
    //
    // `460b135` calibrated `whitePointTarget` on a DISCRIMINATION property: how often the rule
    // returns its cap. That is necessary and not sufficient — a rule can discriminate perfectly and
    // still aim at the wrong place. This measures direction instead: where the frame's white point
    // starts, where the rule moves it to, and where the photographer's own finished version actually
    // put it. Overshoot is the rule driving highlights past the truth.
    //
    // `dull` is the sharpest case, because it is a saturation-only degradation — the luma
    // distribution is IDENTICAL to the reference, so the correct whites push is exactly zero and
    // anything the rule asks for there is invented.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inDir = value(for: "--in-dir", in: rest) else {
            fail("endpoint-probe requires --in-dir")
        }
        let referenceDir = value(for: "--reference-dir", in: rest)
        let perceptionDir = value(for: "--perception-dir", in: rest)
        let paths = try FileManager.default.contentsOfDirectory(atPath: inDir)
            .filter { !$0.hasPrefix(".") }.sorted()
            .map { (inDir as NSString).appendingPathComponent($0) }

        print("frame                          p99.5   whites  ->  after  | reference  overshoot")
        var overshoot: [Double] = [], pushes: [Double] = []
        var pushedWhenNothingWanted = 0, scored = 0
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let image = try? ImageDecoder.decode(url: url),
                  let s = try? ImageStatistics.compute(image) else { continue }

            // The rule needs a perception for its intent gate; fall back to a neutral one so the
            // probe still works on a bare folder of photographs.
            var p = Perception(
                scene: .landscape,
                subject: Perception.Subject(present: false, type: .none, count: .none,
                                            placement: .center),
                lighting: Perception.Lighting(condition: .overcast, direction: .diffuse,
                                              contrastRange: .normal),
                problems: [], intent: .natural, confidence: 0.9)
            let stem = url.deletingPathExtension().lastPathComponent
            if let perceptionDir {
                let pURL = URL(fileURLWithPath: perceptionDir)
                    .appendingPathComponent(stem).appendingPathExtension("json")
                if let loaded = try? PerceptionIO.load(from: pURL) { p = loaded }
            }

            let whites = RecipeEngine.pointPlacement(p, s).whites
            // Where that push actually lands, measured rather than assumed: render whites alone and
            // re-measure p99.5. The slider's units are not luma units and the mapping is the
            // renderer's business, so asking it is the only honest way to get "after".
            var recipe = Recipe.neutral
            recipe.global.whites = whites
            let after = (try? ImageStatistics.compute(try Renderer.render(image, with: recipe)))?
                .whitePoint ?? s.whitePoint

            var line = stem + String(repeating: " ", count: max(1, 30 - stem.count))
            line += String(format: "%6.3f  %+6.0f  ->  %5.3f", s.whitePoint, whites, after)

            if let referenceDir {
                let base = stem.components(separatedBy: "__").first ?? stem
                var refPoint: Double?
                for ext in ["png", "jpg", "jpeg"] where refPoint == nil {
                    let refURL = URL(fileURLWithPath: referenceDir)
                        .appendingPathComponent(base).appendingPathExtension(ext)
                    if FileManager.default.fileExists(atPath: refURL.path),
                       let refImage = try? ImageDecoder.decode(url: refURL),
                       let refStats = try? ImageStatistics.compute(refImage) {
                        refPoint = refStats.whitePoint
                    }
                }
                if let refPoint {
                    let over = after - refPoint
                    line += String(format: "  |    %5.3f    %+6.3f%@", refPoint, over,
                                   over > 0.02 ? "  OVER" : (over < -0.02 ? "  under" : ""))
                    overshoot.append(over); scored += 1
                    // The frame already reaches where the finished photograph does, and the rule
                    // pushed anyway.
                    if s.whitePoint >= refPoint - 0.005, whites > 0 { pushedWhenNothingWanted += 1 }
                }
            }
            pushes.append(whites)
            print(line)
        }

        func median(_ xs: [Double]) -> Double {
            let v = xs.sorted(); return v.isEmpty ? 0 : v[v.count / 2]
        }
        print("\nwhites asked for: median \(Int(median(pushes))), "
              + "capped at 30 on \(pushes.filter { $0 >= 30 }.count) of \(pushes.count), "
              + "left alone on \(pushes.filter { $0 == 0 }.count)")
        if scored > 0 {
            print(String(format:
                "overshoot past the finished photograph: median %+.3f, over on %d of %d frames",
                median(overshoot), overshoot.filter { $0 > 0.02 }.count, scored))
            print("pushed a frame that ALREADY reached the reference: "
                  + "\(pushedWhenNothingWanted) of \(scored)")
        }
    } catch {
        fail("\(error)")
    }

case "subject-coverage":
    // How much of the frame each photograph's subject mask actually covers.
    //
    // Exists to choose `SubjectMask.minimumLiftCoverage` from data rather than from a hunch: the
    // halo that prompted it came from lifting through a mask far too small to carry a lift, and the
    // threshold is only defensible if the numbers for real subjects and real bystanders are known.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inPath = value(for: "--in", in: rest) else { fail("subject-coverage requires --in") }
        let root = URL(fileURLWithPath: inPath)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        let urls = isDir.boolValue ? ((try? BatchApply.imageFiles(in: root)) ?? []) : [root]
        print("frame                        coverage   lifts?")
        for url in urls {
            guard let full = try? ImageDecoder.decode(url: url) else { continue }
            let proxy = PerceptionProxy.downsample(full, maxEdge: 1200)
            guard let found = SubjectMask.subjectWithOrigin(in: proxy) else {
                print("\(url.lastPathComponent.padding(toLength: 26, withPad: " ", startingAt: 0))    no subject")
                continue
            }
            let cover = SubjectMask.coverage(of: found.mask)
            print(String(format: "%@ %9.4f   from %@",
                         url.lastPathComponent.padding(toLength: 26, withPad: " ", startingAt: 0),
                         cover, found.origin == .person ? "person" : "foreground fallback"))
        }
    } catch { fail("\(error)") }

case "proxy-compare":
    // Is the 768 px measurement proxy the same picture whether it comes from the 60 MP decode or
    // from the 1200 px proxy that was built anyway?
    //
    // The question is worth a command because the answer decides ~900 ms of every RAW open.
    // `loadPhoto` builds both proxies from the full-resolution decode — for RAW, `fromFile` refuses
    // (it would hand back the camera's JPEG) so each is a Lanczos pass over 60 megapixels, measured
    // at 1326 ms and 937 ms. Deriving the smaller one from the larger is nearly free.
    //
    // The catch is that it is a two-step resample rather than a one-step, so the 768 px image is not
    // bit-identical — and EVERY recipe number is measured on it. Cheaper is only interesting if the
    // numbers do not move, so this prints what actually moves: the statistics, and the recipe the
    // engine derives from them.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inPath = value(for: "--in", in: rest) else { fail("proxy-compare requires --in") }
        let root = URL(fileURLWithPath: inPath)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
        let urls = isDir.boolValue ? ((try? BatchApply.imageFiles(in: root)) ?? []) : [root]
        guard !urls.isEmpty else { fail("no readable images at \(inPath)") }

        print("frame                     Δmean    Δblack    Δwhite   Δdyn   |  Δev  Δcon Δvib Δwht Δblk  same?")
        var worstStat = 0.0, differing = 0
        for url in urls {
            guard let full = try? ImageDecoder.decode(url: url) else { continue }
            let direct = PerceptionProxy.downsample(full, maxEdge: PerceptionProxy.defaultMaxEdge)
            let large = PerceptionProxy.downsample(full, maxEdge: 1200)
            let derived = PerceptionProxy.downsample(large, maxEdge: PerceptionProxy.defaultMaxEdge)
            guard let a = try? ImageStatistics.compute(direct),
                  let b = try? ImageStatistics.compute(derived) else { continue }

            let p = Perception(
                scene: .landscape,
                subject: Perception.Subject(present: false, type: .none, count: .none, placement: .center),
                lighting: Perception.Lighting(condition: .overcast, direction: .diffuse,
                                              contrastRange: .low),
                problems: [.flat], intent: .natural, confidence: 0.9)
            let ra = RecipeEngine.recipe(perception: p, statistics: a).global
            let rb = RecipeEngine.recipe(perception: p, statistics: b).global
            let same = ra.exposureEV == rb.exposureEV && ra.contrast == rb.contrast
                && ra.vibrance == rb.vibrance && ra.whites == rb.whites && ra.blacks == rb.blacks
            if !same { differing += 1 }
            worstStat = max(worstStat, abs(a.meanLuma - b.meanLuma))
            print(String(format: "%@ %8.5f %9.5f %9.5f %6.4f  | %5.2f %4.0f %4.0f %4.0f %4.0f  %@",
                         url.lastPathComponent.padding(toLength: 24, withPad: " ", startingAt: 0),
                         a.meanLuma - b.meanLuma, a.blackPoint - b.blackPoint,
                         a.whitePoint - b.whitePoint, a.dynamicRange - b.dynamicRange,
                         ra.exposureEV - rb.exposureEV, ra.contrast - rb.contrast,
                         ra.vibrance - rb.vibrance, ra.whites - rb.whites, ra.blacks - rb.blacks,
                         same ? "yes" : "NO"))
        }
        print("")
        print(String(format: "worst |Δ mean luma| %.5f · recipes differing: %d of %d",
                     worstStat, differing, urls.count))
        print("A recipe that differs on any lever means the cheap proxy changes the edit, and the")
        print("900 ms is not free. Identical recipes across the set is the result that permits it.")
    } catch { fail("\(error)") }

case "bench-focus":
    // The culling scan, sequential-slow vs the arrangement the app now uses. Nothing here touches
    // Vision, so unlike the per-photo measurement block this one is safe to parallelise.
    //
    // "new" must be `PhotoTriage.read(url:)` itself, not a re-implementation: an earlier version
    // benchmarked `PerceptionProxy.fromFile` + `FocusMeasure.read`, and on a RAW shoot that is
    // the slow fallback the app no longer takes (`fromFile` refuses a RAW's embedded preview;
    // `measurementProxy` inside PhotoTriage accepts it) and only part of the work — so its
    // ms/photo described a path with no caller. The warm path, MediaCache's verdict cache, is
    // app-layer and out of reach from this CLI; this figure is the cold scan only.
    do {
        let rest = Array(arguments.dropFirst())
        guard let dir = value(for: "--in-dir", in: rest) else { fail("bench-focus requires --in-dir") }
        let files = try BatchApply.imageFiles(in: URL(fileURLWithPath: dir)).sorted { $0.path < $1.path }
        guard !files.isEmpty else { fail("no readable images in \(dir)") }
        func slowRead(_ url: URL) -> FocusMeasure.Reading? {
            // Pool per frame: this path fully decodes the original, and a shoot-length loop of
            // full decodes without a drain is the 60 GB climb BatchApply measured.
            autoreleasepool {
                guard let full = try? ImageDecoder.decode(url: url) else { return nil }
                let lazy = PerceptionProxy.downsample(full, maxEdge: 1200)
                let ctx = CIContext(options: [.cacheIntermediates: false])
                guard let cg = ctx.createCGImage(lazy, from: lazy.extent) else { return nil }
                return FocusMeasure.read(CIImage(cgImage: cg))
            }
        }
        print("Triage scan over \(files.count) photos (cold; the app's warm verdict cache is"
              + " not reachable from the CLI)")
        let mode = value(for: "--mode", in: rest) ?? "new"
        let start = Date()
        if mode == "old" {
            for f in files { _ = slowRead(f) }
        } else {
            let group = DispatchGroup()
            let sem = DispatchSemaphore(value: min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
            for f in files {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    // The app's cold-scan unit of work, exactly: embedded-preview fast path,
                    // histogram + focus + fingerprint, own per-frame pool. Safe concurrent —
                    // PhotoTriage documents it as Vision-free.
                    sem.wait(); _ = PhotoTriage.read(url: f); sem.signal(); group.leave()
                }
            }
            group.wait()
        }
        print(String(format: "  %@: %.0f ms total, %.0f ms/photo", mode as NSString,
                     Date().timeIntervalSince(start) * 1000,
                     Date().timeIntervalSince(start) * 1000 / Double(files.count)))
    } catch { fail("\(error)") }

case "fuse":
    // Experimental: single-image exposure fusion (Mertens). Compare against the untouched frame.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("fuse requires --in") }
    guard let outPath = value(for: "--out", in: rest) else { fail("fuse requires --out") }
    let strength = Double(value(for: "--strength", in: rest) ?? "1.0") ?? 1.0
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let fused = ExposureFusion.fuse(image, strength: strength)
        try ImageWriter.write(fused, to: URL(fileURLWithPath: outPath))
        if let before = try? ImageStatistics.compute(image),
           let after = try? ImageStatistics.compute(fused) {
            print(String(format: "shadows %.3f→%.3f  highlights %.3f→%.3f  median %.3f→%.3f",
                         before.shadowLevel, after.shadowLevel,
                         before.highlightLevel, after.highlightLevel,
                         before.medianLuma, after.medianLuma))
        }
        print("Wrote \(outPath)")
    } catch { fail("\(error)") }

case "info":
    // What the camera recorded — the same data the app's Capture panel shows.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("info requires --in") }
    let info = CaptureInfoReader.read(url: URL(fileURLWithPath: inPath))
    func row(_ label: String, _ value: String?) {
        guard let value else { return }
        print("  " + label.padding(toLength: 12, withPad: " ", startingAt: 0) + value)
    }
    row("Camera", info.camera)
    row("Lens", info.lens)
    row("Exposure", info.summaryText)
    row("Bias", info.exposureBiasText)
    row("Size", info.dimensionsText)
    row("Captured", info.captured.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) })
    row("Location", info.locationText)
    if info.camera == nil && info.summaryText == nil { print("  (no capture metadata in this file)") }

case "horizon":
    // Debug: print the detected leveling angle.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("horizon requires --in") }
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        if let deg = HorizonDetector.levelingAngle(in: image) {
            print(String(format: "horizon leveling angle: %+.2f°", deg))
        } else { print("no horizon detected") }
    } catch { fail("\(error)") }

case "sky":
    // Debug/inspection: segment the sky and preview a local defog/recover through the mask.
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("sky requires --in") }
    guard let outDirPath = value(for: "--out-dir", in: rest) else { fail("sky requires --out-dir") }
    let outDir = URL(fileURLWithPath: outDirPath, isDirectory: true)
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        guard let mask = SkyMask.detect(in: image) else { fail("no sky found in \(inPath)") }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try ImageWriter.write(mask, to: outDir.appendingPathComponent("sky-mask.png"), format: .png)
        if let luma = SubjectMask.maskedMeanLuma(image: image, mask: mask) {
            print(String(format: "sky mean luma: %.3f", luma))
        }
        let skyEdit = Mask(id: "sky", type: "sky", source: "segmentation", invert: false,
                           feather: 45, opacity: 1.0,
                           adjustments: ["highlights": -40, "contrast": 14, "saturation": 12])
        var recipe = Recipe.neutral
        recipe.masks = [skyEdit]
        let edited = Renderer.render(image, with: recipe, maskBitmaps: ["sky": mask])
        try ImageWriter.write(edited, to: outDir.appendingPathComponent("sky-edit.png"), format: .png)
        print("Wrote sky-mask.png + sky-edit.png to \(outDir.path)")
    } catch {
        fail("\(error)")
    }

case "sky-metrics":
    // MEASURE THE SKY, because until now nothing could. Every metric in docs/EVALUATION.md is
    // global or skin-masked, so a style whose entire claim is what it does to a sky was judged by
    // a whole-frame number that passes on ground movement alone — Dramatic and Soft diverge by
    // 0.093 across the frame while their skies are nearly the same picture.
    //
    // Two halves. The left of the table is `SkyMetrics`' reference region: what is there. The right
    // is what `SkyMask` sees of it, which is the mask's report card and not a measurement it
    // grades itself on. With --perception it also renders each candidate style and reports what
    // the style actually did to the sky, which is the instrument `skyDepth` has to be calibrated
    // against.
    let rest = Array(arguments.dropFirst())
    let files: [URL]
    if let one = value(for: "--in", in: rest) {
        files = [URL(fileURLWithPath: one)]
    } else if let dir = value(for: "--in-dir", in: rest) {
        let limit = value(for: "--limit", in: rest).flatMap(Int.init) ?? 12
        files = Array(((try? BatchApply.imageFiles(in: URL(fileURLWithPath: dir))) ?? []).prefix(limit))
    } else {
        fail("sky-metrics requires --in or --in-dir")
    }
    guard !files.isEmpty else { fail("sky-metrics: no readable images") }

    var perception: Perception?
    if let path = value(for: "--perception", in: rest) {
        guard let loaded = try? PerceptionIO.load(from: URL(fileURLWithPath: path)) else {
            fail("sky-metrics: could not read the perception JSON at \(path)")
        }
        perception = loaded
    }

    print("frame                          cover   luma  spread  ground |  mask α  orphan   spill")
    var readings: [SkyMetrics.Reading] = []
    var agreements: [SkyMetrics.MaskAgreement] = []
    var noSkyRegion = 0, noMaskAtAll = 0, groundEaten = 0, maskWithoutSky = 0
    // style id → (readings, divergence vs the unedited frame)
    var styleReadings: [String: [SkyMetrics.Reading]] = [:]
    var styleGlobalOnly: [String: [SkyMetrics.Reading]] = [:]
    var styleDivergence: [String: [SkyMetrics.Divergence]] = [:]
    // The unedited reading of every frame a style was actually measured on. This is the subtrahend
    // for the global/mask split, and it cannot be the `readings` mean: `readings` drops the suspect
    // frames, which are still rendered and still counted below, so subtracting one population's mean
    // from another's would leak every excluded frame's sky luma into the attribution and break the
    // identity global + mask == Δluma.
    var styleBaseline: [String: [SkyMetrics.Reading]] = [:]
    var styleLabels: [String: String] = [:]
    var styleOrder: [String] = []
    // Pairwise, per frame, between every pair of styles — the "are these two candidates actually
    // different where it matters" question, asked of the sky instead of the frame.
    var pairwise: [String: [SkyMetrics.Divergence]] = [:]

    for file in files {
        let name = file.lastPathComponent
        let padded = name.count < 28 ? name + String(repeating: " ", count: 28 - name.count) : name
        guard let decoded = try? ImageDecoder.decode(url: file) else {
            print("\(padded)  (could not decode)")
            continue
        }
        // The measurement proxy the app itself measures on — one size for everything, which is what
        // `1cd6012` unified. A 160-cell grid does not need more than 768 px to sit on.
        let image = PerceptionProxy.downsample(decoded)
        guard let region = try? SkyMetrics.referenceRegion(in: image) else { continue }
        let mask = SkyMask.detect(in: image)
        // Dumped BEFORE the empty-region guard, because a frame the instrument says has no sky is
        // exactly the frame worth looking at.
        if let dump = value(for: "--dump-dir", in: rest) {
            let dir = URL(fileURLWithPath: dump, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stem = file.deletingPathExtension().lastPathComponent
            try? ImageWriter.write(image, to: dir.appendingPathComponent(stem + "-proxy.png"), format: .png)
            if let r = SkyMetrics.regionImage(region) {
                try? ImageWriter.write(r, to: dir.appendingPathComponent(stem + "-region.png"), format: .png)
            }
            if let mask {
                try? ImageWriter.write(mask, to: dir.appendingPathComponent(stem + "-mask.png"), format: .png)
            }
        }
        guard !region.isEmpty, let reading = (try? SkyMetrics.read(image, in: region)) ?? nil else {
            noSkyRegion += 1
            // The cleanest false-positive signal there is: a sky mask on a frame with no sky in
            // it. Counted separately, because loosening the mask to catch an overcast is exactly
            // the change that would start finding skies in a living room.
            if mask != nil { maskWithoutSky += 1 }
            print("\(padded)  (no sky)" + (mask == nil ? "" : "   ← but SkyMask found one"))
            continue
        }
        if mask == nil { noMaskAtAll += 1 }
        guard let agreement = (try? SkyMetrics.agreement(of: mask, with: region)) ?? nil else { continue }

        // A reference region whose ground reads as bright as its sky has swallowed the horizon —
        // wet sand under an overcast, or fog filling the frame. Flagged and left out of the means
        // rather than quietly averaged in.
        let suspect = (reading.groundMeanLuma ?? 0) > reading.meanLuma - 0.10
        if suspect { groundEaten += 1 } else {
            readings.append(reading)
            agreements.append(agreement)
        }

        print(String(format: "%@ %6.3f %6.3f  %6.3f  %6.3f | %7.3f %7.3f %7.3f%@",
                     padded, reading.coverage, reading.meanLuma, reading.spread,
                     reading.groundMeanLuma ?? 0,
                     agreement.meanAlphaInRegion, agreement.orphanedFraction,
                     agreement.spillFraction,
                     suspect ? "  ‡ region includes ground" : (mask == nil ? "  ← no mask" : "")))

        guard let perception else { continue }
        // Render every candidate through the same measured mask bitmaps the app uses. Rendering
        // WITHOUT them would compare the global half of each recipe and silently discard the local
        // half — which is exactly where a sky lever lives.
        guard let stats = try? ImageStatistics.compute(image) else { continue }
        let measured = LocalMasks.measure(in: image)
        let recipes = RecipeEngine.candidates(
            perception: perception, statistics: stats,
            subjectLuma: measured.subjectLuma, skyLuma: measured.skyLuma,
            subjectOrigin: measured.subjectOrigin,
            iso: ExifReader.iso(url: file),
            perceptionHash: PerceptionIO.hash(perception),
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            focus: FocusMeasure.engineReading(for: image))

        var rendered: [(id: String, image: CIImage)] = []
        for recipe in recipes {
            guard let id = recipe.id ?? recipe.label else { continue }
            let out = Renderer.render(image, with: recipe, maskBitmaps: measured.bitmaps)
            rendered.append((id, out))
            if styleLabels[id] == nil { styleLabels[id] = recipe.label ?? id; styleOrder.append(id) }
            let r = (try? SkyMetrics.read(out, in: region)) ?? nil
            // THE SAME RECIPE WITH ITS MASKS WITHHELD. `Renderer` skips any mask it is handed no
            // bitmap for, so this is the recipe's global half alone — and the difference between
            // the two is exactly what the sky mask contributed. Without this split, "the sky came
            // out brighter" cannot be attributed: a lever that is doing nothing and a lever that is
            // doing its job against a global layer doing more look identical in the total.
            let g = (try? SkyMetrics.read(Renderer.render(image, with: recipe), in: region)) ?? nil
            let d = (try? SkyMetrics.compare(image, out, in: region)) ?? nil
            // All four recorded together or not at all: the moment one of them is missing for a
            // frame the others keep, the style row is averaging four different populations and its
            // columns stop adding up.
            if let r, let g, let d {
                styleReadings[id, default: []].append(r)
                styleGlobalOnly[id, default: []].append(g)
                styleDivergence[id, default: []].append(d)
                styleBaseline[id, default: []].append(reading)
            }
        }
        for i in 0..<rendered.count {
            for j in (i + 1)..<rendered.count {
                guard let d = (try? SkyMetrics.compare(rendered[i].image, rendered[j].image,
                                                       in: region)) ?? nil else { continue }
                pairwise["\(rendered[i].id) vs \(rendered[j].id)", default: []].append(d)
            }
        }
    }

    func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

    if !readings.isEmpty {
        print(String(format: "%@ %6.3f %6.3f  %6.3f  %6.3f | %7.3f %7.3f %7.3f",
                     "mean of \(readings.count)".padding(toLength: 28, withPad: " ", startingAt: 0),
                     mean(readings.map(\.coverage)), mean(readings.map(\.meanLuma)),
                     mean(readings.map(\.spread)), mean(readings.map { $0.groundMeanLuma ?? 0 }),
                     mean(agreements.map(\.meanAlphaInRegion)),
                     mean(agreements.map(\.orphanedFraction)),
                     mean(agreements.map(\.spillFraction))))
    }
    print("")
    print("\(files.count) frames · no sky region \(noSkyRegion) · SkyMask returned nothing \(noMaskAtAll)"
          + " · mask on a frame with no sky \(maskWithoutSky)"
          + " · region suspect (excluded from means) \(groundEaten)")
    print("orphan = share of the sky the mask scores below 0.1 alpha. Every sky adjustment in a")
    print("recipe is multiplied by mask α before it reaches a pixel.")

    if perception != nil && !styleOrder.isEmpty {
        print("")
        // Δluma is split into what the recipe's GLOBAL half did to the sky and what the sky MASK
        // then did on top of it, because the two are separate arguments. A style whose global
        // column is large and positive and whose mask column is small is a style being carried
        // along by its own contrast curve — which is the whole complaint about grad-ND levers here.
        print("style        sky luma  spread   Δluma   ← global   ← mask   sky |Δ|  frame |Δ|")
        for id in styleOrder {
            let rs = styleReadings[id] ?? [], ds = styleDivergence[id] ?? []
            guard !rs.isEmpty else { continue }
            let gs = styleGlobalOnly[id] ?? [], bs = styleBaseline[id] ?? []
            let globalDelta = gs.isEmpty ? 0 : mean(gs.map(\.meanLuma)) - mean(bs.map(\.meanLuma))
            let maskDelta = gs.isEmpty ? 0 : mean(rs.map(\.meanLuma)) - mean(gs.map(\.meanLuma))
            print(String(format: "%@ %8.3f %7.3f %+8.3f %+9.3f %+8.3f %9.3f %9.3f",
                         (styleLabels[id] ?? id).padding(toLength: 11, withPad: " ", startingAt: 0),
                         mean(rs.map(\.meanLuma)), mean(rs.map(\.spread)),
                         mean(ds.map(\.skyMeanLumaDelta)), globalDelta, maskDelta,
                         mean(ds.map(\.skyMeanAbsDelta)), mean(ds.map(\.frameMeanAbsDelta))))
        }
        print("")
        print("pairwise, sky vs frame — a pair that separates only in the right-hand column is two")
        print("candidates that differ everywhere except the sky:")
        print("pair                        sky |Δ|  frame |Δ|   ratio")
        for (pair, ds) in pairwise.sorted(by: { mean($0.value.map(\.skyMeanAbsDelta)) < mean($1.value.map(\.skyMeanAbsDelta)) }) {
            let sky = mean(ds.map(\.skyMeanAbsDelta)), frame = mean(ds.map(\.frameMeanAbsDelta))
            print(String(format: "%@ %8.3f %10.3f %7.2f",
                         pair.padding(toLength: 26, withPad: " ", startingAt: 0),
                         sky, frame, frame > 0 ? sky / frame : 0))
        }
    }

case "heal":
    // Heal one or more spots the caller names, and render the result (non-generative,
    // non-destructive). There is no detection any more — see `SpotHeal` for why — so the
    // coordinates come from the caller, exactly as they come from a click in the app. This is
    // how the heal path stays exercisable headlessly.
    //
    //   kelvin-cli heal --in p.jpg --out o.jpg --at 0.31,0.22 --at 0.55,0.40 [--radius 0.01]
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("heal requires --in") }
    guard let outPath = value(for: "--out", in: rest) else { fail("heal requires --out") }
    let healRadius = value(for: "--radius", in: rest).flatMap(Double.init) ?? 0.01
    // `--at` may repeat, so this reads every occurrence rather than using `value(for:)`.
    var healPoints: [CGPoint] = []
    for (i, a) in rest.enumerated() where a == "--at" && i + 1 < rest.count {
        let parts = rest[i + 1].split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { fail("--at wants x,y in 0…1 (got \(rest[i + 1]))") }
        healPoints.append(CGPoint(x: parts[0], y: parts[1]))
    }
    guard !healPoints.isEmpty else { fail("heal requires at least one --at x,y") }
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let spots = healPoints.compactMap { SpotHeal.spot(in: image, at: $0, radius: healRadius) }
        for (p, s) in zip(healPoints, spots) {
            print(String(format: "  (%.3f, %.3f) r=%.4f → source offset (%+.4f, %+.4f)",
                         p.x, p.y, s.radius, s.dx, s.dy))
        }
        print("Healed \(spots.count) of \(healPoints.count) spot(s)")
        var recipe = Recipe.neutral
        recipe.heal = spots
        try ImageWriter.write(Renderer.render(image, with: recipe), to: URL(fileURLWithPath: outPath))
        print("Wrote healed image to \(outPath)")
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

case "pick-probe":
    // WHAT, IF ANYTHING, PREDICTS WHICH LOOK WINS?
    //
    // This is the question the preference loop rests on and the one nobody has asked. What IS
    // known, and is recorded in docs/EVALUATION.md, is the shape of the prize: choosing the right
    // candidate is worth about six times what adding more candidates is. What is also known is
    // that PERCEPTION cannot make that choice — the scene categories the model emits have
    // near-identical distributions over frames where Soft wins and frames where Natural does, so
    // "portrait, overcast" tells you nothing about which of the two the photographer would keep.
    //
    // So the question narrows to: does anything MEASURABLE about the photograph separate them? Not
    // the scene it depicts — the light in it. Median luma, shadow mass, dynamic range, the size of
    // the neutral cast, how much of the frame is nearly clipped. If one of these separates the two
    // groups, a per-frame chooser is buildable and the loop has a shape. If nothing does, the only
    // remaining option is a global "this user tends to prefer Soft" prior, which has already been
    // measured on the real pick log as worth approximately nothing — and the honest conclusion is
    // that the loop as conceived does not work, arrived at in an afternoon instead of a fortnight.
    //
    // It reads a report the harness has already written. Every `engine-<style>` row carries a
    // per-frame `minDeltaE` — distance to the photographer's own edit — so the frame's WINNER is
    // already on disk and needs no re-render. The properties are measured on the corpus SOURCE,
    // because a chooser can only ever see the unedited frame.
    //
    // AUC is the readout, not a p-value: the probability that a randomly chosen frame from one
    // group scores above a randomly chosen frame from the other. 0.50 is a coin flip. It is
    // reported per property, sorted by distance from 0.50, alongside each group's mean — and with
    // the group sizes stated loudly, because on 77 frames a split of 60/17 can manufacture an
    // impressive-looking AUC out of nothing. This project has hunted a threshold before and had it
    // come back at 62% against a coin flip; the instrument exists to make that outcome legible
    // rather than to avoid it.
    do {
        let rest = Array(arguments.dropFirst())
        guard let reportPath = value(for: "--report", in: rest) else {
            fail("pick-probe needs --report <report.json> (written by `eval --out`)")
        }
        guard let corpusPath = value(for: "--corpus", in: rest) else {
            fail("pick-probe needs --corpus <dir> — the properties are measured on its sources")
        }
        let corpusDir = URL(fileURLWithPath: corpusPath, isDirectory: true)
        let reportData = try Data(contentsOf: URL(fileURLWithPath: reportPath))
        guard let root = try JSONSerialization.jsonObject(with: reportData) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else {
            fail("\(reportPath) does not look like an eval report (no `images` array)")
        }

        /// The style closest to the photographer's own edit on one frame, and by how much it beat
        /// the runner-up. The margin matters: a frame the two styles tie on is not evidence about
        /// either, and including it would dilute whatever signal exists with coin flips.
        struct Winner { let id: String; let style: String; let margin: Double }
        var winners: [Winner] = []
        for image in images {
            guard let id = image["id"] as? String,
                  let methods = image["methods"] as? [[String: Any]] else { continue }
            var scores: [(style: String, dE: Double)] = []
            for m in methods {
                guard let name = m["method"] as? String, name.hasPrefix("engine-"),
                      let dE = m["minDeltaE"] as? Double else { continue }
                let style = String(name.dropFirst("engine-".count))
                // `engine-default` and `engine-best` are summaries over the styles, not styles.
                guard style != "default", style != "best" else { continue }
                scores.append((style, dE))
            }
            guard scores.count >= 2 else { continue }
            scores.sort { $0.dE < $1.dE }
            winners.append(Winner(id: id, style: scores[0].style,
                                  margin: scores[1].dE - scores[0].dE))
        }
        guard !winners.isEmpty else { fail("no per-frame engine-<style> rows in that report") }

        var tally: [String: Int] = [:]
        for w in winners { tally[w.style, default: 0] += 1 }
        let ranked = tally.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        print("Frames won, by style (closest to the photographer's own edit):")
        for (style, n) in ranked {
            print(String(format: "  %-10@ %3d  %4.1f%%", style as NSString, n,
                         100 * Double(n) / Double(winners.count)))
        }
        print("")

        // The pair to separate. Defaults to the two winningest styles, which on the paired corpus
        // is where nearly all of the available headroom sits — but it is a flag, because the answer
        // for natural-vs-soft need not be the answer for anything else.
        let pair: [String]
        if let asked = value(for: "--pair", in: rest) {
            pair = asked.split(separator: ",").map(String.init)
        } else {
            pair = Array(ranked.prefix(2).map(\.key))
        }
        guard pair.count == 2 else { fail("--pair takes exactly two style names, comma separated") }
        let minMargin = Double(value(for: "--min-margin", in: rest) ?? "") ?? 0

        let corpus = try Corpus.load(root: corpusDir)
        var sourceById: [String: URL] = [:]
        for entry in corpus.manifest.entries where sourceById[entry.id] == nil {
            sourceById[entry.id] = corpus.sourceURL(for: entry)
        }

        /// One frame's measured light, as a chooser would see it: on the unedited source, with no
        /// reference in hand.
        var groups: [String: [[String: Double]]] = [pair[0]: [], pair[1]: []]
        var missing = 0, tied = 0
        for w in winners where pair.contains(w.style) {
            if w.margin < minMargin { tied += 1; continue }
            guard let url = sourceById[w.id] else { missing += 1; continue }
            guard let image = try? ImageDecoder.decode(url: url),
                  let stats = try? ImageStatistics.compute(image) else { missing += 1; continue }
            groups[w.style]?.append([
                "medianLuma": stats.medianLuma,
                "meanLuma": stats.meanLuma,
                "shadowMass": stats.shadowMass,
                "shadowRegion": stats.shadowRegion,
                "dynamicRange": stats.dynamicRange,
                "highlightLevel": stats.highlightLevel,
                "blackPoint": stats.blackPoint,
                "whitePoint": stats.whitePoint,
                "highlightClip": stats.highlightClip,
                "shadowClip": stats.shadowClip,
                "neutralCast": stats.neutralCastMagnitude,
                "edgeCast": stats.edgeCastMagnitude,
                "chroma": (stats.chromaA * stats.chromaA + stats.chromaB * stats.chromaB).squareRoot(),
            ])
        }
        let a = groups[pair[0]] ?? [], b = groups[pair[1]] ?? []
        if missing > 0 { print("‡ \(missing) frame(s) skipped — no readable source in the corpus") }
        if tied > 0 { print("‡ \(tied) frame(s) skipped — the two styles were within \(minMargin) ΔE") }
        guard a.count >= 3, b.count >= 3 else {
            fail("not enough frames to separate: \(pair[0]) \(a.count), \(pair[1]) \(b.count)")
        }

        /// The probability that a frame drawn from the second group scores above one drawn from the
        /// first — the Mann-Whitney statistic, computed the honest way, by counting every pair.
        /// Ties count a half, so a property that is constant lands on exactly 0.50 rather than on
        /// whichever side the comparison operator happens to fall.
        func auc(_ xs: [Double], _ ys: [Double]) -> Double {
            var wins = 0.0
            for x in xs { for y in ys { wins += y > x ? 1 : (y == x ? 0.5 : 0) } }
            return wins / Double(xs.count * ys.count)
        }
        func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

        let keys = a[0].keys.sorted()
        var rows: [(key: String, ma: Double, mb: Double, auc: Double)] = []
        for k in keys {
            let xs = a.compactMap { $0[k] }, ys = b.compactMap { $0[k] }
            rows.append((k, mean(xs), mean(ys), auc(xs, ys)))
        }
        rows.sort { abs($0.auc - 0.5) > abs($1.auc - 0.5) }

        print("")
        print("Separating \(pair[0]) (n=\(a.count)) from \(pair[1]) (n=\(b.count)) "
              + "on the UNEDITED frame:")
        print(String(format: "%-16@ %10@ %10@ %8@   %@", "property" as NSString,
                     pair[0] as NSString, pair[1] as NSString, "AUC" as NSString,
                     "reading" as NSString))
        print(String(repeating: "-", count: 74))
        for r in rows {
            // Deliberately worded, not starred. A number a reader has to interpret is a number a
            // reader will interpret generously, and this project has been generous to a 62%
            // discriminator before.
            let d = abs(r.auc - 0.5)
            let reading = d >= 0.20 ? "separates" : d >= 0.12 ? "weak" : "nothing"
            print(String(format: "%-16@ %10.4f %10.4f %8.3f   %@", r.key as NSString,
                         r.ma, r.mb, r.auc, reading as NSString))
        }
        print("")
        let best = rows.first.map { abs($0.auc - 0.5) } ?? 0
        if best < 0.12 {
            print("NOTHING SEPARATES THEM. No measured property of the unedited frame predicts which")
            print("of these two the photographer kept. A per-frame chooser has nothing to read, and")
            print("the remaining option is a global prior over the pick log.")
        } else {
            print("The strongest is \(rows[0].key) at AUC \(String(format: "%.3f", rows[0].auc)).")
            print("Before believing it: the groups are \(a.count) and \(b.count) frames, one")
            print("photographer, and this property was chosen from \(rows.count) candidates — which")
            print("is \(rows.count) chances for noise to look like signal. Hold it out before building on it.")
        }
    } catch {
        fail("\(error)")
    }

case "opener-probe":
    // WHAT WOULD THE PER-FRAME OPENER HAVE BOUGHT ON THIS CORPUS, AND AT WHAT FLOORS?
    //
    // `OpeningRule` may open a photograph in something other than Natural when the frame's
    // measured shadow structure clears two floors — but it ships DISABLED, because the floors
    // are uncalibrated (D18: "only above a margin calibrated on the harness"). This is the
    // calibration instrument. Like `pick-probe` it re-reads a report the harness has already
    // written — every `engine-<style>` row carries a per-frame `minDeltaE`, so swapping the
    // opener is arithmetic, not a re-render — and measures the corpus SOURCES, because the rule
    // only ever sees the unedited frame.
    //
    // For every floor pair it prices the swap the rule would have made: the resulting
    // engine-default mean, how many frames it fired on, how many of those it helped and hurt,
    // and the single worst frame it hurt. The worst frame matters more than the mean — D19's
    // lesson is that a zero-mean perturbation can still ruin photographs, and a corpus mean
    // will never show it.
    //
    // A floor pair chosen here is a HYPOTHESIS, not a result. Confirm it end to end, where the
    // curator can still drop the style on frames it is wrong for:
    //
    //     KELVIN_OPENER=soft KELVIN_OPENER_REGION=<r> KELVIN_OPENER_MASS=<m> \
    //         kelvin-cli eval --corpus <dir>
    //
    // and read `engine-default` and `opened in:` off that report. And hold the floors out: a
    // pair swept to its best value on the corpus that chose it is the same trap as choosing a
    // constant on corpus ΔE (docs/EVALUATION.md, "Calibrating a constant").
    do {
        let rest = Array(arguments.dropFirst())
        guard let reportPath = value(for: "--report", in: rest) else {
            fail("opener-probe needs --report <report.json> (written by `eval --out`)")
        }
        guard let corpusPath = value(for: "--corpus", in: rest) else {
            fail("opener-probe needs --corpus <dir> — the floors are measured on its sources")
        }
        let style = value(for: "--style", in: rest) ?? "soft"
        guard style != CandidateCurator.faithfulStyleID else {
            fail("--style \(style) is the opener already; probe a style it could switch TO")
        }
        func floors(_ flag: String, default def: [Double]) -> [Double] {
            guard let raw = value(for: flag, in: rest) else { return def }
            let parsed = raw.split(separator: ",").compactMap { Double($0) }
            guard !parsed.isEmpty else { fail("\(flag) takes comma-separated numbers") }
            return parsed
        }
        let regions = floors("--regions", default: [0.20, 0.225, 0.25, 0.275, 0.30, 0.325, 0.35])
        let masses = floors("--masses", default: [0.02, 0.03, 0.04, 0.05, 0.06, 0.08])

        let reportData = try Data(contentsOf: URL(fileURLWithPath: reportPath))
        guard let root = try JSONSerialization.jsonObject(with: reportData) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else {
            fail("\(reportPath) does not look like an eval report (no `images` array)")
        }

        let corpus = try Corpus.load(root: URL(fileURLWithPath: corpusPath, isDirectory: true))
        var sourceById: [String: URL] = [:]
        for entry in corpus.manifest.entries where sourceById[entry.id] == nil {
            sourceById[entry.id] = corpus.sourceURL(for: entry)
        }

        /// One frame as the probe needs it: what Natural costs, what the candidate style costs,
        /// and the shadow structure the rule would have read off the unedited source.
        struct Frame {
            let id: String
            let naturalDE: Double
            let styleDE: Double
            let shadowRegion: Double
            let shadowMass: Double
        }
        var frames: [Frame] = []
        var missing = 0
        for image in images {
            guard let id = image["id"] as? String,
                  let methods = image["methods"] as? [[String: Any]] else { continue }
            var byStyle: [String: Double] = [:]
            for m in methods {
                guard let name = m["method"] as? String, name.hasPrefix("engine-"),
                      let dE = m["minDeltaE"] as? Double else { continue }
                byStyle[String(name.dropFirst("engine-".count))] = dE
            }
            guard let n = byStyle[CandidateCurator.faithfulStyleID],
                  let s = byStyle[style] else { missing += 1; continue }
            guard let url = sourceById[id],
                  let source = try? ImageDecoder.decode(url: url),
                  let stats = try? ImageStatistics.compute(source) else { missing += 1; continue }
            frames.append(Frame(id: id, naturalDE: n, styleDE: s,
                                shadowRegion: stats.shadowRegion, shadowMass: stats.shadowMass))
        }
        if missing > 0 {
            print("‡ \(missing) frame(s) skipped — no engine-\(style) / engine-natural row, or no "
                  + "readable source")
        }
        guard frames.count >= 5 else {
            fail("only \(frames.count) usable frame(s); a floor chosen on that is a guess")
        }

        let alwaysNatural = frames.map(\.naturalDE).reduce(0, +) / Double(frames.count)
        let oracle = frames.map { min($0.naturalDE, $0.styleDE) }.reduce(0, +)
            / Double(frames.count)
        print("")
        print("\(frames.count) frames · always-natural \(String(format: "%.4f", alwaysNatural))"
              + " · perfect natural-vs-\(style) chooser \(String(format: "%.4f", oracle))"
              + " — the floor and the ceiling every arm below sits between")
        print("")
        print(String(format: "%8@ %8@ %8@ %8@ %6@ %6@ %8@   %@",
                     "region" as NSString, "mass" as NSString, "mean" as NSString,
                     "net" as NSString, "fires" as NSString, "+/-" as NSString,
                     "worst" as NSString, "worst frame" as NSString))
        print(String(repeating: "-", count: 78))
        for region in regions {
            for mass in masses {
                let fired = frames.filter {
                    $0.shadowRegion >= region && $0.shadowMass >= mass
                }
                let mean = frames.map {
                    $0.shadowRegion >= region && $0.shadowMass >= mass ? $0.styleDE : $0.naturalDE
                }.reduce(0, +) / Double(frames.count)
                // Negative net is ΔE saved across the corpus by the swaps this arm makes.
                let net = fired.map { $0.styleDE - $0.naturalDE }.reduce(0, +)
                let helped = fired.filter { $0.styleDE < $0.naturalDE }.count
                let hurt = fired.filter { $0.styleDE > $0.naturalDE }.count
                let worst = fired.max { ($0.styleDE - $0.naturalDE) < ($1.styleDE - $1.naturalDE) }
                let worstDelta = worst.map { $0.styleDE - $0.naturalDE } ?? 0
                print(String(format: "%8.3f %8.3f %8.4f %+8.3f %6d %6@ %+8.3f   %@",
                             region, mass, mean, net, fired.count,
                             "\(helped)/\(hurt)" as NSString,
                             worstDelta,
                             (worstDelta > 0 ? worst?.id ?? "" : "—") as NSString))
            }
        }
        print("")
        print("Read `worst` before `mean`: an arm that saves 0.3 on average while ruining one")
        print("frame by 3 is not a calibration, it is D19 again. Then confirm the chosen floors")
        print("end to end with KELVIN_OPENER=\(style) through `eval`, where curation still gets")
        print("its veto, and hold them out per docs/EVALUATION.md before shipping them.")
    } catch {
        fail("\(error)")
    }

default:
    fail("unknown subcommand '\(subcommand)'. Try `\(tool) --help`.")
}
