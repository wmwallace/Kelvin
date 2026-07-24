import Foundation

/// Turns whatever a VLM actually returns into a `Perception`. Small instruct models ignore
/// "JSON only" often enough that the parser, not the prompt, is the real reliability layer:
/// it tolerates markdown fences, leading/trailing prose, and a bit of chatter around the
/// object. The closed-vocabulary lenience (unknown enum tokens → fallback, unknown problems
/// dropped) lives in `Perception`'s decoder; this stage only has to find the JSON.
public enum PerceptionParser {

    public enum Error: Swift.Error, CustomStringConvertible {
        case noJSONObject(String)

        public var description: String {
            switch self {
            case .noJSONObject(let raw):
                let preview = raw.prefix(200)
                return "No JSON object found in model output: \(preview)"
            }
        }
    }

    /// Parse model output into a `Perception`. Throws only when no balanced JSON object can be
    /// located at all — a malformed-but-present object still decodes, because every field has
    /// a lenient default.
    public static func parse(_ raw: String) throws -> Perception {
        guard let json = extractJSONObject(raw) else {
            throw Error.noJSONObject(raw)
        }
        return try PerceptionIO.decode(Data(json.utf8))
    }

    /// Return the first balanced `{ … }` span in `text`, honouring braces inside string
    /// literals (and their escapes) so a `}` inside `notes` does not truncate the object.
    /// Fences and surrounding prose fall away because we scan for the first `{`.
    static func extractJSONObject(_ text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false

        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                continue
            }
            switch c {
            case "\"": inString = true
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(chars[start...i])
                }
            default: break
            }
        }
        return nil   // unbalanced — no complete object
    }
}
