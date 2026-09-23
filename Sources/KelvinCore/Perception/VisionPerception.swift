import Foundation
@preconcurrency import CoreImage
import Vision

/// A scene read from Apple's Vision framework alone — no language model, no weights to ship.
///
/// **Why this exists.** `docs/EVALUATION.md` ("What the perception read is worth") measured the
/// bundled 2B model's read against a constant one on 77 real edits: the constant read scored
/// *better* on the mean (7.527 vs 7.670 ΔE) and ruined fewer photographs (4 vs 13), and replacing
/// eight of the read's ten fields with constants cost 0.05 ΔE. The two fields the engine genuinely
/// needs are `subject.present` and `subject.type` — and those are detection questions, which
/// Vision answers deterministically, on the Neural Engine, in milliseconds, on every device Kelvin
/// could run on. The model costs 1.72 GB of weights and 4.5–6 s a photograph for the rest.
///
/// So this provider answers exactly those two fields from detectors, and leaves every other field
/// at the same constant `conservativeRead` already ships — deliberately, because the constant is the
/// arm that was measured, and "the model's other fields plus Vision's subject" is a hypothesis
/// nobody has scored. `sceneFromClassifier` is the one exception, off by default, so the corpus can
/// price it rather than this file asserting it.
///
/// **Non-negotiable #1 still holds, more strictly than before.** Vision's classifier emits
/// confidences, and none of them reaches the engine: they decide a *category* here and are then
/// dropped. The engine keeps computing every number from `ImageStatistics` and the mask stack.
///
/// **Blocking.** Vision parks the calling thread. `read(_:)` is synchronous for callers already on
/// a lane (the CLI, an `Offload` lane in the app); `perceive(_:)` hops to its own serial queue so
/// that an `await` from Swift concurrency never blocks a cooperative thread (D21).
public struct VisionPerceptionProvider: PerceptionProvider, Sendable {

    public struct Options: Sendable, Equatable {
        /// Map the classifier's scene labels onto `Scene` (portrait, landscape, interior, night,
        /// event) instead of the constant `.other`. Off until the corpus says it helps: the scene
        /// gates engine behaviour (the sky lever runs only for outdoor scenes, and `.other` counts
        /// as outdoor), so a confident wrong scene can switch a lever off.
        public var sceneFromClassifier: Bool
        public init(sceneFromClassifier: Bool = false) {
            self.sceneFromClassifier = sceneFromClassifier
        }
    }

    public let options: Options
    public init(options: Options = .init()) { self.options = options }

    /// Identifies this provider in `PerceptionStore`'s key, the way a model id does, so a Vision
    /// read and a model read of the same photograph are never confused in the cache.
    public var identifier: String {
        "apple-vision-1" + (options.sceneFromClassifier ? "+scene" : "")
    }

    private static let queue = DispatchQueue(label: "app.usekelvin.vision-perception",
                                             qos: .userInitiated)

    public func perceive(_ image: CIImage) async throws -> Perception {
        let options = self.options
        let box = ImageBox(image: image)
        return await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: Self.read(box.image, options: options)) }
        }
    }

    private struct ImageBox: @unchecked Sendable { let image: CIImage }

    // MARK: The read

    /// What the detectors found, before it is turned into a `Perception`. Exposed for tests and for
    /// the CLI's `vision-label`, which prints it — a read you cannot inspect is a read you cannot
    /// argue with.
    public struct Findings: Sendable, Equatable {
        /// Normalised boxes (Vision convention: origin lower-left).
        public var faces: [CGRect] = []
        public var people: [CGRect] = []
        public var animals: [(label: String, box: CGRect)] = []
        /// Classifier labels at or above `labelFloor`, most confident first.
        public var labels: [(id: String, confidence: Double)] = []

        public static func == (a: Findings, b: Findings) -> Bool {
            a.faces == b.faces && a.people == b.people
                && a.animals.map(\.label) == b.animals.map(\.label)
                && a.animals.map(\.box) == b.animals.map(\.box)
                && a.labels.map(\.id) == b.labels.map(\.id)
        }
    }

    /// Classifier labels below this are not considered at all. Vision's classifier is calibrated
    /// so that its top labels on a clear photograph sit well above it; the floor exists to stop a
    /// 0.1 "cliff" on a studio portrait from meaning anything.
    public static let labelFloor = 0.3

    /// A person counts as the subject when a face or a body is this large a share of the frame.
    /// Below it, people are part of a scene — walkers on a beach — and calling them the subject
    /// is the mistake `RecipeEngine.subjectMask` already defends against with `subjectOrigin`.
    public static let personAreaFloor = 0.015

    /// The classifier's words for what `SubjectType.naturalFeature` means: a sea stack, a
    /// waterfall, a rock arch — one dominant landform that a photographer frames as the subject.
    /// Deliberately excludes the broad ones (`mountain`, `tree`, `forest`, `beach`), which describe
    /// a whole landscape rather than a thing in it.
    public static let naturalFeatureLabels: Set<String> = [
        "cliff", "rocks", "waterfall", "arch", "island", "volcano", "iceberg", "canyon", "cave",
    ]

    public static func findings(in image: CIImage) -> Findings {
        let ext = image.extent
        guard !ext.isInfinite, ext.width > 0, ext.height > 0 else { return Findings() }
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let animals = VNRecognizeAnimalsRequest()
        let classify = VNClassifyImageRequest()
        // One handler, one `perform`, serially — Vision crashed when its requests ran concurrently
        // (see `ShippedCandidates`), and one pass over one image is also the cheapest arrangement.
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do { try handler.perform([faces, humans, animals, classify]) } catch { return Findings() }

        var f = Findings()
        f.faces = (faces.results ?? []).map(\.boundingBox)
        f.people = (humans.results ?? []).filter { $0.confidence >= 0.5 }.map(\.boundingBox)
        f.animals = (animals.results ?? []).compactMap { obs in
            guard let top = obs.labels.first, top.confidence >= 0.5 else { return nil }
            return (top.identifier.lowercased(), obs.boundingBox)
        }
        f.labels = (classify.results ?? [])
            .filter { Double($0.confidence) >= labelFloor }
            .sorted { $0.confidence > $1.confidence }
            .map { ($0.identifier, Double($0.confidence)) }
        return f
    }

    public static func read(_ image: CIImage, options: Options = .init()) -> Perception {
        perception(from: findings(in: image), options: options)
    }

    /// Pure: the mapping from detections to categories, separated so it can be tested without
    /// Vision in the loop.
    public static func perception(from f: Findings, options: Options = .init()) -> Perception {
        let labelIDs = Set(f.labels.map(\.id))
        func area(_ r: CGRect) -> Double { Double(r.width * r.height) }

        let prominentPeople = (f.faces + f.people).filter { area($0) >= personAreaFloor }
        let subject: Perception.Subject
        if !prominentPeople.isEmpty {
            // Count people, not boxes: a face and its body are one person. Faces are the better
            // count where there are any; bodies cover people facing away.
            let n = max(f.faces.filter { area($0) >= personAreaFloor * 0.1 }.count,
                        f.people.filter { area($0) >= personAreaFloor }.count, 1)
            subject = .init(present: true, type: .person, count: subjectCount(n),
                            placement: placement(of: prominentPeople),
                            label: n == 1 ? "person" : "people")
        } else if let animal = f.animals.first {
            subject = .init(present: true, type: .animal, count: subjectCount(f.animals.count),
                            placement: placement(of: f.animals.map(\.box)), label: animal.label)
        } else if labelIDs.contains("animal") || labelIDs.contains("bird") {
            subject = .init(present: true, type: .animal, count: .single, placement: .center,
                            label: labelIDs.contains("bird") ? "bird" : "animal")
        } else if let feature = f.labels.first(where: { naturalFeatureLabels.contains($0.id) }) {
            // Placement is unknown from a whole-image classification; the engine's subject mask
            // comes from Vision's foreground segmentation, not from this, so `.center` costs nothing.
            subject = .init(present: true, type: .naturalFeature, count: .single, placement: .center,
                            label: feature.id.replacingOccurrences(of: "_", with: " "))
        } else {
            subject = .absent
        }

        return Perception(
            scene: options.sceneFromClassifier ? scene(labels: labelIDs, subject: subject) : .other,
            subject: subject,
            // The constant arm's lighting, for the reason in the type's doc: it is what was measured.
            lighting: .init(condition: .indoorDaylight, direction: .diffuse, contrastRange: .normal),
            problems: [],
            intent: .natural,
            confidence: f.labels.first?.confidence ?? 0.3,
            notes: summary(f.labels, subject: subject)
        )
    }

    static func scene(labels: Set<String>, subject: Perception.Subject) -> Scene {
        if labels.contains("night_sky") { return .night }
        if labels.contains("wedding") { return .event }
        if labels.contains("interior_room") { return .interior }
        if subject.type == .person, subject.count == .single || subject.count == .few { return .portrait }
        let outdoor: Set<String> = ["outdoor", "sky", "beach", "shore", "ocean", "mountain", "forest",
                                    "lake", "river", "desert", "cliff", "rocks", "sunset_sunrise"]
        return labels.isDisjoint(with: outdoor) ? .other : .landscape
    }

    /// The scene-summary line the app shows under a photograph — the one place a read explains
    /// itself (see `Perception.notes`). Words, never numbers.
    static func summary(_ labels: [(id: String, confidence: Double)],
                        subject: Perception.Subject) -> String? {
        // "structure", "outdoor" and friends are true of nearly everything and say nothing.
        let vague: Set<String> = ["outdoor", "structure", "people", "adult", "animal", "mammal",
                                  "material", "textile", "plant"]
        let words = labels.map(\.id).filter { !vague.contains($0) }.prefix(3)
            .map { $0.replacingOccurrences(of: "_", with: " ") }
        var parts = Array(words)
        if let label = subject.label, !parts.contains(label) { parts.insert(label, at: 0) }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ").prefix(1).uppercased()
            + parts.joined(separator: " · ").dropFirst()
    }

    /// The same buckets `Perception.Subject` decodes a numeric count into.
    static func subjectCount(_ n: Int) -> SubjectCount {
        switch n {
        case ..<1: return .none
        case 1: return .single
        case 2...4: return .few
        default: return .crowd
        }
    }

    static func placement(of boxes: [CGRect]) -> Placement {
        guard let first = boxes.first else { return .center }
        let union = boxes.dropFirst().reduce(first) { $0.union($1) }
        // Spread across most of the frame is not a position.
        if union.width > 0.7 && boxes.count > 1 { return .distributed }
        let col = union.midX < 1.0 / 3 ? 0 : (union.midX < 2.0 / 3 ? 1 : 2)
        // Vision's origin is lower-left; the vocabulary's "upper" is the top of the picture.
        let row = union.midY > 2.0 / 3 ? 0 : (union.midY > 1.0 / 3 ? 1 : 2)
        let grid: [[Placement]] = [[.upperLeft, .upperCenter, .upperRight],
                                   [.centerLeft, .center, .centerRight],
                                   [.lowerLeft, .lowerCenter, .lowerRight]]
        return grid[row][col]
    }
}
