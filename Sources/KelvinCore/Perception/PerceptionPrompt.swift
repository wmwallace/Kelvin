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

        Do not think step by step, explain your reasoning, or write anything before or after \
        the JSON. Your entire reply must begin with { and end with }.

        ONE RULE, AND IT APPLIES TO "lighting.condition" ONLY — it must not influence "scene", \
        "subject" or anything else. Judge the light from the DIRECTION and HARDNESS of the \
        shadows, never from the colour of the image. A warm or cool tint is almost always a \
        white-balance error, which a separate stage measures and corrects; it is not evidence \
        of time of day. Say golden-hour only for a low sun casting long raking shadows, and \
        blue-hour only for real twilight after sunset. Soft shadows and flat light mean \
        overcast or open-shade however warm the picture looks.

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
          "confidence": a number from 0 to 1 for how certain you are
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
