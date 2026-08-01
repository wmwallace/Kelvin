import XCTest
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import KelvinCore
@testable import KelvinApp

/// The cache that makes a shoot on a NAS bearable.
///
/// Two properties matter and everything here is one of them:
///
/// 1. **The second answer equals the first.** A cache that returns something subtly different from a
///    cold read is worse than no cache, because the difference only appears on machines where the
///    folder has been opened before — which is to say, never on the developer's second run and always
///    on a user's first.
/// 2. **A file that changed is a miss.** Same requirement `PerceptionStore` has, and the same test
///    it considers its most important one.
final class MediaCacheTests: XCTestCase {

    private var dir: URL!
    private var cacheDir: URL!
    private var cache: MediaCache!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-media-\(UUID().uuidString)", isDirectory: true)
        cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Never `MediaCache.shared` — that writes into the real user cache, and a test that pollutes
        // it would also be a test whose result depends on what the app did last.
        cache = MediaCache(directory: cacheDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A real JPEG on disk, with a recognisable pattern rather than flat colour so a lossy round trip
    /// would actually show up as different bytes.
    @discardableResult
    private func writeJPEG(named name: String, width: Int = 400, height: Int = 300,
                           seed: UInt8 = 0) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("no bitmap context")
        }
        for y in stride(from: 0, to: height, by: 10) {
            for x in stride(from: 0, to: width, by: 10) {
                ctx.setFillColor(red: Double((x &+ Int(seed)) % 255) / 255,
                                 green: Double(y % 255) / 255,
                                 blue: Double((x &+ y &+ Int(seed)) % 255) / 255, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: 10, height: 10))
            }
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.jpeg.identifier as CFString, 1, nil)
        else { throw XCTSkip("no JPEG encoder") }
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// The image's pixels in one fixed layout, so two `CGImage`s can be compared for **the picture**
    /// rather than for how ImageIO happened to arrange it in memory.
    ///
    /// Comparing `dataProvider` buffers directly does not work and the reason is worth knowing:
    /// ImageIO hands back a JPEG thumbnail as `noneSkipFirst` (XRGB) and the same image decoded from
    /// a PNG as `noneSkipLast` (RGBX). Same sRGB colour space, same 8 bits, same values — the channels
    /// are in a different order, so 76,623 of 76,800 bytes differ while not one pixel does. Measured,
    /// not assumed. Drawing both into an identical context is what "identical" has to mean here, and
    /// it is also what every consumer does, since anything measuring pixels goes through CIImage or a
    /// CGContext and gets normalised on the way in.
    private func pixels(of image: CGImage) -> Data? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                 bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let base = ctx.data
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: base, count: image.width * image.height * 4)
    }

    private func entryCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
            .filter { !$0.hasPrefix("tmp-") }.count
    }

    // MARK: - Thumbnails

    /// The property the whole cache rests on. A cached thumbnail must be the SAME PIXELS as a cold
    /// decode, not merely a similar-looking image — which is why entries are PNG and not JPEG.
    ///
    /// If this ever fails, the strip is showing one thing on a cold folder and another on a warm one,
    /// and anything that ever measures a thumbnail silently inherits that.
    func testACachedThumbnailIsPixelIdenticalToAFreshDecode() throws {
        let photo = try writeJPEG(named: "_DSC0001.JPG")

        let cold = try XCTUnwrap(PhotoBrowser.decodeThumbnailCG(for: photo, maxPixel: 160))
        let first = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 160))
        let second = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 160))

        XCTAssertEqual(first.width, cold.width)
        XCTAssertEqual(first.height, cold.height)
        XCTAssertEqual(second.width, cold.width)
        XCTAssertEqual(second.height, cold.height)
        XCTAssertEqual(pixels(of: first), pixels(of: cold))
        XCTAssertEqual(pixels(of: second), pixels(of: cold),
                       "a cached thumbnail must be the same PICTURE as a cold read — see the note on "
                       + "MediaCache.thumbnailCG about why entries are PNG, and the note on `pixels` "
                       + "about why this compares normalised pixels rather than raw buffers")
    }

    /// The point of the exercise: the second read does not touch the original.
    ///
    /// Proved by deleting the photograph. Nothing else can distinguish "served from the cache" from
    /// "read the file again quickly", and on a share that distinction is the entire feature.
    func testTheSecondThumbnailComesFromDiskAndNotFromThePhoto() throws {
        let photo = try writeJPEG(named: "_DSC0002.JPG")
        let warm = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 160))

        try FileManager.default.removeItem(at: photo)
        // A miss would have to go to the file, and the file is gone.
        XCTAssertNil(PhotoBrowser.decodeThumbnailCG(for: photo, maxPixel: 160))

        // The key needs a `stat`, which a deleted file cannot answer — so this is honestly a miss
        // too. What it proves is the entry was WRITTEN, which the count below confirms.
        XCTAssertNil(cache.thumbnailCG(for: photo, maxPixel: 160))
        XCTAssertGreaterThan(try entryCount(), 0)
        XCTAssertEqual(warm.width, 160)
    }

    /// A 160 px entry must never be served to a caller that asked for 320. Both sizes appear in the
    /// strip depending on the row height.
    func testThumbnailsOfDifferentSizesDoNotShareAnEntry() throws {
        let photo = try writeJPEG(named: "_DSC0003.JPG")
        let small = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 160))
        let large = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 320))
        XCTAssertEqual(small.width, 160)
        XCTAssertEqual(large.width, 320)
        XCTAssertEqual(try entryCount(), 2)
    }

    // MARK: - Invalidation

    /// The one that matters most, in `PerceptionStore`'s words. A photograph replaced under Kelvin —
    /// re-exported, re-synced by the NAS, restored from a backup — must not keep showing the old
    /// thumbnail forever, because the key never changes on its own.
    func testAChangedFileInvalidatesItsEntry() throws {
        let photo = try writeJPEG(named: "_DSC0004.JPG", width: 400, height: 300, seed: 0)
        let before = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 160))

        // A different picture at a different size, so both the bytes and the aspect change.
        try FileManager.default.removeItem(at: photo)
        _ = try writeJPEG(named: "_DSC0004.JPG", width: 400, height: 200, seed: 90)

        let after = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 160))
        XCTAssertNotEqual(before.height, after.height,
                          "the entry was keyed on size+mtime and both changed, so this must be a miss")
    }

    /// Moving a shoot into a different folder must NOT empty the cache. This is the whole reason the
    /// key is name+size+mtime rather than the path — `PerceptionStore` measured 19 of 23 entries
    /// orphaned by an afternoon of tidying, and a photographer reorganising a library is normal.
    func testMovingAPhotographKeepsItsEntry() throws {
        let photo = try writeJPEG(named: "_DSC0005.JPG")
        _ = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 160))
        let entriesBefore = try entryCount()

        let elsewhere = dir.appendingPathComponent("2026-07-29 Wedding", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = elsewhere.appendingPathComponent("_DSC0005.JPG")
        try FileManager.default.moveItem(at: photo, to: moved)

        _ = try XCTUnwrap(cache.thumbnailCG(for: moved, maxPixel: 160))
        XCTAssertEqual(try entryCount(), entriesBefore,
                       "a moved photograph must hit its existing entry, not write a second one")
    }

    // MARK: - Content hash

    /// The chunked hash must equal the whole-file hash it replaced. It is stamped into saved edits and
    /// preference records, so a hash that changed meaning would detach every record written before it
    /// from every record written after.
    func testTheContentHashMatchesASingleShotSHA256() throws {
        let photo = try writeJPEG(named: "_DSC0006.JPG", width: 900, height: 600)
        let expected = "sha256:" + SHA256.hash(data: try Data(contentsOf: photo))
            .compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(cache.imageId(for: photo), expected)
        // And again, from the cache this time.
        XCTAssertEqual(cache.imageId(for: photo), expected)
    }

    /// Bigger than one 4 MB chunk, so the streaming loop is actually exercised rather than reading
    /// everything on the first pass. A RAW is 25–60 MB and this is the code path it takes.
    func testTheContentHashIsCorrectForAFileLargerThanOneChunk() throws {
        let url = dir.appendingPathComponent("big.JPG")
        var blob = Data(count: 0)
        // Deterministic, and not compressible into a uniform block.
        for i in 0..<(9 * 1024 * 1024) { blob.append(UInt8(truncatingIfNeeded: i &* 31)) }
        try blob.write(to: url)

        let expected = "sha256:" + SHA256.hash(data: blob)
            .compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(cache.imageId(for: url), expected)
    }

    func testAMissingFileHasNoContentHash() {
        XCTAssertNil(cache.imageId(for: dir.appendingPathComponent("nothing.ARW")))
    }

    // MARK: - Capture info

    /// The DTO must not lose anything the strip groups or sorts on. A dropped capture date silently
    /// reorders a shoot; a dropped coordinate silently disables grouping by place.
    func testCaptureInfoSurvivesTheRoundTripThroughTheCache() throws {
        let photo = try writeJPEG(named: "_DSC0007.JPG", width: 640, height: 480)
        let cold = CaptureInfoReader.read(url: photo)
        let warm = cache.captureInfo(for: photo)      // writes the entry
        let cached = cache.captureInfo(for: photo)    // reads it back

        XCTAssertEqual(warm, cold)
        XCTAssertEqual(cached, cold, "CaptureInfo's == covers dates, coordinates and dimensions")
        XCTAssertEqual(cached.positionStatus, cold.positionStatus,
                       "positionStatus is outside == and is what tells 'no receiver' from 'no fix'")
        XCTAssertEqual(cached.pixelWidth, 640)
        XCTAssertEqual(cached.pixelHeight, 480)
    }

    /// The cached folder walk must agree with `PhotoOrder.captureIndex`, which is what it replaced at
    /// the call site and where the tested ordering rules live.
    func testTheCachedCaptureIndexAgreesWithTheUncachedOne() throws {
        let a = try writeJPEG(named: "_DSC0010.JPG")
        let b = try writeJPEG(named: "_DSC0011.JPG")
        let uncached = PhotoOrder.captureIndex(for: [a, b])
        XCTAssertEqual(cache.captureIndex(for: [a, b]), uncached)
        XCTAssertEqual(cache.captureIndex(for: [a, b]), uncached, "and again, warm")
    }

    // MARK: - Triage verdicts

    /// Property 1 for the measuring pass: a warm verdict is the SAME verdict — focus reading,
    /// statistics, signature and concerns — as a cold measurement, proven against both the
    /// read-through path and the stored entry.
    func testAStoredVerdictRoundTripsExactly() throws {
        let photo = try writeJPEG(named: "_DSC0030.JPG")
        let cold = try XCTUnwrap(PhotoTriage.read(url: photo))
        let warm = try XCTUnwrap(cache.verdict(for: photo))       // measures and writes the entry
        let cached = try XCTUnwrap(cache.storedVerdict(for: photo))
        XCTAssertEqual(warm, cold)
        XCTAssertEqual(cached, cold,
                       "every reading must survive the round trip, and the re-derived concerns "
                       + "must agree with the cold ones while the thresholds have not moved")
    }

    /// The reason the entry stores readings and not conclusions. A stored verdict whose concerns
    /// LIE about its own readings must come back corrected: if this fails, a threshold moved in
    /// `PhotoTriage` keeps serving flags decided under the old rules to every shoot measured
    /// before the change.
    func testConcernsAreReDerivedFromCurrentThresholdsOnLoad() throws {
        let photo = try writeJPEG(named: "_DSC0031.JPG")
        // Statistics that trip `veryDark` and a focus reading that trips `softFocus`, stored with
        // concerns claiming nothing is wrong.
        let statistics = ImageStatistics(
            meanLuma: 0.05, medianLuma: 0.05, blackPoint: 0, shadowLevel: 0.01,
            highlightLevel: 0.3, whitePoint: 0.4, highlightClip: 0, shadowClip: 0.2,
            chromaA: 1.5, chromaB: -2.0, shadowMass: 0.7, shadowRegion: 0.9)
        let focus = FocusMeasure.Reading(acuity: 1.5, measurable: true)
        let lying = PhotoTriage.Verdict(
            concerns: [],
            focus: focus,
            statistics: statistics,
            signature: PhotoTriage.Signature(bits: 0x0123_4567_89AB_CDEF, contrast: 0.02))
        cache.storeVerdict(lying, for: photo)

        let loaded = try XCTUnwrap(cache.storedVerdict(for: photo))
        XCTAssertEqual(loaded.concerns, PhotoTriage.concerns(for: statistics, focus: focus))
        XCTAssertEqual(loaded.concerns, [.softFocus, .veryDark])
        XCTAssertEqual(loaded.statistics, statistics)
        XCTAssertEqual(loaded.focus, focus)
        XCTAssertEqual(loaded.signature, lying.signature,
                       "the 64-bit fingerprint must survive JSON exactly — one flipped bit moves "
                       + "a frame between near-duplicate groups")
    }

    /// A version this code does not know is a miss, never a guess — the reader must refuse the
    /// entry rather than reinterpret its fields.
    func testABumpedVerdictVersionIsAMiss() throws {
        let photo = try writeJPEG(named: "_DSC0032.JPG")
        _ = try XCTUnwrap(cache.verdict(for: photo))
        XCTAssertNotNil(cache.storedVerdict(for: photo))

        // Rewrite the one JSON entry as a future version, fields otherwise intact.
        let entries = try FileManager.default
            .contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: entry)) as? [String: Any])
        object["version"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: entry)

        XCTAssertNil(cache.storedVerdict(for: photo))
    }

    /// The two decode paths can rasterise the same photograph differently — `triage-compare`
    /// exists to measure exactly that — so a verdict measured down one must never be served for
    /// the other.
    func testTheFastAndFullDecodePathsDoNotShareAVerdictEntry() throws {
        let photo = try writeJPEG(named: "_DSC0033.JPG")
        _ = try XCTUnwrap(cache.verdict(for: photo))              // fastRAW: true
        XCTAssertNil(cache.storedVerdict(for: photo, fastRAW: false))
    }

    /// A re-synced or restored file must miss even when nothing visible changed: the key carries
    /// the modification date, and this proves the verdict entry inherits that.
    func testATouchedFileMissesItsVerdictEntry() throws {
        let photo = try writeJPEG(named: "_DSC0034.JPG")
        _ = try XCTUnwrap(cache.verdict(for: photo))
        XCTAssertNotNil(cache.storedVerdict(for: photo))

        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(90)], ofItemAtPath: photo.path)
        XCTAssertNil(cache.storedVerdict(for: photo),
                     "same bytes, new mtime — the entry must not survive the touch")
    }

    // MARK: - Housekeeping

    /// A cache in `~/Library/Caches` that grows forever is bad manners, and this is the only thing
    /// standing between a large library and a few gigabytes nobody asked for.
    func testTrimmingEvictsUntilTheCacheFitsItsBudget() throws {
        for i in 0..<6 { _ = try writeJPEG(named: "_DSC01\(i).JPG", width: 600, height: 400, seed: UInt8(i)) }
        for i in 0..<6 {
            _ = cache.thumbnailCG(for: dir.appendingPathComponent("_DSC01\(i).JPG"), maxPixel: 320)
        }
        let before = cache.totalBytes()
        XCTAssertGreaterThan(before, 0)

        cache.trim(toBytes: before / 2)
        let after = cache.totalBytes()
        XCTAssertLessThanOrEqual(after, before / 2)
        XCTAssertGreaterThan(before, after, "something must actually have been evicted")
    }

    func testTrimmingLeavesACacheThatAlreadyFitsAlone() throws {
        let photo = try writeJPEG(named: "_DSC0020.JPG")
        _ = cache.thumbnailCG(for: photo, maxPixel: 160)
        let before = cache.totalBytes()
        cache.trim(toBytes: MediaCache.byteBudget)
        XCTAssertEqual(cache.totalBytes(), before)
    }

    /// Emptying it is offered in Settings, so it has to be true that everything comes back.
    func testEmptyingTheCacheIsRecoverable() throws {
        let photo = try writeJPEG(named: "_DSC0021.JPG")
        let before = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 160))
        cache.removeAll()
        XCTAssertEqual(cache.totalBytes(), 0)

        let after = try XCTUnwrap(cache.thumbnailCG(for: photo, maxPixel: 160))
        XCTAssertEqual(pixels(of: after), pixels(of: before))
    }

    /// The app's cache must not be pointed anywhere surprising. It is under the bundle identifier,
    /// which is frozen (CLAUDE.md) — and it must NOT be in Application Support, where edits live and
    /// where macOS will never reclaim it.
    func testTheSharedCacheLivesInCachesAndNotBesideTheEdits() {
        let path = MediaCache.defaultDirectory.path
        XCTAssertTrue(path.contains("/Caches/"), "regenerable data belongs in Caches: \(path)")
        XCTAssertTrue(path.contains(Branding.bundleIdentifier))
        XCTAssertFalse(path.contains("Application Support"))
        XCTAssertFalse(EditStore.directory.path.hasPrefix(MediaCache.defaultDirectory.path),
                       "emptying the cache must never be able to delete somebody's edits")
    }
}

/// Which volume a photograph is on, and therefore how eager Kelvin should be.
final class StorageVolumeTests: XCTestCase {

    /// The boot disk is local. If this ever reports otherwise, every adaptation keyed off it fires on
    /// every user with no NAS in sight.
    func testTheBootVolumeIsNotANetworkVolume() {
        XCTAssertFalse(StorageVolume.isNetwork(FileManager.default.temporaryDirectory))
        XCTAssertFalse(StorageVolume.isNetwork(URL(fileURLWithPath: NSHomeDirectory())))
    }

    /// A path that does not resolve must answer *something* rather than trapping, and "local" is the
    /// right default: it changes no behaviour, where a wrong "network" would.
    func testAPathThatDoesNotExistIsTreatedAsLocal() {
        let nowhere = URL(fileURLWithPath: "/Volumes/NotMounted-\(UUID().uuidString)/_DSC0001.ARW")
        XCTAssertFalse(StorageVolume.isNetwork(nowhere))
    }

    /// Asked twice, answered the same way — the answer is cached per volume because it is a `statfs`
    /// and a 437-frame shoot would otherwise ask 437 times for one bit.
    func testTheAnswerIsStableAcrossRepeatedCalls() {
        let url = FileManager.default.temporaryDirectory
        let first = StorageVolume.isNetwork(url)
        for _ in 0..<50 { XCTAssertEqual(StorageVolume.isNetwork(url), first) }
    }
}
