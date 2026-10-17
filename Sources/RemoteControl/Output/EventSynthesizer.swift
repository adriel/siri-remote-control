import AppKit
import CoreGraphics
import RemoteCore

/// Posts synthetic keyboard, mouse, scroll and media-key events. Needs the Accessibility permission;
/// without it macOS silently drops everything posted here.
@MainActor
final class EventSynthesizer {
    enum MouseButton { case left, right, middle }

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    enum MediaKey: Int32 {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case play = 16
        case next = 17
        case previous = 18
        case fast = 19
        case rewind = 20
    }

    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var leftDown = false
    private(set) var rightDown = false
    private(set) var middleDown = false
    private var lastClickAt: TimeInterval = 0
    private var lastClickPosition: CGPoint = .zero
    private var clickCount = 0
    private var virtualCursor: CGPoint?
    private var scrollRemainder = 0.0

    var anyMouseButtonDown: Bool { leftDown || rightDown || middleDown }

    // MARK: Media keys

    func mediaKey(_ key: MediaKey, modifiers: NSEvent.ModifierFlags = []) {
        postSystemDefined(key.rawValue, down: true, modifiers: modifiers)
        postSystemDefined(key.rawValue, down: false, modifiers: modifiers)
    }

    private func postSystemDefined(_ key: Int32, down: Bool, modifiers: NSEvent.ModifierFlags) {
        let flags = NSEvent.ModifierFlags(rawValue: (down ? 0xA00 : 0xB00) | modifiers.rawValue)
        let data1 = (Int(key) << 16) | ((down ? 0xA : 0xB) << 8)
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: 8, data1: data1, data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    func key(_ shortcut: KeyShortcut, down: Bool, autorepeat: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: down) else { return }
        event.flags = Self.flags(for: shortcut.modifiers)
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    func tapKey(_ shortcut: KeyShortcut) {
        key(shortcut, down: true)
        key(shortcut, down: false)
    }

    private static func flags(for modifiers: ModifierSet) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        return flags
    }

    // MARK: Mouse

    var cursorLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func moveCursor(dx: Double, dy: Double) {
        let actual = cursorLocation
        // Keep sub-pixel precision across moves unless the real mouse moved the cursor meanwhile.
        var base = actual
        if let v = virtualCursor, abs(v.x - actual.x) < 1.5, abs(v.y - actual.y) < 1.5 { base = v }
        let target = Self.clampToDisplays(CGPoint(x: base.x + dx, y: base.y + dy), from: actual)
        virtualCursor = target

        let type: CGEventType
        let button: CGMouseButton
        if leftDown { type = .leftMouseDragged; button = .left }
        else if rightDown { type = .rightMouseDragged; button = .right }
        else if middleDown { type = .otherMouseDragged; button = .center }
        else { type = .mouseMoved; button = .left }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        event.post(tap: .cghidEventTap)
    }

    func mouseButton(_ button: MouseButton, down: Bool) {
        let position = cursorLocation
        let type: CGEventType
        let cgButton: CGMouseButton
        switch (button, down) {
        case (.left, true): type = .leftMouseDown; cgButton = .left
        case (.left, false): type = .leftMouseUp; cgButton = .left
        case (.right, true): type = .rightMouseDown; cgButton = .right
        case (.right, false): type = .rightMouseUp; cgButton = .right
        case (.middle, true): type = .otherMouseDown; cgButton = .center
        case (.middle, false): type = .otherMouseUp; cgButton = .center
        }

        var clickState = 1
        if button == .left {
            if down {
                let now = ProcessInfo.processInfo.systemUptime
                let near = hypot(position.x - lastClickPosition.x, position.y - lastClickPosition.y) < 5
                clickCount = (now - lastClickAt <= NSEvent.doubleClickInterval && near) ? clickCount + 1 : 1
                lastClickAt = now
                lastClickPosition = position
            }
            clickState = max(clickCount, 1)
        }

        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)

        switch button {
        case .left: leftDown = down
        case .right: rightDown = down
        case .middle: middleDown = down
        }
    }

    func releaseAllMouseButtons() {
        if leftDown { mouseButton(.left, down: false) }
        if rightDown { mouseButton(.right, down: false) }
        if middleDown { mouseButton(.middle, down: false) }
    }

    /// Vertical pixel scroll. Positive scrolls up (towards the top of the document).
    func scroll(pixels: Double) {
        scrollRemainder += pixels
        let whole = scrollRemainder.rounded(.towardZero)
        guard whole != 0 else { return }
        scrollRemainder -= whole
        let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: Int32(whole), wheel2: 0, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    func resetScroll() { scrollRemainder = 0 }

    private static func clampToDisplays(_ point: CGPoint, from current: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let bounds = ids.map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(point) }) { return point }
        let home = bounds.first { $0.contains(current) } ?? bounds.first ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return CGPoint(x: min(max(point.x, home.minX), home.maxX - 1), y: min(max(point.y, home.minY), home.maxY - 1))
    }
}
