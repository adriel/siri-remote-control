import RemoteCore
import ServiceManagement
import SwiftUI

struct GeneralTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controller: RemoteController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable Remote Control", isOn: $settings.enabled)
                Picker("Mode", selection: Binding(get: { settings.mode }, set: { controller.setMode($0) })) {
                    ForEach(RemoteMode.allCases) { mode in
                        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .disabled(!settings.enabled)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Press the Siri (side) button to switch modes. Right-click the menu bar icon to turn the app on or off.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Toggle(isOn: $settings.exclusiveAccess) {
                    Text("Block macOS's default button actions")
                    Text("Takes exclusive access to the remote's buttons, so Play doesn't also open Music and volume doesn't change twice.")
                }
                Toggle("Show a banner when the mode changes", isOn: $settings.showModeHUD)
            }

            Section("Trackpad mode: cursor") {
                LabeledSlider(title: "Cursor speed", value: $settings.cursorSpeed, range: 0.2...3, format: "%.1f×")
                LabeledSlider(title: "Acceleration", value: $settings.cursorAcceleration, range: 0...3, format: "%.1f")
            }

            Section {
                LabeledSlider(title: "Hold before scrolling", value: $settings.holdToScrollDelay, range: 0.15...1.0, format: "%.2f s")
                LabeledSlider(title: "Scroll speed", value: $settings.scrollSpeed, range: 0.2...4, format: "%.1f×")
                Toggle("Reverse scroll direction", isOn: $settings.reverseScroll)
                Toggle("Show indicator by the cursor while scrolling", isOn: $settings.showScrollIndicator)
            } header: {
                Text("Trackpad mode: scrolling")
            } footer: {
                Text("Rest your finger on the clickpad without moving it, then draw circles. Clockwise scrolls down, anticlockwise scrolls up. Lift your finger to stop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't update the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack {
            Text(title).frame(width: 170, alignment: .leading)
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}
