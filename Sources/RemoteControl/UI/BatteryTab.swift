import SwiftUI

struct BatteryTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var battery: BatteryMonitor
    @State private var notificationStatus: Permissions.Status = .notDetermined

    var body: some View {
        Form {
            Section("Siri Remote battery") {
                if let reading = battery.reading {
                    HStack(spacing: 16) {
                        Image(systemName: Self.symbol(for: reading.level))
                            .font(.system(size: 40))
                            .foregroundStyle(reading.level <= settings.batteryThreshold ? .red : .green)
                            .symbolRenderingMode(.hierarchical)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(reading.level)%").font(.system(size: 28, weight: .semibold)).monospacedDigit()
                            Text("Updated \(reading.date.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Refresh") { battery.refresh() }
                    }
                } else {
                    HStack {
                        Text("No battery reading yet. Press a button on the remote to wake it.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { battery.refresh() }
                    }
                }
            }

            Section {
                Toggle("Notify me when the battery is low", isOn: $settings.batteryAlertsEnabled)
                HStack {
                    Text("Alert at")
                    Slider(
                        value: Binding(get: { Double(settings.batteryThreshold) }, set: { settings.batteryThreshold = Int($0) }),
                        in: 5...50, step: 5
                    )
                    Text("\(settings.batteryThreshold)%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!settings.batteryAlertsEnabled)
                HStack {
                    Text("Notifications: \(notificationStatus.label)")
                        .foregroundStyle(notificationStatus == .granted ? Color.secondary : Color.orange)
                    Spacer()
                    if notificationStatus == .notDetermined {
                        Button("Allow Notifications") {
                            Task { _ = await Permissions.requestNotifications(); await refreshStatus() }
                        }
                    } else if notificationStatus == .denied {
                        Button("Open Notification Settings") { Permissions.open(.notifications) }
                    }
                    Button("Send Test Notification") {
                        Notifier.shared.post(id: "test", title: "Siri Remote battery low", body: "This is a test. You'll get an alert like this at \(settings.batteryThreshold)%.")
                    }
                }
            } header: {
                Text("Low battery alert")
            } footer: {
                Text("You get one alert each time the level drops to the threshold. It re-arms after the remote is charged above it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            BatteryHistorySections()
        }
        .formStyle(.grouped)
        .task { await refreshStatus() }
    }

    private func refreshStatus() async {
        notificationStatus = await Permissions.notifications()
    }

    private static func symbol(for level: Int) -> String {
        switch level {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}
