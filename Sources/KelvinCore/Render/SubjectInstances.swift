import Foundation
// @preconcurrency because CoreImage's Sendable annotations differ by SDK: on the macOS 27
// SDK CIImage is Sendable and this is a no-op, while on the SDK shipped with Xcode 16 —
// which is what CI runs — it is not, and Swift 6 mode rejects the stored properties below.
// Without this the project builds on the author's Mac and fails for everybody else.
@preconcurrency import CoreImage
import Vision

/// Every distinct thing in the frame worth editing on its own — *this* person, *that* dog, the
/// hillside — rather than one merged "subject".
///
/// `SubjectMask.subject(in:)` deliberately fuses everything Vision finds into a single mask, on the
/// reasoning that "a pair of birds is one subject as far as an edit goes". That is wrong as soon as
/// the two things want different treatment, which is most of the time: two people at different
/// distances from the light, a dark dog against a bright hill, one face in shade and one in sun.
/// Merging them means the only available edit is the average of what each needs.
///
/// So this returns them separately, each labelled, so the app can offer them as a list and the
/// photographer can pick one. Ordering is stable and meaningful — people first, then animals, then
/// anything else, each group largest-first — because the list is a UI and its order is a claim
/// about what matters in the picture.
public enum SubjectInstances {

    /// What kind of thing an instance is. Drives both the label and the ordering; the engine can
    /// also treat a person differently from a rock (skin tone protection, for one).
    public enum Kind: String, Sendable, Equatable, Codable {
        case person, animal, object

        /// Singular noun used to build the display label.
        var noun: String {
            switch self {
            case .person: return "Person"
            case .animal: return "Animal"
            case .object: return "Subject"
            }
        }
    }

    public struct Instance: Sendable {
        /// Stable within one detection pass — used as the recipe mask `id` and the bitmap key.
        public let id: String
        /// What the user sees: "Person 1", "Dog", "Subject 2".
        public let label: String
        public let kind: Kind
        /// Grayscale mask, white = this instance, at the source image's extent.
        public let mask: CIImage
        /// Fraction of the frame it covers — drives ordering and the list's size indicator.
        public let coverage: Double
        /// Normalised bounding box (Vision convention, bottom-left origin), for hit-testing a
        /// click on the photo and for placing a label.
        public let boundingBox: CGRect
        /// How sure the classifier was about `label`, 0–1, or nil when the name did not come from
        /// the classifier at all — people and cats/dogs are found by dedicated Vision requests and
        /// named from what found them, so there is no guess to qualify.
        ///
        /// Shown to the user, and that is the point. Vision recognises a car perfectly well
        /// (automobile 0.51, vehicle 0.51, car 0.47) while failing Apple's calibrated precision
        /// gate, and the same gate correctly rejects reading a garden gnome as an owl at 0.46.
        /// Confidence cannot separate those two, so the honest move is to show the guess with its
        /// number and let the name be corrected, rather than silently show "Subject" for both.
        public let nameConfidence: Double?

        /// This instance's identity without its pixels — cheap to keep in a session and to hand
        /// back at export time. See `reidentify`.
        public init(id: String, label: String, kind: Kind, mask: CIImage, coverage: Double,
                    boundingBox: CGRect, nameConfidence: Double? = nil) {
            self.id = id; self.label = label; self.kind = kind; self.mask = mask
            self.coverage = coverage; self.boundingBox = boundingBox
            self.nameConfidence = nameConfidence
        }

        public var reference: Reference { Reference(id: id, kind: kind, boundingBox: boundingBox) }
    }

    /// Who an instance *is*, separated from the bitmap that shows where it is.
    ///
    /// The ids above are Vision's per-pass instance indices. They are stable within one detection
    /// pass and meaningless between two: run the segmentation again — on the same photo at a
    /// different resolution, which is exactly what export does — and `person2` may be a different
    /// person, or nobody. A recipe that says "brighten person2" would then silently brighten
    /// somebody else in the exported file while looking correct on screen.
    ///
    /// So the id is never re-derived. The pass the photographer actually edited against hands its
    /// references forward, and `reidentify` matches a fresh detection back onto them by geometry.
    public struct Reference: Sendable, Equatable, Codable {
        public let id: String
        public let kind: Kind
        /// Normalised (Vision convention), so it carries across resolutions unchanged.
        public let boundingBox: CGRect

        public init(id: String, kind: Kind, boundingBox: CGRect) {
            self.id = id; self.kind = kind; self.boundingBox = boundingBox
        }
    }

    /// The result of matching a fresh detection back onto a known set of instances.
    public struct Reidentified: Sendable {
        /// The instance now standing for each original id — the whole instance, not just its
        /// pixels, because a caller re-keying stored masks needs the id and box this pass gave it
        /// and should not have to identify the match back out of a bitmap to get them.
        public let instances: [String: Instance]
        /// Ids that nothing in the fresh pass matched — the subject moved out of the frame, or
        /// segmentation simply found it this time and not that time. The caller must decide what
        /// to do; rendering with a silently missing mask drops the local edit without a word.
        public let unmatched: [String]

        /// Fresh masks keyed by the ORIGINAL instance's id, ready for `Renderer.render`.
        public var bitmaps: [String: CIImage] { instances.mapValues(\.mask) }
    }

    /// Two boxes are the same thing if they cover the same ground. Below this, they are not.
    /// Generous by the standards of object detection (0.5 is the usual "same object" bar) because
    /// the two passes here are the *same photograph* at two resolutions, where the same subject
    /// lands at an IoU well above 0.9 — anything near the threshold is already suspicious.
    public static let reidentificationOverlap = 0.5

    /// Re-key a fresh detection's masks onto the ids a recipe was authored against.
    ///
    /// Matching is greedy by descending overlap, each side used once, so the strongest agreement
    /// wins and no two references can claim the same mask. Kind breaks ties but does not gate the
    /// match: the person segmentation is a threshold decision and can flip between a 1200px proxy
    /// and a 60 MP frame, and dropping an edit because someone was re-classified is a worse
    /// failure than matching them across that flip. Geometry is the stronger evidence — two
    /// *different* subjects overlapping this much in one photograph is not a real case.
    public static func reidentify(_ fresh: [Instance], as references: [Reference],
                                  minimumOverlap: Double = reidentificationOverlap) -> Reidentified {
        var pairs: [(ref: Int, fresh: Int, iou: Double, sameKind: Bool)] = []
        for (r, reference) in references.enumerated() {
            for (f, instance) in fresh.enumerated() {
                let iou = intersectionOverUnion(reference.boundingBox, instance.boundingBox)
                guard iou >= minimumOverlap else { continue }
                pairs.append((r, f, iou, reference.kind == instance.kind))
            }
        }
        // Descending overlap; same-kind first where two are equally good. The index tie-breaks last
        // so the result cannot depend on the order pairs happened to be built in.
        pairs.sort {
            if $0.iou != $1.iou { return $0.iou > $1.iou }
            if $0.sameKind != $1.sameKind { return $0.sameKind }
            return ($0.ref, $0.fresh) < ($1.ref, $1.fresh)
        }

        var matched: [String: Instance] = [:]
        var usedReferences = Set<Int>(), usedFresh = Set<Int>()
        for pair in pairs {
            guard !usedReferences.contains(pair.ref), !usedFresh.contains(pair.fresh) else { continue }
            usedReferences.insert(pair.ref); usedFresh.insert(pair.fresh)
            matched[references[pair.ref].id] = fresh[pair.fresh]
        }
        let unmatched = references.enumerated()
            .filter { !usedReferences.contains($0.offset) }
            .map { $0.element.id }
        return Reidentified(instances: matched, unmatched: unmatched)
    }

    /// Standard IoU on normalised boxes. Symmetric, unlike `overlap` below — here neither box is
    /// the authority, they are two readings of the same thing.
    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, !i.isEmpty else { return 0 }
        let intersection = Double(i.width * i.height)
        let union = Double(a.width * a.height + b.width * b.height) - intersection
        guard union > 0 else { return 0 }
        return intersection / union
    }

    /// A mask covering essentially the whole frame is not a subject, it is the picture. Vision
    /// returns exactly that on a featureless image — hand it a flat grey field and it proposes the
    /// entire frame as an instance — and a "Subject 1: 99%" row selecting everything is worse than
    /// an empty list, because it looks like a local edit and behaves like a global one.
    static let maximumCoverage = 0.92

    /// Find every separable subject in the frame. Empty when Vision finds nothing salient — which
    /// is a real answer (a flat landscape has no subject) and not a failure.
    ///
    /// - Parameter limit: how many to return. The list is a UI; twenty rows of rubble helps nobody.
    public static func detect(in image: CIImage, limit: Int = 8) -> [Instance] {
        guard #available(macOS 14.0, *) else { return [] }
        let ext = image.extent
        guard !ext.isInfinite, ext.width > 0, ext.height > 0 else { return [] }

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        var found: [Instance] = []

        // PEOPLE FIRST, individually. The generic foreground segmentation groups touching subjects
        // into one instance — two people sitting together on a porch swing came back as a single
        // mask covering half the frame, which is precisely the thing that makes per-subject editing
        // useless. Vision has a dedicated request that separates people, so use it for them and
        // keep the generic one for everything else.
        // Gate on the SEMANTIC person segmentation first. The instance request will invent a
        // person where there is none — handed a flat grey field it confidently returns one
        // covering 57% of the frame. `SubjectMask.person` already knows how to answer this
        // honestly (Vision returns an all-black mask, not nil, when nobody is there), so ask it
        // whether there is a person at all before asking how many.
        let anyPerson = SubjectMask.person(in: image) != nil
        let people = VNGeneratePersonInstanceMaskRequest()
        if anyPerson, (try? handler.perform([people])) != nil, let result = people.results?.first {
            for index in result.allInstances {
                guard let buffer = try? result.generateScaledMaskForImage(
                        forInstances: IndexSet(integer: index), from: handler) else { continue }
                let mask = align(CIImage(cvPixelBuffer: buffer), to: image)
                let cover = SubjectMask.coverage(of: mask)
                guard cover >= SubjectMask.minimumCoverage, cover <= maximumCoverage else { continue }
                found.append(Instance(id: "person\(index)", label: Kind.person.noun, kind: .person,
                                      mask: mask, coverage: cover,
                                      boundingBox: normalisedBounds(of: mask, in: ext)))
            }
        }

        // Then everything that isn't a person: pets, and whatever else stands out.
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        let animals = animalBoxes(in: image, handler: handler)
        if (try? handler.perform([foreground])) != nil, let result = foreground.results?.first {
            for index in result.allInstances {
                guard let buffer = try? result.generateScaledMaskForImage(
                        forInstances: IndexSet(integer: index), from: handler) else { continue }
                let mask = align(CIImage(cvPixelBuffer: buffer), to: image)
                let cover = SubjectMask.coverage(of: mask)
                guard cover >= SubjectMask.minimumCoverage, cover <= maximumCoverage else { continue }

                // Skip anything already covered by a person instance — the generic pass sees the
                // same people, merged, and adding that back would put a bogus "everyone at once"
                // row in the list beside the individual ones.
                //
                // Tested BOTH directions, because the merged mask is a superset: on a four-person
                // group shot the merged blob is 60% of the frame while each person is ~10–20%, so
                // "how much of the blob is this person" is small for every one of them and the
                // duplicate slipped through. The telling question is the other one — does this new
                // mask swallow an instance we already have?
                if found.contains(where: {
                    overlapOfMasks(mask, $0.mask) > 0.5 || overlapOfMasks($0.mask, mask) > 0.7
                }) { continue }

                let box = normalisedBounds(of: mask, in: ext)
                if let animal = animals.first(where: { overlap($0.box, box) > 0.35 }) {
                    found.append(Instance(id: "instance\(index)", label: animal.label, kind: .animal,
                                          mask: mask, coverage: cover, boundingBox: box))
                } else {
                    // NAME whatever it is. The segmentation is class-agnostic — it will happily cut
                    // out a jellyfish, a frog, or the one rock the photograph is actually about —
                    // but it cannot say what it found, and a list of rows all reading "Subject" is
                    // barely better than not separating them. So classify the crop.
                    let named = name(of: mask, in: image, box: box)
                    found.append(Instance(id: "instance\(index)",
                                          label: named?.label ?? Kind.object.noun,
                                          kind: .object, mask: mask, coverage: cover, boundingBox: box,
                                          nameConfidence: named?.confidence))
                }
            }
        }

        // People first, then animals, then everything else; within a group, biggest first. A
        // photographer scanning this list is looking for the subject, and the subject is usually
        // the person, and usually large.
        let rank: [Kind: Int] = [.person: 0, .animal: 1, .object: 2]
        found.sort {
            (rank[$0.kind] ?? 9, -$0.coverage) < (rank[$1.kind] ?? 9, -$1.coverage)
        }
        return numbered(Array(found.prefix(limit)))
    }

    /// "Person", "Person" → "Person 1", "Person 2"; a lone one keeps the bare noun, because
    /// "Person 1" when there is only one person reads like a bug.
    static func numbered(_ items: [Instance]) -> [Instance] {
        var counts: [String: Int] = [:]
        for item in items { counts[item.label, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return items.map { item in
            guard (counts[item.label] ?? 0) > 1 else { return item }
            seen[item.label, default: 0] += 1
            return Instance(id: item.id, label: "\(item.label) \(seen[item.label]!)",
                            kind: item.kind, mask: item.mask, coverage: item.coverage,
                            boundingBox: item.boundingBox)
        }
    }

    // MARK: - Classification helpers

    /// What the thing in this mask actually is — "Jellyfish", "Frog", "Rock" — by classifying the
    /// crop it occupies. Uses Vision's on-device classifier, so it stays inside KelvinCore with no
    /// model dependency and no network.
    ///
    /// Returns nil rather than guessing. A confidently wrong label ("Banana" on your hero rock) is
    /// worse than the honest fallback of "Subject", because the label is what the photographer
    /// clicks on to find the thing they mean.
    /// The name for one instance, and how sure it is — nil confidence means the classifier
    /// cleared Apple's precision gate and the name is not presented as a guess.
    private static func name(of mask: CIImage, in image: CIImage,
                             box: CGRect) -> (label: String, confidence: Double?)? {
        let ext = image.extent
        // Crop to the instance, with a little margin — classifiers do better with some context
        // than with a shape shaved to its outline.
        let margin = 0.06
        let rect = CGRect(x: ext.origin.x + max(0, box.minX - margin) * ext.width,
                          y: ext.origin.y + max(0, box.minY - margin) * ext.height,
                          width: min(1, box.width + margin * 2) * ext.width,
                          height: min(1, box.height + margin * 2) * ext.height)
        let crop = image.cropped(to: rect)
        guard !crop.extent.isEmpty, crop.extent.width > 16, crop.extent.height > 16 else { return nil }

        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(ciImage: crop, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results else { return nil }

        // The precision gate USED to be a veto, and it silently swallowed correct answers: a car
        // that Vision reads as automobile 0.51 / vehicle 0.51 / car 0.47 fails it outright, so the
        // row said "Subject". It is not useless though — it is what stops a garden gnome in a tree
        // being confidently labelled "Owl" at 0.46, and no confidence threshold separates those
        // two cases because the wrong one scores as highly as the right one.
        //
        // So it stops being a veto and becomes a measurement. Anything past the gate is trusted
        // outright; anything short of it is still offered, with its confidence, for the user to
        // accept or type over. A visible guess that can be corrected beats a hidden one.
        let usable = results.filter { !generic.contains($0.identifier) }
        let trusted = usable.filter { $0.hasMinimumPrecision(0.7, forRecall: 0.1) }
        let pool = trusted.isEmpty ? usable : trusted
        guard let name = preferredLabel(from: pool.map { ($0.identifier, Double($0.confidence)) })
        else { return nil }
        let confidence = pool.map { Double($0.confidence) }.max() ?? 0
        return (name, trusted.isEmpty ? confidence : nil)
    }

    /// Choose which surviving classification to show, and format it for a mask row.
    ///
    /// Vision answers with a taxonomy rather than one label: a single squirrel comes back as
    /// `animal`, `mammal`, `rodent` and `squirrel` at *identical* confidence — 0.991 each,
    /// measured — ordered general to specific. `max(by:)` keeps the FIRST of equal elements, so
    /// every such row read "Animal" while "Squirrel" sat in the same list at the same confidence.
    ///
    /// Among candidates that are equally confident, the most specific one is the one worth
    /// showing: "Squirrel" tells you which mask you are about to edit and "Animal" does not.
    /// Ties only — this never trades confidence for specificity.
    static func preferredLabel(from candidates: [(identifier: String, confidence: Double)],
                               minimumConfidence: Double = 0.25) -> String? {
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }),
              best.confidence > minimumConfidence else { return nil }
        // Float confidences that print identically can differ in the last bit, so compare with a
        // tolerance rather than for exact equality.
        let tied = candidates.filter { $0.confidence >= best.confidence - 0.0005 }
        let chosen = tied.last ?? best
        // Identifiers are lowercase, sometimes compound ("sea_turtle").
        let words = chosen.identifier.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Labels that are true but useless on a mask row — they describe the picture, not the thing.
    private static let generic: Set<String> = [
        "outdoor", "indoor", "nature", "landscape", "sky", "plant", "material", "structure",
        "machine", "device", "equipment",
        "abstract", "art", "light", "shape", "pattern", "texture", "surface", "background",
        "macro", "close_up", "photography", "still_life", "reflection", "shadow", "colour", "color"
    ]

    private struct AnimalBox { let label: String; let box: CGRect }

    /// Cats and dogs are what Vision recognises by name; anything else animal-shaped falls through
    /// to the generic subject path rather than being mislabelled.
    private static func animalBoxes(in image: CIImage, handler: VNImageRequestHandler) -> [AnimalBox] {
        let request = VNRecognizeAnimalsRequest()
        guard (try? handler.perform([request])) != nil,
              let results = request.results else { return [] }
        return results.compactMap { observation in
            guard let top = observation.labels.first, top.confidence > 0.6 else { return nil }
            // Vision's identifiers are lowercase ("dog", "cat"); title-case for display.
            return AnimalBox(label: top.identifier.prefix(1).uppercased() + top.identifier.dropFirst(),
                             box: observation.boundingBox)
        }
    }

    /// Fraction of `a` that `b` covers — asymmetric on purpose: we ask "is this instance mostly
    /// inside that animal's box", not "are the two the same size".
    private static func overlap(_ b: CGRect, _ a: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, a.width > 0, a.height > 0 else { return 0 }
        return Double((i.width * i.height) / (a.width * a.height))
    }

    /// How much of `subject` is also lit in `reference`. Used to decide whether an instance is a
    /// person, by testing it against the person segmentation.
    private static func overlapOfMasks(_ subject: CIImage, _ reference: CIImage) -> Double {
        guard let a = try? ImageWriter.rgba8Sampled(subject, width: 64, height: 64),
              let b = try? ImageWriter.rgba8Sampled(reference, width: 64, height: 64) else { return 0 }
        var both = 0, subjectOnly = 0
        a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in
                let s = ap.bindMemory(to: UInt8.self)
                let r = bp.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: a.count, by: 4) where s[i] > 96 {
                    subjectOnly += 1
                    if r[i] > 96 { both += 1 }
                }
            }
        }
        return subjectOnly > 0 ? Double(both) / Double(subjectOnly) : 0
    }

    /// Tight normalised bounds of the lit area, for hit-testing and labelling.
    private static func normalisedBounds(of mask: CIImage, in extent: CGRect) -> CGRect {
        let n = 64
        guard let data = try? ImageWriter.rgba8Sampled(mask, width: n, height: n) else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        var minX = n, minY = n, maxX = -1, maxY = -1
        data.withUnsafeBytes { dp in
            let px = dp.bindMemory(to: UInt8.self)
            for row in 0..<n {
                for col in 0..<n where px[(row * n + col) * 4] > 96 {
                    minX = min(minX, col); maxX = max(maxX, col)
                    minY = min(minY, row); maxY = max(maxY, row)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        // `rgba8Sampled` rasterises top-down; Vision's normalised space is bottom-up, so flip Y.
        let d = Double(n)
        return CGRect(x: Double(minX) / d, y: 1 - Double(maxY + 1) / d,
                      width: Double(maxX - minX + 1) / d, height: Double(maxY - minY + 1) / d)
    }

    private static func align(_ mask: CIImage, to image: CIImage) -> CIImage {
        let sx = image.extent.width / mask.extent.width
        let sy = image.extent.height / mask.extent.height
        return mask
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: image.extent.origin.x,
                                               y: image.extent.origin.y))
    }
}
