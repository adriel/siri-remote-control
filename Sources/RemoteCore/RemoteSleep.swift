import Foundation

/// When the app should drop the remote's Bluetooth link to save its battery.
public struct SleepPolicy: Equatable, Sendable {
    /// Drop the link after this long without a button press or touch.
    public var idleEnabled: Bool
    public var idleInterval: TimeInterval
    /// When the Mac wakes during the day, drop the link straight away. The Mac's own sleep stops the idle
    /// timer, so this covers waking up in the morning after the remote was last used the night before.
    public var dropOnDaytimeWake: Bool
    /// Daytime runs from `dayStartHour`:00 up to `dayEndHour`:00, local time.
    public var dayStartHour: Int
    public var dayEndHour: Int

    public init(idleEnabled: Bool = true, idleInterval: TimeInterval = 3600, dropOnDaytimeWake: Bool = true, dayStartHour: Int = 5, dayEndHour: Int = 18) {
        self.idleEnabled = idleEnabled
        self.idleInterval = idleInterval
        self.dropOnDaytimeWake = dropOnDaytimeWake
        self.dayStartHour = dayStartHour
        self.dayEndHour = dayEndHour
    }

    public func isDaytime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if dayStartHour == dayEndHour { return true }
        if dayStartHour < dayEndHour { return hour >= dayStartHour && hour < dayEndHour }
        return hour >= dayStartHour || hour < dayEndHour // wraps past midnight
    }

    public func isIdle(lastActivity: Date, now: Date) -> Bool {
        idleEnabled && now.timeIntervalSince(lastActivity) >= idleInterval
    }

    /// Whether a Mac wake at `wake` should drop the link, given the last button press or touch.
    public func shouldDropOnWake(at wake: Date, lastActivity: Date, calendar: Calendar = .current) -> Bool {
        dropOnDaytimeWake && isDaytime(wake, calendar: calendar) && lastActivity < wake
    }
}

/// One stretch with the remote's link dropped.
public struct SleepPeriod: Codable, Equatable, Sendable, Identifiable {
    public var start: Date
    /// nil while the remote is still asleep.
    public var end: Date?
    public var reason: String
    /// Battery level just before the link was dropped, and the first reading after it came back.
    public var levelAtStart: Int?
    public var levelAtEnd: Int?

    public var id: Date { start }

    public init(start: Date, end: Date? = nil, reason: String, levelAtStart: Int? = nil, levelAtEnd: Int? = nil) {
        self.start = start
        self.end = end
        self.reason = reason
        self.levelAtStart = levelAtStart
        self.levelAtEnd = levelAtEnd
    }

    public func duration(now: Date) -> TimeInterval { (end ?? now).timeIntervalSince(start) }

    /// Percentage points used while asleep, once both ends are known.
    public var used: Int? {
        guard let levelAtStart, let levelAtEnd, levelAtEnd <= levelAtStart else { return nil }
        return levelAtStart - levelAtEnd
    }
}

/// Every time the app dropped the remote's link, kept for as long as the battery history.
public struct SleepLog: Codable, Equatable, Sendable {
    public private(set) var periods: [SleepPeriod]

    public init(periods: [SleepPeriod] = []) {
        self.periods = periods.sorted { $0.start < $1.start }
    }

    public var current: SleepPeriod? { periods.last.flatMap { $0.end == nil ? $0 : nil } }

    public mutating func begin(at date: Date, reason: String, level: Int?) {
        end(at: date, level: nil)
        periods.append(SleepPeriod(start: date, reason: reason, levelAtStart: level))
        periods.removeAll { date.timeIntervalSince($0.start) > BatteryHistory.retention }
    }

    public mutating func end(at date: Date, level: Int?) {
        guard let index = periods.indices.last, periods[index].end == nil else { return }
        periods[index].end = max(date, periods[index].start)
        periods[index].levelAtEnd = level
    }

    /// Fills in the level for the most recent wake, from the first reading after the remote came back.
    /// Returns true if it changed anything.
    @discardableResult
    public mutating func noteReading(level: Int, at date: Date, within window: TimeInterval = 600) -> Bool {
        guard let index = periods.indices.last, let end = periods[index].end, periods[index].levelAtEnd == nil,
              date >= end, date.timeIntervalSince(end) <= window else { return false }
        periods[index].levelAtEnd = level
        return true
    }
}

/// Battery use with the link dropped versus connected, to see whether dropping it helps.
public struct DrainComparison: Equatable, Sendable {
    public var asleepHours: Double = 0
    public var asleepUsed: Double = 0
    public var connectedHours: Double = 0
    public var connectedUsed: Double = 0
    public var sleepCount = 0

    /// Percentage points per 24 hours, nil until there's enough time to say.
    public var asleepPerDay: Double? { asleepHours >= 1 ? asleepUsed / asleepHours * 24 : nil }
    public var connectedPerDay: Double? { connectedHours >= 1 ? connectedUsed / connectedHours * 24 : nil }

    /// Gaps longer than this between readings (Mac asleep, app not running) don't count as connected time.
    public static let maxGap: TimeInterval = 3 * 3600

    /// Splits the battery used since `since` between time asleep and time connected. Each step between two
    /// readings is shared out in proportion to how much of it the remote spent asleep. Charging is skipped.
    public static func compute(history: BatteryHistory, sleep: SleepLog, since: Date, now: Date) -> DrainComparison {
        var result = DrainComparison()
        let periods = sleep.periods.filter { ($0.end ?? now) > since }
        result.sleepCount = periods.count
        let samples = history.samples(since: since)
        for (a, b) in zip(samples, samples.dropFirst()) {
            let span = b.date.timeIntervalSince(a.date)
            guard span > 0 else { continue }
            let delta = b.level - a.level
            if delta >= BatteryDay.chargeThreshold { continue }
            let used = Double(max(0, -delta))
            let asleep = periods.reduce(0.0) { total, period in
                let start = max(period.start, a.date)
                let end = min(period.end ?? now, b.date)
                return total + max(0, end.timeIntervalSince(start))
            }
            // A long gap with no sleep period means the Mac was off or asleep: the remote's state is unknown.
            if asleep == 0, span > maxGap { continue }
            let connected = span - asleep
            result.asleepHours += asleep / 3600
            result.asleepUsed += used * asleep / span
            result.connectedHours += connected / 3600
            result.connectedUsed += used * connected / span
        }
        return result
    }
}
