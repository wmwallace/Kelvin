import Foundation

/// The instruction handed to the VLM. It is built from the perception enums themselves, so
/// the allowed-value lists in the prompt can never drift from the `Codable` schema the parser
/// decodes into — add an enum case and the prompt updates for free.
///
/// The prompt is deliberately strict: a 4B model kept on a tight leash with a closed
/// vocabulary and a JSON-only instruction is the difference between a usable perception layer
/// and one that emits prose the parser has to fight. Reliability here is prompt + forgiving
/// parser, not model size (non-negotiable #1 / CLAUDE.md).
public enum PerceptionPrompt {

    /// A single self-contained instruction (system + task in one string), suitable for a
    /// small instruct model. `PerceptionParser` consumes whatever the model returns.
    public static func instruction() -> String {
        """
        You are a photo-analysis module inside a photo editor. Look at the image and describe \
        it with structured judgments only. You do NOT suggest edit amounts or numbers — only \
        categories. A separate deterministic engine computes the actual adjustments.

        Output ONLY a single JSON object, no prose and no markdown fences. Choose every value \
        strictly from the allowed list for its field; if unsure, pick the closest allowed \
        value. Schema:

        {
          "scene": one of [\(list(Scene.self))],
          "subject": {
            "present": true or false,
            "type": one of [\(list(SubjectType.self))],
            "count": one of [\(list(SubjectCount.self))],
            "placement": one of [\(list(Placement.self))]
          },
          "lighting": {
            "condition": one of [\(list(Condition.self))],
            "direction": one of [\(list(Direction.self))],
            "contrast_range": one of [\(list(ContrastRange.self))]
          },
          "problems": array (may be empty) drawn from [\(list(Problem.self))]. \
        Include a problem only if it is clearly visible.
          "intent": one of [\(list(Intent.self))] — the editing goal that best suits \
        this photo,
          "confidence": a number from 0 to 1 for how certain you are,
          "notes": one short sentence of free-text explanation
        }

        Return the JSON object and nothing else.
        """
    }

    /// Comma-separated raw values for a closed enum, in declaration order.
    static func list<T: RawRepresentable & CaseIterable>(_ type: T.Type) -> String
    where T.RawValue == String {
        T.allCases.map { $0.rawValue }.joined(separator: ", ")
    }
}
