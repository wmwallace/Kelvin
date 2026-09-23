import Foundation

/// A photograph whose bytes are in iCloud rather than on this Mac.
///
/// With "Optimize Mac Storage" on, macOS evicts files from an iCloud-synced folder — Desktop and
/// Documents are the common case — and leaves a *dataless* placeholder: the right name, the right
/// size, no contents. The first read of any byte blocks until the whole file has come back down.
/// Measured on the owner's Mac, 23 September 2026: one byte of an evicted 60 MB Sony RAW took
/// **42.4 s**, and 8 of the 49 frames in the shoot being edited were evicted.
///
/// That wait is harmless where somebody asked for it and ruinous anywhere else. Kelvin's decode
/// lane is serial (see `Offload`), and a read-ahead decode that stumbled on an evicted neighbour
/// held it for the length of the download: the photograph actually opened "waited 50.5 s behind 2
/// others, then ran 1.62 s". So the rule is that only work somebody is waiting on — opening a
/// photograph, exporting one — ever downloads, and it does so through `materialise` BEFORE it
/// takes a decode slot. Everything speculative asks `isEvicted` and leaves the file where it is,
/// because macOS evicted it for want of disk space and pulling a whole shoot back behind the
/// user's back would fight the system for the same space.
public enum CloudFile {

    /// Whether `url` is a dataless placeholder. One `lstat`; never triggers a download.
    public static func isEvicted(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_DATALESS) != 0
    }

    public struct DownloadFailed: LocalizedError {
        public let name: String
        public init(name: String) { self.name = name }
        public var errorDescription: String? {
            "\(name) is in iCloud and could not be downloaded. Check your connection and try again."
        }
    }

    /// Bring an evicted file's bytes down, blocking until they are here. A no-op for a file that is
    /// already local. BLOCKING — call it on a lane, never on the cooperative pool (D21).
    ///
    /// Reading one byte is the whole mechanism: the kernel materialises the entire file before the
    /// read returns, through whichever file provider owns it. Nothing iCloud-specific is asked for,
    /// so there is no entitlement to hold and no API that only works inside a ubiquity container.
    public static func materialise(_ url: URL) throws {
        guard isEvicted(url) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            _ = try handle.read(upToCount: 1)
        } catch {
            throw DownloadFailed(name: url.lastPathComponent)
        }
        if isEvicted(url) { throw DownloadFailed(name: url.lastPathComponent) }
    }
}
