import XCTest
@testable import FITHealthCore

final class FITParserTests: XCTestCase {
    func testSessionAndHeartRate() throws {
        var parser = FITParser(data: fixture())
        let activity = try parser.parse()
        XCTAssertEqual(activity.sport, 2)
        XCTAssertEqual(activity.distance, 12500)
        XCTAssertEqual(activity.calories, 320)
        XCTAssertEqual(activity.duration, 1800)
        XCTAssertEqual(activity.elapsed, 1800)
        XCTAssertEqual(activity.end.timeIntervalSince(activity.start), 1800)
        XCTAssertEqual(activity.start.timeIntervalSince1970, 1_731_065_600)
        XCTAssertEqual(activity.heartRates.map(\.bpm), [130, 140])
        XCTAssertTrue(activity.locations.isEmpty)
    }

    func testBigEndianDefinitions() throws {
        var parser = FITParser(data: fixture(bigEndian: true))
        let activity = try parser.parse()
        XCTAssertEqual(activity.distance, 12500)
        XCTAssertEqual(activity.calories, 320)
    }

    func testCompressedTimestampRolloverAndDeveloperFields() throws {
        var payload = definition(local: 0, global: 20, fields: [(253, 4, 0x86), (3, 1, 2)], developerSize: 2)
        payload += [0] + integer(1_100_000_030, 4) + [130, 44, 55]
        payload += [0x80 | 2, 140, 66, 77]
        payload += session()
        var parser = FITParser(data: wrap(payload))
        let activity = try parser.parse()
        XCTAssertEqual(activity.heartRates.count, 2)
        XCTAssertEqual(activity.heartRates[1].date.timeIntervalSince(activity.heartRates[0].date), 4)
    }

    func testInvalidValuesAreNotImported() throws {
        var payload = definition(local: 0, global: 20, fields: [(253, 4, 0x86), (3, 1, 2)])
        payload += [0] + integer(1_100_000_000, 4) + [255]
        payload += session(distance: 0xFFFFFFFF, calories: 0xFFFF)
        var parser = FITParser(data: wrap(payload))
        let activity = try parser.parse()
        XCTAssertNil(activity.distance)
        XCTAssertNil(activity.calories)
        XCTAssertTrue(activity.heartRates.isEmpty)
    }

    func testCorruptionAndTruncation() {
        var data = fixture()
        data[20] ^= 1
        var parser = FITParser(data: data)
        XCTAssertThrowsError(try parser.parse())
        for count in [0, 10, 13, 30] {
            var parser = FITParser(data: fixture().prefix(count))
            XCTAssertThrowsError(try parser.parse())
        }
    }

    func testRejectsMultipleSessions() {
        var parser = FITParser(data: wrap(session() + session()))
        XCTAssertThrowsError(try parser.parse())
    }

    func testTimerEvents() throws {
        var payload = definition(local: 0, global: 21, fields: [(253, 4, 0x86), (0, 1, 0), (1, 1, 0)])
        payload += [0] + integer(1_100_000_100, 4) + [0, 4]
        payload += [0] + integer(1_100_000_120, 4) + [0, 0]
        payload += session()
        var parser = FITParser(data: wrap(payload))
        XCTAssertEqual(try parser.parse().timerEvents.map(\.paused), [true, false])
    }

    func testElapsedIncludesRest() throws {
        var parser = FITParser(data: wrap(session(elapsed: 2_000_000, timer: 1_800_000)))
        let activity = try parser.parse()
        XCTAssertEqual(activity.duration, 1800)
        XCTAssertEqual(activity.elapsed, 2000)
        XCTAssertEqual(activity.end.timeIntervalSince(activity.start), 2000)
    }

    func testGPSEnhancedSpeedAndAltitude() throws {
        let lat = Int32((31.23 / 180.0) * 2_147_483_648.0)
        let lon = Int32((121.47 / 180.0) * 2_147_483_648.0)
        var payload = definition(local: 0, global: 20, fields: [
            (253, 4, 0x86), (0, 4, 0x85), (1, 4, 0x85), (73, 4, 0x86), (2, 2, 0x84)
        ])
        payload += [0] + integer(1_100_000_000, 4) + sint32(lat) + sint32(lon)
        payload += integer(8_333, 4) + integer(2_824, 2)
        payload += session()
        var parser = FITParser(data: wrap(payload))
        let activity = try parser.parse()
        XCTAssertEqual(activity.locations.count, 1)
        XCTAssertEqual(activity.locations[0].latitude, 31.23, accuracy: 0.0001)
        XCTAssertEqual(activity.locations[0].longitude, 121.47, accuracy: 0.0001)
        XCTAssertEqual(activity.samples[0].speed ?? 0, 8.333, accuracy: 0.0001)
        XCTAssertEqual(activity.samples[0].altitude ?? 0, 64.8, accuracy: 0.05)
    }

    func testLaps() throws {
        var payload = definition(local: 0, global: 19, fields: [
            (2, 4, 0x86), (7, 4, 0x86), (8, 4, 0x86), (9, 4, 0x86), (110, 4, 0x86)
        ])
        payload += [0] + integer(1_100_000_000, 4) + integer(300_000, 4) + integer(280_000, 4)
        payload += integer(5_000_00, 4) + integer(5_273, 4)
        payload += session()
        var parser = FITParser(data: wrap(payload))
        let laps = try parser.parse().laps
        XCTAssertEqual(laps.count, 1)
        XCTAssertEqual(laps[0].distance, 5000)
        XCTAssertEqual(laps[0].duration, 280)
        XCTAssertEqual(laps[0].avgSpeed ?? 0, 5.273, accuracy: 0.0001)
    }

    func testIgpsportRideFile() throws {
        let url = URL(fileURLWithPath: "/Users/mianshuang/Downloads/ride-0-2026-09-20-20-19-33.fit")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        var parser = FITParser(data: try Data(contentsOf: url))
        let activity = try parser.parse()
        XCTAssertEqual(activity.sport, 2)
        XCTAssertEqual(activity.subSport, 7)
        XCTAssertEqual(activity.distance ?? 0, 35_570.4, accuracy: 0.1)
        XCTAssertEqual(activity.duration, 6320)
        XCTAssertEqual(activity.elapsed, 9269)
        XCTAssertEqual(activity.calories, 846)
        XCTAssertEqual(activity.avgSpeed ?? 0, 5.628, accuracy: 0.001)
        XCTAssertEqual(activity.maxSpeed ?? 0, 10.197, accuracy: 0.001)
        XCTAssertEqual(activity.ascent, 142)
        XCTAssertEqual(activity.descent, 137)
        XCTAssertGreaterThanOrEqual(activity.locations.count, 6200)
        XCTAssertEqual(activity.laps.count, 8)
        XCTAssertEqual(activity.laps[0].distance ?? 0, 5000, accuracy: 0.1)
        XCTAssertEqual(activity.laps[0].avgSpeed ?? 0, 5.273, accuracy: 0.01)
        XCTAssertFalse(activity.timerEvents.isEmpty)
        XCTAssertTrue(activity.heartRates.isEmpty)
    }

    func testSpeedDownsampleAveragesEveryInterval() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<12).map { index in
            (start.addingTimeInterval(Double(index)), Double(index + 1))
        }
        let reduced = RideSampling.downsample(points, interval: 5)
        XCTAssertEqual(reduced.count, 3)
        XCTAssertEqual(reduced[0].1, 3, accuracy: 0.0001)
        XCTAssertEqual(reduced[1].1, 8, accuracy: 0.0001)
        XCTAssertEqual(reduced[2].1, 11.5, accuracy: 0.0001)
        XCTAssertEqual(reduced[0].0, points[4].0)
        XCTAssertEqual(RideSampling.speedInterval, 5)
    }

    func testPreviewPointsKeepsEndpoints() {
        let points = Array(0..<1_000)
        let reduced = RideSampling.previewPoints(points, maxCount: 720)
        XCTAssertEqual(reduced.count, 720)
        XCTAssertEqual(reduced.first, 0)
        XCTAssertEqual(reduced.last, 999)
        XCTAssertEqual(RideSampling.previewPoints(Array(0..<10)).count, 10)
    }

    func testPersistEstimateGrowsWithGPSAndHasTimeout() {
        let small = RideTiming.persistEstimate(gps: 100, speedSamples: 80, events: 2)
        let large = RideTiming.persistEstimate(gps: 6_299, speedSamples: 6_299, events: 81)
        XCTAssertLessThan(small, large)
        XCTAssertGreaterThanOrEqual(large, 2)
        XCTAssertLessThanOrEqual(RideTiming.persistTimeout(estimate: large), 90)
        XCTAssertGreaterThanOrEqual(RideTiming.persistTimeout(estimate: large), 25)
        XCTAssertEqual(RideTiming.parseTimeout(estimate: 2), 16)
        XCTAssertEqual(RideTiming.authorizeTimeout, 75)
    }

    func testTimeoutCancelsSlowWork() async {
        do {
            _ = try await withTimeout(0.05) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return 1
            }
            XCTFail("应判定超时")
        } catch let error as RideWaitError {
            XCTAssertEqual(error, .timedOut(0.05))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testRejectsNonCyclingAndIndoor() {
        var parser = FITParser(data: wrap(session(sport: 1)))
        XCTAssertThrowsError(try parser.parse()) { XCTAssertEqual($0 as? FITError, .notOutdoorCycling) }
        parser = FITParser(data: wrap(session(subSport: 6)))
        XCTAssertThrowsError(try parser.parse()) { XCTAssertEqual($0 as? FITError, .notOutdoorCycling) }
    }

    private func fixture(bigEndian: Bool = false) -> Data {
        var payload = definition(local: 0, global: 20, fields: [(253, 4, 0x86), (3, 1, 2)], bigEndian: bigEndian)
        payload += [0] + integer(1_100_000_000, 4, bigEndian) + [130]
        payload += [0] + integer(1_100_000_010, 4, bigEndian) + [140]
        payload += session(bigEndian: bigEndian)
        return wrap(payload)
    }

    private func session(bigEndian: Bool = false, distance: UInt64 = 1_250_000, calories: UInt64 = 320,
                         elapsed: UInt64 = 1_800_000, timer: UInt64 = 1_800_000,
                         sport: UInt8 = 2, subSport: UInt8? = nil) -> [UInt8] {
        var fields: [(UInt8, UInt8, UInt8)] = [(2, 4, 0x86), (5, 1, 0)]
        if subSport != nil { fields.append((6, 1, 0)) }
        fields += [(7, 4, 0x86), (8, 4, 0x86), (9, 4, 0x86), (11, 2, 0x84)]
        var bytes = definition(local: 1, global: 18, fields: fields, bigEndian: bigEndian)
        bytes += [1] + integer(1_100_000_000, 4, bigEndian) + [sport]
        if let subSport { bytes.append(subSport) }
        bytes += integer(elapsed, 4, bigEndian) + integer(timer, 4, bigEndian)
        bytes += integer(distance, 4, bigEndian) + integer(calories, 2, bigEndian)
        return bytes
    }

    private func definition(local: UInt8, global: UInt64, fields: [(UInt8, UInt8, UInt8)], bigEndian: Bool = false, developerSize: UInt8 = 0) -> [UInt8] {
        var bytes: [UInt8] = [0x40 | local | (developerSize > 0 ? 0x20 : 0), 0, bigEndian ? 1 : 0]
        bytes += integer(global, 2, bigEndian) + [UInt8(fields.count)]
        for field in fields { bytes += [field.0, field.1, field.2] }
        if developerSize > 0 { bytes += [1, 0, developerSize, 0] }
        return bytes
    }

    private func integer(_ value: UInt64, _ size: Int, _ bigEndian: Bool = false) -> [UInt8] {
        let bytes = (0..<size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return bigEndian ? bytes.reversed() : bytes
    }

    private func sint32(_ value: Int32, _ bigEndian: Bool = false) -> [UInt8] {
        integer(UInt64(UInt32(bitPattern: value)), 4, bigEndian)
    }

    private func wrap(_ payload: [UInt8]) -> Data {
        var bytes: [UInt8] = [14, 0x20, 0, 0]
        bytes += integer(UInt64(payload.count), 4) + Array(".FIT".utf8)
        bytes += integer(UInt64(FITParser.crc(bytes[...])), 2)
        bytes += payload
        bytes += integer(UInt64(FITParser.crc(bytes[...])), 2)
        return Data(bytes)
    }
}
