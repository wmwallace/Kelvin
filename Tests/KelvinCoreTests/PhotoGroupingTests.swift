import XCTest
import ImageIO
@testable import KelvinCore

/// Grouping a shoot for culling: by day, by burst, by place.
///
/// The properties that matter are the same three every time — the groups partition the input (no
/// frame lost, none duplicated), the residue of frames that cannot be grouped goes last, and the
/// answer does not depend on the order the filesystem handed the folder over in.
final class PhotoGroupingTests: XCTestCase {

    private typealias Group = PhotoOrder.PhotoGroup

    private let dir = URL(fileURLWithPath: "/shoot", isDirectory: true)
    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }

    /// UTC, not the host's zone: a day-boundary test that passes in London and fails in Auckland
    /// is not a test.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        let components = DateComponents(year: 2026, month: 7, day: day,
                                        hour: hour, minute: minute, second: second)
        return utc.date(from: components) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Groups reduced to what a reader can check at a glance: the filenames in each, in order.
    private func shape(_ groups: [Group]) -> [[String]] {
        groups.map { $0.urls.map { $0.lastPathComponent } }
    }

    // MARK: - By day

    func testADayIsAGroup() {
        let morning = url("a.ARW"), evening = url("b.ARW"), nextDay = url("c.ARW")
        let dates = [morning: date(4, 9), evening: date(4, 19), nextDay: date(5, 10)]

        let groups = PhotoOrder.groupedByDay([nextDay, evening, morning], captureDates: dates,
                                             calendar: utc)
        XCTAssertEqual(shape(groups), [["a.ARW", "b.ARW"], ["c.ARW"]])
        XCTAssertEqual(groups.first?.start, date(4, 9))
        XCTAssertEqual(groups.first?.end, date(4, 19))
    }

    /// A shoot that runs past midnight becomes two days. That is what a calendar day *is* — worth
    /// pinning so the behaviour is a recorded choice rather than something discovered at a wedding.
    func testAShootPastMidnightSplitsAtMidnight() {
        let lastDance = url("a.ARW"), afterMidnight = url("b.ARW")
        let dates = [lastDance: date(4, 23, 55), afterMidnight: date(5, 0, 5)]

        let groups = PhotoOrder.groupedByDay([lastDance, afterMidnight], captureDates: dates,
                                             calendar: utc)
        XCTAssertEqual(groups.count, 2, "ten minutes apart, but two calendar days")
    }

    /// Reversed means newest first — days *and* the frames inside them, so the head of the strip
    /// is the last thing that happened.
    func testReversedDayGroupingReadsNewestFirst() {
        let a = url("a.ARW"), b = url("b.ARW"), c = url("c.ARW")
        let dates = [a: date(4, 9), b: date(4, 19), c: date(5, 10)]

        let groups = PhotoOrder.groupedByDay([a, b, c], captureDates: dates, calendar: utc,
                                             reversed: true)
        XCTAssertEqual(shape(groups), [["c.ARW"], ["b.ARW", "a.ARW"]])
    }

    /// Same policy `sorted` applies to undated files, and for the same reason: "newest first" must
    /// not answer with a pile of frames that have no date at all.
    func testUndatedFramesAreTheLastGroupInBothDirections() {
        let shot = url("_DSC1.ARW"), scan = url("scan-2.tif"), export = url("export-1.jpg")
        let dates = [shot: date(4, 9)]

        for reversed in [false, true] {
            let groups = PhotoOrder.groupedByDay([scan, export, shot], captureDates: dates,
                                                 calendar: utc, reversed: reversed)
            XCTAssertEqual(shape(groups), [["_DSC1.ARW"], ["export-1.jpg", "scan-2.tif"]],
                           "reversed: \(reversed)")
            XCTAssertEqual(groups.last?.isResidue, true)
            XCTAssertNil(groups.last?.start, "a residue group has no place on a timeline")
        }
    }

    /// The count on screen has to equal the count in the folder. A grouping that quietly drops the
    /// frames it could not place would be the worst kind of wrong: invisible.
    func testEveryFrameLandsInExactlyOneDayGroup() {
        let frames = (1...9).map { url("_DSC\($0).ARW") }
        var dates: [URL: Date] = [:]
        for (index, frame) in frames.enumerated() where index % 3 != 0 {
            dates[frame] = date(4 + index / 4, 9 + index)
        }

        let grouped = PhotoOrder.groupedByDay(frames, captureDates: dates, calendar: utc)
            .flatMap { $0.urls }
        XCTAssertEqual(grouped.count, frames.count)
        XCTAssertEqual(Set(grouped), Set(frames))
    }

    func testDayGroupingIsDeterministicUnderShuffling() {
        let frames = (1...8).map { url("_DSC\($0).ARW") }
        var dates: [URL: Date] = [:]
        for (index, frame) in frames.enumerated() where index != 3 {
            dates[frame] = date(4 + index % 2, 12)      // two days, several frames sharing a stamp
        }

        let expected = PhotoOrder.groupedByDay(frames, captureDates: dates, calendar: utc)
        for _ in 0..<20 {
            let again = PhotoOrder.groupedByDay(frames.shuffled(), captureDates: dates, calendar: utc)
            XCTAssertEqual(shape(again), shape(expected))
            XCTAssertEqual(again.map { $0.id }, expected.map { $0.id },
                           "ids identify content, so they must be stable too")
        }
    }

    // MARK: - Bursts

    /// What a burst is for: six frames of one pose, then the photographer lowers the camera.
    func testABurstEndsWhenTheShootingStops() {
        let run = [url("_DSC1.ARW"), url("_DSC2.ARW"), url("_DSC3.ARW")]
        let later = url("_DSC4.ARW")
        var dates = [later: at(60)]
        for (index, frame) in run.enumerated() { dates[frame] = at(Double(index)) }

        let groups = PhotoOrder.groupedIntoBursts(run + [later], captureDates: dates)
        XCTAssertEqual(shape(groups), [["_DSC1.ARW", "_DSC2.ARW", "_DSC3.ARW"], ["_DSC4.ARW"]])
        XCTAssertEqual(groups.first?.duration, 2)
    }

    /// "Within N seconds" includes exactly N. At EXIF's one-second resolution the boundary is a
    /// case that occurs constantly, not a pedantic one.
    func testTheGapBoundaryIsInclusive() {
        let a = url("a.ARW"), b = url("b.ARW")

        let onTheBoundary = PhotoOrder.groupedIntoBursts(
            [a, b], captureDates: [a: at(0), b: at(PhotoOrder.burstGap)])
        XCTAssertEqual(onTheBoundary.count, 1, "exactly the gap is still the same burst")

        let justPast = PhotoOrder.groupedIntoBursts(
            [a, b], captureDates: [a: at(0), b: at(PhotoOrder.burstGap + 1)])
        XCTAssertEqual(justPast.count, 2)
    }

    /// A burst written by a camera is *mostly* identical timestamps — EXIF resolves to the second,
    /// so ten frames at 10 fps share one. They are one burst, in filename order.
    func testIdenticalTimestampsAreOneBurst() {
        let frames = (1...6).map { url("_DSC\($0).ARW") }
        var dates: [URL: Date] = [:]
        for frame in frames { dates[frame] = at(42) }

        let groups = PhotoOrder.groupedIntoBursts(frames.shuffled(), captureDates: dates)
        XCTAssertEqual(shape(groups), [frames.map { $0.lastPathComponent }])
        XCTAssertEqual(groups.first?.duration, 0, "one EXIF second is all the file recorded")
    }

    /// Reversing the strip reverses the shoot. It must not change *which* frames are in a burst
    /// together — that is a fact about the shoot, not about how it is being read.
    func testReversingDoesNotChangeBurstMembership() {
        let first = [url("a.ARW"), url("b.ARW")], second = [url("c.ARW"), url("d.ARW")]
        let dates = [first[0]: at(0), first[1]: at(1), second[0]: at(30), second[1]: at(31)]

        let forwards = PhotoOrder.groupedIntoBursts(first + second, captureDates: dates)
        let backwards = PhotoOrder.groupedIntoBursts(first + second, captureDates: dates,
                                                     reversed: true)
        XCTAssertEqual(shape(forwards), [["a.ARW", "b.ARW"], ["c.ARW", "d.ARW"]])
        XCTAssertEqual(shape(backwards), [["d.ARW", "c.ARW"], ["b.ARW", "a.ARW"]])
        XCTAssertEqual(Set(forwards.map { Set($0.urls) }), Set(backwards.map { Set($0.urls) }))
    }

    /// A frame with no timestamp cannot be near another one in time. Guessing it into the nearest
    /// burst would be inventing the one fact it is missing.
    func testUndatedFramesCannotBeInABurst() {
        let shot = url("_DSC1.ARW"), scan = url("scan.tif")
        let groups = PhotoOrder.groupedIntoBursts([scan, shot], captureDates: [shot: at(0)])
        XCTAssertEqual(shape(groups), [["_DSC1.ARW"], ["scan.tif"]])
        XCTAssertEqual(groups.last?.isResidue, true)
    }

    func testBurstGroupingIsDeterministicUnderShuffling() {
        // Two bursts, one loose frame, one undated — and every frame inside a burst sharing a
        // timestamp, which is the case where a non-total comparator would show itself.
        let burstA = (1...4).map { url("_DSC\($0).ARW") }
        let burstB = (5...7).map { url("_DSC\($0).ARW") }
        let loose = url("_DSC8.ARW"), undated = url("scan.tif")
        var dates: [URL: Date] = [loose: at(500)]
        for frame in burstA { dates[frame] = at(10) }
        for frame in burstB { dates[frame] = at(200) }

        let all = burstA + burstB + [loose, undated]
        let expected = PhotoOrder.groupedIntoBursts(all, captureDates: dates)
        XCTAssertEqual(expected.count, 4)
        for _ in 0..<20 {
            XCTAssertEqual(shape(PhotoOrder.groupedIntoBursts(all.shuffled(), captureDates: dates)),
                           shape(expected))
        }
    }

    // MARK: - By location

    private func place(_ lat: Double, _ lon: Double) -> GeoPoint {
        GeoPoint(latitude: lat, longitude: lon)
    }

    /// The radius has to be big enough that GPS jitter never splits one spot, and small enough that
    /// two venues stay apart. 150 m apart is one place; 5 km is not.
    func testOnePlaceIsOneGroupAndAnotherPlaceIsAnother() {
        let a = url("a.ARW"), b = url("b.ARW"), away = url("c.ARW")
        let locations = [a: place(51.5074, -0.1278),
                         b: place(51.5087, -0.1278),         // ~145 m north
                         away: place(51.5500, -0.1278)]      // ~4.7 km north
        let dates = [a: at(0), b: at(10), away: at(20)]

        let groups = PhotoOrder.groupedByLocation([away, b, a], locations: locations,
                                                  captureDates: dates)
        XCTAssertEqual(shape(groups), [["a.ARW", "b.ARW"], ["c.ARW"]])
        XCTAssertEqual(groups.first?.anchor, locations[a], "the first frame at a place anchors it")
    }

    /// Two frames either side of the date line, 222 m apart. Under any implementation that
    /// subtracts longitudes flat they are 40 000 km apart and land in different groups — the bug
    /// nobody notices until someone shoots in Fiji.
    func testTheAntiMeridianDoesNotSplitAPlace() {
        let east = url("east.ARW"), west = url("west.ARW")
        let locations = [east: place(-16.5, 179.999), west: place(-16.5, -179.999)]

        let groups = PhotoOrder.groupedByLocation([east, west], locations: locations)
        XCTAssertEqual(groups.count, 1, "222 m apart, not most of the way round the world")
    }

    /// Proximity is measured on the globe, not in degrees. The same 0.004° of longitude is 445 m at
    /// the equator and 222 m at 60°N, so it straddles the radius — one splits, the other does not.
    /// A grouping that compared degrees would answer the same in both places and be wrong in one.
    func testProximityFollowsTheGlobeNotTheDegrees() {
        let a = url("a.ARW"), b = url("b.ARW")

        let equator = PhotoOrder.groupedByLocation(
            [a, b], locations: [a: place(0, 36.8219), b: place(0, 36.8259)])
        XCTAssertEqual(equator.count, 2, "445 m apart on the equator is two places")

        let north = PhotoOrder.groupedByLocation(
            [a, b], locations: [a: place(60, 10.7), b: place(60, 10.704)])
        XCTAssertEqual(north.count, 1, "the same degrees at 60°N are 222 m — one place")
    }

    /// Mixed geotagging is the normal state of a real folder: a phone frame among a card of files
    /// from a body with no receiver. The ones without a fix are the residue, never assigned to the
    /// nearest place.
    func testFramesWithoutAFixAreTheResidueGroup() {
        let tagged = url("phone.HEIC"), untagged1 = url("_DSC1.ARW"), untagged2 = url("_DSC2.ARW")
        let groups = PhotoOrder.groupedByLocation(
            [untagged2, tagged, untagged1],
            locations: [tagged: place(51.5074, -0.1278)],
            captureDates: [tagged: at(0), untagged1: at(10), untagged2: at(20)])

        XCTAssertEqual(shape(groups), [["phone.HEIC"], ["_DSC1.ARW", "_DSC2.ARW"]])
        XCTAssertEqual(groups.last?.isResidue, true)
        XCTAssertNil(groups.last?.anchor)
    }

    /// A folder where nothing has GPS — most folders — is one group holding everything, not an
    /// empty result and not an error. The residue stays last even though its frames are the only
    /// ones with dates, because a bucket of "could not place these" is not the head of a strip.
    func testAFolderWithNoGPSAtAllIsOneResidueGroup() {
        let frames = (1...4).map { url("_DSC\($0).ARW") }
        var dates: [URL: Date] = [:]
        for (index, frame) in frames.enumerated() { dates[frame] = at(Double(index)) }

        let groups = PhotoOrder.groupedByLocation(frames, locations: [:], captureDates: dates)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.isResidue, true)
        XCTAssertEqual(groups.first?.count, 4)
    }

    /// Why the clustering anchors instead of merging transitively. Four frames 200 m apart in a
    /// line: every frame is within the radius of the one before it, so single-link would chain the
    /// whole 600 m walk into one "place". Anchoring bounds a group at twice the radius, so a group
    /// stays somewhere you could stand.
    func testAWalkDoesNotChainIntoOnePlace() {
        let frames = (1...4).map { url("_DSC\($0).ARW") }
        var locations: [URL: GeoPoint] = [:]
        var dates: [URL: Date] = [:]
        for (index, frame) in frames.enumerated() {
            locations[frame] = place(0, 0.0018 * Double(index))     // ~200 m steps at the equator
            dates[frame] = at(Double(index) * 60)
        }

        let groups = PhotoOrder.groupedByLocation(frames, locations: locations, captureDates: dates)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(shape(groups), [["_DSC1.ARW", "_DSC2.ARW"], ["_DSC3.ARW", "_DSC4.ARW"]])
    }

    /// Which frame becomes an anchor decides the groups, so it cannot depend on the order the
    /// filesystem listed the folder in. Identical timestamps are included deliberately: they are
    /// the case where the ordering falls through to the filename tie-break.
    func testLocationGroupingIsDeterministicUnderShuffling() {
        let harbour = (1...3).map { url("_DSC\($0).ARW") }
        let headland = (4...6).map { url("_DSC\($0).ARW") }
        let untagged = url("scan.tif")
        var locations: [URL: GeoPoint] = [:]
        var dates: [URL: Date] = [untagged: at(0)]
        for frame in harbour {
            locations[frame] = place(50.1, -5.5)
            dates[frame] = at(100)                      // one shared EXIF second
        }
        for frame in headland {
            locations[frame] = place(50.12, -5.5)       // ~2.2 km away
            dates[frame] = at(100)
        }

        let all = harbour + headland + [untagged]
        let expected = PhotoOrder.groupedByLocation(all, locations: locations, captureDates: dates)
        XCTAssertEqual(expected.count, 3)
        for _ in 0..<20 {
            let again = PhotoOrder.groupedByLocation(all.shuffled(), locations: locations,
                                                     captureDates: dates)
            XCTAssertEqual(shape(again), shape(expected))
            XCTAssertEqual(again.map { $0.anchor }, expected.map { $0.anchor })
            XCTAssertEqual(again.map { $0.id }, expected.map { $0.id })
        }
    }

    /// Grouping by place still reads as a shoot: earliest first.
    func testLocationGroupsAreOrderedByWhenYouWereThere() {
        let second = url("b.ARW"), first = url("a.ARW")
        let locations = [first: place(48.8584, 2.2945), second: place(48.8606, 2.3376)]
        let dates = [first: at(0), second: at(3_600)]

        let groups = PhotoOrder.groupedByLocation([second, first], locations: locations,
                                                  captureDates: dates)
        XCTAssertEqual(shape(groups), [["a.ARW"], ["b.ARW"]])
    }

    // MARK: - Shared properties

    func testEmptyInputIsNoGroups() {
        XCTAssertTrue(PhotoOrder.groupedByDay([], captureDates: [:]).isEmpty)
        XCTAssertTrue(PhotoOrder.groupedIntoBursts([], captureDates: [:]).isEmpty)
        XCTAssertTrue(PhotoOrder.groupedByLocation([], locations: [:]).isEmpty)
    }

    /// The browser's single entry point. Worth pinning because a mis-wired case here would look
    /// exactly like the grouping itself being wrong.
    func testTheGroupKeyDispatchesToTheMatchingGrouping() {
        let a = url("a.ARW"), b = url("b.ARW")
        let index = PhotoOrder.CaptureIndex(dates: [a: at(0), b: at(600)],
                                            locations: [a: place(51.5, -0.12)])

        XCTAssertEqual(
            shape(PhotoOrder.grouped([a, b], by: .day, index: index, calendar: utc)),
            shape(PhotoOrder.groupedByDay([a, b], captureDates: index.dates, calendar: utc)))
        XCTAssertEqual(
            shape(PhotoOrder.grouped([a, b], by: .burst, index: index)),
            shape(PhotoOrder.groupedIntoBursts([a, b], captureDates: index.dates)))
        XCTAssertEqual(
            shape(PhotoOrder.grouped([a, b], by: .location, index: index)),
            shape(PhotoOrder.groupedByLocation([a, b], locations: index.locations,
                                               captureDates: index.dates)))
        XCTAssertTrue(index.hasAnyLocation)
        XCTAssertFalse(PhotoOrder.CaptureIndex(dates: index.dates).hasAnyLocation,
                       "a folder with no fixes anywhere is where the location lens is pointless")
    }

    /// Reading the folder. Dates and positions come out of one header read per file, because
    /// opening every file twice to fetch them separately would double the slowest part of opening
    /// a shoot. Both are absent when the file did not record them — never zero, never epoch.
    func testCaptureIndexReadsDatesAndPositionsInOnePass() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kelvin-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let placed = dir.appendingPathComponent("placed.jpg")
        let bare = dir.appendingPathComponent("bare.jpg")
        // A whole second: EXIF's `DateTimeOriginal` has no finer resolution to round-trip.
        let capturedAt = Date(timeIntervalSince1970: 1_780_000_000)
        try TestSupport.writeJPEG(to: placed, captured: capturedAt, gps: [
            kCGImagePropertyGPSLatitude: 51.5074, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 0.1278, kCGImagePropertyGPSLongitudeRef: "W"
        ])
        try TestSupport.writeJPEG(to: bare)

        let index = PhotoOrder.captureIndex(for: [placed, bare,
                                                  dir.appendingPathComponent("missing.jpg")])
        XCTAssertEqual(index.dates[placed], capturedAt)
        XCTAssertEqual(index.locations[placed]?.latitude ?? 0, 51.5074, accuracy: 1e-4)
        XCTAssertNil(index.dates[bare])
        XCTAssertNil(index.locations[bare], "no fix is an absence, not a zero")
        XCTAssertEqual(index.dates.count, 1, "an unreadable file is skipped, never a crash")

        XCTAssertEqual(PhotoOrder.captureDates(for: [placed, bare]), index.dates,
                       "the dates-only reader must agree with the one-pass index")
    }

    /// The group comparator is **total**, and the shuffle tests above cannot show that.
    ///
    /// Measured: making `compareGroups` return `.orderedSame` for two distinct groups breaks none
    /// of them, because Swift's `sorted(by:)` is stable in practice at these sizes. It is not
    /// documented as stable, which is the same reason `compareFilenames` carries a path tie-break
    /// and has its own direct test. So the property is asserted on the comparator itself: no two
    /// distinct groups compare equal, and swapping the arguments flips the answer.
    func testGroupComparatorIsTotal() {
        let dates = [url("a.ARW"): at(100), url("b.ARW"): at(100), url("c.ARW"): at(100)]
        let here = place(50.1, -5.5), there = place(50.2, -5.5)

        // One group per tie-break the comparator has to reach: the same instant at two places, the
        // same instant at the same place, groups with no dates at all, and the residue.
        let groups = [
            Group(kind: .location, urls: [url("a.ARW")], captureDates: dates, anchor: here),
            Group(kind: .location, urls: [url("b.ARW")], captureDates: dates, anchor: there),
            Group(kind: .location, urls: [url("c.ARW")], captureDates: dates, anchor: here),
            Group(kind: .location, urls: [url("d.ARW")], captureDates: [:], anchor: here),
            Group(kind: .location, urls: [url("e.ARW")], captureDates: [:]),
            Group(kind: .location, urls: [url("f.ARW")], captureDates: dates, isResidue: true)
        ]

        for (i, a) in groups.enumerated() {
            XCTAssertEqual(PhotoOrder.compareGroups(a, a), .orderedSame, "a group equals itself")
            for b in groups[(i + 1)...] {
                let forwards = PhotoOrder.compareGroups(a, b)
                XCTAssertNotEqual(forwards, .orderedSame, "\(a.id) vs \(b.id) must be ordered")
                let backwards = PhotoOrder.compareGroups(b, a)
                XCTAssertEqual(forwards == .orderedAscending, backwards == .orderedDescending,
                               "\(a.id) vs \(b.id) is not antisymmetric")
            }
        }
    }

    /// No group is ever empty — a heading with nothing under it is a bug the UI would render.
    func testNoGroupIsEmpty() {
        let frames = (1...5).map { url("_DSC\($0).ARW") }
        var dates: [URL: Date] = [:]
        var locations: [URL: GeoPoint] = [:]
        for (index, frame) in frames.enumerated() where index != 2 {
            dates[frame] = at(Double(index) * 100)
            locations[frame] = place(Double(index) * 0.5, 1)
        }

        let everything = PhotoOrder.groupedByDay(frames, captureDates: dates, calendar: utc)
            + PhotoOrder.groupedIntoBursts(frames, captureDates: dates)
            + PhotoOrder.groupedByLocation(frames, locations: locations, captureDates: dates)
        XCTAssertFalse(everything.isEmpty)
        for group in everything { XCTAssertFalse(group.urls.isEmpty, group.id) }
    }
}
