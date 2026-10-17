import AppKit
import Combine
import RemoteCore

/// Routes remote input to actions according to the current mode and mapping.
@MainActor
final class RemoteController: ObservableObject {
    let settings: AppSettings
    let log: DiagnosticsLog
    let hid = HIDRemoteManager()
    let touch = MultitouchManager.shared
    let battery = BatteryMonitor()
    let batteryHistory: BatteryHistoryStore
    let pairing = BluetoothPairing()

    /// Buttons currently held down on the remote (for the live diagram and mapping highlight).
    @Published private(set) var pressedButtons: Set<RemoteButton> = []
    /// Most recent finger position in normalised surface coordinates (y up), nil when no finger is down.
    @Published private(set) var touchPoint: CGPoint?
    @Published private(set) var gesturePhase: TouchGestureRecognizer.Phase = .idle
    @Published private(set) var lastButtonEvent: String?

    private let synth = EventSynthesizer()
    private lazy var performer = ActionPerformer(synth: synth)
    private let recognizer = TouchGestureRecognizer()
    private var held: [RemoteButton: RemoteAction] = [:]
    private var repeatTimers: [RemoteButton: Timer] = [:]
    private var holdTimer: Timer?
    private var suppressMovementUntil: TimeInterval = 0
    private var lastMoveTime: TimeInterval?
    private var cancellables: Set<AnyCancellable> = []
    /// The clickpad region that was under the finger when the clickpad went down.
    private var clickpadHeld: RemoteButton?
    /// Last finger position and when it was seen, so a click right as the finger lands still finds a region.
    private var lastFinger: (point: CGPoint, time: TimeInterval)?
    private var touchFrameCount = 0
    private var touchStartTime: TimeInterval = 0
    private var warnedNoAccessibilityThisTouch = false
    private var permissionTimer: Timer?
    /// Per-touch totals for the Diagnostics summary logged at finger-up.
    private var touchMoved = CGVector.zero
    private var touchScrolled = 0.0

    /// Base cursor travel, in points, for a swipe across the full width of the surface.
    private static let pointsPerSurfaceWidth = 900.0
    /// Base scroll distance, in pixels, for one full circle.
    private static let pixelsPerRevolution = 1000.0

    init(batteryHistory: BatteryHistoryStore? = nil) {
        settings = .shared
        log = .shared
        self.batteryHistory = batteryHistory ?? BatteryHistoryStore()
    }

    func start() {
        hid.onButton = { [weak self] button, usage, pressed in self?.handleHIDButton(button, usage: usage, pressed: pressed) }
        hid.onDeviceConnected = { [weak self] remote in self?.remoteConnected(remote) }
        hid.onDeviceDisconnected = { [weak self] _ in self?.releaseEverything() }
        touch.onFrame = { [weak self] samples, time in self?.handleTouch(samples, at: time) }
        touch.onButtonState = { [weak self] new, old in self?.handleClickpadState(new: new, old: old) }
        battery.onReading = { [weak self] reading in self?.evaluateBattery(reading) }

        settings.$enabled.removeDuplicates().dropFirst().sink { [weak self] enabled in
            self?.applyEnabled(enabled)
        }.store(in: &cancellables)
        settings.$exclusiveAccess.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.restartInput() }
        }.store(in: &cancellables)
        settings.$holdToScrollDelay.sink { [weak self] delay in
            self?.recognizer.configuration.holdDuration = delay
        }.store(in: &cancellables)
        settings.$batteryThreshold.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.batteryThresholdChanged() }
        }.store(in: &cancellables)

        log.add(.info, .system, "Permissions: Accessibility \(Permissions.accessibility.label), Input Monitoring \(Permissions.inputMonitoring.label)")
        if Permissions.inputMonitoring == .notDetermined { Permissions.requestInputMonitoring() }
        if Permissions.accessibility != .granted { Permissions.requestAccessibility() }
        watchPermissions()

        battery.start()
        applyEnabled(settings.enabled)
    }

    func shutdown() {
        releaseEverything()
        hid.stop()
        touch.stop()
    }

    // MARK: Enable / mode

    func toggleEnabled() {
        settings.enabled.toggle()
        if settings.showModeHUD {
            HUD.shared.show(
                symbol: settings.enabled ? "appletvremote.gen4.fill" : "appletvremote.gen4",
                title: settings.enabled ? "Remote Control On" : "Remote Control Off"
            )
        }
    }

    private func applyEnabled(_ enabled: Bool) {
        releaseEverything()
        // While disabled the remote is still opened (shared) so Diagnostics can show presses,
        // but nothing is acted on and macOS keeps its default behaviour.
        hid.start(exclusive: enabled && settings.exclusiveAccess)
        touch.start()
        log.add(.info, .system, enabled ? "Remote Control enabled (\(settings.mode.shortName) mode)" : "Remote Control disabled. Presses are only logged.")
    }

    func restartInput() {
        releaseEverything()
        hid.stop()
        touch.stop()
        applyEnabled(settings.enabled)
    }

    func setMode(_ mode: RemoteMode) {
        guard mode != settings.mode else { return }
        releaseEverything()
        settings.mode = mode
        if settings.showModeHUD { HUD.shared.show(symbol: mode.symbolName, title: mode.displayName) }
        log.add(.info, .system, "Switched to \(mode.displayName)")
    }

    // MARK: Permissions

    /// macOS only applies newly granted Accessibility/Input Monitoring to a fresh process,
    /// so relaunch as soon as either flips to granted.
    private func watchPermissions() {
        var lastAX = Permissions.accessibility
        var lastIM = Permissions.inputMonitoring
        guard lastAX != .granted || lastIM != .granted else { return }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let ax = Permissions.accessibility
                let im = Permissions.inputMonitoring
                defer { lastAX = ax; lastIM = im }
                guard (ax == .granted && lastAX != .granted) || (im == .granted && lastIM != .granted) else { return }
                timer.invalidate()
                self?.log.add(.success, .system, "Permission granted. Relaunching so macOS applies it.")
                HUD.shared.show(symbol: "checkmark.shield", title: "Permission granted\nRestarting…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { AppRelauncher.relaunch() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: Buttons

    private func handleHIDButton(_ button: RemoteButton?, usage: HIDUsage, pressed: Bool) {
        guard let button else {
            log.add(.warning, .button, "Unrecognised HID usage \(usage) \(pressed ? "pressed" : "released"), no button mapped")
            return
        }
        handleButton(button, source: usage.description, pressed: pressed)
    }

    /// The clickpad's single switch, reported by MultitouchSupport. Which "button" it was comes from the finger position.
    private func handleClickpadState(new: UInt32, old: UInt32) {
        log.add(.info, .button, "Clickpad switch (multitouch) 0x\(String(old, radix: 16)) → 0x\(String(new, radix: 16))")
        let pressed = new != 0
        guard pressed != (old != 0) else { return }
        if pressed {
            let now = ProcessInfo.processInfo.systemUptime
            let point = touchPoint ?? lastFinger.flatMap { now - $0.time < 0.5 ? $0.point : nil }
            let button = point.map { SiriRemoteHID.clickpadButton(x: $0.x, y: $0.y) } ?? .select
            let position = point.map { String(format: "(%.2f, %.2f)", $0.x, $0.y) } ?? "unknown position"
            clickpadHeld = button
            handleButton(button, source: "click at \(position), state 0x\(String(new, radix: 16))", pressed: true)
        } else if let button = clickpadHeld {
            clickpadHeld = nil
            handleButton(button, source: "click", pressed: false)
        }
    }

    private func handleButton(_ button: RemoteButton, source: String, pressed: Bool) {
        let arrow = pressed ? "↓" : "↑"
        if pressed {
            guard !pressedButtons.contains(button) else { return }
            pressedButtons.insert(button)
            lastButtonEvent = "\(button.displayName) (\(source))"
        } else {
            pressedButtons.remove(button)
        }

        guard settings.enabled else {
            if pressed { log.add(.info, .button, "\(button.displayName) \(arrow) ignored: Remote Control is disabled") }
            return
        }

        if pressed {
            let mode = settings.mode
            let action = settings.mapping.action(for: button, in: mode)
            held[button] = action
            if mode == .trackpad, button.isClickpad {
                recognizer.cancelHold()
                suppressMovementUntil = ProcessInfo.processInfo.systemUptime + 0.12
            }
            switch action.kind {
            case .toggleMode: setMode(settings.mode.toggled)
            case .switchToRemoteMode: setMode(.remote)
            case .switchToTrackpadMode: setMode(.trackpad)
            default: break
            }
            let outcome = performer.perform(action, phase: .press)
            logPress(button, source: source, mode: mode, action: action, outcome: outcome)
            if action.kind.repeatsWhileHeld { startRepeating(button, action) }
        } else {
            stopRepeating(button)
            guard let action = held.removeValue(forKey: button) else { return }
            if button.isClickpad { suppressMovementUntil = ProcessInfo.processInfo.systemUptime + 0.08 }
            _ = performer.perform(action, phase: .release)
        }
    }

    private func logPress(_ button: RemoteButton, source: String, mode: RemoteMode, action: RemoteAction, outcome: ActionPerformer.Outcome?) {
        let prefix = "\(button.displayName) ↓ [\(source)] in \(mode.shortName) mode → \(action.displayName)"
        guard let outcome else {
            log.add(.info, .button, prefix)
            return
        }
        let level: DiagnosticsLog.Level = switch outcome.status {
        case .done: .success
        case .ignored: .info
        case .warning: .warning
        case .failed: .error
        }
        log.add(level, .button, "\(prefix): \(outcome.detail)")
    }

    private func startRepeating(_ button: RemoteButton, _ action: RemoteAction) {
        stopRepeating(button)
        let interval = action.kind == .keyboardShortcut ? 0.06 : 0.12
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.held[button] == action else { return }
                let repeating = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { _ = self?.performer.perform(action, phase: .repeatPress) }
                }
                RunLoop.main.add(repeating, forMode: .common)
                self.repeatTimers[button] = repeating
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimers[button] = timer
    }

    private func stopRepeating(_ button: RemoteButton) {
        repeatTimers.removeValue(forKey: button)?.invalidate()
    }

    /// Lets go of everything we're holding: keys, mouse buttons, repeat timers, gestures.
    private func releaseEverything() {
        for timer in repeatTimers.values { timer.invalidate() }
        repeatTimers.removeAll()
        for (_, action) in held { _ = performer.perform(action, phase: .release) }
        held.removeAll()
        pressedButtons.removeAll()
        clickpadHeld = nil
        synth.releaseAllMouseButtons()
        endGesture()
    }

    // MARK: Touch

    private func handleTouch(_ samples: [TouchSample], at time: TimeInterval) {
        let finger = samples.first(where: \.isTouching)
        let point = finger.map { CGPoint(x: $0.x, y: $0.y) }
        let trackpad = settings.enabled && settings.mode == .trackpad
        if let point {
            if touchPoint == nil {
                touchFrameCount = 0
                touchStartTime = time
                warnedNoAccessibilityThisTouch = false
                if trackpad { log.add(.info, .touch, String(format: "Finger down at (%.2f, %.2f)", point.x, point.y)) }
            }
            touchFrameCount += 1
            lastFinger = (point, time)
        } else if let last = touchPoint, trackpad {
            log.add(.info, .touch, String(format: "Finger up at (%.2f, %.2f) after %d frames", last.x, last.y, touchFrameCount))
        }
        touchPoint = point

        guard trackpad else {
            if recognizer.phase != .idle { endGesture() }
            return
        }
        let phaseBefore = recognizer.phase
        handleGesture(recognizer.process(samples, at: time), at: time)
        if phaseBefore == .pending, recognizer.phase == .moving {
            log.add(.info, .touch, String(
                format: "Finger moved after %.2f s, before the %.2f s hold, so this touch moves the pointer. Rest still a moment longer to scroll.",
                time - touchStartTime, recognizer.configuration.holdDuration
            ))
        }
        updateHoldTimer()
    }

    private func updateHoldTimer() {
        gesturePhase = recognizer.phase
        guard recognizer.phase == .pending else {
            holdTimer?.invalidate()
            holdTimer = nil
            return
        }
        guard holdTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.handleGesture(self.recognizer.tick(at: now), at: now)
                self.updateHoldTimer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func handleGesture(_ outputs: [GestureOutput], at time: TimeInterval) {
        for output in outputs {
            switch output {
            case .touchBegan:
                lastMoveTime = nil
                touchMoved = .zero
                touchScrolled = 0

            case let .move(dx, dy):
                guard time >= suppressMovementUntil else { continue }
                if !AXIsProcessTrusted() {
                    if !warnedNoAccessibilityThisTouch {
                        warnedNoAccessibilityThisTouch = true
                        log.add(.error, .touch, "Pointer movement dropped: Accessibility permission not granted")
                    }
                    continue
                }
                let dt = lastMoveTime.map { max(time - $0, 0.004) } ?? 0.016
                lastMoveTime = time
                let speed = hypot(dx, dy) / dt // surface widths per second
                let gain = Self.pointsPerSurfaceWidth * settings.cursorSpeed * (1 + settings.cursorAcceleration * min(speed, 4) * 0.6)
                // Surface y points up; screen y points down.
                synth.moveCursor(dx: dx * gain, dy: -dy * gain)
                touchMoved.dx += dx * gain
                touchMoved.dy -= dy * gain

            case .scrollArmed:
                synth.resetScroll()
                log.add(.info, .touch, "Hold detected: circle to scroll")
                if settings.showScrollIndicator { HUD.shared.showScrollIndicator(at: synth.cursorLocation) }

            case let .scroll(radians):
                // Clockwise (negative) scrolls down the page, like a click wheel.
                var pixels = radians / (2 * .pi) * Self.pixelsPerRevolution * settings.scrollSpeed
                if settings.reverseScroll { pixels = -pixels }
                synth.scroll(pixels: pixels)
                touchScrolled += pixels

            case let .touchEnded(wasScrolling):
                lastMoveTime = nil
                if wasScrolling {
                    let direction = touchScrolled < 0 ? "down the page" : "up the page"
                    log.add(.info, .touch, String(format: "Scrolled %.0f px %@", abs(touchScrolled), direction))
                } else if touchMoved != .zero {
                    log.add(.info, .touch, String(format: "Pointer moved Δx %+.0f pt, Δy %+.0f pt (screen, + is right/down)", touchMoved.dx, touchMoved.dy))
                }
                if wasScrolling { HUD.shared.hideScrollIndicator() }
            }
        }
        gesturePhase = recognizer.phase
    }

    private func endGesture() {
        let outputs = recognizer.reset()
        handleGesture(outputs, at: ProcessInfo.processInfo.systemUptime)
        holdTimer?.invalidate()
        holdTimer = nil
        HUD.shared.hideScrollIndicator()
    }

    // MARK: Devices & battery

    private func remoteConnected(_ remote: HIDRemoteManager.RemoteDevice) {
        if remote.address != "unknown" { settings.knownRemotes[remote.address] = remote.modelName }
        pairing.remoteDidConnect(name: remote.modelName)
        // The touch surface comes up alongside the button interface; make sure we're attached.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.touch.attachedCount == 0 else { return }
            self.touch.rescan()
        }
        battery.refresh()
    }

    private func evaluateBattery(_ reading: BatteryMonitor.Reading) {
        batteryHistory.record(level: reading.level, at: reading.date)
        let threshold = settings.batteryThreshold
        if reading.level <= threshold {
            guard settings.batteryAlertsEnabled, !settings.batteryAlertSent else { return }
            Notifier.shared.lowBattery(level: reading.level, threshold: threshold)
            settings.batteryAlertSent = true
            log.add(.warning, .battery, "Low battery alert sent (\(reading.level)% ≤ \(threshold)%)")
        } else if reading.level >= threshold + 3, settings.batteryAlertSent {
            settings.batteryAlertSent = false
        }
    }

    private func batteryThresholdChanged() {
        guard let reading = battery.reading else { return }
        if reading.level > settings.batteryThreshold { settings.batteryAlertSent = false }
        evaluateBattery(reading)
    }
}
