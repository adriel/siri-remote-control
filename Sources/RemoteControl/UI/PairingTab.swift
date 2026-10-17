import SwiftUI

struct PairingTab: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var hid: HIDRemoteManager
    @EnvironmentObject private var battery: BatteryMonitor
    @EnvironmentObject private var pairing: BluetoothPairing
    @State private var confirmUnpair: String?
    @State private var unpairMessage: String?

    var body: some View {
        Form {
            Section("Paired remotes") {
                if settings.knownRemotes.isEmpty && hid.devices.isEmpty {
                    Text("No Siri Remote has connected to this Mac yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(remoteRows, id: \.address) { row in
                    HStack(spacing: 12) {
                        Image(systemName: "appletvremote.gen4.fill")
                            .font(.title2)
                            .foregroundStyle(row.connected ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.model).fontWeight(.medium)
                            Text(row.address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(row.connected ? "Connected" : "Not connected (asleep or unpaired)")
                                .font(.caption)
                                .foregroundStyle(row.connected ? .green : .secondary)
                            if row.connected, let level = battery.reading?.level {
                                Text("Battery \(level)%").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Unpair…", role: .destructive) { confirmUnpair = row.address }
                    }
                }
                if let unpairMessage {
                    Text(unpairMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Bring the remote close to your Mac.")
                    step(2, "Hold **Back** and **Volume Up** together for about 5 seconds until it enters pairing mode.")
                    step(3, "Click **Find Remote** and then **Pair**, or connect it from Bluetooth Settings under Nearby Devices.")
                }
                .padding(.vertical, 4)

                HStack {
                    switch pairing.state {
                    case .scanning:
                        ProgressView().controlSize(.small)
                        Text("Looking for remotes in pairing mode…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { pairing.stopScan() }
                    case .connecting, .waitingForSystem:
                        ProgressView().controlSize(.small)
                        Text(stateText).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { pairing.cancel() }
                    default:
                        Button("Find Remote") { pairing.startScan() }
                        Button("Open Bluetooth Settings") { BluetoothPairing.openBluetoothSettings() }
                        Spacer()
                    }
                }

                ForEach(pairing.candidates) { candidate in
                    HStack {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(candidate.name)
                        Text("signal \(candidate.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Pair") { pairing.pair(candidate) }
                            .disabled(pairing.state != .scanning)
                    }
                }

                switch pairing.state {
                case let .paired(name):
                    Label("\(name) is paired and connected.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                default:
                    EmptyView()
                }
            } header: {
                Text("Pair a remote")
            } footer: {
                Text("A Siri Remote pairs with one device at a time. Pairing it to this Mac disconnects it from your Apple TV. To move it back, hold Back + Volume Up near the Apple TV.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Unpair this remote?", isPresented: Binding(get: { confirmUnpair != nil }, set: { if !$0 { confirmUnpair = nil } })) {
            Button("Unpair", role: .destructive) { if let address = confirmUnpair { unpair(address) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will forget the remote. You'll need to put it in pairing mode to use it again.")
        }
    }

    private struct RemoteRow {
        let address: String
        let model: String
        let connected: Bool
    }

    private var remoteRows: [RemoteRow] {
        var rows: [String: RemoteRow] = [:]
        for (address, model) in settings.knownRemotes {
            rows[address] = RemoteRow(address: address, model: model, connected: false)
        }
        for device in hid.devices {
            rows[device.address] = RemoteRow(address: device.address, model: device.modelName, connected: true)
        }
        return rows.values.sorted { $0.address < $1.address }
    }

    private var stateText: String {
        switch pairing.state {
        case let .connecting(name): "Connecting to \(name)…"
        case let .waitingForSystem(message): message
        default: ""
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.bold())
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
        }
    }

    private func unpair(_ address: String) {
        switch BluetoothPairing.unpair(address: address) {
        case .removed:
            settings.knownRemotes[address] = nil
            unpairMessage = "Asked macOS to forget \(address). If it still shows in Bluetooth Settings, remove it there."
            DiagnosticsLog.shared.add(.info, .pairing, "Unpaired \(address)")
        case .notFound:
            unpairMessage = "macOS doesn't list \(address) as paired. Removed it from this list."
            settings.knownRemotes[address] = nil
        case .unsupported:
            unpairMessage = "This macOS version doesn't allow unpairing from apps. Use Bluetooth Settings: click ⓘ next to the remote, then Forget This Device."
            BluetoothPairing.openBluetoothSettings()
        }
    }
}
