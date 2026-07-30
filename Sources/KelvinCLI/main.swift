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
      \(tool) wb-probe --in-dir <dir> [--reference-dir <dir>] [--cost]
      \(tool) instances --in <image>
      \(tool) grow --in <image> --at <x,y> [--tolerance <t>] [--softness <s>] [--out-dir <dir>]

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
        let rendered = Renderer.render(image, with: recipe, maskBitmaps: measured.bitmaps)
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

case "dust-map":
    // Does this shoot have sensor dust, and where? Per-frame detection cannot answer that — it
    // reports whatever small dark compact thing sits on a smooth field, which on a beach is kelp
    // and on a street is a distant window. Dust is the thing that does not move between frames.
    //
    // Frames are grouped by ORIENTATION before the recurrence test: the same sensor position maps
    // to different normalised image coordinates in a portrait frame than a landscape one, so
    // mixing them would hide real dust. Aperture is reported alongside because dust is a
    // depth-of-field effect — at f/2.8 a mote is too far out of focus to render at all, so a shoot
    // full of wide-open frames can be perfectly clean AND perfectly dusty at the same time.
    do {
        let rest = Array(arguments.dropFirst())
        guard let inDir = value(for: "--in-dir", in: rest) else { fail("dust-map requires --in-dir") }
        let limit = value(for: "--limit", in: rest).flatMap(Int.init) ?? 40
        let minFrames = value(for: "--min-frames", in: rest).flatMap(Int.init) ?? 3
        var images = try BatchApply.imageFiles(in: URL(fileURLWithPath: inDir, isDirectory: true))
        guard !images.isEmpty else { fail("no images in \(inDir)") }
        images = Array(images.prefix(limit))

        // orientation → (per-frame spot lists, apertures seen)
        var byOrientation: [String: [[HealSpot]]] = [:]
        var apertures: [String: [Double]] = [:]
        var perFrame: [(String, Int, Double?)] = []
        for url in images {
            guard let image = try? ImageDecoder.decode(url: url) else { continue }
            let landscape = image.extent.width >= image.extent.height
            let key = landscape ? "landscape" : "portrait"
            let spots = DustDetector.detect(in: image)
            byOrientation[key, default: []].append(spots)
            let f = ExifReader.fNumber(url: url)
            if let f { apertures[key, default: []].append(f) }
            perFrame.append((url.lastPathComponent, spots.count, f))
        }

        print("per-frame candidates (what the detector reports today):")
        for (name, count, f) in perFrame {
            print(String(format: "  %-22@ %3d  %@", name as NSString, count,
                         (f.map { String(format: "f/%.1f", $0) } ?? "f/?") as NSString))
        }

        for (orientation, frames) in byOrientation.sorted(by: { $0.key < $1.key }) {
            let total = frames.reduce(0) { $0 + $1.count }
            let recurring = DustDetector.recurring(in: frames, minimumFrames: minFrames)
            let aps = apertures[orientation] ?? []
            let stopped = aps.filter { $0 >= 8 }.count
            print("\n\(orientation): \(frames.count) frame(s), \(total) candidate(s), "
                  + "\(stopped) at f/8 or smaller")
            print("  recurring in ≥\(minFrames) frames: \(recurring.count)")
            for s in recurring {
                print(String(format: "    x=%.4f y=%.4f r=%.4f", s.x, s.y, s.radius))
            }
            if recurring.isEmpty && total > 0 {
                print("  → every candidate was scene content: nothing held still between frames.")
            }
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
            _ = time("  dust scan") { DustDetector.detect(in: proxy) }
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
               { _ = DustDetector.detect(in: proxy) }, { _ = FocusMeasure.read(proxy) }]
            : [visionSerial, { _ = DustDetector.detect(in: proxy) }, { _ = FocusMeasure.read(proxy) }]
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
                                    subjectLuma: nil, skyLuma: nil, iso: ExifReader.iso(url: url))
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
    // The culling focus scan, sequential vs the arrangement the app now uses. FocusMeasure touches
    // no Vision, so unlike the per-photo measurement block this one is safe to parallelise.
    do {
        let rest = Array(arguments.dropFirst())
        guard let dir = value(for: "--in-dir", in: rest) else { fail("bench-focus requires --in-dir") }
        let files = try BatchApply.imageFiles(in: URL(fileURLWithPath: dir)).sorted { $0.path < $1.path }
        guard !files.isEmpty else { fail("no readable images in \(dir)") }
        // @Sendable, because this is called from a global-queue closure below. Top-level code is
        // main-actor isolated, so a plain local function inherits that isolation and the call is a
        // hard error on the SDK CI builds against. It reads nothing shared — a URL in, a struct out.
        @Sendable func read(_ url: URL) -> FocusMeasure.Reading? {
            if let fast = PerceptionProxy.fromFile(url, maxEdge: 1200) { return FocusMeasure.read(fast) }
            guard let full = try? ImageDecoder.decode(url: url) else { return nil }
            let lazy = PerceptionProxy.downsample(full, maxEdge: 1200)
            let ctx = CIContext(options: [.cacheIntermediates: false])
            guard let cg = ctx.createCGImage(lazy, from: lazy.extent) else { return nil }
            return FocusMeasure.read(CIImage(cgImage: cg))
        }
        func slowRead(_ url: URL) -> FocusMeasure.Reading? {
            guard let full = try? ImageDecoder.decode(url: url) else { return nil }
            let lazy = PerceptionProxy.downsample(full, maxEdge: 1200)
            let ctx = CIContext(options: [.cacheIntermediates: false])
            guard let cg = ctx.createCGImage(lazy, from: lazy.extent) else { return nil }
            return FocusMeasure.read(CIImage(cgImage: cg))
        }
        print("Focus scan over \(files.count) photos")
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
                    sem.wait(); _ = read(f); sem.signal(); group.leave()
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
            generatedAt: ISO8601DateFormatter().string(from: Date()))

        var rendered: [(id: String, image: CIImage)] = []
        for recipe in recipes {
            guard let id = recipe.id ?? recipe.label else { continue }
            let out = Renderer.render(image, with: recipe, maskBitmaps: measured.bitmaps)
            rendered.append((id, out))
            if styleLabels[id] == nil { styleLabels[id] = recipe.label ?? id; styleOrder.append(id) }
            if let r = (try? SkyMetrics.read(out, in: region)) ?? nil {
                styleReadings[id, default: []].append(r)
            }
            // THE SAME RECIPE WITH ITS MASKS WITHHELD. `Renderer` skips any mask it is handed no
            // bitmap for, so this is the recipe's global half alone — and the difference between
            // the two is exactly what the sky mask contributed. Without this split, "the sky came
            // out brighter" cannot be attributed: a lever that is doing nothing and a lever that is
            // doing its job against a global layer doing more look identical in the total.
            if let g = (try? SkyMetrics.read(Renderer.render(image, with: recipe), in: region)) ?? nil {
                styleGlobalOnly[id, default: []].append(g)
            }
            if let d = (try? SkyMetrics.compare(image, out, in: region)) ?? nil {
                styleDivergence[id, default: []].append(d)
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
            let gs = styleGlobalOnly[id] ?? []
            let globalDelta = gs.isEmpty ? 0 : mean(gs.map(\.meanLuma)) - mean(readings.map(\.meanLuma))
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
    // Auto-detect dust/spots and render the healed result (non-generative, non-destructive).
    let rest = Array(arguments.dropFirst())
    guard let inPath = value(for: "--in", in: rest) else { fail("heal requires --in") }
    guard let outPath = value(for: "--out", in: rest) else { fail("heal requires --out") }
    do {
        let image = try ImageDecoder.decode(url: URL(fileURLWithPath: inPath))
        let spots = DustDetector.detect(in: image)
        print("Detected \(spots.count) spot(s)")
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

default:
    fail("unknown subcommand '\(subcommand)'. Try `\(tool) --help`.")
}
