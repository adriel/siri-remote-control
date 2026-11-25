import XCTest
@testable import RemoteCore

final class RemoteSleepTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    // MARK: Policy

    func testDaytimeWindow() {
        let policy = SleepPolicy(dayStartHour: 5, dayEndHour: 18)
        XCTAssertFalse(policy.isDaytime(date(10, 4, 59), calendar: calendar))
        XCTAssertTrue(policy.isDaytime(date(10, 5), calendar: calendar))
        XCTAssertTrue(policy.isDaytime(date(10, 17, 59), calendar: calendar))
        XCTAssertFalse(policy.isDaytime(date(10, 18), calendar: calendar))
    }

    func testDaytimeWindowCanWrapPastMidnight() {
        let policy = SleepPolicy(dayStartHour: 22, dayEndHour: 6)
        XCTAssertTrue(policy.isDaytime(date(10, 23), calendar: calendar))
        XCTAssertTrue(policy.isDaytime(date(10, 2), calendar: calendar))
        XCTAssertFalse(policy.isDaytime(date(10, 12), calendar: calendar))
    }

    func testIdle() {
        let policy = SleepPolicy(idleInterval: 3600)
        XCTAssertFalse(policy.isIdle(lastActivity: date(10, 20), now: date(10, 20, 59)))
        XCTAssertTrue(policy.isIdle(lastActivity: date(10, 20), now: date(10, 21)))
        var off = policy
        off.idleEnabled = false
        XCTAssertFalse(off.isIdle(lastActivity: date(10, 20), now: date(11, 20)))
    }

    func testDropsOnMorningWakeOnlyWithoutNewerActivity() {
        let policy = SleepPolicy()
        // Used last night, Mac woke at 7am: drop.
        XCTAssertTrue(policy.shouldDropOnWake(at: date(11, 7), lastActivity: date(10, 23), calendar: calendar))
        // Mac woke at 9pm: leave it.
        XCTAssertFalse(policy.shouldDropOnWake(at: date(11, 21), lastActivity: date(10, 23), calendar: calendar))
        // Woke before 5am: leave it (the idle timer still applies).
        XCTAssertFalse(policy.shouldDropOnWake(at: date(11, 4), lastActivity: date(10, 23), calendar: calendar))
        var off = policy
        off.dropOnDaytimeWake = false
        XCTAssertFalse(off.shouldDropOnWake(at: date(11, 7), lastActivity: date(10, 23), calendar: calendar))
    }

    // MARK: Log

    func testLogBeginsAndEndsPeriods() {
        var log = SleepLog()
        log.begin(at: date(10, 7), reason: "idle", level: 80)
        XCTAssertEqual(log.current?.start, date(10, 7))
        log.end(at: date(10, 19), level: nil)
        XCTAssertNil(log.current)
        XCTAssertTrue(log.noteReading(level: 79, at: date(10, 19, 1)))
        XCTAssertFalse(log.noteReading(level: 78, at: date(10, 19, 2))) // already filled
        XCTAssertEqual(log.periods.first?.used, 1)
    }

    func testReadingLongAfterWakeIsNotUsed() {
        var log = SleepLog()
        log.begin(at: date(10, 7), reason: "idle", level: 80)
        log.end(at: date(10, 19), level: nil)
        XCTAssertFalse(log.noteReading(level: 70, at: date(10, 20)))
        XCTAssertNil(log.periods.first?.used)
    }

    func testBeginClosesAnOpenPeriod() {
        var log = SleepLog()
        log.begin(at: date(10, 7), reason: "idle", level: 80)
        log.begin(at: date(10, 9), reason: "idle", level: 79)
        XCTAssertEqual(log.periods.count, 2)
        XCTAssertEqual(log.periods[0].end, date(10, 9))
    }

    // MARK: Comparison

    func testSplitsDrainBetweenAsleepAndConnected() {
        var history = BatteryHistory()
        // Connected 18:00–24:00 using 6 points, then asleep 00:00–12:00 (no readings) using 1.
        history.record(level: 90, at: date(10, 18))
        history.record(level: 87, at: date(10, 21))
        history.record(level: 84, at: date(11, 0))
        history.record(level: 83, at: date(11, 12))
        var log = SleepLog()
        log.begin(at: date(11, 0), reason: "idle", level: 84)
        log.end(at: date(11, 12), level: 83)

        let c = DrainComparison.compute(history: history, sleep: log, since: date(10, 18), now: date(11, 12))
        XCTAssertEqual(c.sleepCount, 1)
        XCTAssertEqual(c.asleepHours, 12, accuracy: 0.01)
        XCTAssertEqual(c.asleepUsed, 1, accuracy: 0.01)
        XCTAssertEqual(c.connectedHours, 6, accuracy: 0.01)
        XCTAssertEqual(c.connectedUsed, 6, accuracy: 0.01)
        XCTAssertEqual(c.asleepPerDay ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(c.connectedPerDay ?? 0, 24, accuracy: 0.01)
    }

    func testSkipsChargingAndLongUnexplainedGaps() {
        var history = BatteryHistory()
        history.record(level: 10, at: date(10, 8))
        history.record(level: 100, at: date(10, 9))   // charged
        history.record(level: 99, at: date(10, 10))
        history.record(level: 95, at: date(11, 10))   // a day's gap with no sleep period: Mac was off
        let c = DrainComparison.compute(history: history, sleep: SleepLog(), since: date(10, 8), now: date(11, 10))
        XCTAssertEqual(c.connectedHours, 1, accuracy: 0.01) // the charging hour is skipped too
        XCTAssertEqual(c.connectedUsed, 1, accuracy: 0.01)
        XCTAssertNil(c.asleepPerDay)
    }
}
