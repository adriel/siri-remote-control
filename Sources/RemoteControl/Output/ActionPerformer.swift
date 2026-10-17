import AppKit
import Carbon
import RemoteCore

/// Carries out a `RemoteAction` for one phase of a button press and reports what happened.
@MainActor
final class ActionPerformer {
    enum Phase { case press, repeatPress, release }

    struct Outcome {
        enum Status { case done, ignored, warning, failed }
        let status: Status
        let detail: String
    }

    let synth: EventSynthesizer

    init(synth: EventSynthesizer) {
        self.synth = synth
    }

    func perform(_ action: RemoteAction, phase: Phase) -> Outcome? {
        if action.kind.needsAccessibility, !AXIsProcessTrusted() {
            return phase == .press
                ? Outcome(status: .failed, detail: "Accessibility permission not granted, so macOS drops synthetic events")
                : nil
        }

        switch action.kind {
        case .none:
            return phase == .press ? Outcome(status: .ignored, detail: "no action assigned") : nil

        case .volumeUp: return media(.soundUp, phase)
        case .volumeDown: return media(.soundDown, phase)
        case .volumeUpFine: return media(.soundUp, phase, fine: true)
        case .volumeDownFine: return media(.soundDown, phase, fine: true)
        case .mute: return media(.mute, phase)
        case .playPause: return media(.play, phase)
        case .nextTrack: return media(.next, phase)
        case .previousTrack: return media(.previous, phase)
        case .fastForward: return media(.fast, phase)
        case .rewind: return media(.rewind, phase)
        case .brightnessUp: return media(.brightnessUp, phase)
        case .brightnessDown: return media(.brightnessDown, phase)

        case .keyboardShortcut:
            guard let shortcut = action.shortcut else {
                return phase == .press ? Outcome(status: .ignored, detail: "no key chosen") : nil
            }
            switch phase {
            case .press: synth.key(shortcut, down: true)
            case .repeatPress: synth.key(shortcut, down: true, autorepeat: true)
            case .release: synth.key(shortcut, down: false)
            }
            guard phase == .press else { return nil }
            return keystrokeOutcome("sent \(shortcut.displayString)")

        case .leftClick: return mouse(.left, phase)
        case .rightClick: return mouse(.right, phase)
        case .middleClick: return mouse(.middle, phase)

        case .sleepDisplay:
            guard phase == .press else { return nil }
            run("/usr/bin/pmset", ["displaysleepnow"])
            return Outcome(status: .done, detail: "display sleep")

        case .lockScreen:
            guard phase == .press else { return nil }
            synth.tapKey(KeyShortcut(keyCode: KeyCatalog.q, modifiers: [.control, .command]))
            return Outcome(status: .done, detail: "sent ⌃⌘Q")

        case .missionControl:
            guard phase == .press else { return nil }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            return Outcome(status: .done, detail: "opened Mission Control")

        case .toggleMode, .switchToRemoteMode, .switchToTrackpadMode:
            return nil // handled by RemoteController
        }
    }

    private func media(_ key: EventSynthesizer.MediaKey, _ phase: Phase, fine: Bool = false) -> Outcome? {
        guard phase != .release else { return nil }
        // ⇧⌥ with the volume keys makes macOS step volume in quarters.
        synth.mediaKey(key, modifiers: fine ? [.shift, .option] : [])
        guard phase == .press else { return nil }
        if fine { return Outcome(status: .done, detail: "media key sent with ⇧⌥ (quarter step)") }
        if key == .play || key == .next || key == .previous {
            return Outcome(status: .done, detail: "media key sent to the Now Playing app")
        }
        return Outcome(status: .done, detail: "media key sent")
    }

    private func mouse(_ button: EventSynthesizer.MouseButton, _ phase: Phase) -> Outcome? {
        switch phase {
        case .press:
            synth.mouseButton(button, down: true)
            return Outcome(status: .done, detail: "mouse down at \(Self.format(synth.cursorLocation))")
        case .release:
            synth.mouseButton(button, down: false)
            return nil
        case .repeatPress:
            return nil
        }
    }

    private func keystrokeOutcome(_ detail: String) -> Outcome {
        let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? "frontmost app"
        if IsSecureEventInputEnabled() {
            let owner = SystemInspector.secureInputOwner().map { " by \($0.name)" } ?? ""
            return Outcome(status: .warning, detail: "\(detail) to \(target), but Secure Input is on\(owner), so keystrokes may be blocked")
        }
        return Outcome(status: .done, detail: "\(detail) to \(target)")
    }

    private func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }

    private static func format(_ p: CGPoint) -> String { "(\(Int(p.x)), \(Int(p.y)))" }
}
