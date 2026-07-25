import Foundation

extension BatchApply {

    /// Where a batch writes its edited copies, and what it does when a name is already taken.
    ///
    /// This type exists because the destination is the only part of batch that can destroy work.
    /// Everything else in the batch path is additive — decode, render, encode — and a bug there
    /// produces an ugly photo. A bug here produces a missing photo, and the photographer finds out
    /// weeks later. So the destination rules live in one small, tested place instead of being
    /// re-derived by each caller (the CLI and the app were each rolling their own, and only one of
    /// them was safe).
    ///
    /// Two invariants, both load-bearing:
    ///
    ///   1. **The originals are never written to.** The destination is refused outright if it is
    ///      the folder the sources came from (CLAUDE.md non-negotiable #3).
    ///   2. **Nothing already in the destination is overwritten unless asked.** See `OnCollision`.
    public struct Destination: Sendable {

        /// What to do when the chosen output name already exists in the destination folder.
        ///
        /// The default is `uniqueSuffix`, and the alternatives are worth spelling out because both
        /// of them lose something:
        ///
        ///   - `overwrite` as a default is the failure mode that loses work. A photographer runs a
        ///     batch, tweaks the look, runs it again into the same folder — and the first set is
        ///     gone with no prompt and no undo. It stays available, but only from an explicit
        ///     "replace what's there" choice.
        ///   - `skip` as a default loses the NEW render instead of the old one, and does it
        ///     silently in the direction the user least expects: they re-ran the batch precisely
        ///     because they changed something, and they would get a folder of stale edits that
        ///     look, from Finder, exactly like fresh ones.
        ///
        /// `uniqueSuffix` is the only policy where nothing the user made disappears. Its cost is
        /// duplicates piling up in the folder, which is visible, obvious, and fixable by deleting
        /// files. The other two costs are invisible and unfixable.
        public enum OnCollision: String, Sendable, CaseIterable {
            /// Write alongside the existing file as `name-2`, `name-3`, … Default.
            case uniqueSuffix
            /// Leave the existing file alone and report the source as skipped. Useful for resuming
            /// an interrupted batch without re-rendering what already landed.
            case skip
            /// Replace the existing file. Only ever from an explicit user choice.
            case overwrite
        }

        /// What a destination decided to do with one source file, before any pixels are rendered.
        /// Separating the decision from the work is what makes the collision policy testable
        /// without a renderer, and lets a caller with its own render loop (the app re-perceives
        /// every frame) reuse these rules instead of reinventing them.
        public enum Plan: Sendable, Equatable {
            case write(URL)
            case skip(existing: URL)
        }

        /// A destination that cannot be used. These are refusals, not failures: they are raised
        /// before a single file is written, so a bad destination costs nothing.
        public enum Problem: Swift.Error, CustomStringConvertible, Equatable {
            /// The destination is the folder a source came from. Writing there could overwrite the
            /// originals — the one thing this app promises never to do.
            case sameAsSource(URL)
            /// Something is already at that path and it is not a folder.
            case notADirectory(URL)
            case createFailed(URL, String)

            public var description: String {
                switch self {
                case .sameAsSource(let url):
                    return "destination \(url.path) is the source folder — "
                        + "batch writes edited copies elsewhere and never touches the originals"
                case .notADirectory(let url):
                    return "destination \(url.path) exists and is not a folder"
                case .createFailed(let url, let why):
                    return "could not create destination \(url.path): \(why)"
                }
            }
        }

        public var directory: URL
        public var onCollision: OnCollision
        public var format: ImageWriter.Format

        public init(directory: URL,
                    onCollision: OnCollision = .uniqueSuffix,
                    format: ImageWriter.Format = .png) {
            self.directory = directory
            self.onCollision = onCollision
            self.format = format
        }

        /// Create the folder if it is missing, and refuse the configurations that could destroy
        /// originals. Call once, before any file is written.
        ///
        /// Creating the folder is deliberate: a photographer typing a new folder name into a save
        /// panel, or a script pointing at `~/Exports/2026-07-24/`, expects it to appear. Only the
        /// leaf is unusual; `withIntermediateDirectories` covers the rest.
        public func prepare(sources: [URL]) throws {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: directory.path, isDirectory: &isDir) {
                guard isDir.boolValue else { throw Problem.notADirectory(directory) }
            } else {
                do {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    throw Problem.createFailed(directory, "\(error)")
                }
            }

            // Checked AFTER the folder exists, on purpose: the identity check below is far more
            // reliable when both paths resolve to something real, and if the destination is the
            // source folder then it already existed and nothing was created.
            for source in sources where Destination.isSameDirectory(directory, source.deletingLastPathComponent()) {
                throw Problem.sameAsSource(directory)
            }
        }

        /// Decide where `source` should be written, honouring the collision policy.
        ///
        /// The name comes from `ExportNaming`, so a batch and a single export name files the same
        /// way: original stem first (that is how the edit maps back to the frame on the card),
        /// then what was understood about the photo. A batch that renamed files differently from
        /// the export panel would be two conventions in one folder.
        public func plan(for source: URL, perception: Perception? = nil, look: String? = nil) -> Plan {
            let stem = ExportNaming.stem(for: source, perception: perception, look: look)
            let ext = format.fileExtension
            let direct = directory.appendingPathComponent(stem).appendingPathExtension(ext)
            guard FileManager.default.fileExists(atPath: direct.path) else { return .write(direct) }
            switch onCollision {
            case .overwrite:    return .write(direct)
            case .skip:         return .skip(existing: direct)
            case .uniqueSuffix: return .write(ExportNaming.uniqueURL(in: directory, stem: stem, ext: ext))
            }
        }

        /// Are these two paths the same folder on disk?
        ///
        /// String comparison is not enough and the difference is not academic. `/tmp/shoot` and
        /// `/private/tmp/shoot` are the same folder on macOS (a symlinked root); so are
        /// `~/Shoot` and `~/shoot` on a case-insensitive volume, and so is any folder reached
        /// through a symlink or a `..`. Every one of those spellings, compared as text, reads as a
        /// *different* folder and would sail straight past the guard into overwriting originals.
        ///
        /// So identity comes from the filesystem — `fileResourceIdentifier` is unique per file for
        /// as long as the URL is held — and text comparison is only the fallback for paths that do
        /// not exist, where there is nothing to ask.
        ///
        /// Symlinks are resolved BEFORE asking for the identifier, and that order was measured, not
        /// assumed: `fileResourceIdentifier` describes the *link*, not its target, so a destination
        /// pointed at a symlink to the source folder came back as a different file and the first
        /// version of this guard waved it through — a batch then wrote into the source folder.
        static func isSameDirectory(_ a: URL, _ b: URL) -> Bool {
            let ra = a.resolvingSymlinksInPath().standardizedFileURL
            let rb = b.resolvingSymlinksInPath().standardizedFileURL
            let idA = try? ra.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
            let idB = try? rb.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
            if let idA, let idB { return idA.isEqual(idB) }
            return ra.path == rb.path
        }
    }
}
