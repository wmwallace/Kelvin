import Foundation
import CryptoKit

/// Loading perception JSON and hashing it for provenance. A recipe records the SHA-256 of
/// the exact perception it was generated from (`Provenance.perceptionHash`), so a preference
/// pair can be tied back to the judgment that produced its candidates (docs/RECIPE-SCHEMA.md
/// Stage 3).
public enum PerceptionIO {
    public static func load(from url: URL) throws -> Perception {
        try decode(try Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> Perception {
        try JSONDecoder().decode(Perception.self, from: data)
    }

    /// A stable content hash of a perception value: encode with sorted keys so the digest is
    /// independent of field order, then SHA-256. Prefixed `sha256:` to match the schema.
    public static func hash(_ perception: Perception) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(perception) else { return "sha256:unknown" }
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
