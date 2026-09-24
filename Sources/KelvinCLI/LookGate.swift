import Foundation

/// The release gate on what a look does to real photographs (`kelvin-cli look-gate`).
///
/// Every visible defect found on 23–24 September 2026 — flat red firelit faces, a blown tulip sky, a
/// cyan lake, a crunchy lavender field — was a render the corpus could not see: a per-channel clip on
/// a few percent of a frame is a small ΔE to a reference. `look-audit` measures that damage directly;
/// this compares two of its runs over the same frames and fails when a look that a photographer
/// would SEE — the one a photograph opens in, or one the picker shows — got worse. The frames are the
/// owner's own, listed outside the repository (their paths do not belong in a public one), which is
/// why this is a release step and not a CI job.
enum LookGate {

    /// How much worse is worse. Percentages of the frame (or of the face), added over the camera's
    /// own render — the `…New` measures `look-audit` writes. Small enough to catch a new flat-red
    /// patch on a face, large enough that sampling noise on a proxy does not trip it.
    struct Tolerance {
        var flatNew = 0.005        // one-channel-flat pixels the look added
        var clipNew = 0.02         // clipped pixels the look added
        var faceFlat = 0.05        // share of a face gone one-channel flat
    }

    struct Row: Hashable {
        let path: String
        let look: String
    }

    struct Reading {
        let opener: Bool
        let shown: Bool
        let flatNew: Double
        let clipNew: Double
        let faceFlat: Double?
    }

    static func load(_ url: URL) throws -> [Row: Reading] {
        var out: [Row: Reading] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  o["ablate"] == nil,
                  let path = o["path"] as? String, let look = o["look"] as? String else { continue }
            let clip = (o["clip"] as? Double) ?? 0, clipSource = (o["clipSource"] as? Double) ?? 0
            out[Row(path: path, look: look)] = Reading(
                opener: (o["opener"] as? Bool) ?? false,
                shown: (o["curated"] as? Bool) ?? false,
                flatNew: (o["flatNew"] as? Double) ?? 0,
                clipNew: max(0, clip - clipSource),
                faceFlat: (o["faceFlat"] as? Double).map { $0 - ((o["faceFlatSource"] as? Double) ?? 0) })
        }
        return out
    }

    /// Lines describing every regression; empty when the gate passes. Only looks that are seen —
    /// the opener or a shown candidate, in EITHER run — are judged.
    static func regressions(baseline: [Row: Reading], current: [Row: Reading],
                            tolerance t: Tolerance = Tolerance()) -> [String] {
        var out: [String] = []
        for (row, now) in current.sorted(by: { ($0.key.path, $0.key.look) < ($1.key.path, $1.key.look) }) {
            guard let was = baseline[row], now.opener || now.shown || was.opener || was.shown else { continue }
            let name = (row.path as NSString).lastPathComponent + " · " + row.look + (now.opener ? " (opens)" : "")
            if now.flatNew > was.flatNew + t.flatNew {
                out.append(String(format: "%@: flat single-channel %.2f%% → %.2f%%", name, was.flatNew * 100, now.flatNew * 100))
            }
            if now.clipNew > was.clipNew + t.clipNew {
                out.append(String(format: "%@: added clipping %.2f%% → %.2f%%", name, was.clipNew * 100, now.clipNew * 100))
            }
            if let f = now.faceFlat, f > (was.faceFlat ?? 0) + t.faceFlat {
                out.append(String(format: "%@: face gone flat %.1f%% → %.1f%%", name, (was.faceFlat ?? 0) * 100, f * 100))
            }
        }
        return out
    }

    /// Frames the baseline had and the current run lost (evicted, unreadable) — reported, because a
    /// gate that silently judged fewer frames would pass for the wrong reason.
    static func missing(baseline: [Row: Reading], current: [Row: Reading]) -> Set<String> {
        Set(baseline.keys.map(\.path)).subtracting(current.keys.map(\.path))
    }

    static func run(arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let b = value("--baseline"), let c = value("--current") else {
            FileHandle.standardError.write(Data("look-gate requires --baseline <audit.jsonl> --current <audit.jsonl>\n".utf8))
            return 2
        }
        do {
            let baseline = try load(URL(fileURLWithPath: b)), current = try load(URL(fileURLWithPath: c))
            let lost = missing(baseline: baseline, current: current)
            let found = regressions(baseline: baseline, current: current)
            let judged = Set(current.keys.map(\.path)).count
            print("look-gate: \(judged) frames judged, \(current.count) frame/look pairs")
            if !lost.isEmpty {
                print("  ⚠︎ \(lost.count) frame(s) in the baseline were not read this time (evicted or unreadable):")
                for p in lost.sorted() { print("    \((p as NSString).lastPathComponent)") }
            }
            if found.isEmpty {
                print("look-gate: PASS — no seen look got visibly worse")
                return 0
            }
            print("look-gate: FAIL — \(found.count) regression(s):")
            for line in found { print("  ✗ \(line)") }
            return 1
        } catch {
            FileHandle.standardError.write(Data("look-gate: \(error)\n".utf8))
            return 2
        }
    }
}
