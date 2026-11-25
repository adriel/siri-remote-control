import RemoteCore
import SwiftUI

/// Battery tab: the settings for putting the remote to sleep, and how much battery it uses asleep vs connected.
struct RemoteSleepSections: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var sleeper: RemoteSleeper
    @EnvironmentObject private var batteryHistory: BatteryHistoryStore

    private static let idleChoices = [15, 30, 60, 120, 180]
    /// How far back the asleep/connected comparison looks.
    private static let comparisonWindow: TimeInterval = 14 * 86_400

    var body: some View {
        Section {
            status
            HStack {
                Toggle("Disconnect when idle for", isOn: $settings.sleepWhenIdle)
                Spacer()
                Picker("Idle time", selection: $settings.sleepIdleMinutes) {
                    ForEach(Self.idleChoices, id: \.self) { Text(RemoteSleeper.duration(TimeInterval($0 * 60))).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!settings.sleepWhenIdle)
            }
            Toggle("Disconnect as soon as the Mac wakes during the day", isOn: $settings.sleepOnDaytimeWake)
            HStack {
                Text("Daytime is from")
                Picker("From", selection: $settings.daytimeStartHour) { hours }.labelsHidden().fixedSize()
                Text("to")
                Picker("To", selection: $settings.daytimeEndHour) { hours }.labelsHidden().fixedSize()
                Spacer()
            }
            .disabled(!settings.sleepOnDaytimeWake)
        } header: {
            Text("Sleep the remote to save battery")
        } footer: {
            Text("macOS keeps the remote connected all the time, so its radio never fully rests. Remote Control can drop the Bluetooth link instead. Press any button to wake the remote: it reconnects in a second or two, and that first press may not do anything. The idle timer counts time the Mac was asleep, too.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            comparison
        } header: {
            Text("Does sleeping help?")
        } footer: {
            Text("Compares the last two weeks. The battery is reported in whole percent, so give it a week or so before reading much into it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Status

    @ViewBuilder private var status: some View {
        HStack(spacing: 10) {
            switch sleeper.state {
            case let .asleep(since):
                Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Asleep since \(Self.dayTime(since))")
                    Text("Press any button on the remote to wake it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            case .connected:
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected")
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("Last used \(RemoteSleeper.duration(max(0, context.date.timeIntervalSince(sleeper.lastActivity)))) ago")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Disconnect Now") { sleeper.sleepNow(reason: "disconnected from Settings") }
            case .dropping:
                ProgressView().controlSize(.small)
                Text("Disconnecting…")
                Spacer()
            case .disconnected:
                Image(systemName: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.secondary)
                Text("Not connected")
                Spacer()
            }
        }
        if let error = sleeper.lastError {
            Text("Last attempt failed: \(error)").font(.caption).foregroundStyle(.orange)
        }
    }

    private var hours: some View {
        ForEach(0..<24, id: \.self) { hour in
            Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())
                .map { $0.formatted(date: .omitted, time: .shortened) } ?? "\(hour):00").tag(hour)
        }
    }

    // MARK: Comparison

    @ViewBuilder private var comparison: some View {
        let now = Date()
        let stats = DrainComparison.compute(
            history: batteryHistory.history, sleep: sleeper.sleepLog,
            since: now.addingTimeInterval(-Self.comparisonWindow), now: now
        )
        if stats.sleepCount == 0 {
            Text("No sleeps yet. Once the remote has slept a few times, this compares its battery use asleep with connected.")
                .foregroundStyle(.secondary)
        } else {
            rateRow("While asleep", symbol: "moon.zzz", perDay: stats.asleepPerDay, hours: stats.asleepHours,
                    detail: "\(stats.sleepCount) \(stats.sleepCount == 1 ? "sleep" : "sleeps")")
            rateRow("While connected", symbol: "dot.radiowaves.left.and.right", perDay: stats.connectedPerDay, hours: stats.connectedHours,
                    detail: "includes the time you use it")
            let recent = sleeper.sleepLog.periods.suffix(6).reversed()
            ForEach(Array(recent)) { period in
                SleepPeriodRow(period: period, now: now)
            }
        }
    }

    private func rateRow(_ title: String, symbol: String, perDay: Double?, hours: Double, detail: String) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(perDay.map { String(format: "%.1f%% a day", $0) } ?? "Not enough data yet").monospacedDigit()
                Text(String(format: "%.0f h, %@", hours, detail)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func dayTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

private struct SleepPeriodRow: View {
    let period: SleepPeriod
    let now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(RemoteSleepSections.dayTime(period.start)) – \(endText)")
                Text(period.reason.prefix(1).uppercased() + period.reason.dropFirst()).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(RemoteSleeper.duration(period.duration(now: now))).monospacedDigit()
                Text(levels).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private var endText: String {
        guard let end = period.end else { return "now" }
        return Calendar.current.isDate(end, inSameDayAs: period.start)
            ? end.formatted(date: .omitted, time: .shortened)
            : RemoteSleepSections.dayTime(end)
    }

    private var levels: String {
        switch (period.levelAtStart, period.levelAtEnd) {
        case let (start?, end?): "\(start)% → \(end)%"
        case let (start?, nil): period.end == nil ? "from \(start)%" : "\(start)% → ?"
        default: ""
        }
    }
}
