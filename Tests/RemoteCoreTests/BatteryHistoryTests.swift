import XCTest
@testable import RemoteCore

final class BatteryHistoryTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testRecordsChangesAndHeartbeatOnly() {
        var h = BatteryHistory()
        XCTAssertTrue(h.record(level: 90, at: date(10, 8)))
        XCTAssertFalse(h.record(level: 90, at: date(10, 8, 10)))  // same level, within heartbeat
        XCTAssertTrue(h.record(level: 89, at: date(10, 8, 12)))   // level changed
        XCTAssertTrue(h.record(level: 89, at: date(10, 8, 45)))   // heartbeat elapsed
        XCTAssertFalse(h.record(level: 70, at: date(10, 8, 30)))  // out of order
        XCTAssertEqual(h.samples.map(\.level), [90, 89, 89])
    }

    func testPrunesOlderThanRetention() {
        var h = BatteryHistory()
        h.record(level: 100, at: date(1, 8))
        h.record(level: 50, at: date(1, 8).addingTimeInterval(BatteryHistory.retention + 60))
        XCTAssertEqual(h.samples.map(\.level), [50])
    }

    func testDaysAreNewestFirstAndSplitAtMidnight() {
        var h = BatteryHistory()
        h.record(level: 80, at: date(14, 22))
        h.record(level: 78, at: date(15, 9))
        h.record(level: 75, at: date(15, 20))
        h.record(level: 74, at: date(16, 7))
        let days = h.days(count: 3, now: date(16, 12), calendar: calendar)
        XCTAssertEqual(days.map(\.start), [date(16, 0), date(15, 0), date(14, 0)])
        XCTAssertEqual(days[1].samples.map(\.level), [78, 75])
        XCTAssertEqual(days[1].startLevel, 80)  // carried in from the 14th
        XCTAssertEqual(days[1].endLevel, 75)
        XCTAssertEqual(days[1].used, 5)
        XCTAssertEqual(days[0].used, 1)
        XCTAssertEqual(days[1].chartSamples.first, BatterySample(date: date(15, 0), level: 80))
    }

    func testChargingCountsSeparatelyAndJitterNetsOut() {
        var h = BatteryHistory()
        h.record(level: 30, at: date(15, 8))
        h.record(level: 28, at: date(15, 9))
        h.record(level: 29, at: date(15, 10))  // jitter
        h.record(level: 27, at: date(15, 11))
        h.record(level: 90, at: date(15, 14))  // charged
        h.record(level: 88, at: date(15, 20))
        let day = h.days(count: 1, now: date(15, 23), calendar: calendar)[0]
        XCTAssertEqual(day.used, 5)     // 30→28 (2), +1 jitter nets to 1, 29→27 (2), 90→88 (2)
        XCTAssertEqual(day.charged, 63)
        XCTAssertEqual(day.lowestLevel, 27)
    }

    func testEmptyDayHasNoReadings() {
        var h = BatteryHistory()
        h.record(level: 60, at: date(13, 12))
        let days = h.days(count: 3, now: date(15, 12), calendar: calendar)
        XCTAssertFalse(days[0].hasReadings)
        XCTAssertNil(days[0].endLevel)
        XCTAssertEqual(days[0].used, 0)
        XCTAssertEqual(days[0].chartSamples, [])
    }

    func testSamplesSincePinsPriorLevelToStart() {
        var h = BatteryHistory()
        h.record(level: 70, at: date(8, 12))
        h.record(level: 65, at: date(12, 12))
        let s = h.samples(since: date(10, 0))
        XCTAssertEqual(s, [BatterySample(date: date(10, 0), level: 70), BatterySample(date: date(12, 12), level: 65)])
    }

    func testCodableRoundTrip() throws {
        var h = BatteryHistory()
        h.record(level: 42, at: date(15, 8))
        let decoded = try JSONDecoder().decode(BatteryHistory.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(decoded, h)
    }
}
