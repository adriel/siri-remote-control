import AppKit
import Charts
import RemoteCore
import SwiftUI

/// Chart colours: one series (battery level) in the accent blue, recessive greys for chrome.
enum ChartPalette {
    static let series = dynamic(light: 0x2A78D6, dark: 0x3987E5)
    static let grid = dynamic(light: 0xE1E0D9, dark: 0x2C2C2A)
    static let reference = dynamic(light: 0x898781, dark: 0x898781)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

enum HistoryRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    var id: Int { rawValue }
    var label: String { self == .week ? "Past Week" : "Past Month" }
}

/// Battery history for the Battery tab: a range control, the level chart, and one section per day.
struct BatteryHistorySections: View {
    @EnvironmentObject private var store: BatteryHistoryStore
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("batteryHistoryRange") private var range: HistoryRange = .week

    var body: some View {
        let now = Date()
        let days = store.history.days(count: range.rawValue, now: now)
        let rangeStart = days.last?.start ?? now
        // End at midnight tonight so the last axis label has room and the rest of today reads as "not yet".
        let rangeEnd = days.first?.end ?? now.addingTimeInterval(3600)

        Section {
            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)

            if store.history.samples.isEmpty {
                Text("History starts now. A reading is saved whenever the level changes, and every 30 minutes while the remote is connected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                UsageStats(days: days, currentLevel: store.history.samples.last?.level)
                BatteryLevelChart(
                    samples: store.history.samples(since: rangeStart),
                    domain: rangeStart...rangeEnd,
                    threshold: settings.batteryThreshold,
                    range: range
                )
                .frame(height: 200)
                .padding(.vertical, 4)
            }
        } header: {
            Text("Battery history")
        }

        if !store.history.samples.isEmpty {
            ForEach(DayGroup.make(from: days)) { group in
                Section {
                    switch group {
                    case let .day(day):
                        BatteryDayRow(day: day, threshold: settings.batteryThreshold)
                    case .empty:
                        Text("No readings. The remote was asleep or away, or the app wasn't running.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(group.title(now: now))
                }
            }
        }
    }
}

/// A day with readings gets its own section; a run of empty days shares one.
private enum DayGroup: Identifiable {
    case day(BatteryDay)
    case empty([BatteryDay]) // newest first

    var id: Date {
        switch self {
        case let .day(day): day.start
        case let .empty(days): days[0].start
        }
    }

    static func make(from days: [BatteryDay]) -> [DayGroup] {
        var groups: [DayGroup] = []
        for day in days {
            if day.hasReadings {
                groups.append(.day(day))
            } else if case let .empty(run)? = groups.last {
                groups[groups.count - 1] = .empty(run + [day])
            } else {
                groups.append(.empty([day]))
            }
        }
        return groups
    }

    func title(now: Date) -> String {
        switch self {
        case let .day(day):
            return Self.dayTitle(day.start, now: now)
        case let .empty(days):
            guard days.count > 1, let oldest = days.last else { return Self.dayTitle(days[0].start, now: now) }
            return "\(Self.dayTitle(oldest.start, now: now)) – \(Self.dayTitle(days[0].start, now: now))"
        }
    }

    private static func dayTitle(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }
}

/// Average daily use over the days that have readings, and how long the current charge should last.
private struct UsageStats: View {
    let days: [BatteryDay]
    let currentLevel: Int?

    var body: some View {
        let measured = days.filter(\.hasReadings)
        let totalUsed = measured.reduce(0) { $0 + $1.used }
        let perDay = measured.isEmpty ? 0 : Double(totalUsed) / Double(measured.count)
        HStack(spacing: 32) {
            stat("Used", "\(totalUsed)%", detail: "over \(measured.count) day\(measured.count == 1 ? "" : "s") with readings")
            stat("Average", perDay > 0 ? String(format: "%.1f%% a day", perDay) : "—", detail: nil)
            if let currentLevel, perDay >= 0.5 {
                stat("Lasts about", "\(Int((Double(currentLevel) / perDay).rounded())) more days", detail: "at this rate")
            }
            Spacer()
        }
    }

    private func stat(_ label: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold))
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

/// Battery level over the selected range, with a hover crosshair that snaps to the nearest reading.
struct BatteryLevelChart: View {
    let samples: [BatterySample]
    let domain: ClosedRange<Date>
    let threshold: Int
    let range: HistoryRange

    @State private var hovered: BatterySample?

    /// Readings more than this far apart are drawn as separate line segments instead of being joined.
    private static let gap: TimeInterval = 3 * 3600

    var body: some View {
        let segments = Self.segments(samples)
        Chart {
            ForEach(segments.indices, id: \.self) { index in
                let segment = segments[index]
                ForEach(segment, id: \.date) { sample in
                    AreaMark(
                        x: .value("Time", sample.date),
                        yStart: .value("Floor", 0),
                        yEnd: .value("Level", sample.level),
                        series: .value("Segment", index)
                    )
                    .foregroundStyle(ChartPalette.series.opacity(0.1))
                    LineMark(x: .value("Time", sample.date), y: .value("Level", sample.level), series: .value("Segment", index))
                        .foregroundStyle(ChartPalette.series)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if segment.count == 1, let lone = segment.first {
                    PointMark(x: .value("Time", lone.date), y: .value("Level", lone.level))
                        .foregroundStyle(ChartPalette.series)
                        .symbolSize(30)
                }
            }

            RuleMark(y: .value("Alert level", threshold))
                .foregroundStyle(ChartPalette.reference)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            if let hovered {
                RuleMark(x: .value("Time", hovered.date))
                    .foregroundStyle(ChartPalette.reference.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                // A surface-coloured ring keeps the marker legible on top of the line.
                PointMark(x: .value("Time", hovered.date), y: .value("Level", hovered.level))
                    .foregroundStyle(Color(nsColor: .controlBackgroundColor))
                    .symbolSize(150)
                PointMark(x: .value("Time", hovered.date), y: .value("Level", hovered.level))
                    .foregroundStyle(ChartPalette.series)
                    .symbolSize(64)
                    .annotation(position: .top, spacing: 8, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(hovered.level)%").font(.callout.weight(.semibold))
                            Text(hovered.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ChartPalette.grid)
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
            }
            // The alert line is labelled in the right-hand gutter so the label never sits on the data.
            AxisMarks(position: .trailing, values: [threshold]) { _ in
                AxisValueLabel { Text("Alert \(threshold)%") }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 7)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ChartPalette.grid)
                AxisValueLabel(format: range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geometry[plot].origin.x
                            guard let date: Date = proxy.value(atX: x) else { return }
                            hovered = samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .accessibilityLabel("Battery level, \(range.label.lowercased())")
    }

    static func segments(_ samples: [BatterySample]) -> [[BatterySample]] {
        var result: [[BatterySample]] = []
        for sample in samples {
            if let last = result.last?.last, sample.date.timeIntervalSince(last.date) <= gap {
                result[result.count - 1].append(sample)
            } else {
                result.append([sample])
            }
        }
        return result
    }
}

/// One day: how much was used, start and end level, a 24-hour chart, and the readings themselves.
private struct BatteryDayRow: View {
    let day: BatteryDay
    let threshold: Int

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Used").font(.caption).foregroundStyle(.secondary)
                Text("\(day.used)%").font(.title2.weight(.semibold))
            }
            .frame(width: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                if let start = day.startLevel, let end = day.endLevel {
                    Text("\(start)% → \(end)%")
                }
                if let lowest = day.lowestLevel {
                    Text("Lowest \(lowest)%").font(.caption).foregroundStyle(.secondary)
                }
                if day.charged > 0 {
                    Label("Charged +\(day.charged)%", systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            DayChart(day: day, threshold: threshold)
                .frame(width: 280, height: 76)
        }
        .padding(.vertical, 2)

        DisclosureGroup("Readings (\(day.samples.count))") {
            ForEach(day.samples.reversed(), id: \.date) { sample in
                HStack {
                    Text(sample.date.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(sample.level)%").monospacedDigit()
                }
                .font(.caption)
            }
        }
        .font(.callout)
    }
}

private struct DayChart: View {
    let day: BatteryDay
    let threshold: Int

    var body: some View {
        Chart {
            ForEach(day.chartSamples, id: \.date) { sample in
                AreaMark(x: .value("Time", sample.date), yStart: .value("Floor", 0), yEnd: .value("Level", sample.level))
                    .foregroundStyle(ChartPalette.series.opacity(0.1))
                LineMark(x: .value("Time", sample.date), y: .value("Level", sample.level))
                    .foregroundStyle(ChartPalette.series)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if day.chartSamples.count == 1, let lone = day.chartSamples.first {
                PointMark(x: .value("Time", lone.date), y: .value("Level", lone.level))
                    .foregroundStyle(ChartPalette.series)
                    .symbolSize(30)
            }
            RuleMark(y: .value("Alert level", threshold))
                .foregroundStyle(ChartPalette.reference.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
        .chartXScale(domain: day.start...day.end)
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ChartPalette.grid)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(ChartPalette.grid)
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .accessibilityLabel("Battery level during the day")
    }
}
