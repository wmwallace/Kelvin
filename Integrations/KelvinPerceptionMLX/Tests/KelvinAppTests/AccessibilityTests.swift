import XCTest
import KelvinCore
@testable import KelvinApp

/// What the app says out loud.
///
/// The whole application had zero accessibility labels while generating an accurate one-sentence
/// description of every photograph and showing it only to people who can see it. These pin the
/// spoken text itself rather than the modifiers — a label that compiles and says "image" is the
/// failure being fixed, so asserting the *content* is the only assertion worth making.
@MainActor
final class AccessibilityTests: XCTestCase {

    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/shoot/\(name)") }

    private func state(with photos: [URL]) -> AppState {
        let s = AppState()
        s.folderPhotos = photos
        return s
    }

    private func verdict(_ concerns: [PhotoTriage.Concern]) -> PhotoTriage.Verdict {
        PhotoTriage.Verdict(
            concerns: concerns,
            focus: FocusMeasure.Reading(acuity: 4, measurable: true),
            statistics: ImageStatistics(
                meanLuma: 0.4, medianLuma: 0.4, blackPoint: 0, shadowLevel: 0.1,
                highlightLevel: 0.9, whitePoint: 1, highlightClip: 0, shadowClip: 0,
                chromaA: 0, chromaB: 0),
            signature: PhotoTriage.Signature(bits: 0, contrast: 10))
    }

    // MARK: A frame, spoken

    /// The filename comes first because it is the frame's identity, and a VoiceOver user hears this
    /// while arrowing through a shoot — whatever distinguishes one frame from the next has to
    /// arrive before the things every frame shares.
    func testAFrameIsNamedBeforeItIsDescribed() {
        let a = url("_DSC0001.ARW")
        let s = state(with: [a])
        XCTAssertTrue(s.spokenDescription(for: a).hasPrefix("_DSC0001.ARW"),
                      "got: \(s.spokenDescription(for: a))")
    }

    /// The decisions already made about a frame are part of what it is. Someone culling by ear
    /// needs to hear that this one is already flagged.
    func testFlagsAndEditsAreSpoken() {
        let a = url("a.ARW"), b = url("b.ARW")
        let s = state(with: [a, b])
        s.flags = [a: .keep, b: .reject]
        s.editedURLs = [a]

        let spokenA = s.spokenDescription(for: a)
        XCTAssertTrue(spokenA.contains("flagged Keep"), "got: \(spokenA)")
        XCTAssertTrue(spokenA.contains("edited"), "got: \(spokenA)")
        XCTAssertTrue(s.spokenDescription(for: b).contains("flagged Reject"))
    }

    /// An automatic judgement that is visible to sighted users and silent to everyone else is half
    /// a feature. The scan's findings use the same words as the tooltip.
    func testTheScansFindingsAreSpoken() {
        let a = url("a.ARW")
        let s = state(with: [a])
        s.triage = [a: verdict([.veryDark])]
        let spoken = s.spokenDescription(for: a)
        XCTAssertTrue(spoken.contains(PhotoTriage.Concern.veryDark.message), "got: \(spoken)")
    }

    /// A frame nobody has read yet says so by omission rather than inventing a description.
    func testAnUnreadFrameIsJustItsName() {
        let a = url("unread.ARW")
        let s = state(with: [a])
        XCTAssertEqual(s.spokenDescription(for: a), "unread.ARW")
    }

    // MARK: The histogram, spoken

    /// **A histogram is pure geometry, so naming it says nothing** — "histogram" tells a VoiceOver
    /// user exactly as much as an unlabelled image does. It has to speak the reading.
    func testTheHistogramSpeaksItsReadingRatherThanItsName() {
        let spoken = HistogramView.spoken(nil)
        XCTAssertFalse(spoken.lowercased().contains("chart"))
        XCTAssertTrue(spoken.contains("no photograph"), "got: \(spoken)")
    }

    /// Where the tones sit, which is the first thing anyone reads a histogram for.
    func testTheHistogramSaysWhereTheTonesSit() throws {
        // A dark frame: the mass belongs in the shadows.
        let dark = try XCTUnwrap(HistogramReader.read(flat(12)))
        XCTAssertTrue(HistogramView.spoken(dark).contains("shadows"),
                      "got: \(HistogramView.spoken(dark))")

        let bright = try XCTUnwrap(HistogramReader.read(flat(238)))
        XCTAssertTrue(HistogramView.spoken(bright).contains("highlights"),
                      "got: \(HistogramView.spoken(bright))")
    }

    /// Clipping is the thing a photographer most needs told, and it is named per channel.
    func testTheHistogramSpeaksClipping() throws {
        let blown = try XCTUnwrap(HistogramReader.read(flat(255)))
        let spoken = HistogramView.spoken(blown)
        XCTAssertTrue(spoken.contains("blown to white"), "got: \(spoken)")

        let clean = try XCTUnwrap(HistogramReader.read(flat(128)))
        XCTAssertTrue(HistogramView.spoken(clean).contains("nothing clipped"),
                      "got: \(HistogramView.spoken(clean))")
    }

    /// A cast is what the colour in the curves means, so it is what the words have to carry.
    func testACastIsSpokenAsChannelsDisagreeing() throws {
        let warm = try XCTUnwrap(HistogramReader.read(flat(r: 220, g: 130, b: 60)))
        let spoken = HistogramView.spoken(warm)
        XCTAssertTrue(spoken.contains("R running brighter than B"), "got: \(spoken)")

        let neutral = try XCTUnwrap(HistogramReader.read(flat(128)))
        XCTAssertTrue(HistogramView.spoken(neutral).contains("channels balanced"),
                      "got: \(HistogramView.spoken(neutral))")
    }

    // MARK: Fixtures

    private func flat(_ v: UInt8) -> CIImage { flat(r: v, g: v, b: v) }

    private func flat(r: UInt8, g: UInt8, b: UInt8, size: Int = 64) -> CIImage {
        let bpr = size * 4
        var px = [UInt8](repeating: 0, count: bpr * size)
        for i in stride(from: 0, to: px.count, by: 4) {
            px[i] = r; px[i + 1] = g; px[i + 2] = b; px[i + 3] = 255
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: bpr, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return CIImage(cgImage: ctx.makeImage()!)
    }
}
