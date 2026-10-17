import Foundation

public struct BatterySample: Codable, Equatable, Sendable {
    public var date: Date
    public var level: Int

    public init(date: Date, level: Int) {
        self.date = date
        self.level = level
    }
}

/// Battery readings over time. A reading is kept when the level changes, and otherwise at most every
/// `heartbeat`, so flat stretches still show up without storing a sample every couple of minutes.
public struct BatteryHistory: Codable, Equatable, Sendable {
    public private(set) var samples: [BatterySample]

    /// A little over a month, so the 30-day view always has a reading from before its first day.
    public static let retention: TimeInterval = 35 * 86_400
    public static let heartbeat: TimeInterval = 30 * 60

    public init(samples: [BatterySample] = []) {
        self.samples = samples.sorted { $0.date < $1.date }
    }

    /// Returns true if the reading was stored.
    @discardableResult
    public mutating func record(level: Int, at date: Date) -> Bool {
        let level = min(max(level, 0), 100)
        if let last = samples.last {
            guard date > last.date else { return false }
            if last.level == level, date.timeIntervalSince(last.date) < Self.heartbeat { return false }
        }
        samples.append(BatterySample(date: date, level: level))
        prune(now: date)
        return true
    }

    public mutating func prune(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.date) > Self.retention }
    }

    /// The last `count` calendar days ending today, newest first.
    public func days(count: Int, now: Date, calendar: Calendar = .current) -> [BatteryDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).compactMap { offset -> BatteryDay? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let inDay = samples.filter { $0.date >= start && $0.date < end }
            let before = samples.last { $0.date < start }
            return BatteryDay(start: start, end: end, samples: inDay, carriedIn: before)
        }
    }

    /// Samples from `start` on, plus the one just before it so a chart's line reaches its left edge.
    public func samples(since start: Date) -> [BatterySample] {
        var result = samples.filter { $0.date >= start }
        if let before = samples.last(where: { $0.date < start }) {
            result.insert(BatterySample(date: start, level: before.level), at: 0)
        }
        return result
    }
}

/// One calendar day of battery readings.
public struct BatteryDay: Identifiable, Equatable, Sendable {
    public let start: Date
    public let end: Date
    /// Readings taken during the day.
    public let samples: [BatterySample]
    /// The last reading before the day began: the level the day started at.
    public let carriedIn: BatterySample?

    public var id: Date { start }
    public var hasReadings: Bool { !samples.isEmpty }

    /// A rise smaller than this is sensor jitter, not a charge.
    public static let chargeThreshold = 3

    public var startLevel: Int? { carriedIn?.level ?? samples.first?.level }
    public var endLevel: Int? { samples.last?.level }
    public var lowestLevel: Int? { samples.map(\.level).min() }

    /// Percentage points used during the day. Jitter that bounces back up is netted out.
    public var used: Int { tally.used }
    /// Percentage points gained from charging.
    public var charged: Int { tally.charged }

    /// The day's readings with the carried-in level pinned to midnight, for charting.
    public var chartSamples: [BatterySample] {
        guard let carriedIn, hasReadings else { return samples }
        return [BatterySample(date: start, level: carriedIn.level)] + samples
    }

    private var tally: (used: Int, charged: Int) {
        let levels = (carriedIn.map { [$0] } ?? []) + samples
        var used = 0
        var charged = 0
        for (a, b) in zip(levels, levels.dropFirst()) {
            let delta = b.level - a.level
            if delta < 0 {
                used -= delta
            } else if delta >= Self.chargeThreshold {
                charged += delta
            } else {
                used = max(0, used - delta)
            }
        }
        return (used, charged)
    }
}
