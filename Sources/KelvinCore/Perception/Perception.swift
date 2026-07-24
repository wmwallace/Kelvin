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

        public static let absent = Subject(
            present: false, type: .none, count: .none, placement: .center
        )

        public init(present: Bool, type: SubjectType, count: SubjectCount, placement: Placement) {
            self.present = present; self.type = type; self.count = count; self.placement = placement
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            present = try c.decodeIfPresent(Bool.self, forKey: .present) ?? false
            type = try c.decodeIfPresent(SubjectType.self, forKey: .type) ?? .none
            count = try c.decodeIfPresent(SubjectCount.self, forKey: .count) ?? .none
            placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .center
        }

        enum CodingKeys: String, CodingKey { case present, type, count, placement }
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
