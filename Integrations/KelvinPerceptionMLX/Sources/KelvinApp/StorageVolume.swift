import Foundation
import KelvinCore

/// Whether the photographs someone is editing are on this Mac or across a network.
///
/// Kelvin treated a gigabit SMB share exactly like an internal SSD, which is the root of every
/// "it's slow or non-responsive over my NAS" report: the same eagerness, the same per-file passes,
/// the same silence about why any of it is taking a moment. The difference is not bandwidth but
/// **latency** — a share answers a file open in milliseconds rather than microseconds, and opening a
/// shoot asks a few thousand times.
///
/// Nothing in here changes what Kelvin computes. It changes how much it is willing to do
/// speculatively, and it gives the status line something honest to say.
enum StorageVolume {

    /// Whether `url` lives on a volume that is not physically attached to this Mac.
    ///
    /// `volumeIsLocalKey` covers the cases that matter together — SMB, AFP and NFS mounts all report
    /// false — where checking for a specific filesystem type would need a list nobody can keep
    /// current. An external USB disk reports *local*, correctly: it is slower than the internal SSD
    /// but by a factor, not by a round trip, and the adaptations here would buy nothing.
    ///
    /// iCloud Drive and other file providers report local, which is the one wrong answer this gives.
    /// A dataless file materialises on first read and behaves like a very slow local disk; treating
    /// that as a network volume would be the more useful lie, but `volumeIsLocalKey` is not how you
    /// detect it and guessing from the path (`~/Library/Mobile Documents`) is the kind of cleverness
    /// that breaks on the next OS. Left as a known gap rather than papered over.
    static func isNetwork(_ url: URL) -> Bool {
        let volume = volumeIdentifier(for: url)
        if let known = cache.withLock({ $0[volume] }) { return known }
        // A FRESH URL, never the one the caller handed in. Foundation caches resource values on the
        // URL object, and `AppState` passes one URL around for as long as a photograph is open —
        // the same trap `PerceptionStore.contentHint` documents, and the reason that function uses
        // `FileManager` instead. Volume-ness does not change under a file the way size does, so this
        // is belt and braces rather than a live bug.
        let probe = URL(fileURLWithPath: url.standardizedFileURL.path)
        let answer = (try? probe.resourceValues(forKeys: [.volumeIsLocalKey]))
            .flatMap(\.volumeIsLocal)
            .map { !$0 } ?? false
        cache.withLock { $0[volume] = answer }
        return answer
    }

    /// Which volume a path is on, as a cache key.
    ///
    /// The check is one `statfs` and the answer is a property of the volume rather than the file, so
    /// asking per frame across a 437-photo shoot would be 437 syscalls for one bit. Keyed on the
    /// volume rather than the folder so a second shoot on the same share is free.
    private static func volumeIdentifier(for url: URL) -> String {
        let probe = URL(fileURLWithPath: url.standardizedFileURL.path)
        if let values = try? probe.resourceValues(forKeys: [.volumeURLKey]),
           let volume = values.volume {
            return volume.standardizedFileURL.path
        }
        // No volume URL means the path does not resolve — a deleted file, or a share that has just
        // gone away. Key on the first path component so the miss is at least stable.
        return "/" + (url.standardizedFileURL.pathComponents.dropFirst().first ?? "")
    }

    private static let cache = Mutex<[String: Bool]>([:])
}

/// A lock around a value, because `StorageVolume`'s cache is read from every detached task that
/// touches a file and Swift 6 will not let a mutable `static var` be shared without one.
///
/// Hand-rolled rather than `os_unfair_lock` or Foundation's `NSLock` subclassing dance because CI
/// builds against an older SDK than this Mac does (see `docs/DECISIONS.md` on the Swift divergence)
/// and `Synchronization.Mutex` is not available there. `NSLock` is available everywhere and this is
/// a handful of bits guarded a few dozen times a session.
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
