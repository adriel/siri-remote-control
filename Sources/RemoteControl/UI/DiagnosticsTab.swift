import AppKit
import RemoteCore
import SwiftUI

/// Snapshot of everything that can stop a press from working. Refreshed every couple of seconds while visible.
@MainActor
final class DiagnosticsModel: ObservableObject {
    struct Check: Identifiable {
        enum Status { case ok, warning, problem }
        let id: String
        let title: String
        let status: Status
        let detail: String
        var fix: (label: String, action: () -> Void)?
    }

    @Published private(set) var checks: [Check] = []
    @Published private(set) var clients: [SystemInspector.HIDClient] = []
    @Published private(set) var conflicts: [SystemInspector.ConflictingProcess] = []
    @Published private(set) var taps: [SystemInspector.EventTap] = []
    @Published private(set) var notificationStatus: Permissions.Status = .notDetermined

    func refresh(controller: RemoteController) async {
        notificationStatus = await Permissions.notifications()
        let productIDs = Set(controller.hid.devices.map(\.productID))
        clients = SystemInspector.remoteClients(productIDs: productIDs)
        conflicts = SystemInspector.conflictingProcesses()
        taps = SystemInspector.interceptingEventTaps()
        checks = buildChecks(controller)
    }

    private func buildChecks(_ controller: RemoteController) -> [Check] {
        var checks: [Check] = []
        let settings = controller.settings
        let remote = controller.hid.devices.first

        checks.append(Check(
            id: "enabled", title: "Remote Control enabled",
            status: settings.enabled ? .ok : .problem,
            detail: settings.enabled ? "\(settings.mode.displayName) is active." : "The app is off, so presses are only logged. Right-click the menu bar icon to turn it on.",
            fix: settings.enabled ? nil : ("Turn On", { settings.enabled = true })
        ))

        if let remote {
            checks.append(Check(id: "remote", title: "Remote connected", status: .ok, detail: "\(remote.modelName), \(remote.address)"))
            if !remote.isOpen {
                checks.append(Check(
                    id: "open", title: "Button input", status: .problem,
                    detail: "Couldn't open the remote's buttons: \(HIDRemoteManager.describe(remote.openResult)).",
                    fix: ("Retry", { controller.restartInput() })
                ))
            } else if settings.enabled && settings.exclusiveAccess && !remote.exclusive {
                checks.append(Check(
                    id: "open", title: "Button input", status: .warning,
                    detail: "Opened in shared mode, so macOS also reacts to presses (Music opening, double volume steps).",
                    fix: ("Retry", { controller.restartInput() })
                ))
            } else {
                checks.append(Check(id: "open", title: "Button input", status: .ok, detail: remote.exclusive ? "Exclusive. macOS's default actions are blocked." : "Shared access."))
            }
        } else {
            let since = controller.hid.lastDisconnect.map { " Last seen \($0.formatted(date: .omitted, time: .standard))." } ?? ""
            checks.append(Check(
                id: "remote", title: "Remote connected", status: .problem,
                detail: "No Siri Remote is connected. It sleeps after a few minutes. Press a button to wake it. The press that wakes it may be dropped.\(since)",
                fix: ("Pairing…", { NotificationCenter.default.post(name: .openSettingsTab, object: SettingsTab.pairing) })
            ))
        }

        let touchAttached = controller.touch.attachedCount > 0
        let lastFrame = controller.touch.lastFrameAt.map { " Last touch \($0.formatted(date: .omitted, time: .standard))." } ?? ""
        checks.append(Check(
            id: "touch", title: "Touch surface",
            status: touchAttached ? .ok : (remote == nil ? .warning : .problem),
            detail: touchAttached ? "Receiving touch frames.\(lastFrame)" : (controller.touch.loadError ?? "Not attached. Trackpad mode needs it."),
            fix: touchAttached ? nil : ("Rescan", { controller.touch.rescan() })
        ))

        let ax = Permissions.accessibility
        checks.append(Check(
            id: "ax", title: "Accessibility permission", status: ax == .granted ? .ok : .problem,
            detail: ax == .granted ? "Can post keys, clicks, scrolls and media keys." : "Without it macOS silently drops every key, click, scroll and media key this app sends.",
            fix: ax == .granted ? nil : ("Grant…", { Permissions.requestAccessibility(); Permissions.open(.accessibility) })
        ))

        let im = Permissions.inputMonitoring
        checks.append(Check(
            id: "im", title: "Input Monitoring permission", status: im == .granted ? .ok : .warning,
            detail: im == .granted ? "Can read the remote's buttons." : "May be needed to read the remote's buttons on this macOS version.",
            fix: im == .granted ? nil : ("Grant…", { Permissions.requestInputMonitoring(); Permissions.open(.inputMonitoring) })
        ))

        let others = clients.filter { !$0.isSystem }
        checks.append(Check(
            id: "clients", title: "Other apps using the remote",
            status: others.isEmpty ? .ok : .problem,
            detail: others.isEmpty ? "None." : others.map { "\($0.name) (\($0.interfaces.joined(separator: ", ")))" }.joined(separator: "; ") + ". They can grab presses before this app sees them."
        ))

        if let owner = SystemInspector.secureInputOwner() {
            checks.append(Check(
                id: "secure", title: "Secure Input", status: .warning,
                detail: "\(owner.name) has Secure Input on (usually a focused password field), so macOS blocks synthetic keystrokes until it's turned off."
            ))
        } else {
            checks.append(Check(id: "secure", title: "Secure Input", status: .ok, detail: "Off."))
        }

        let userTaps = taps.filter { !$0.isSystem }
        let systemTaps = taps.filter(\.isSystem)
        var tapDetail = userTaps.isEmpty
            ? "No other app is filtering input events."
            : userTaps.map { "\($0.processName) (\($0.intercepts.joined(separator: ", ")))" }.joined(separator: "; ") + " can change or swallow events."
        if !systemTaps.isEmpty {
            tapDetail += " macOS: " + systemTaps.map(\.processName).joined(separator: ", ") + " (normal)."
        }
        checks.append(Check(id: "taps", title: "Event interceptors", status: userTaps.isEmpty ? .ok : .warning, detail: tapDetail))

        return checks
    }
}

extension Notification.Name {
    static let openSettingsTab = Notification.Name("RemoteControl.openSettingsTab")
}

struct DiagnosticsTab: View {
    @EnvironmentObject private var controller: RemoteController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var log: DiagnosticsLog
    @EnvironmentObject private var hid: HIDRemoteManager
    @StateObject private var model = DiagnosticsModel()

    var body: some View {
        // No outer scroll view: the fixed-height parts sit at the top and the event log takes whatever height is left.
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 6) {
                        RemoteDiagramView(pressed: controller.pressedButtons, touch: controller.touchPoint)
                            .frame(width: 88, height: 264)
                        Text(controller.lastButtonEvent ?? "Press a button…")
                            .font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                        Text("Gesture: \(controller.gesturePhase.rawValue)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(width: 128)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Health checks").font(.headline)
                        LazyVGrid(
                            columns: [GridItem(.flexible(), spacing: 18, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            ForEach(model.checks) { check in CheckRow(check: check) }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)

                if !model.conflicts.isEmpty {
                    GroupBox("Apps known to interfere") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.conflicts) { app in
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    VStack(alignment: .leading) {
                                        Text(app.name).fontWeight(.medium)
                                        Text(app.reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if app.canQuit {
                                        Button("Quit \(app.name)") {
                                            SystemInspector.quit(pid: app.pid)
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { controller.restartInput() }
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(2)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox("Processes attached to the remote") {
                    VStack(alignment: .leading, spacing: 3) {
                        if model.clients.isEmpty {
                            Text("None besides this app.").foregroundStyle(.secondary)
                        }
                        ForEach(model.clients) { client in
                            HStack {
                                Text(client.name).fontWeight(client.isSystem ? .regular : .semibold)
                                Text(verbatim: "pid \(client.pid)").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(client.interfaces.joined(separator: ", ")).font(.caption)
                                Text(client.isSystem ? "macOS" : "third-party")
                                    .font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(client.isSystem ? Color.secondary.opacity(0.15) : Color.orange.opacity(0.25)))
                            }
                        }
                        Text("Play/Pause, Next and Previous go to whichever app macOS considers Now Playing. If nothing is playing, macOS may open Music.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(2)
                }
                .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Event log").font(.headline)
                            Spacer()
                            Toggle("Log raw input", isOn: $hid.rawLogging)
                                .toggleStyle(.checkbox)
                                .help("Logs every raw report from all of the remote's interfaces. Useful when a button does nothing at all.")
                            Button("Copy Report") { copyReport() }
                            Button("Clear") { log.clear() }
                        }
                        .padding(.bottom, 4)
                        ScrollViewReader { proxy in
                            List(log.entries.suffix(300)) { entry in
                                LogRow(entry: entry)
                                    .id(entry.id)
                                    .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            }
                            .listStyle(.plain)
                            .environment(\.defaultMinListRowHeight, 18)
                            .frame(minHeight: 90, maxHeight: .infinity)
                            .onChange(of: log.entries.last?.id) { _, id in
                                if let id { proxy.scrollTo(id, anchor: .bottom) }
                            }
                            .onAppear {
                                if let id = log.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                            }
                        }
                    }
                    .padding(2)
                }
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            while !Task.isCancelled {
                await model.refresh(controller: controller)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func copyReport() {
        var lines = ["Remote Control diagnostic report — \(Date().formatted())", ""]
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Enabled: \(settings.enabled), mode: \(settings.mode.rawValue), exclusive: \(settings.exclusiveAccess)")
        for device in hid.devices {
            lines.append("Remote: \(device.modelName) pid=0x\(String(device.productID, radix: 16)) addr=\(device.address) open=\(HIDRemoteManager.describe(device.openResult)) exclusive=\(device.exclusive)")
        }
        lines.append("")
        for check in model.checks { lines.append("[\(check.status)] \(check.title): \(check.detail)") }
        lines.append("")
        for client in model.clients { lines.append("Client: \(client.name) pid \(client.pid) — \(client.interfaces.joined(separator: ", "))") }
        for tap in model.taps { lines.append("Event tap: \(tap.processName) pid \(tap.pid)\(tap.isSystem ? " (system)" : "") — \(tap.intercepts.joined(separator: ", "))") }
        lines.append("")
        lines.append(log.text)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

private struct CheckRow: View {
    let check: DiagnosticsModel.Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).fontWeight(.medium)
                Text(check.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let fix = check.fix {
                Button(fix.label, action: fix.action).controlSize(.small)
            }
        }
    }

    private var icon: String {
        switch check.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .problem: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .ok: .green
        case .warning: .orange
        case .problem: .red
        }
    }
}

private struct LogRow: View {
    let entry: DiagnosticsLog.Entry
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.formatter.string(from: entry.date))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Image(systemName: entry.level.symbol)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(entry.category.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 50, alignment: .leading)
            Text(entry.message)
                .font(.system(size: 11))
                .textSelection(.enabled)
        }
    }

    private var color: Color {
        switch entry.level {
        case .info: .secondary
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}
