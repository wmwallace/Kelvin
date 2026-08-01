import Foundation

/// Stage 1 of the schema (docs/RECIPE-SCHEMA.md): the perception layer's output.
///
/// This is what the VLM emits and — critically — the *only* thing it emits: categorical
/// judgments, never numbers. The recipe engine turns these judgments into parameters using
/// measured image statistics (see `ImageStatistics`). That split is non-negotiable #1 in
/// CLAUDE.md and the reason the architecture works with a 4B-class model.
///
/// Until the perception layer (build-order step 4) exists, these values are hand-labelled
/// JSON fed to the engine. The engine cannot tell the difference, which is the point.
public struct Perception: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var scene: Scene
    public var subject: Subject
    public var lighting: Lighting
    public var problems: [Problem]
    public var intent: Intent
    /// Gates behaviour: below a threshold the engine falls back to a conservative,
    /// scene-agnostic recipe rather than committing to a scene-specific look.
    public var confidence: Double
    /// Free text. **Never parsed** — for debugging and for explaining a choice to the user.
    /// Do not build logic on it (docs/RECIPE-SCHEMA.md).
    /// One sentence from the model naming what it actually saw.
    ///
    /// Briefly removed, because it costs real time: generation is the whole cost of a read, it is
    /// dominated by DECODE rather than by looking at the photograph, and measured, this field is
    /// 13% of it (6.48s → 5.66s, 410 → 326 characters). It was cut for being written for a human
    /// who was never shown it.
    ///
    /// Then put back, because the answer was to SHOW it rather than to stop asking. This codebase's
    /// standing objection to automatic judgements is that they are unfalsifiable — "a flag you can
    /// click through to a measurement is not". The app reads a photograph, proposes four
    /// interpretations of it, and without this said nothing at all about what it thought it was
    /// looking at. When a candidate comes out wrong, this is what tells you whether the READ was
    /// wrong or the MAPPING was, which are entirely different bugs.
    ///
    /// 13% for the app's only explanation of itself is a fair price, and it is now paid deliberately
    /// instead of by default.
    public var notes: String?

    public static let currentSchemaVersion = 1

    public init(
        schemaVersion: Int = currentSchemaVersion,
        scene: Scene,
        subject: Subject,
        lighting: Lighting,
        problems: [Problem],
        intent: Intent,
        confidence: Double,
        notes: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.scene = scene
        self.subject = subject
        self.lighting = lighting
        self.problems = problems
        self.intent = intent
        self.confidence = confidence
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case scene, subject, lighting, problems, intent, confidence, notes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? Perception.currentSchemaVersion
        scene = try c.decodeIfPresent(Scene.self, forKey: .scene) ?? .other
        subject = try c.decodeIfPresent(Subject.self, forKey: .subject) ?? .absent
        lighting = try c.decodeIfPresent(Lighting.self, forKey: .lighting) ?? .unknown
        // Unknown problem tokens are DROPPED, not coerced. Coercing an off-list token to a
        // real problem would silently add an effect; a stray token from a small model
        // should sink to a no-op instead. Decode as raw strings, keep only valid ones.
        let rawProblems = try c.decodeIfPresent([String].self, forKey: .problems) ?? []
        problems = rawProblems.compactMap(Problem.init(rawValue:))
        intent = try c.decodeIfPresent(Intent.self, forKey: .intent) ?? .natural
        confidence = clamp(try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0, to: 0...1)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    public struct Subject: Codable, Equatable, Sendable {
        public var present: Bool
        public var type: SubjectType
        public var count: SubjectCount
        public var placement: Placement
        /// A short name for the subject in the model's own words — "sea stack", "dog", "bride".
        /// **Display only, and that is a rule, not a preference**: free text from a small model
        /// is where hallucinations live, so nothing in the engine may branch on it — the same
        /// discipline as "the model never emits numbers", applied to names. The closed `type`
        /// vocabulary remains the only subject field a decision may read.
        public var label: String?

        public static let absent = Subject(
            present: false, type: .none, count: .none, placement: .center
        )

        public init(present: Bool, type: SubjectType, count: SubjectCount, placement: Placement,
                    label: String? = nil) {
            self.present = present; self.type = type; self.count = count; self.placement = placement
            self.label = label
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            present = try c.decodeIfPresent(Bool.self, forKey: .present) ?? false
            type = try c.decodeIfPresent(SubjectType.self, forKey: .type) ?? .none
            count = Self.decodeCount(c)
            placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .center
            // Trimmed and capped, then emptied to nil: a blank label should read as "no label",
            // and a runaway generation must not become a paragraph in a UI card.
            let raw = try c.decodeIfPresent(String.self, forKey: .label)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            label = raw.flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
        }

        /// The VLM is asked for a `count` *word* (none/single/few/crowd) but a small model will
        /// sometimes answer with a literal number ("count": 2). Accept both rather than throwing
        /// away the whole perception over one field — the same leniency the enums get for
        /// off-vocabulary strings, extended to a type mismatch.
        private static func decodeCount(_ c: KeyedDecodingContainer<CodingKeys>) -> SubjectCount {
            if let word = try? c.decode(SubjectCount.self, forKey: .count) { return word }
            let n: Int?
            if let i = try? c.decode(Int.self, forKey: .count) { n = i }
            else if let d = try? c.decode(Double.self, forKey: .count) { n = Int(d.rounded()) }
            else { n = nil }
            guard let count = n else { return .none }
            switch count {
            case ..<1:  return .none
            case 1:     return .single
            case 2...4: return .few
            default:    return .crowd
            }
        }

        enum CodingKeys: String, CodingKey { case present, type, count, placement, label }
    }

    public struct Lighting: Codable, Equatable, Sendable {
        public var condition: Condition
        public var direction: Direction
        public var contrastRange: ContrastRange

        public static let unknown = Lighting(
            condition: .indoorDaylight, direction: .diffuse, contrastRange: .normal
        )

        public init(condition: Condition, direction: Direction, contrastRange: ContrastRange) {
            self.condition = condition; self.direction = direction; self.contrastRange = contrastRange
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            condition = try c.decodeIfPresent(Condition.self, forKey: .condition) ?? .indoorDaylight
            direction = try c.decodeIfPresent(Direction.self, forKey: .direction) ?? .diffuse
            contrastRange = try c.decodeIfPresent(ContrastRange.self, forKey: .contrastRange) ?? .normal
        }

        enum CodingKeys: String, CodingKey {
            case condition, direction
            case contrastRange = "contrast_range"
        }
    }
}

// MARK: - Closed enumerations

/// The perception vocabulary is deliberately closed (docs/RECIPE-SCHEMA.md): an open
/// vocabulary makes the recipe engine untestable. Decoding is lenient — an off-list token
/// maps to a safe fallback rather than throwing — because the upstream author is a small
/// model, not a validator.
public protocol LenientEnum: RawRepresentable, Codable, CaseIterable, Sendable
where RawValue == String {
    /// Value substituted when an off-vocabulary token is decoded.
    static var fallback: Self { get }
}

public extension LenientEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }
}

public enum Scene: String, LenientEnum {
    case portrait, landscape, street, interior, macro, night, event
    case stillLife = "still-life"
    case document, other
    public static let fallback = Scene.other
}

public enum SubjectType: String, LenientEnum {
    case person, animal, object, none
    /// A landscape's dominant natural feature — a sea stack, a waterfall, a lone tree. Added by
    /// owner decision (1 Aug 2026) after the paired corpus showed the model *seeing* sea stacks
    /// ("Dark silhouette of sea stacks…") and reporting no subject because the vocabulary had no
    /// word for them — it split identical rock formations between `object` and `none`. A frame
    /// read this way is eligible for the subject lift like `animal` (riding the salient-fallback
    /// mask), and is deliberately NOT a warm subject: rock and water have no skin-hue claim.
    case naturalFeature = "natural-feature"
    public static let fallback = SubjectType.none
}

public enum SubjectCount: String, LenientEnum {
    case none, single, few, crowd
    public static let fallback = SubjectCount.none
}

public enum Placement: String, LenientEnum {
    case upperLeft = "upper-left"
    case upperCenter = "upper-center"
    case upperRight = "upper-right"
    case centerLeft = "center-left"
    case center
    case centerRight = "center-right"
    case lowerLeft = "lower-left"
    case lowerCenter = "lower-center"
    case lowerRight = "lower-right"
    case distributed
    public static let fallback = Placement.center
}

public enum Condition: String, LenientEnum {
    case goldenHour = "golden-hour"
    case blueHour = "blue-hour"
    case overcast
    case harshSun = "harsh-sun"
    case openShade = "open-shade"
    case indoorTungsten = "indoor-tungsten"
    case indoorMixed = "indoor-mixed"
    case indoorDaylight = "indoor-daylight"
    case nightAmbient = "night-ambient"
    case flash, backlit
    public static let fallback = Condition.indoorDaylight
}

public enum Direction: String, LenientEnum {
    case front, side, back, top, diffuse
    public static let fallback = Direction.diffuse
}

public enum ContrastRange: String, LenientEnum {
    case low, normal, high, extreme
    public static let fallback = ContrastRange.normal
}

public enum Intent: String, LenientEnum {
    case natural, documentary
    case portraitFlattering = "portrait-flattering"
    case dramatic, archival
    case productAccurate = "product-accurate"
    public static let fallback = Intent.natural
}

/// Unlike the other perception enums, `Problem` is NOT lenient: it appears inside an array,
/// where an off-list token must vanish rather than fall back to a real problem (which would
/// add an unintended effect). Unknown tokens are filtered out during `Perception` decode via
/// `Problem(rawValue:)` returning nil.
public enum Problem: String, Codable, CaseIterable, Sendable {
    case underexposedSubject = "underexposed-subject"
    case overexposed
    case blownHighlights = "blown-highlights"
    case crushedShadows = "crushed-shadows"
    case colorCast = "color-cast"
    case lowContrast = "low-contrast"
    case flat, noise, haze
    case tiltedHorizon = "tilted-horizon"
    case softFocus = "soft-focus"
    case mixedWhiteBalance = "mixed-white-balance"
}
